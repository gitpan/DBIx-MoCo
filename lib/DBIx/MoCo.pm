package DBIx::MoCo;
use strict;
use warnings;
use base qw (Class::Data::Inheritable);
use DBIx::MoCo::List;
use DBIx::MoCo::Cache;
use DBIx::MoCo::Schema;
use DBIx::MoCo::Column;
use Carp;
use Class::Trigger;
use UNIVERSAL::require;
use Scalar::Util qw(weaken);

our $VERSION = '0.10';
our $AUTOLOAD;
our $cache_status = {
    retrieve_count => 0,
    retrieve_cache_count => 0,
    retrieve_all_count => 0,
    has_many_count => 0,
    has_many_cache_count => 0,
    retrieved_oids => [],
};
# $cache_status provides ..
#  retrieve_count, retrieve_cache_count, retrieved_oids
#  retrieve_all_count, has_many_count, has_many_cache_count,

__PACKAGE__->mk_classdata($_) for qw(cache_object db_object table
                                     retrieve_keys _schema);

__PACKAGE__->add_trigger(after_create => \&_after_create);
__PACKAGE__->add_trigger(before_update => \&_before_update);
__PACKAGE__->add_trigger(after_update => \&_after_update);
__PACKAGE__->add_trigger(before_delete => \&_before_delete);

__PACKAGE__->cache_object('DBIx::MoCo::Cache');

my ($cache,$db,$session);

# Session
sub start_session {
    my $class = shift;
    $class->end_session if $class->is_in_session;
    $session = {
        changed_objects => [],
        pid => $$,
        created => time(),
    };
}

sub is_in_session { $session }
sub session { $session }

sub end_session {
    my $class = shift;
    $session or return;
    $class->save_changed;
    $cache_status->{retrieved_oids} = [];
    $session = undef;
}

sub save_changed {
    my $class = shift;
    $class->is_in_session or return;
    $_->save for @{$class->session->{changed_objects}};
}

sub _after_create {
    my ($class, $self) = @_;
    $self or return;
    $self->store_self_cache;
    $class->_flush_belongs_to($self);
}

sub _before_update {
    my ($class, $self) = @_;
    $self or return;
    $self->flush_self_cache;
}

sub _after_update {
    my ($class, $self) = @_;
    $self or return;
    $self->store_self_cache;
}

sub _before_delete {
    my ($class, $self) = @_;
    $self or return;
    #warn 'delete '.$self->object_id;
    $self->flush_self_cache;
    $class->_flush_belongs_to($self);
}

# Cache
sub cache_status { $cache_status };

sub _flush_belongs_to {
    my ($class, $self) = @_;
    $self or return;
    for my $attr (keys %{$class->has_a}) {
        my $ha = $class->has_a->{$attr};
        unless (defined $ha->{other_attrs}) {
            my $oa = [];
            for my $oattr (keys %{$ha->{class}->has_many}) {
                my $hm = $ha->{class}->has_many->{$oattr};
                if ($hm->{class} eq $class) {
                    push @$oa, $oattr;
                }
            }
            $ha->{other_attrs} = $oa;
            #warn join(' / ', %$ha);
        }
        for my $oattr (@{$ha->{other_attrs}}) {
            #warn "call $self->$attr->flush($oattr)";
            my $parent = $self->$attr() or next;
            $parent->flush($oattr);
        }
    }
}

sub cache {
    my $class = shift;
    $class = ref($class) if ref($class);
    my ($k,$v) = @_;
    $cache ||= $class->cache_object->new;
    $cache->set($k => $v) if defined $v;
    return $cache->get($k);
}

sub flush_self_cache {
    my $self = shift;
    my $class = ref $self or return;
    for (@{$self->object_ids}) {
        weaken($class->cache($_));
        $cache->remove($_);
    }
}

sub store_self_cache {
    my $self = shift;
    my $class = ref $self or return;
    $class->cache($_, $self) for @{$self->object_ids};
}

# Relations
sub _relationship {
    my $class = shift;
    my ($reltype, $attr, $model, $option) = @_;
    my $vname = $class . '::' . $reltype;
    no strict 'refs';
    $$vname ||= {};
    if ($attr && $model) {
        $$vname->{$attr} = {
            class => $model,
            option => $option || {},
        };
    }
    return $$vname;
}

sub has_a { shift->_relationship('has_a', @_) }
sub has_many { shift->_relationship('has_many', @_) }

