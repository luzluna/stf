# Watches for requests to reload the configuration for the workers
# 

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

    my $id = $self->id();
    if (! $id ) {
        $id = $self->generator->create_id();
        $self->id( $id );
    }
    
    my $dbh = $self->get('DB::Master');
    $dbh->do( <<EOSQL, undef, $id );
        REPLACE INTO worker (id, expires_at) VALUES ( ?, DATE_ADD(NOW(), INTERVAL 10 MINUTE) )
EOSQL
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

    kill HUP => $self->parent_pid;
}

1;
