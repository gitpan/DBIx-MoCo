package DBIx::MoCo::List;
use strict;
use warnings;
use Carp qw/croak/;
use List::Util ();
use List::MoreUtils ();

our $AUTOLOAD;

sub AUTOLOAD {
    my $self = $_[0];
    my $class = ref($self) || $self;
    $self = undef unless ref($self);
    (my $method = $AUTOLOAD) =~ s!.+::!!;
    return if $method eq 'DESTROY';
    no strict 'refs';
    if ($method =~ /^map_(.+)$/o) {
        *$AUTOLOAD = $class->_map_handler($1);
        goto &$AUTOLOAD;
    }
}

sub _map_handler {
    my $class = shift;
    my $method = shift;
    return sub {
        shift->map(sub { $_->$method() });
    };
}

sub new {
    my ($class, $array) = @_;
    $class = ref $class || $class;
    $array ||= [];
    croak sprintf("Argument must be an array reference (%s)", ref $array)
        unless ref $array eq 'ARRAY';
    bless $array, $class;
}

sub push {
    my $self = shift;
    push @$self, @_;
    $self;
}

sub unshift {
    my $self = shift;
    unshift @$self, @_;
    $self;
}

sub shift {
    shift @{$_[0]};
}

sub pop {
    pop @{$_[0]};
}

sub first {
    $_[0]->[0];
}

sub last {
    $_[0]->[-1];
}

sub dump {
    my $self = CORE::shift;
    require Data::Dumper;
    Data::Dumper->new([ $self->to_a ])->Purity(1)->Terse(1)->Dump;
}

sub zip {
    my $self = CORE::shift;
    my $array = \@_;
    my $index = 0;
    $self->collect(sub { 
         my $ary = $self->new([$_]);
         $ary->push($_->[$index]) for @$array;
         $index++;
         $ary;
    });
}

sub delete {
    my ($self, $value, $code) = @_;
    my $found = 0;
    do { my $item = $self->shift; $item == $value ? $found = 1 : $self->push($item) } for (0..$self->_last_index);
    $found ? $value 
           : ref $code eq 'CODE' ? do { local $_ = $value; return $code->($_) }
                                 : return ;
}

sub delete_at {
    my ($self, $pos) = @_;
    my $last_index = $self->_last_index;
    return if $pos > $last_index ;
    my $result;
    $_ == $pos ? $result = $self->shift 
               : $self->push($self->shift) for 0..$last_index;
    return $result;
}

sub delete_if {
    my ($self, $code) = @_;
    croak "Argument must be a code" unless ref $code eq 'CODE';
    my $last_index = $self->_last_index;
    for (0..$last_index) {
        my $item = $self->shift;
        local $_ = $item;
        $self->push($item) if $code->($_);
    }
    return $self;
}

sub inject {
    my ($self, $result, $code) = @_;
    croak "Argument must be a code" unless ref $code eq 'CODE';
    $result = $code->($result, $_) for @{$self->dup};
    return $result;
}

sub join {
    my ($self, $delimiter) = @_;
    join $delimiter, @$self;
}

sub each_index {
    my ($self, $code) = @_;
    $self->new([ 0..$self->_last_index ])->each($code);
}

sub _last_index {
    my $self = CORE::shift;
    $self->length ? $self->length - 1 : 0;
};

sub concat {
    my ($self, $array) = @_;
    $self->push(@$array);
    $self;
}

*append = \&concat;

sub prepend {
    my ($self, $array) = @_;
    $self->unshift(@$array);
    $self;
}

sub _append_undestructive {
    my ($self, $array) = @_;
    $self->dup->push(@$array);
}

sub _prepend_undestructive {
    my ($self, $array) = @_;
    $self->dup->unshift(@$array);
}

sub add {
    my ($self, $array, $bool) = @_;
    $bool ? $self->_prepend_undestructive($array)
          : $self->_append_undestructive($array);
}

sub each {
    my ($self, $code) = @_;
    croak "Argument must be a code" unless ref $code eq 'CODE';
    $code->($_) for @{$self->dup};
    $self;
}

sub collect {
    my ($self, $code) = @_;
    croak "Argument must be a code" unless ref $code eq 'CODE';
    my @collected = CORE::map &$code, @{$self->dup};
    wantarray ? @collected : $self->new(\@collected);
}

*map = \&collect;

sub grep {
    my ($self, $code) = @_;
    croak "Argument must be a code" unless ref $code eq 'CODE';
    my @grepped = CORE::grep &$code, @$self;
    wantarray ? @grepped : $self->new(\@grepped);
}

sub find {
    my ($self, $code) = @_;
    croak "Argument must be a code" unless ref $code eq 'CODE';
    for (@$self) { &$code and return $_ }
}

sub sort {
    my ($self, $code) = @_;
    my @sorted = $code ? CORE::sort { $code->($a, $b) } @$self : CORE::sort @$self;
    wantarray ? @sorted : $self->new(\@sorted);
}

sub compact {
    CORE::shift->grep(sub { defined  });
}

sub length {
    scalar @{$_[0]};
}

*size = \&length;

sub flatten {
    my $self = CORE::shift;
    $self->collect(sub { _flatten($_)  });
}

sub _flatten {
    my $element = CORE::shift;
    (ref $element and ref $element eq 'ARRAY')
        ? CORE::map { _flatten($_) } @$element
        : $element;
}

sub is_empty {
    !$_[0]->length;
}

sub uniq {
    my $self = CORE::shift;
    $self->new([ List::MoreUtils::uniq(@$self) ]);
}

sub reduce {
    my ($self, $code) = @_;
    croak "Argument must be a code" unless ref $code eq 'CODE';
    List::Util::reduce { $code->($a, $b) } @$self;
}

sub to_a {
    my @unblessed = @{$_[0]};
    \@unblessed;
}

sub as_list { # for Template::Iterator
    CORE::shift;
}

sub dup {
    __PACKAGE__->new($_[0]->to_a);
}

sub reverse {
    my $self = CORE::shift;
    $self->new([ reverse @$self ]);
}

sub sum {
    List::Util::sum @{$_[0]};
}

1;

=head1 NAME

DBIx::MoCo::List - Array iterator for DBIx::MoCo.

=head1 SYNOPSIS

  my $array_ref = [
    {name => 'jkondo'},
    {name => 'cinnamon'}
  ];
  my $list = DBIx::MoCo::List->new($array_ref);

  $list->size; # 2
  my @names = $list->map_name; # ('jkondo','cinnamon')
  my $first = $list->pop; # first hash

=head1 SEE ALSO

L<DBIx::MoCo>

=head1 AUTHOR

Junya Kondo, E<lt>jkondo@hatena.comE<gt>, Naoya Ito, E<lt>naoya@hatena.ne.jpE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) Hatena Inc. All Rights Reserved.

This library is free software; you may redistribute it and/or modify
it under the same terms as Perl itself.

=cut
