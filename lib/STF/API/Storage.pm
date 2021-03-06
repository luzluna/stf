package STF::API::Storage;
use Mouse;
use Guard ();
use STF::Constants qw(:storage STF_DEBUG STF_ENABLE_STORAGE_META);

with 'STF::API::WithDBI';

my @META_KEYS = qw(used capacity notes);

# XXX These queries to load meta info should, and can be optimized
around search => sub {
    my ($next, $self, @args) = @_;
    my $list = $self->$next(@args);
    if ( STF_ENABLE_STORAGE_META ) {
        my $meta_api = $self->get('API::StorageMeta');
        foreach my $object ( @$list ) {
            my ($meta) = $meta_api->search({ storage_id => $object->{id} });
            $object->{meta} = $meta;
        }
    }
    return wantarray ? @$list : $list;
};

around lookup => sub {
    my ($next, $self, $id) = @_;
    my $object = $self->$next($id);
    if ( STF_ENABLE_STORAGE_META ) {
        my ($meta) = $self->get('API::StorageMeta')->search({
            storage_id => $object->{id}
        });
        $object->{meta} = $meta;
    }
    return $object;
};

around create => sub {
    my ($next, $self, $args) = @_;

    my %meta_args;
    if ( STF_ENABLE_STORAGE_META ) {
        foreach my $key ( @META_KEYS ) {
            if (exists $args->{$key} ) {
                $meta_args{$key} = delete $args->{$key};
            }
        }
    }

    my $rv = $self->$next($args);

    if ( STF_ENABLE_STORAGE_META ) {
        $self->get('API::StorageMeta')->create({
            %meta_args,
            storage_id => $args->{id},
        });
    }
    return $rv;
};

sub update_meta {
    if ( STF_ENABLE_STORAGE_META ) {
        my ($self, $storage_id, $args) = @_;
        my $rv = $self->get('API::StorageMeta')->update_for( $storage_id, $args );
        return $rv;
    }
}

sub update_usage_for_all {
    my $self = shift;

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare( "SELECT id FROM storage" );
    $sth->execute();
    my $storage_id;
    $sth->bind_columns( \$storage_id );
    while ( $sth->fetchrow_arrayref ) {
        $self->update_usage( $storage_id );
    }
}

sub update_usage {
    my( $self, $storage_id ) = @_;

    if (STF_DEBUG) {
        printf STDERR "[    Usage] Updating usage for storage %s\n",
            $storage_id
        ;
    }
    my $dbh = $self->dbh;
    my($used) = $dbh->selectrow_array( <<EOSQL, undef, $storage_id ) || 0;
        SELECT SUM(o.size)
            FROM object o JOIN entity e ON o.id = e.object_id
            WHERE e.storage_id = ?
EOSQL

    $dbh->do( <<EOSQL, undef, $used, $storage_id );
        UPDATE storage_meta SET used = ? WHERE storage_id = ?
EOSQL
    $self->lookup( $storage_id ); # for cache
    return $used;
}


sub move_entities {
    my ($self, $storage_id, $check_cb) = @_;

    my $dbh = $self->dbh;

    my ($max) = $dbh->selectrow_array( <<EOSQL, undef, $storage_id );
        SELECT MAX(e.object_id) FROM entity e WHERE e.storage_id = ?
EOSQL

    my $sth = $dbh->prepare( <<EOSQL );
        SELECT e.object_id FROM entity e FORCE INDEX (PRIMARY)
            WHERE e.storage_id = ? AND e.object_id < ? ORDER BY e.object_id DESC LIMIT ?
EOSQL
    my $limit = 10_000;
    my $processed = 0;
    my $object_id = $max + 1;
    my $queue_api = $self->get( 'API::Queue');

    my $size = $queue_api->size( 'repair_object' );
    while ( 1 ) {
        if ( ! $check_cb->() ) {
            last;
        }

        my $rv = $sth->execute( $storage_id, $object_id, $limit );
        last if $rv <= 0;
        $sth->bind_columns( \($object_id ) );
        while ( $sth->fetchrow_arrayref ) {
            $processed++;

            my $object = $self->get('API::Object')->lookup( $object_id );

            if ( STF_DEBUG ) {
                printf STDERR "[   Storage] Sending object %s to repair queue\n",
                    $object_id,
                ;
            }

            # XXX Grrr, I want to say "put this in the repair queue, but don't
            # propagate it in the object health queue", but because of
            # historical reasons there are no way to pass in extra meta data
            # (obviously, we can change that, but that entails rethinking
            # the API, and I'm in no mood to do this right now).
            # Here, I'm going to resort to prefixing the data with
            # extra markers. This means the worker also needs to change. eek
            #
            # Prefixes:
            #   NP: no propagate
            $queue_api->enqueue( repair_object => "NP:$object_id" );
        }
        if ( $limit <= $processed ) {
            if ( STF_DEBUG ) {
                printf STDERR "[   Storage] Sent %d objects, sleeping to give it some time...\n",
                    $limit
                ;
            }

            my $prev = $size;
            $size = $queue_api->size( 'repair_object' );
            while ( $size > $prev ) {
                sleep 60;
                $size = $queue_api->size( 'repair_object' );
            }
        }
    }

    return $processed;
}

1;
