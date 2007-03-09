#!perl -T
use strict;
use warnings;
use File::Spec;
use lib File::Spec->catdir('lib');
use lib File::Spec->catdir('t', 'lib');

ThisTest->runtests;

# ThisTest
package ThisTest;
use base qw/Test::Class/;
use Test::More;
use DBIx::MoCo;
use Data::Dumper;

sub retrieve_keys : Tests {
    DBIx::MoCo->retrieve_keys(['user_id', 'entry_id']);
    is_deeply(DBIx::MoCo->retrieve_keys, ['user_id', 'entry_id']);
}


1;
