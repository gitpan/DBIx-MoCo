package DBIx::MoCo;
use strict;
use warnings;
use base qw (Class::Data::Inheritable);
use DBIx::MoCo::List;
use DBIx::MoCo::Cache;
use Carp;
use Class::Trigger;

our $VERSION = '0.06';
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

__PACKAGE__->mk_classdata($_) for qw(cache_object db_object);
__PACKAGE__->mk_classdata($_) for qw(table primary_keys keys);
__PACKAGE__->add_trigger(after_create => \&_after_create);
__PACKAGE__->add_trigger(after_delete => \&_after_delete);
__PACKAGE__->add_trigger(after_update => \&_after_update);

__PACKAGE__->keys([]);
__PACKAGE__->cache_object('DBIx::MoCo::Cache');

my ($cache,$db,$session);

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
    $_->save for @{$session->{changed_objects}};
    $cache_status->{retrieved_oids} = [];
    $session = undef;
}

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

sub _after_create {
    my ($class, $self) = @_;
    $self or return;
    $class->cache($_, $self) for @{$self->object_ids};
    $class->_flush_belongs_to($self);
}

sub _after_delete {
    my ($class, $self) = @_;
    $self or return;
    #warn 'delete '.$self->object_id;
    $class->flush_cache($self);
    $class->_flush_belongs_to($self);
}

sub _after_update {}

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

sub object_id {
    my $self = shift;
    my $class = ref($self) || $self;
    $self = undef unless ref($self);
    my ($key, $col);
    if ($self && $self->{object_id}) {
        return $self->{object_id};
    } elsif ($self) {
        for (sort @{$class->primary_keys}) {
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

sub cache {
    my $class = shift;
    $class = ref($class) if ref($class);
    my ($k,$v) = @_;
    $cache ||= $class->cache_object->new;
    $cache->set($k => $v) if defined $v;
    return $cache->get($k);
}

sub db {
    my $class = shift;
    $class->db_object;
}

sub flush_cache {
    my $class = shift;
    my $o = shift or return;
    #warn "flush cache $o";
    $cache->remove($_) for @{$o->object_ids};
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
        if ($o && ($oid ne $o->object_id)) {
            my $oid2 = $o->object_id;
            if (defined $class->cache($oid2)) {
                $o = $class->cache($oid2);
            } else {
                $class->cache($oid2 => $o);
            }
        }
        $class->cache($oid => $o);
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
    my $res = $class->db->select($class->table,$class->primary_keys,
                                 $args{where},$args{order},\%args);
    return $res;
}

sub create {
    my $class = shift;
    my %args = @_;
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
    my %args;
    for (@{$class->primary_keys}) {
        $args{$_} = $self->{$_} or die "$self doesn't have $_";
    }
    $class->db->delete($class->table,\%args) or croak 'couldnt delete';
    $class->call_trigger('after_delete', $self);
    return 1;
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
    $class->db->delete($class->table,$args{where}) or croak 'couldnt delete';
    $class->call_trigger('after_delete', $_) for (@$caches);
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
        my @keys = split('_and_', $by);
        *$AUTOLOAD = $create ? $class->_retrieve_by_or_create_handler(@keys) :
            $class->_retrieve_by_handler(@keys);
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
            );
        } else {
            return $self->{$method};
        }
    }
}

sub _retrieve_by_handler {
    my $class = shift;
    my @keys = @_;
    return sub {
        my $self = shift;
        my %args;
        @args{@keys} = @_;
        $self->retrieve(%args);
    };
}

sub _retrieve_by_or_create_handler {
    my $class = shift;
    my @keys = @_;
    return sub {
        my $self = shift;
        my %args;
        @args{@keys} = @_;
        $self->retrieve(%args) || $class->create(%args);
    };
}

sub DESTROY {
    my $class = shift;
    $class->end_session;
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
    my @oids = ($self->object_id);
    for my $key (@{$class->keys}) {
        next unless $self->{$key};
        push @oids, $class->object_id($key => $self->{$key});
    }
    return \@oids;
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
  package Blog::TableObject;
  use base qw 'DBIx::MoCo'; # Inherit DBIx::MoCo

  __PACKAGE__->db_object('Blog::DataBase');

  1;

  # Third, create your models.
  package Blog::User;
  use base qw 'Blog::TableObject';

  __PACKAGE__->table('user');
  __PACKAGE__->primary_keys(['user_id']);
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
  use base qw 'Blog::TableObject';

  __PACKAGE__->table('entry');
  __PACKAGE__->primary_keys(['entry_id']);
  __PACKAGE__->keys(['uri']);
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
  use base qw 'Blog::TableObject';

  __PACKAGE__->table('bookmark');
  __PACKAGE__->primary_keys(['user_id','entry_id']);
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

=head1 SEE ALSO

L<SQL::Abstract>, L<Class::DBI>, L<Cache>,

=head1 AUTHOR

Junya Kondo, E<lt>jkondo@hatena.comE<gt>, Naoya Ito, E<lt>naoya@hatena.ne.jpE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) Hatena Inc. All Rights Reserved.

This library is free software; you may redistribute it and/or modify
it under the same terms as Perl itself.

=cut