# schema
sub schema {
    my $class = shift;
    unless ($class->_schema) {
        $class->_schema(DBIx::MoCo::Schema->new($class));
    }
    return $class->_schema;
}

sub primary_keys {
    my $class = shift;
    $class->schema->primary_keys;
}

sub unique_keys {
    my $class = shift;
    $class->schema->unique_keys;
}

sub columns {
    my $class = shift;
    $class->schema->columns;
}

sub has_column {
    my $class = shift;
    my $col = shift or return;
    $class->columns or return;
    grep { $col eq $_ } @{$class->columns};
}

# oid, db, create, retrieve..
sub object_id {
    my $self = shift;
    my $class = ref($self) || $self;
    $self = undef unless ref($self);
    my ($key, $col);
    if ($self && $self->{object_id}) {
        return $self->{object_id};
    } elsif ($self) {
        for (sort @{$class->retrieve_keys || $class->primary_keys}) {
            $self->{$_} or warn "$_ is undefined for $self" and return;
            $key .= "-$_-" . $self->{$_};
        }
        $key = $class . $key;
    } elsif ($_[3]) {
        my %args = @_;
        $key .= "-$_-$args{$_}" for (sort keys %args);
        $key = $class . $key;
    } elsif (@{$class->primary_keys} == 1) {
        my @args = @_;
        $col = $args[1] ? $args[0] : $class->primary_keys->[0];
        my $value = $args[1] ? $args[1] : $args[0];
        $key = $class . '-' . $col . '-' . $value;
    }
    return $key;
}

sub db {
    my $class = shift;
    $class->db_object;
}

sub retrieve {
    my $cs = $cache_status;
    $cs->{retrieve_count}++;
    my $class = shift;
    my $oid = $class->object_id(@_);
    if (defined $class->cache($oid)) {
        #warn "use cache $oid";
        $cs->{retrieve_cache_count}++;
        return $class->cache($oid);
    } else {
        #warn "use db $oid";
        push @{$cs->{retrieved_oids}}, $oid if $class->is_in_session;
        my %args = $_[1] ? @_ : ($class->primary_keys->[0] => $_[0]);
        my $res = $class->db->select($class->table,'*',\%args);
        my $h = $res->[0];
        my $o = $h ? $class->new(%$h) : '';
        if ($o) {
            $o->store_self_cache;
        } else {
            # $class->cache($oid => $o) if $o;
            $class->cache($oid => $o); # cache null object for performance.
        }
        return $o;
    }
}

sub retrieve_or_create {
    my $class = shift;
    my %args = @_;
    my %keys;
    @keys{@{$class->primary_keys}} = @args{@{$class->primary_keys}};
    $class->retrieve(%keys) || $class->create(%args);
}

sub retrieve_all {
    my $cs = $cache_status;
    $cs->{retrieve_all_count}++;
    my $class = shift;
    my %args = @_;
    my $result = [];
    my $list = $class->retrieve_all_id_hash(%args);
    push @$result, $class->retrieve(%$_) for (@$list);
    wantarray ? @$result :
        DBIx::MoCo::List->new($result);
}

sub retrieve_all_id_hash {
    my $class = shift;
    my %args = @_;
    ref $args{where} eq 'HASH' or die 'please specify where in hash';
    my $res = $class->db->select($class->table,
                                 $class->retrieve_keys || $class->primary_keys,
                                 $args{where},$args{order},\%args);
    return $res;
}

sub create {
    my $class = shift;
    my %args = @_;
    $class->call_trigger('before_create', \%args);
    my $o = $class->new(%args);
    if ($class->is_in_session && $o->has_primary_keys) {
        $o->set(to_be_inserted => 1);
        $o->changed_cols->{$_}++ for (keys %args);
        push @{$class->session->{changed_objects}}, $o;
    } else {
        $class->db->insert($class->table,\%args) or croak 'couldnt create';
        my $pk = $class->primary_keys->[0];
        unless ($args{$pk}) {
            my $id = $class->db->last_insert_id;
            $o->set($pk => $id);
        }
    }
    $class->call_trigger('after_create', $o);
    return $o;
}

sub delete {
    my $self = shift;
    my $class = ref($self) ? ref($self) : $self;
    $self = shift unless ref($self);
    $self or return;
    $self->call_trigger('before_delete', $self);
    my %args;
    for (@{$class->primary_keys}) {
        $args{$_} = $self->{$_} or die "$self doesn't have $_";
    }
    my $res = $class->db->delete($class->table,\%args) or croak 'couldnt delete';
    $self = undef;
    return $res;
}

