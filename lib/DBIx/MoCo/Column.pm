package DBIx::MoCo::Column;
use strict;
use Carp;

sub new {
    my $class = shift;
    my $self = shift; # scalar
    bless \$self, $class;
}

1;

=head1 NAME

DBIx::MoCo::Column - Scalar blessed class for inflating columns.

=head1 SYNOPSIS

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

=head1 SEE ALSO

L<DBIx::MoCo>

=head1 AUTHOR

Junya Kondo, E<lt>jkondo@hatena.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) Hatena Inc. All Rights Reserved.

This library is free software; you may redistribute it and/or modify
it under the same terms as Perl itself.

=cut
