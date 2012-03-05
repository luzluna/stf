package STF::Dispatcher;
use strict;
use feature 'state';
use parent qw( STF::Trait::WithDBI );
use File::Basename ();
use File::Temp ();
use Guard ();
use POSIX();
use Scalar::Util ();
use STF::Constants qw(
    :entity
    STF_DEBUG
    STF_TIMER
    STF_NGINX_STYLE_REPROXY
    STF_NGINX_STYLE_REPROXY_ACCEL_REDIRECT_URL
    STF_ENABLE_STORAGE_META
    STF_ENABLE_OBJECT_META
);
use STF::Context;
use STF::Dispatcher::PSGI::HTTPException;
use STF::SerialGenerator;
use STF::Utils ();
use Time::HiRes ();
use Class::Accessor::Lite
    rw => [ qw(
        cache
        cache_expires
        context
        connect_info
        generator
        host_id
        health_check_probability
        min_consistency
    ) ]
;

BEGIN {
    if ( STF_ENABLE_OBJECT_META ) {
        require Digest::MD5;
    }
}

sub bootstrap {
    my $class = shift;
    my $context = STF::Context->bootstrap;
    my $config = $context->config;

    $class->new(
        cache_expires => 300,
        %{$config->{'Dispatcher'}},
        container => $context->container,
        context   => $context,
    );
}

# XXX use hash so we can de-register ourselves?
my @RESOURCE_DESTRUCTION_GUARDS;
END {
    undef @RESOURCE_DESTRUCTION_GUARDS;
}

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        health_check_probability => 0.001,
        %args,
    }, $class;

    my $generator = STF::SerialGenerator->new(
        id => $self->host_id,
    );
    $self->generator( $generator );

    # XXX WHAT ON EARTH ARE YOU DOING HERE?
    #
    # We normally protect ourselves from leaking resources in DESTROY, but...
    # when we are enveloped in a PSGI app, a reference to us stays alive until
    # global destruction.
    #
    # At global destruction time, the order in which objects get cleaned
    # up is undefined, so it often happens that the mutex/shared memory gets
    # freed before the dispatcher object -- so when DESTROY gets called,
    # $self->{mutex} and $self->{shared_mem} are gone already, and we can't
    # call remove().
    #
    # To avoid this, we keep a guard object that makes sure that the resources
    # are cleaned up at END {} time
    push @RESOURCE_DESTRUCTION_GUARDS, (sub {
        my $SELF = shift;
        Scalar::Util::weaken($SELF);
        Guard::guard(sub {
            eval { $SELF->cleanup };
        });
    })->($self);

    $self;
}

sub DESTROY {
    my $self = shift;
    $self->cleanup;
}

sub cleanup {
    my $self = shift;
    $self->generator->cleanup;
}

sub start_request {
    my ($self, $env) = @_;
    if ( STF_DEBUG ) {
        printf STDERR "[Dispatcher] Starting request scope\n";
    }
    return $self->container->new_scope();
}

sub handle_exception {
    my ($self, $e) = @_;

    if (ref $e eq 'ARRAY') {
        STF::Dispatcher::PSGI::HTTPException->throw(@$e);
    }
}

sub get_bucket {
    my ($self, $args) = @_;

    my ($bucket) = $self->get('API::Bucket')->lookup_by_name( $args->{bucket_name} );
    if ( STF_DEBUG ) {
        if ( $bucket ) {
            print STDERR "[Dispatcher] Found bucket $args->{bucket_name}:\n";
        } else {
            printf STDERR "[Dispatcher] Could not find bucket $args->{bucket_name}\n";
        }
    }
    return $bucket || ();
}

sub create_id { $_[0]->generator->create_id() }

sub create_bucket {
    my ($self, $args) = @_;

    state $txn = $self->txn_block(sub {
        my ($self, $id, $bucket_name) = @_;
        my $bucket_api = $self->get('API::Bucket');
        $bucket_api->create({
            id   => $id,
            name => $bucket_name,
        } );
    });

    my $res = $txn->( $self->create_id, $args->{bucket_name} );
    if (my $e = $@) {
        if (STF_DEBUG) {
            printf STDERR "Failed to create bucket: $e\n";
        }
        $self->handle_exception($e);
    }

    return $res || ();
}

