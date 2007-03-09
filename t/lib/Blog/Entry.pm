package Blog::Entry;
use strict;
use warnings;
use base qw 'Blog::Class';

__PACKAGE__->table('entry');
__PACKAGE__->has_a(
    user => 'Blog::User',
    { key => 'user_id' }
);
__PACKAGE__->has_many(
    bookmarks => 'Blog::Bookmark',
    { key => 'entry_id' }
);

sub unique_keys { ['uri'] }

1;
