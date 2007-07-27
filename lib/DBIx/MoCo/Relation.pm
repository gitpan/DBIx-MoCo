package DBIx::MoCo::Relation;
use strict;
use Carp;

my $relation = {};

sub register {
    my $class = shift;
    my ($klass, $type, $attr, $model, $option) = @_;
    $relation->{$klass} ||= {has_a => {},has_many => {}};
    $relation->{$klass}->{$type}->{$attr} = {
        class => $model,
        option => $option || '',
    };
    my $registry = 'register_' . $type;
    $class->$registry(@_);
    $class->register_flusher(@_);
}

sub register_has_a {
    my $class = shift;
    my ($klass, $type, $attr, $model, $option) = @_;
    my ($my_key, $other_key);
    $option->{key} or return;
    if (ref $option->{key} eq 'HASH') {
        ($my_key, $other_key) = %{$option->{key}};
    } else {
        $my_key = $other_key = $option->{key};
    }
    my $icache_key = $attr;
    my $cs = $klass->cache_status;
    my $subname = $klass . '::' . $attr;
    no strict 'refs';
    no warnings 'redefine';
    if ($klass->icache_expiration) {
        *$subname = sub {
            my $self = shift;
            my $ic = $self->icache;
            if ($ic && defined $ic->{$icache_key}) {
                $cs->{retrieve_count}++;
                $cs->{retrieve_icache_count}++;
                return $ic->{$icache_key};
            } else {
                defined $self->{$my_key} or return;
                my $o = $model->retrieve($other_key => $self->{$my_key}) || undef;
                $ic->{$icache_key} = $o if $o;
                return $o;
            }
        };
    } else {
        *$subname = sub {
            my $self = shift;
            defined $self->{$my_key} or return;
            $model->retrieve($other_key => $self->{$my_key}) || undef;
        };
    }
}

sub register_has_many {
    my $class = shift;
    my ($klass, $type, $attr, $model, $option) = @_;
    my $array_key = $klass->has_many_keys_name($attr);
    my $max_key = $klass->has_many_max_offset_name($attr);
    $option->{key} or confess 'key is not specified';
    my ($my_key, $other_key, $where);
    if (ref $option->{key} eq 'HASH') {
        ($my_key, $other_key) = %{$option->{key}};
    } else {
        $my_key = $other_key = $option->{key};
    }
    $where = "$other_key = ?";
    $where .= ' and ' . $option->{condition} if $option->{condition};
    my $subname = $klass . '::' . $attr;
    my $icache_key = $attr;
    no strict 'refs';
    no warnings 'redefine';
    *$subname = sub {
        # warn "level 1 has many called for $subname";
        my $search = {
            field => join(',', @{$model->retrieve_keys || $model->primary_keys}),
            table => $model->table,
            order => $option ? $option->{order} || '' : '',
            group => $option ? $option->{group} || '' : '',
        };
        my $cs = $klass->cache_status;
        *$subname = sub {
            # warn "level 2 has many called for $subname";
            $cs->{has_many_count}++;
            my ($self,$off,$lt) = @_;
            my $icache = $self->icache;
            $off ||= 0;
            my $max_off = defined $lt ? $off + $lt : undef;
            if (defined $self->{$array_key} && (
                (defined $self->{$max_key} && $self->{$max_key} == -1) ||
                    ($max_off && 0 <= $max_off && $max_off <= $self->{$max_key}) )
            ) {
                if ($icache && $icache->{$icache_key}) {
                    $cs->{has_many_icache_count}++;
                    # warn "use icache $icache_key for " . $self;
                    return $icache->{$icache_key}->slice(
                        $off || 0, defined $max_off ? $max_off - 1 : undef);
                } else {
                    # warn "$attr cache($self->{$max_key}) is in range $max_off";
                    $cs->{has_many_cache_count}++;
                }
            } else {
                defined $self->{$my_key} or return;
                $search->{where} = [$where, $self->{$my_key}];
                $search->{limit} = (defined $max_off && $max_off > 0) ?
                    $max_off : '';
                $self->{$array_key} = $model->db->search(%$search);
                $self->{$max_key} = $max_off || -1;
                # warn @{$self->{$array_key}};
            }
            my $last = ($max_off && $max_off <= $#{$self->{$array_key}})
                ? $max_off - 1 : $#{$self->{$array_key}};
            if ($icache) {
                # warn "set icache and return";
                $icache->{$icache_key} = $model->retrieve_multi(@{$self->{$array_key}});
                return $icache->{$icache_key}->slice($off || 0, $last) || undef;
                # return $icache->{$icache_key};
            } else {
                # warn "return retrieve_multi";
                return $model->retrieve_multi(@{$self->{$array_key}}[$off || 0 .. $last]);
            }
        };
        goto &$subname;
    };
}

sub register_flusher {
    shift; # Relation
    my ($klass, $type, $attr, $model, $option) = @_;
    my $flusher = $klass . '::flush_belongs_to';
    no strict 'refs';
    no warnings 'redefine';
    *$flusher = sub {
        # warn "level 1 flusher called for $flusher";
        my ($class, $self) = @_;
        $self or confess '$self is not specified';
        my $has_a = $relation->{$klass}->{has_a};
        for my $attr (keys %$has_a) {
            my $ha = $has_a->{$attr};
            my $oa = [];
            my $other = $relation->{$ha->{class}};
            for my $oattr (keys %{$other->{has_many}}) {
                my $hm = $other->{has_many}->{$oattr};
                if ($hm->{class} eq $class) {
                    # push @$oa, $ha->{class}->has_many_keys_name($oattr);
                    push @$oa, $oattr;
                }
            }
            $ha->{other_attrs} = $oa;
            # warn join(' / ', %$ha);
        }
        *$flusher = sub {
            # warn "level 2 flusher called for $flusher";
            my ($class, $self) = @_;
            for my $attr (keys %$has_a) {
                my $parent = $self->$attr() or next;
                for my $oattr (@{$has_a->{$attr}->{other_attrs}}) {
                    # warn "call $self->$attr->flush($oattr)";
                    $parent->flush_has_many_keys($oattr);
                    $parent->flush_icache($oattr);
                }
            }
        };
        goto &$flusher;
    };
}

1;

=head1 NAME

DBIx::MoCo::Relation - Storage class for relation definitions.

=head1 SEE ALSO

L<DBIx::MoCo>

=head1 AUTHOR

Junya Kondo, E<lt>http://jkondo.vox.com/E<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) Hatena Inc. All Rights Reserved.

This library is free software; you may redistribute it and/or modify
it under the same terms as Perl itself.

=cut
