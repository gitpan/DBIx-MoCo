package DBIx::MoCo::Schema;
use strict;
use Carp;

sub new {
    my $class = shift;
    my $moco = shift or return;
    my $self = {
        moco => $moco,
        primary_keys => undef,
        uniquie_keys => undef,
        columns => undef,
    };
    bless $self, $class;
}

sub primary_keys {
    my $self = shift;
    unless ($self->{primary_keys}) {
        my $moco = $self->{moco};
        $self->{primary_keys} = $moco->db->primary_keys($moco->table);
    }
    $self->{primary_keys};
}

sub uniquie_keys {
    my $self = shift;
    unless ($self->{uniquie_keys}) {
        my $moco = $self->{moco};
        $self->{uniquie_keys} = $moco->db->unique_keys($moco->table);
    }
    $self->{unique_keys};
}

sub columns {
    my $self = shift;
    unless ($self->{columns}) {
        my $moco = $self->{moco};
        $self->{columns} = $moco->db->columns($moco->table);
    }
    $self->{columns};
}

sub param {
    my $self = shift;
    return $self->{$_[0]} if not exists $_[1];
    @_ % 2 and croak
        sprintf "%s : You gave me an odd number of parameters to param()";
    my %args = @_;
    $self->{$_} = $args{$_} for keys %args;
}

1;

=head1 NAME

DBIx::MoCo::Schema - Schema class for DBIx::MoCo classes

=head1 SYNOPSIS

  my $schema = DBIx::MoCo::Schema->new('MyMoCoClass'); # make an instance

  my $schema = MyMoCoClass->schema; # MyMoCoClass isa DBIx::MoCo
  $schema->primary_keys; # same as MyMoCoClass->primary_keys
  $schema->uniquie_keys; # same as MyMoCoClass->uniquie_keys
  $schema->columns; # same as MyMoCoClass->columns

  # you can set any parameters using param
  $schema->param(validation => {
    name => ['NOT_BLANK', 'ASCII', ['LENGTH', 2, 5]],
    # for example, FormValidator::Simple style definitions
  });
  $schema->param('validation'); # returns validation definitions

=head1 SEE ALSO

L<DBIx::MoCo>, L<FormValidator::Simple>

=head1 AUTHOR

Junya Kondo, E<lt>jkondo@hatena.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) Hatena Inc. All Rights Reserved.

This library is free software; you may redistribute it and/or modify
it under the same terms as Perl itself.

=cut