sub delete_bucket {
    my ($self, $args) = @_;

    state $txn = $self->txn_block(sub {
        my ($self, $id ) = @_;
        my $bucket_api = $self->get('API::Bucket');

        # Puts the bucket into deleted_bucket
        my $rv = $bucket_api->mark_for_delete( { id => $id } );
        if ($rv == 0) {
            STF::Dispatcher::PSGI::HTTPException->throw( 403, [], [] );
        }

        return 1;
    });

    my ($bucket, $recursive) = @$args{ qw(bucket) };
    my $res = $txn->( $bucket->{id} );
    if (my $e = $@) {
        if (STF_DEBUG) {
            print STDERR "[Dispatcher] Failed to delete bucket: $e\n";
        }
        $self->handle_exception($e);
    } else {
        if ( STF_DEBUG ) {
            printf STDERR "[Dispatcher] Deleted bucket %s (%s)\n",
                $bucket->{name},
                $bucket->{id}
            ;
        }
    }

    if ($res) {
        # Worker does the object deletion
        $self->enqueue( delete_bucket => $bucket->{id} );
    }

    return $res || ();
}

sub is_valid_object {
    my ($self, $args) = @_;
    my ($bucket, $object_name ) = @$args{ qw( bucket object_name ) };

    my $object_api = $self->get( 'API::Object' );
    return $object_api->find_active_object_id( {
        bucket_id => $bucket->{id},
        object_name => $object_name
    } );
}

sub create_object {
    my ($self, $args) = @_;

    my $timer;
    if ( STF_TIMER ) {
        $timer = STF::Utils::timer_guard();
    }

    state $txn = $self->txn_block( sub {
        my $txn_timer;
        if ( STF_TIMER ) {
            $txn_timer = STF::Utils::timer_guard( "create_object (txn closure)");
        }

        my ($self, $object_id, $bucket_id, $replicas, $object_name, $size, $consistency, $suffix, $input) = @_;

        my $object_api = $self->get( 'API::Object' );
        my $entity_api = $self->get( 'API::Entity' );

        # check if this object has already been created before.
        # if it has, make sure to delete it first
        if ( STF_DEBUG ) {
            printf STDERR "[Dispatcher] Create object checking if object '%s' on bucket '%s' exists\n",
                $bucket_id,
                $object_name,
            ;
        }

        my $find_object_timer;
        if ( STF_TIMER ) {
            $find_object_timer = STF::Utils::timer_guard( "create_object (find object)");
        }
        my $old_object_id = $object_api->find_object_id( {
            bucket_id =>  $bucket_id,
            object_name => $object_name
        } );
        if ( STF_TIMER ) {
            undef $find_object_timer;
        }

        if ( $old_object_id ) {
            if ( STF_DEBUG ) {
                printf STDERR "[Dispatcher] Object '%s' on bucket '%s' already exists\n",
                    $object_name,
                    $bucket_id,
                ;
            }
            $object_api->mark_for_delete( $old_object_id );
        }

        my $insert_object_timer;
        if ( STF_TIMER ) {
            $insert_object_timer = STF::Utils::timer_guard( "create_object (insert)" );
        }

        my $internal_name = $object_api->create_internal_name( { suffix => $suffix } );
        # Create an object entry. This is the "master" reference to the object.
        $object_api->create({
            id            => $object_id,
            bucket_id     => $bucket_id,
            object_name   => $object_name,
            internal_name => $internal_name,
            size          => $size,
            replicas      => $replicas,
        } );

        if ( STF_ENABLE_OBJECT_META ) {
            # XXX I'm not sure below is correct, but it works on my tests :/
            my $md5 = Digest::MD5->new;
            if ( eval { fileno $input }) {
                $md5->addfile( $input );
            } elsif ( eval { $input->can('read') } ) {
                $md5->add( $input->read() );
            }
            seek $input, 0, 0;
            $self->get('API::ObjectMeta')->create({
                object_id => $object_id,
                hash      => $md5->hexdigest,
            });
        }

        if ( STF_TIMER ) {
            undef $insert_object_timer;
        }

        # Create entities. These are the actual entities which are replicated
        # across the system
        # XXX - We're calling "replicate" here, but this here is for "consistency"

        my $min = $self->min_consistency;
        if ( defined $min && $consistency < $min ) {
            if ( STF_DEBUG ) {
                printf STDERR "[Dispatcher] Got consistency %d, but our minimum consistency is %d\n",
                    $consistency, $min
            }
            $consistency = $min;
        }
        my $replicated = $entity_api->replicate({
            object_id => $object_id,
            replicas  => $consistency,
            input     => $input,
        });

        return (1, $old_object_id);
    } );

    my ($bucket, $replicas, $object_name, $size, $consistency, $suffix, $input) = 
        @$args{ qw( bucket replicas object_name size consistency suffix input) };

    if ( STF_DEBUG ) {
        printf STDERR "[Dispatcher] Create object %s/%s\n",
            $bucket->{name},
            $object_name
        ;
    }
    my $object_id = $self->create_id();

    my ($res, $old_object_id) = $txn->(
        $object_id, $bucket->{id}, $replicas, $object_name, $size, $consistency, $suffix, $input );
    if (my $e = $@) {
        if (STF_DEBUG) {
            print STDERR "Error while creating object: $e\n";
        }
        $self->handle_exception($e);
        return ();
    }

    my $post_timer;
    if (STF_TIMER) {
        $post_timer = STF::Utils::timer_guard( "create_object (post process)" );
    }

    if ($old_object_id) {
        if ( STF_DEBUG ) {
            print STDERR
                "[Dispatcher] Request $bucket->{name}/$object_name was for existing content.\n",
                " + Will queue request to delete old object ($old_object_id)\n"
            ;
        }
        $self->enqueue( delete_object => $old_object_id );
    }

    $self->enqueue( replicate => $object_id );
    if (STF_TIMER) {
        undef $post_timer;
    }

    return $res;
}