sub delete_all {
    my $class = shift;
    my %args = @_;
    ref $args{where} eq 'HASH' or die 'please specify where in hash';
    my $list = $class->retrieve_all_id_hash(%args);
    my $caches = [];
    for (@$list) {
        my $oid = $class->object_id(%$_);
        my $c = $class->cache($oid) or next;
        push @$caches, $c;
    }
    $class->call_trigger('before_delete', $_) for (@$caches);
    $class->db->delete($class->table,$args{where}) or croak 'couldnt delete';
    return 1;
}

sub count {
    my $class = shift;
    my $args;
    if (ref($_[0]) eq 'HASH') { # for FormValidator::Simple::Plugin::DBIC::UNIQUE
        $args = shift;
    } else {
        %$args = @_;
    }
    $class->db->select($class->table,'count(*) as count',$args)->[0]->{count};
}

sub search {
    my $class = shift;
    my %args = @_;
    $args{table} = $class->table;
    my $res = $class->db->search(%args);
    $_ = $class->new(%$_) for (@$res);
    wantarray ? @$res :
        DBIx::MoCo::List->new($res);
}

sub find {
    my $class = shift;
    my $where = shift or return;
    $class->search(
        where => $where,
        offset => 0,
        limit => 1,
    )->first;
}

sub quote {
    my $class = shift;
    $class->db->dbh->quote(shift);
}

# new
sub new {
    my $class = shift;
    my %args = @_;
    my $self = \%args;
    $self->{changed_cols} = {};
    bless $self, $class;
}

# AUTOLOAD
sub AUTOLOAD {
    my $self = $_[0];
    my $class = ref($self) || $self;
    $self = undef unless ref($self);
    (my $method = $AUTOLOAD) =~ s!.+::!!;
    return if $method eq 'DESTROY';
    no strict 'refs';
    if ($method =~ /^retrieve_by_(.+?)(_or_create)?$/o) {
        my ($by, $create) = ($1,$2);
        *$AUTOLOAD = $create ? $class->_retrieve_by_or_create_handler($by) :
            $class->_retrieve_by_handler($by);
    } elsif ($method =~ /^(\w+)_as_(\w+)$/) {
        my ($col,$as) = ($1,$2);
        *$AUTOLOAD = $class->_column_as_handler($col,$as);
    } elsif ($class->has_a->{$method}) {
        *$AUTOLOAD = $class->_has_a_handler($method);
    } elsif ($class->has_many->{$method}) {
        *$AUTOLOAD = $class->_has_many_handler($method);
#    } elsif (defined $self->{$method}) {
    } else {
        *$AUTOLOAD = sub { shift->param($method, @_) };
    }
    goto &$AUTOLOAD;
}

sub _column_as_handler {
    my $class = shift;
    my ($col,$as) = @_;
    unless (DBIx::MoCo::Column->can($as)) {
        my $plugin = "DBIx::MoCo::Column::$as";
        $plugin->require;
        croak "Couldn't load column plugin $plugin: $@"  if $@;
        {
            no strict 'refs';
            push @{"DBIx::MoCo::Column::ISA"}, $plugin;
        }
    }
    return sub {
        my $self = shift;
        my $v = $self->$col or return;
        $self->column($col)->$as();
    }
}

sub _has_a_handler {
    my $class = shift;
    my $method = shift;
    my $rel = $class->has_a->{$method} or return;
    return sub {
        my $self = shift;
        unless (defined $self->{$method}) {
            my $key = $rel->{option}->{key} or return;
            if (ref($key) eq 'HASH') {
                ($key) = keys %$key;
            }
            my $id = $self->{$key} or return;
            $self->{$method} = $rel->{class}->retrieve($id);
        }
        return $self->{$method};
    }
}

