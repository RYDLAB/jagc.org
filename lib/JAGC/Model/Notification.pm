package JAGC::Model::Notification;

use Mojo::Base 'MojoX::Model';
use Mango::BSON ':bson';

sub comments {
  my ($self, %args) = @_;
  my $db = $self->app->db; 

  $self->_notification( $args{uid}, $args{tid}, 'comment' );

}

sub solutions {
  my ($self, %args) = @_;
  my $db = $self->app->db; 
  my $log = $self->app->log;

  my $tid = bson_oid $args{tid};
  my $uid = $args{uid};

  my $task;
  eval { $task = $db->c('task')->find_one($tid) };

  if( $@ ) {
    my $msg = "Error while find_one task $tid: $@";
    $log->error($msg);
    return ( err => $msg );
  }

  if ($task && $task->{con}) {
    $log->warn("Attempt to subscribe on contest task uid: $uid,  tid: $tid");
    return ( tid => $tid );
  }

  $self->_notification( $args{uid}, $args{tid}, 'solution' );
  return ( tid => $tid );
}

sub _notification {
  my ( $self, $uid, $tid, $type ) = @_;

  $uid = bson_oid $uid;
  $tid = bson_oid $tid;

  my $db  = $self->app->db;
  my $log = $self->app->log;

  my $notification;
  eval { $notification = $db->c('notification')->find_one(bson_doc (uid => $uid, tid => $tid)) };

  if( $@ ) {
    my $msg = "Error while find notification $uid: $@";
    $log->error( $msg );
    return ( err => $msg );
  }

  my $action = '$addToSet';
  $action = '$pull' if $notification && grep { $_ eq $type } @{$notification->{for}};

  eval { $db->c('notification')
        ->update(bson_doc(uid => $uid, tid => $tid), {$action => {for => $type}}, {upsert => 1}) };

  if( $@ ) {
    my $msg = "Error while upsert notification: $@";
    $log->error( $msg );
    return ( err => $msg );
  }

  return ( tid => $tid );
}

1;