sub get_object {
    my ($self, $args) = @_;

    my $timer;
    if ( STF_TIMER ) {
        $timer = STF::Utils::timer_guard();
    }

    my ($bucket, $object_name, $force_master, $req) =
        @$args{ qw(bucket object_name force_master request) };

    my $if_modified_since = $req->header('If-Modified-Since');
    my $object_api = $self->get('API::Object');
    my $uri = $object_api->get_any_valid_entity_url({
        bucket_id         => $bucket->{id},
        object_name       => $object_name,
        if_modified_since => $if_modified_since,

        # XXX forcefully check the health of this object randomly
        health_check      => rand() < $self->health_check_probability,
    });

    if ($uri) {
        my @args = (200, [ 'X-Reproxy-URL' => $uri ]);
        if ( STF_NGINX_STYLE_REPROXY ) {
            # nginx emulation of X-Reproxy-URL
            # location /reproxy {
            #     internal;
            #     set $reproxy $upstream_http_x_reproxy_url;
            #     proxy_pass $reproxy;
            #     proxy_hide_header Content-Type;
            # }
            push @{$args[1]},
                'X-Accel-Redirect' => STF_NGINX_STYLE_REPROXY_ACCEL_REDIRECT_URL
            ;
        }
        STF::Dispatcher::PSGI::HTTPException->throw(@args);
    }

    if ( STF_DEBUG ) {
        print STDERR "[Dispatcher] get_object() could not find suitable entity for $object_name\n";
    }

    return ();
}

