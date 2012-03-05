package STF::Worker::Loop::Q4M;
use strict;
use parent qw(
    STF::Worker::Loop
    STF::Trait::WithDBI
);
use POSIX qw(:signal_h);
use Guard ();
use Scalar::Util ();
use Time::HiRes ();
use STF::Constants qw(STF_DEBUG);
use Class::Accessor::Lite
    rw => [ qw(interval timeout) ]
;

sub queue_table {
    my ($self, $impl) = @_;

    if ( my $code = $impl->can('queue_table') ) {
        return $code->($impl);
    }

    my $table = (split /::/, Scalar::Util::blessed $impl)[-1];
    $table =~ s/([a-z0-9])([A-Z])/$1_$2/g;
    return sprintf 'queue_%s', lc $table;
}

sub queue_waitcond {
    my ($self, $impl) = @_;

    if ( my $code = $impl->can('queue_waitcond') ) {
        return $code->($impl);
    }

    $self->queue_table( $impl );
}

sub work {
    my ($self, $impl) = @_;

    my $guard = $self->container->new_scope();

    my $timeout = $impl->queue_timeout();
    my $table = $self->queue_table( $impl );
    my $waitcond = $self->queue_waitcond( $impl );
    my $dbh = $self->get('DB::Queue') or
        Carp::confess( "Could not fetch DB::Queue" );

    my $object_id;

    my $sigset = POSIX::SigSet->new( SIGINT, SIGQUIT, SIGTERM );
    my $sth;
    my $cancel_q4m = POSIX::SigAction->new(sub {
        if ( $self->status ) {
            eval { $sth->cancel };
            eval { $dbh->disconnect };
            $self->status(0);
        }
    }, $sigset, &POSIX::SA_NOCLDSTOP);
    my $setsig = sub {
        # XXX use SigSet to properly interrupt the process
        POSIX::sigaction( SIGINT,  $cancel_q4m );
        POSIX::sigaction( SIGQUIT, $cancel_q4m );
        POSIX::sigaction( SIGTERM, $cancel_q4m );
    };

    $setsig->();

    my $default = POSIX::SigAction->new('DEFAULT');
    my $on_timeout = $impl->can('on_timeout');

    while ( $self->should_loop ) {
        $sth = $dbh->prepare(<<EOSQL);
            SELECT args FROM $table WHERE queue_wait(?, ?)
EOSQL

        my $rv = $sth->execute($waitcond, $timeout);
        if ($rv == 0) { # nothing found
            $sth->finish;
            eval {
                if ( $on_timeout ) {
                    $on_timeout->( $impl );
                }
            };
            if ($@) {
                printf STDERR "[ Loop::Q4M] on_timeout callback failed: $@\n";
            }
            next;
        }

        $sth->bind_columns( \$object_id );
        while ( $self->should_loop && $sth->fetchrow_arrayref ) {
            my $extra_guard;
            if (STF_DEBUG) {
                my ($row_id) = $dbh->selectrow_array( "SELECT queue_rowid()" );
                printf STDERR "[ Loop::Q4M] ---- START %s:%s ----\n", $table, $row_id;
                printf STDERR "[ Loop::Q4M] Got new item from %s (%s)\n",
                    $table,
                    $object_id
                ;
                $extra_guard = Guard::guard(sub {
                    printf STDERR "[ Loop::Q4M] ---- END %s:%s ----\n", $table, $row_id;
                } );
            }
            eval { $dbh->do("SELECT queue_end()") };

            $self->incr_processed();
            my $sig_guard = Guard::guard(\&$setsig);

            # XXX Disable signal handling during work_once
            POSIX::sigaction( SIGINT,  $default );
            POSIX::sigaction( SIGQUIT, $default );
            POSIX::sigaction( SIGTERM, $default );

            my $guard = $impl->container->new_scope;
            eval { $impl->work_once( $object_id ) };
            warn $@ if $@;
            if ( (my $interval = $self->interval) > 0 ) {
                Time::HiRes::usleep( $interval );
            }
        }
    }
    eval { $dbh->do("SELECT queue_end()") };

    eval {
        if ( my $on_exit = $impl->can('on_exit') ) {
            $on_exit->( $impl );
        }
    };
    if ($@) {
        printf STDERR "[ Loop::Q4M] Error while executing on_exit for $self ($$): $@\n";
    }
    if ( STF_DEBUG ) {
        printf STDERR "[ Loop::Q4M] Process for $self ($$) exiting...\n";
    }
}

1;