sub _has_many_handler {
    my $class = shift;
    my $method = shift;
    my $rel = $class->has_many->{$method} or return;
    return sub {
        my $cs = $cache_status;
        $cs->{has_many_count}++;
        my $self = shift;
        my $off = shift || 0;
        my $lt = shift;
        my $max_off = $lt ? $off + $lt : -1;
        my $max_key = $method . '_max_offset';
        if (defined $self->{$method} && (
            $self->{$max_key} == -1 ||
                (0 <= $max_off && $max_off <= $self->{$max_key}) )) {
            #warn "$method cache($self->{$max_key}) is in range $max_off";
            $cs->{has_many_cache_count}++;
        } else {
            my $key = $rel->{option}->{key} or return;
            my ($k, $v);
            if (ref $key eq 'HASH') {
                my $my_key;
                ($my_key, $k) = %$key;
                $v = $self->{$my_key} or return;
            } else {
                $k = $key;
                $v = $self->{$k} or return;
            }
            $self->{$method} = $rel->{class}->retrieve_all(
                where => {$k => $v},
                order => $rel->{option} ? $rel->{option}->{order} || '' : '',
                limit => $max_off > 0 ? $max_off : '',
            );
            $self->{$max_key} = $max_off;
        }
        if (defined $off && $lt) {
            return DBIx::MoCo::List->new(
                [@{$self->{$method}}[$off .. $max_off - 1]],
            )->compact;
        } else {
            return $self->{$method};
        }
    }
}

sub _retrieve_by_handler {
    my $class = shift;
    my $by = shift or return;
    if ($by =~ /.+_or_.+/) {
        my @keys = split('_or_', $by);
        return sub {
            my $self = shift;
            my $v = shift;
            for (@keys) {
                my $o = $self->retrieve($_ => $v);
                return $o if $o;
            }
        };
    } else {
        my @keys = split('_and_', $by);
        return sub {
            my $self = shift;
            my %args;
            @args{@keys} = @_;
            $self->retrieve(%args);
        };
    }
}

sub _retrieve_by_or_create_handler {
    my $class = shift;
    my $by = shift or return;
    my @keys = split('_and_', $by);
    return sub {
        my $self = shift;
        my %args;
        @args{@keys} = @_;
        return $self->retrieve(%args) || $class->create(%args);
    };
}

sub DESTROY {
    my $class = shift;
    $class->save_changed;
}

# Instance methods
sub flush {
    my $self = shift;
    my $attr = shift or return;
    #warn "flush " . $self->object_id . '->' . $attr;
    $self->{$attr} = undef;
}

sub param {
    my $self = shift;
    my $class = ref $self or return;
    return $self->{$_[0]} unless defined($_[1]);
    @_ % 2 and croak "You gave me an odd number of parameters to param()!";
    $class->call_trigger('before_update', $self);
    my %args = @_;
    $self->{$_} = $args{$_} for (keys %args);
    if ($class->is_in_session) {
        $self->{to_be_updated}++;
        $self->{changed_cols}->{$_}++ for (keys %args);
        push @{$class->session->{changed_objects}}, $self;
    } else {
        my %where;
        for (@{$class->primary_keys}) {
            $where{$_} = $self->{$_} or return;
        }
        $class->db->update($class->table,\%args,\%where) or croak 'couldnt update';
    }
    $class->call_trigger('after_update', $self);
    return 1;
}

sub column {
    my $self = shift;
    my $col = shift or return;
    my $v = $self->{$col} or return;
    return DBIx::MoCo::Column->new($v);
}

sub set {
    my $self = shift;
    my ($k,$v) = @_;
    $self->{$k} = $v;
}

sub has_primary_keys {
    my $self = shift;
    my $class = ref $self;
    for (@{$class->primary_keys}) {
        $self->{$_} or return;
    }
    return 1;
}

sub save {
    my $self = shift;
    my $class = ref $self;
    keys %{$self->{changed_cols}} or return;
    my %args;
    for (keys %{$self->{changed_cols}}) {
        defined $self->{$_} or croak "$_ is undefined";
        $args{$_} = $self->{$_};
    }
    if ($self->{to_be_inserted}) {
        $class->db->insert($class->table,\%args);
        $self->{changed_cols} = {};
        $self->{to_be_inserted} = undef;
    } elsif ($self->{to_be_updated}) {
        my %where;
        for (@{$class->primary_keys}) {
            $where{$_} = $self->{$_} or croak "$_ is undefined";
        }
        $class->db->update($class->table,\%args,\%where);
        $self->{changed_cols} = {};
        $self->{to_be_updated} = undef;
    }
}

sub object_ids { # returns all possible oids
    my $self = shift;
    my $class = ref $self or return;
    my $oids = {};
    $oids->{$self->object_id} = 1 if $self->object_id;
    for my $key (@{$class->unique_keys}) {
        next unless $self->{$key};
        my $oid = $class->object_id($key => $self->{$key}) or next;
        $oids->{$oid}++;
    }
    return [sort keys %$oids];
}

