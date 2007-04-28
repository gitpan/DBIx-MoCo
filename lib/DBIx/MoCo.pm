package DBIx::MoCo;
use strict;
use warnings;
use base qw (Class::Data::Inheritable);
use DBIx::MoCo::Relation;
use DBIx::MoCo::List;
use DBIx::MoCo::Cache;
use DBIx::MoCo::Schema;
use DBIx::MoCo::Column;
use Carp;
use Class::Trigger;
use UNIVERSAL::require;
use Scalar::Util qw(weaken);

our $VERSION = '0.13';
our $AUTOLOAD;

my $cache_status = {
    retrieve_count => 0,
    retrieve_cache_count => 0,
    retrieve_all_count => 0,
    has_many_count => 0,
    has_many_cache_count => 0,
    retrieved_oids => [],
};
my ($cache,$db,$session);

__PACKAGE__->mk_classdata($_) for qw(cache_object db_object table
                                     retrieve_keys _schema);
__PACKAGE__->cache_object('DBIx::MoCo::Cache');

# SESSION & CACHE CONTROLLERS
__PACKAGE__->add_trigger(after_create => sub {
    my ($class, $self) = @_;
    $self or confess '$self is not specified';
    $class->store_self_cache($self);
    $class->flush_belongs_to($self);
});
__PACKAGE__->add_trigger(before_update => sub {
    my ($class, $self) = @_;
    $self or confess '$self is not specified';
    $class->flush_self_cache($self);
});
__PACKAGE__->add_trigger(after_update => sub {
    my ($class, $self) = @_;
    $self or confess '$self is not specified';
    $class->store_self_cache($self);
});
__PACKAGE__->add_trigger(before_delete => sub {
    my ($class, $self) = @_;
    $self or confess '$self is not specified';
    $class->flush_self_cache($self);
    $class->flush_belongs_to($self);
});

sub cache_status { $cache_status }

sub cache {
    my $class = shift;
    $class = ref($class) if ref($class);
    my ($k,$v) = @_;
    $cache ||= $class->cache_object->new;
    $cache->set($k => $v) if defined $v;
    return $cache->get($k);
}

sub flush_belongs_to {} # it's delivered from MoCo::Relation

sub flush_self_cache {
    my ($class, $self) = @_;
    if (!$self && ref $class) {
        $self = $class;
        $class = ref $self;
    }
    $self or confess '$self is not specified';
    for (@{$self->object_ids}) {
        # warn "flush $_";
        weaken($class->cache($_));
        $cache->remove($_);
    }
}

sub store_self_cache {
    my ($class, $self) = @_;
    if (!$self && ref $class) {
        $self = $class;
        $class = ref $self;
    }
    $self or confess '$self is not specified';
    # warn "store $_" for @{$self->object_ids};
    $class->cache($_, $self) for @{$self->object_ids};
}

# session controllers
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

# CLASS DEFINISION METHODS
sub relation { 'DBIx::MoCo::Relation' }
sub has_a {
    my $class = shift;
    $class->relation->register($class, 'has_a', @_);
}
sub has_many {
    my $class = shift;
    $class->relation->register($class, 'has_many', @_);
}
sub schema {
    my $class = shift;
    unless ($class->_schema) {
        $class->_schema(DBIx::MoCo::Schema->new($class));
    }
    return $class->_schema;
}

sub primary_keys { $_[0]->schema->primary_keys }
sub unique_keys { $_[0]->schema->unique_keys }
sub columns { $_[0]->schema->columns }

sub has_column {
    my $class = shift;
    my $col = shift or return;
    $class->columns or return;
    grep { $col eq $_ } @{$class->columns};
}

# DATA OPERATIONAL METHODS
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

sub db { $_[0]->db_object }