sub delete_object {
    my ($self, $args) = @_;

    my $timer;
    if ( STF_TIMER ) {
        $timer = STF::Utils::timer_guard();
    }

    state $txn = $self->txn_block( sub {
        my ($self, $bucket_id, $object_name) = @_;
        my $object_api = $self->get( 'API::Object' );
        my $object_id = $object_api->find_object_id( {
            bucket_id => $bucket_id,
            object_name => $object_name
        } );

        if (! $object_id) {
            if ( STF_DEBUG ) {
                printf STDERR "[Dispatcher] No matching object_id found for DELETE\n";
            }
            return ();
        }

        if (! $object_api->mark_for_delete( $object_id ) ) {
            STF::Dispatcher::PSGI::HTTPException->throw( 500, [], [] );
        }

        return (1, $object_id);
    } );

    my ($bucket, $object_name) = @$args{ qw(bucket object_name) };
    my ($res, $object_id) = $txn->( $bucket->{id}, $object_name);
    if (my $e = $@) {
        if (STF_DEBUG) {
            print STDERR "Failed to delete object: $e\n";
        }
        $self->handle_exception($e);
        return ();
    }

    if ($object_id) {
        $self->enqueue( delete_object => $object_id );
    }
    return $res || ();
}

sub modify_object {
    my ($self, $args) = @_;

    my ($bucket, $object_name, $replicas) = @$args{ qw(bucket object_name replicas) };
    if ( STF_DEBUG ) {
        printf STDERR "[Dispatcher] Modifying %s/%s (replicas = %d)\n",
            $bucket->{name},
            $object_name,
            $replicas
        ;
    }

    state $txn = $self->txn_block( sub {
        my ($self, $bucket_id, $object_name, $replicas) = @_;
        my $object_api = $self->get('API::Object');
        my $object_id = $object_api->find_active_object_id( {
            bucket_id => $bucket_id,
            object_name =>  $object_name
        } );
        if (! $object_id) {
            printf STDERR "[Dispatcher] Create object checking if object '%s' on bucket '%s' exists\n",
                $bucket_id,
                $object_name,
            ;
            return ();
        }

        $object_api->update($object_id => {
            num_replica => $replicas
        });
        if ( STF_DEBUG ) {
            printf STDERR "[Dispatcher] Updated %s to num_replica = %d\n",
                $object_id,
                $replicas
            ;
        }

        return $object_id;
    });

    my ($object_id) = $txn->( $bucket->{id}, $object_name, $replicas);
    if (my $e = $@) {
        if (STF_DEBUG) {
            printf STDERR "[Dispatcher]: Failed to modify object: %s\n", $e;
        }
        $self->handle_exception($e);
        return ();
    }

    if ( $object_id ) {
        $self->enqueue( replicate => $object_id );
    }

    return (!(!$object_id)) || ();
}

sub rename_object {
    my ($self, $args) = @_;

    state $txn = $self->txn_block( sub {
        my ($self, $source_bucket_id, $source_object_name, $dest_bucket_id, $dest_object_name) = @_;
        my $object_api = $self->get('API::Object');
        my $object_id = $object_api->rename( {
            source_bucket_id => $source_bucket_id,
            source_object_name => $source_object_name,
            destination_bucket_id => $dest_bucket_id,
            destination_object_name => $dest_object_name
        });
        return $object_id;
    } );

    my $object_id = $txn->(
        $args->{source_bucket}->{id},
        $args->{source_object_name},
        $args->{destination_bucket}->{id},
        $args->{destination_object_name},
    );
    if (my $e = $@) {
        if (STF_DEBUG) {
            printf STDERR "[Dispatcher]: Failed to rename object: %s\n", $e;
        }
        $self->handle_exception($e);
        return ();
    }

    return $object_id;
}

sub enqueue {
    my ($self, $func, $object_id) = @_;

    my $queue_api = $self->get( 'API::Queue' );
    my $rv = eval { $queue_api->enqueue( $func, $object_id ) };
    if ($@) {
        # XXX This should not be seen by the client,
        # but we need to make sure to log it
        printf STDERR "[Dispatcher] Error while enqueuing: %s\n + func: %s\n + object ID = %s\n",
            $@,
            $func,
            $object_id,
        ;
    }
    return $rv;
}

1;

__END__

=head1 NAME

STF::Dispatcher - Dispatcher For STF

=head1 SYNOPSIS

    use STF::Dispatcher::PSGI;
    use STF::Dispatcher;

    my $impl = STF::Dispatcher->new(
        host_id => 100, # number
        ...
    );

    STF::Dispatcher::PSGI->new(impl => $impl)->to_app;

=cut
