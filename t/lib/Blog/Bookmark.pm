package Blog::Bookmark;
use strict;
use warnings;
use base qw 'Blog::Class';

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
