# Watches for requests to reload the configuration for the workers

package STF::Worker::ReloadConfig;
use strict;
use parent qw(STF::Worker::Base STF::Trait::WithDBI);
use Digest::MD5 ();
use STF::Constants qw(STF_DEBUG);
use Sys::Hostname ();
use Time::HiRes ();
use Class::Accessor::Lite
    rw => [ qw( id ) ]
;

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(
        loop_class => $ENV{ STF_QUEUE_TYPE } || 'Q4M',
        @_
    );

    $self->register;

    $self;
}

sub register {
    my $self = shift;

    my $dbh = $self->get('DB::Master');
    my $id = $self->id() ||$self->generator->create_id();

    my $rv;
    do {
        local $dbh->{RaiseError} = 0;
        $rv = $dbh->do( <<EOSQL, undef, $id );
            INSERT INTO worker (id, expires_at) VALUES ( ?, DATE_ADD(NOW(), INTERVAL 10 MINUTE) )
EOSQL
        if ($rv) {
            $self->id ( $id );
        } else {
            $id = $self->generator->create_id();
        }
    } while( ! $rv);
}

sub unregister {
    my $self = shift;
    my $id = $self->id();
    if (! $id ) {
        return;
    }
    
    my $dbh = $self->get('DB::Master');
    $dbh->do( <<EOSQL, undef, $id );
        DELETE FROM worker WHERE id = ?
EOSQL
}

sub queue_waitcond {
    my $self = shift;
    return sprintf 'queue_reload_config:args=%s', $self->id,;
}

sub on_timeout {
    my $self = shift;
    $self->register();
}

sub on_exit {
    my $self = shift;
    $self->unregister();
}

sub work_once {
    my ($self, $worker_id) = @_;

    if (STF_DEBUG) {
        printf STDERR "[    Reload] Received reload request. Sending parent (%d) HUP\n",
            $self->parent_pid;
    }
    kill HUP => $self->parent_pid;
}

1;
