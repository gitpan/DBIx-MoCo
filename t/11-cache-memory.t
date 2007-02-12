#!perl -T
use strict;
use warnings;
use File::Spec;
use lib File::Spec->catdir('lib');
use lib File::Spec->catdir('t', 'lib');

Blog::Class->cache_object('Cache::Memory');
ThisTest->runtests;

# ThisTest
package ThisTest;
use base qw/Test::Class/;
use Test::More;
use Blog::User;

sub cache_memory : Tests {
    is (Blog::Class->cache_object, 'Cache::Memory');
    eval {use Cache::Memory };
    return if $@;
    my $u1 = Blog::User->retrieve(1);
    my $u2 = Blog::User->retrieve(1);
    is $u2, $u1;
    my $u3 = Blog::User->retrieve_by_name('jkondo');
    is $u3, $u1;
}

1;