sub retrieve {
    my $cs = $cache_status;
    $cs->{retrieve_count}++;
    my $class = shift;
    my $oid = $class->object_id(@_);
    if (defined $class->cache($oid)) {
        # warn "use cache $oid";
        $cs->{retrieve_cache_count}++;
        return $class->cache($oid);
    } else {
        # warn "use db $oid";
        push @{$cs->{retrieved_oids}}, $oid if $class->is_in_session;
        my %args = $_[1] ? @_ : ($class->primary_keys->[0] => $_[0]);
        my $res = $class->db->select($class->table,'*',\%args);
        my $h = $res->[0];
        my $o = $h ? $class->new(%$h) : '';
        if ($o) {
            $class->store_self_cache($o);
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
    $args{table} = $class->table;
    $args{field} = join(',', @{$class->retrieve_keys || $class->primary_keys});
    my $res = $class->db->search(%args);
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

sub search {
    my $class = shift;
    my %args = @_;
    $args{table} = $class->table;
    my $res = $class->db->search(%args);
    $_ = $class->new(%$_) for (@$res);
    wantarray ? @$res :
        DBIx::MoCo::List->new($res);
}

sub count {
    my $class = shift;
    my $where = shift;
    $class->db->search(
        table => $class->table,
        field => 'COUNT(*) as count',
        where => $where || '',
    )->[0]->{count};
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
    } elsif ($method =~ /^(\w+)_as_(\w+)$/o) {
        my ($col,$as) = ($1,$2);
        *$AUTOLOAD = $class->_column_as_handler($col, $as);
    } elsif (defined $self->{$method} || $class->has_column($method)) {
        *$AUTOLOAD = sub { shift->param($method, @_) };
    } else {
        croak "undefined method $method";
    }
    goto &$AUTOLOAD;
}

{
    my $real_can = \&UNIVERSAL::can;
    no warnings 'redefine', 'once';
    *DBIx::MoCo::can = sub {
        my ($class, $method) = @_;
        if (my $sub = $real_can->(@_)) {
            # warn "found $method in $class";
            return $sub;
        }
        no strict 'refs';
        if (my $auto = *{$class . '::AUTOLOAD'}{CODE}) {
            return $auto;
        }
        $AUTOLOAD = $class . '::' . $method;
        eval {&DBIx::MoCo::AUTOLOAD(@_)} unless *$AUTOLOAD{CODE};
        return *$AUTOLOAD{CODE};
    };
}

sub _column_as_handler {
    my $class = shift;
    my ($colname, $as) = @_;
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
        my $column = $self->column($colname) or return;
        if (my $new = shift) {
            my $as_string = $as . '_as_string'; # e.g. URI_as_string
            my $v = $column->can($as_string) ?
                $column->$as_string($new) : scalar $new;
            $self->param($colname => $v);
        }
        $self->column($colname)->$as();
    }
}

sub column {
    my $self = shift;
    my $col = shift or return;
    my $v = $self->{$col} or return;
    return DBIx::MoCo::Column->new($v);
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

sub new {
    my $class = shift;
    my %args = @_;
    my $self = \%args;
    $self->{changed_cols} = {};
    bless $self, $class;
}

sub flush {
    my $self = shift;
    my $attr = shift or return;
    # warn "flush " . $self->object_id . '->' . $attr;
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

  # Now, You can use some methods same as Class::DBI.
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

=item flush_belongs_to

Flushes all caches whose have has_many arrays including the object.

=back

And, here are the triggers which call their functions.

=over 4

=item _after_create

Calls C<store_self_cache> and C<flush_belongs_to>.

=item _before_update

Calls C<flush_self_cache>.

=item _after_update

Calls C<store_self_cache>.

=item _before_delete

Calls C<flush_self_cache> and C<flush_belongs_to>.

=back

=head1 CLASS DEFINISION METHODS

Here are common methods related with class definisions.

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
You can define additional conditions as below.

  Blog::User->has_many(
    root_messages => 'Blog::Message', {
      key => {name => 'to_name'},
      condition => 'reference_id is null',
      order => 'modified desc',
    },
  );

C<condition> is additional sql statement will be used in where statement.
C<order> is used for specifying order statement.
In above case, SQL statement will be

  SELECT message_id FROM message
  WHERE to_name = 'myname' AND reference_id is null
  ORDER BY modified desc

And, all each results will be inflated as Blog::Message by retrieving
all records again (with using cache).

=item retrieve_keys

Defines keys for retrieving by retrieve_all etc.
If there aren't any unique keys in your table, please specify these keys.

  package Blog::Bookmark;

  __PACKAGE__->retrieve_keys(['user_id', 'entry_id']);
  # When user can add multiple bookmarks onto same entry.

=item primary_keys

Returns primary keys. Usually it returns them automatically by retrieving
schema data from database.
But you can also redefine this parameter by overriding this method.
It's useful when MoCo cannot get schema data from your dsn.

  sub primary_keys {['user_id']}

=item unique_keys

Returns unique keys including primary keys. You can override this as same as C<primary_keys>.

  sub unique_keys {['user_id','name']}

=item schema

Returns DBIx::MoCo::Schema object reference related with your model class.
You can set/get any parameters using Schema's C<param> method.
See L<DBIx::MoCo::Schema> for details.

=item columns

Returns array reference of column names.

=item has_column(col_name)

Returns which the table has the column or not.

=back

=head1 SESSION & CACHE METHODS

Here are common methods related with session.

=over 4

=item start_session

Starts session.

=item end_session

Ends session.

=item is_in_session

Returns DBIx::MoCo is in session or not.

=item cache_status

Returns cache status of the current session as a hash reference.
cache_status provides retrieve_count, retrieve_cache_count, retrieved_oids
retrieve_all_count, has_many_count, has_many_cache_count,

=item flush

Delete attribute from given attr. name.

=item save

Saves changed columns in the current session.

=back

=head1 DATA OPERATIONAL METHODS

Here are common methods related with operating data.

=over 4

=item retrieve

Retrieves an object and returns that using cache (if possible).

  my $u1 = Blog::User->retrieve(123); # retrieve by primary_key
  my $u2 = Blog::User->retrieve(user_id => 123); # same as above
  my $u3 = Blog::User->retrieve(name => 'jkondo'); # retrieve by name

=item retrieve_all

Returns results of given conditions as C<DBIx::MoCo::List> instance.

  my $users = Blog::User->retrieve_all(birthday => '2001-07-15');

=item retrieve_or_create

Retrieves a object or creates new record with given data and returns that.

  my $user = Blog::User->retrieve_or_create(name => 'jkondo');

=item create

Creates new object and returns that.

  my $user = Blog::User->create(
    name => 'jkondo',
    birthday => '2001-07-15',
  );

=item delete

Deletes a object. You can call C<delete> as both of class and instance method.

  $user->delte;
  Blog::User->delete($user);

=item delete_all

Deletes all records with given conditions. You should specify the conditions
as a hash reference.

  Blog::User->delete_all({birthday => '2001-07-15'});

=item search

Returns results of given conditions as C<DBIx::MoCo::List> instance.
You can specify search conditions in 3 diferrent ways. "Hash reference style",
"Array reference style" and "Scalar style".

Hash reference style is same as SQL::Abstract style and like this.

  Blog::User->search(where => {name => 'jkondo'});

Array style is the most flexible. You can use placeholder.

  Blog::User->search(
    where => ['name = ?', 'jkondo'],
  );
  Blog::User->search(
    where => ['name in (?,?)', 'jkondo', 'cinnamon'],
  );
  Blog::Entry->search(
    where => ['name = :name and date like :date'],
             name => 'jkondo', date => '2007-04%'],
  );

Scalar style is the simplest one, and most flexible in other word.

  Blog::Entry->search(
    where => "name = 'jkondo' and DATE_ADD(date, INTERVAL 1 DAY) > NOW()',
  );

You can also specify C<field>, C<order>, C<offset>, C<limit>, C<group> too.
Full spec search statement will be like the following.

  Blog::Entry->search(
    field => 'entry_id',
    where => ['name = ?', 'jkondo'],
    order => 'created desc',
    offset => 0,
    limit => 1,
    group => 'title',
  );

Search results will not be cached because MoCo expects that the conditions
for C<search> will be complicated and should not be cached.
You should use C<retrieve> or C<retrieve_all> method instead of C<search>
if you'll use simple conditions.

=item count

Returns the count of results matched with given conditions. You can specify
the conditions in same way as C<search>'s where spec.

  Blog::User->count({name => 'jkondo'}); # Hash reference style
  Blog::User->count(['name => ?', 'jkondo']); # Array reference style
  Blog::User->count("name => 'jkondo'"); # Scalar style

=item find

Similar to search, but returns only the first item as a reference (not as an array).

=item retrieve_by_column(_and_column2)

Auto generated method which returns an object by using key defined is method and given value.

  my $user = Blog::User->retrieve_by_name('jkondo');

=item retrieve_by_column(_and_column2)_or_create

Similar to retrieve_or_create.

  my $user = Blog::User->retrieve_by_name_or_create('jkondo');

=item retrieve_by_column_or_column2

Returns an object matched with given column names.

  my $user = Blog::User->retrieve_by_user_id_or_name('jkondo');

=item param

Set or get attribute from given attr. name.

=item set

Set attribute which is not related with DB schema or set temporary.

=item column_as_something

Inflate column value by using DBIx::MoCo::Column::* plugins.
If you set up your plugin like this,

  package DBIx::MoCo::Column::URI;

  sub URI {
    my $self = shift;
    return URI->new($$self);
  }

  sub URI_as_string {
    my $class = shift;
    my $uri = shift or return;
    return $uri->as_string;
  }

  1;

Then, you can use column_as_URI method as following,

  my $e = MyEntry->retrieve(..);
  print $e->uri; # 'http://test.com/test'
  print $e->uri_as_URI->host; # 'test.com';

  my $uri = URI->new('http://www.test.com/test');
  $e->uri_as_URI($uri); # set uri by using URI instance

The name of infrate method which will be imported must be same as the package name.

If you don't define "as string" method (such as C<URI_as_string>), 
scalar evaluated value of given argument will be used for new value instead.

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

=item quote

Quotes given string using DBI's quote method.

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

L<DBIx::MoCo::DataBase>, L<SQL::Abstract>, L<Class::DBI>, L<Cache>,

=head1 AUTHOR

Junya Kondo, E<lt>http://jkondo.vox.com/E<gt>,
Naoya Ito, E<lt>naoya@hatena.ne.jpE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) Hatena Inc. All Rights Reserved.

This library is free software; you may redistribute it and/or modify
it under the same terms as Perl itself.

=cut
