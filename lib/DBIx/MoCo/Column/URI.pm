package DBIx::MoCo::Column::URI;
use strict;
use warnings;
use URI;

sub URI {
    my $self = shift;
    return URI->new($$self);
}

1;