1;

__END__

=head1 NAME

DBIx::MoCo - Light & Fast Model Component

=head1 SYNOPSIS

  # First, set up your db.
  package Blog::DataBase;
  use base qw(DBIx::MoCo::DataBase);

  __PACKAGE__->dsn('dbi:mysql:dbname=blog');
  __PACKAGE__->username('test');
  __PACKAGE__->password('test');

  1;

  # Second, create a base class for all models.
  package Blog::MoCo;
  use base qw 'DBIx::MoCo'; # Inherit DBIx::MoCo
  use Blog::DataBase;

  __PACKAGE__->db_object('Blog::DataBase');

  1;

  # Third, create your models.
  package Blog::User;
  use base qw 'Blog::MoCo';

  __PACKAGE__->table('user');
  __PACKAGE__->has_many(
      entries => 'Blog::Entry',
      { key => 'user_id' }
  );
  __PACKAGE__->has_many(
      bookmarks => 'Blog::Bookmark',
      { key => 'user_id' }
  );

  1;

  package Blog::Entry;
  use base qw 'Blog::MoCo';

  __PACKAGE__->table('entry');
  __PACKAGE__->has_a(
      user => 'Blog::User',
      { key => 'user_id' }
  );
  __PACKAGE__->has_many(
      bookmarks => 'Blog::Bookmark',
      { key => 'entry_id' }
  );

  1;

  package Blog::Bookmark;
  use base qw 'Blog::MoCo';

  __PACKAGE__->table('bookmark');
  __PACKAGE__->has_a(
      user => 'Blog::User',
      { key => 'user_id' }
  );
  __PACKAGE__->has_a(
      entry => 'Blog::Entry',
      { key => 'entry_id' }
  );

  1;

  # Now, You can use some methods same as in Class::DBI.
  # And, all objects are stored in cache automatically.
  my $user = Blog::User->retrieve(user_id => 123);
  print $user->name;
  $user->name('jkontan'); # update db immediately
  print $user->name; # jkontan

  my $user2 = Blog::User->retrieve(user_id => 123);
  # $user is same as $user2

  # You can easily get has_many objects array.
  my $entries = $user->entries;
  my $entries2 = $user->entries;
  # $entries is same reference as $entries2
  my $entry = $entries->first; # isa Blog::Entry
  print $entry->title; # you can use methods in Entry class.

  Blog::Entry->create(
    user_id => 123,
    title => 'new entry!',
  );
  # $user->entries will be flushed automatically.
  my $entries3 = $user->entries;
  # $entries3 isnt $entries

  print ($entries->last eq $entries2->last); # 1
  print ($entries->last eq $entries3->last); # 1
  # same instance

  # You can delay update/create query to database using session.
  DBIx::MoCo->start_session;
  $user->name('jkondo'); # not saved now. changed in cache.
  print $user->name; # 'jkondo'
  $user->save; # update db
  print Blog::User->retrieve(123)->name; # 'jkondo'

  # Or, update queries will be thrown automatically after ending session.
  $user->name('jkontan');
  DBIx::MoCo->end_session;
  print Blog::User->retrieve(123)->name; # 'jkontan'

=head1 DESCRIPTION

Light & Fast Model Component

=head1 CACHE ALGORITHM

MoCo caches objects effectively.
There are 3 functions to control MoCo's cache. Their functions are called 
appropriately when some operations are called to a particular object.

Here are the 3 functions.

=over 4

=item store_self_cache

Stores self instance for all own possible object ids.

=item flush_self_cache

Flushes all caches for all own possible object ids.

=item _flush_belongs_to

Flushes all caches whose have has_many arrays including the object.

=back

And, here are the triggers which call their functions.

=over 4

=item _after_create

Calls C<store_self_cache> and C<_flush_belongs_to>.

=item _before_update

Calls C<flush_self_cache>.

=item _after_update

Calls C<store_self_cache>.

=item _before_delete

Calls C<flush_self_cache> and C<_flush_belongs_to>.

=back

=head1 CLASS METHODS

Here are common class methods of DBIx::MoCo.

=over 4

=item add_trigger

Adds triggers. Here are the types which called from DBIx::MoCo.

  before_create
  after_create
  before_update
  after_update
  before_delete

