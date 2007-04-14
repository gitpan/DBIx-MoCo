package DBIx::MoCo::DataBase;
use strict;
use warnings;
use Carp;
use base qw (Class::Data::Inheritable);
use DBI;
use SQL::Abstract;

__PACKAGE__->mk_classdata($_) for qw(dsn username password
                                     cache_connection last_insert_id);
__PACKAGE__->cache_connection(1);

our $DEBUG = 0;

my $sqla = SQL::Abstract->new;

sub insert {
    my $class = shift;
    my ($table, $args) = @_;
    my ($sql, @binds) = $sqla->insert($table,$args);
    carp $sql . '->execute(' . join(',', @binds) . ')' if $DEBUG;
    $class->execute($sql,undef,\@binds);
}

sub delete {
    my $class = shift;
    my ($table, $where) = @_;
    ref $where eq 'HASH' or croak 'where must be a HASH';
    my ($sql, @binds) = $sqla->delete($table,$where);
    carp $sql . '->execute(' . join(',', @binds) . ')' if $DEBUG;
    $class->execute($sql,undef,\@binds);
}

sub update {
    my $class = shift;
    my ($table, $args, $where) = @_;
    my ($sql, @binds) = $sqla->update($table,$args,$where);
    carp $sql . '->execute(' . join(',', @binds) . ')' if $DEBUG;
    $class->execute($sql,undef,\@binds);
}

sub select {
    my $class = shift;
    my ($table, $args, $where, $order, $limit) = @_;
    my ($sql, @binds) = $sqla->select($table,$args,$where,$order);
    $sql .= $class->_parse_limit($limit) if $limit;
    carp $sql . '->execute(' . join(',', @binds) . ')' if $DEBUG;
    my $data;
    $class->execute($sql,\$data,\@binds) or return;
    return $data;
}

sub search {
    my $class = shift;
    my %args = @_;
    my ($sql, @binds) = $class->_search_sql(\%args);
    carp $sql . '->execute(' . join(',', @binds) . ')' if $DEBUG;
    my $data;
    $class->execute($sql,\$data,\@binds) or return;
    return $data;
}

sub _search_sql {
    my $class = shift;
    my $args = shift;
    my $field = $args->{field} || "*";
    my $sql = "SELECT $field FROM " . $args->{table};
    $sql .= " USE INDEX ($args->{use_index})" if $args->{use_index};
    my ($where,@binds) = $class->_parse_where($args->{where});
    $sql .= $where if $where;
    $sql .= " GROUP BY $args->{group}" if $args->{group};
    $sql .= " ORDER BY $args->{order}" if $args->{order};
    $sql .= $class->_parse_limit($args);
    return ($sql,@binds);
}

sub _parse_where {
    my ($class, $where) = @_;
    my $binds = [];
    if (ref $where eq 'ARRAY') {
        my $sql = shift @$where;
        if ($sql =~ m!\s*:[A-Za-z_][A-Za-z0-9_]+\s*!o) {
            @$where % 2 and croak "You gave me an odd number of parameters to 'where'!";
            my %named_values = @$where;
            my @values;
            $sql =~ s{:([A-Za-z_][A-Za-z0-9_]*)}{
                croak "$1 is not exists in hash" if !exists $named_values{$1};
                my $value = $named_values{$1};
                if (ref $value eq 'ARRAY') {
                    push @values, $_ for @$value;
                    join ',', map('?', 1..@$value);
                } else {
                    push @values, $value;
                    '?'
                }
            }ge;
            $binds = \@values;
        } else {
            $binds = $where;
        }
        return (' WHERE ' . $sql, @$binds);
    } elsif (ref $where eq 'HASH') {
        return $sqla->where($where);
    } elsif ($where) {
        return ' WHERE ' . $where;
    }
    return $where;
}

sub _parse_limit {
    my ($class, $args) = @_;
    my $sql = '';
    if ($args->{offset} || $args->{limit}) {
        $sql .= " LIMIT ";
        if ($args->{offset} && $args->{offset} =~ m/^\d+$/o) {
            $sql .= $args->{offset}.",";
        }
        $sql .= $args->{limit} =~ /^\d+$/o ? $args->{limit} : '1';
    }
    return $sql;
}

sub dbh {
    my $class = shift;
    my $connect = $class->cache_connection ? 'connect_cached' : 'connect';
    DBI->$connect(
        $class->dsn, $class->username, $class->password
    );
}

sub execute {
    my $class = shift;
    my ($sql, $data, $binds) = @_;
    $sql or return;
    my @bind_values = ref $binds eq 'ARRAY' ? @$binds : ();
    my $dbh = $class->dbh;
    my $sth = @bind_values ? $dbh->prepare_cached($sql,undef,1) :
        $dbh->prepare($sql);
    unless ($sth) { carp $dbh->errstr and return; }
    if (defined $data) {
        $sth->execute(@bind_values) or 
            carp sprintf('SQL Error: "%s" (%s)', $sql, $sth->errstr) and return;
        $$data = $sth->fetchall_arrayref({});
    } else {
        unless ($sth->execute(@bind_values)) {
            carp qq/SQL Error "$sql"/;
            return;
        }
    }
    if ($sql =~ /^insert/io) {
        $class->last_insert_id($dbh->last_insert_id(undef,undef,undef,undef) ||
                           $dbh->{'mysql_insertid'});
    }
    return !$sth->err;
}

sub vendor {
    my $class = shift;
    $class->dbh->get_info(17); # SQL_DBMS_NAME
}

sub primary_keys {
    my $class = shift;
    my $table = shift or return;
    if ($class->vendor eq 'MySQL') {
        my $sth = $class->dbh->column_info(undef,undef,$table,'%');
        return [
            map {$_->{COLUMN_NAME}}
            grep {$_->{mysql_is_pri_key}}
            @{$sth->fetchall_arrayref({})}
        ];
    } else {
        return [$class->dbh->primary_key(undef,undef,$table)];
    }
}

sub unique_keys {
    my $class = shift;
    my $table = shift or return;
    if ($class->vendor eq 'MySQL') {
        my $sql = "show index from $table";
        my $data;
        $class->execute($sql,\$data);
        return [
            map {$_->{Column_name}}
            grep {!$_->{Non_unique}}
            @$data
        ];
    } else {
        return $class->primary_keys($table);
    }
}

sub columns {
    my $class = shift;
    my $table = shift or return;
    my $sth = $class->dbh->column_info(undef,undef,$table,'%') or return;
    return [
        map {$_->{COLUMN_NAME}}
        @{$sth->fetchall_arrayref({})}
    ];
}

1;

=head1 NAME

DBIx::MoCo::DataBase - Data Base Handler for DBIx::MoCo

=head1 SYNOPSIS

  package MyDataBase;
  use base qw(DBIx::MoCo::DataBase);

  __PACKAGE__->dsn('dbi:mysql:myapp');
  __PACKAGE__->username('test');
  __PACKAGE__->password('test');

  1;

  # In your scripts
  MyDataBase->execute('select 1');

=head1 METHODS

=item cache_connection

Controlls cache behavior for dbh connection. (default 1)
If its set to 0, DBIx::MoCo::DataBase uses DBI->connect instead of
DBI->connect_cached.

  DBIx::MoCo::DataBase->cache_connection(0);

=head1 SEE ALSO

L<DBIx::MoCo>, L<SQL::Abstract>

=head1 AUTHOR

Junya Kondo, E<lt>jkondo@hatena.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) Hatena Inc. All Rights Reserved.

This library is free software; you may redistribute it and/or modify
it under the same terms as Perl itself.

=cut