You can add your trigger like this.

  package Blog::User;
  __PACKAGE__->add_trigger(before_create => sub
    my ($class, $args) = @_;
    $args->{name} .= '-san';
  });

  # in your scripts
  my $u = Blog::User->create(name => 'ishizaki');
  is ($u->name, 'ishizaki-san'); # ok.

C<before_create> passes a hash reference of new object data as the
second argument, and all other triggers pass the instance C<$self>.

=item has_a

Defines has_a relationship between 2 models.

=item has_many

Defines has_many relationship between 2 models.

=item retrieve_keys

Defines keys for retrieving by retrieve_all etc.
If there aren't any unique keys in your table, please specify these keys.

  package Blog::Bookmark;

  __PACKAGE__->retrieve_keys(['user_id', 'entry_id']);
  # When user can add multiple bookmarks onto same entry.

=item start_session

=item end_session

=item is_in_session

=item cache_status

Returns cache status hash reference.
cache_status provides retrieve_count, retrieve_cache_count, retrieved_oids
retrieve_all_count, has_many_count, has_many_cache_count,

=item cache

Set or get cache.

=item schema

Returns DBIx::MoCo::Schema object reference related with your model class.

=item primary_keys

=item unique_keys

=item columns

=item has_column(col_name)

Returns which the table has the column or not.

=item retrieve

=item retrieve_or_create

=item retrieve_all

=item retrieve_all_id_hash

=item create

=item delete_all

=item count

=item search

=item find

Similar to search, but returns only the first item as a reference (not array).

=item retrieve_by_column(_and_column2)

=item retrieve_by_column(_and_column2)_or_create

=item retrieve_by_column_or_column2

=item column_as_something

Inflate column value by using DBIx::MoCo::Column::* plugins.
If you set up your plugin like this,

  package DBIx::MoCo::Column::MyColumn;

  sub MyColumn {
    my $self = shift;
    return "My Column $$self";
  }

  1;

Then, you can use column_as_MyColumn method

  my $o = MyObject->retrieve(..);
  print $o->name; # "jkondo"
  print $o->name_as_MyColumn; # "My Column jkondo";

You can also inflate your column value with blessing with other classes.
Method name which will be imported must be same as the package name.

=item has_a, has_many auto generated methods

If you define has_a, has_many relationships,

  package Blog::Entry;
  use base qw 'Blog::MoCo';

  __PACKAGE__->table('entry');
  __PACKAGE__->has_a(
      user => 'Blog::User',
      { key => 'user_id' }
  );
  __PACKAGE__->has_many(
      bookmarks => 'Blog::Bookmark',
      { key => 'entry_id' }
  );

You can use those keys as methods.

  my $e = Blog::Entry->retrieve(..);
  print $e->user; # isa Blog::User
  print $e->bookmarks; # isa ARRAY of Blog::Bookmark

=back

=head1 CLASS OR INSTANCE METHODS

Here are common class or instance methods of DBIx::MoCo.

=over 4

=item object_id

=item delete

=item quote

=back

=head1 INSTANCE METHODS

Here are common instance methods of DBIx::MoCo.

=over 4

=item flush_self_cache

Flush caches for self possible object ids.

=item store_self_cache

Store self into cache for possible object ids.

=item flush

Delete attribute from given attr. name.

=item param

Set or get attribute from given attr. name.

=item set

Set attribute which is not related with DB schema or set temporary.

=item has_primary_keys

=item save

Saves changed columns in session.

=item object_ids

Returns all possible object-ids.

=back

=head1 FORM VALIDATION

You can validate user parameters using moco's schema.
For example you can define your validation profile using param like this,

  package Blog::User;

  __PACKAGE__->schema->param([
    name => ['NOT_BLANK', 'ASCII', ['DBIC_UNIQUE', 'Blog::User', 'name']],
    mail => ['NOT_BLANK', 'EMAIL_LOOSE'],
  ]);

And then,

  # In your scripts
  sub validate {
    my $self = shift;
    my $q = $self->query;
    my $prof = Blog::User->schema->param('validation');
    my $result = FormValidator::Simple->check($q => $prof);
    # handle errors ...
  }

=head1 SEE ALSO

L<SQL::Abstract>, L<Class::DBI>, L<Cache>,

=head1 AUTHOR

Junya Kondo, E<lt>http://jkondo.vox.com/E<gt>,
Naoya Ito, E<lt>naoya@hatena.ne.jpE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) Hatena Inc. All Rights Reserved.

This library is free software; you may redistribute it and/or modify
it under the same terms as Perl itself.

=cut
