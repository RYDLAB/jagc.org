package JAGC::Model::Comment;

use Mojo::Base 'MojoX::Model';
use Mango::BSON ':bson';
use JAGC::Model::Task qw( HIDE_TASK HIDE_SOLUTIONS );

sub _get_comments {
  my ($self, $id, $type) = @_;

  my $db = $self->app->db;
  $id = bson_oid $id;

  my $item = $db->c($type)->find_one($id);

  my $parent_fld = $type eq 'task' ? 'task' : 'solution';
  my $item_fld = $type eq 'task' ? 'tid' : 'sid';

  my $comments = $db->c('comment')->find({type => $type, $item_fld => $id, del => bson_false})
    ->sort(bson_doc(ts => 1))->all;

  return wantarray ? () : undef if !$item;
  my $comment||= ();

  return ( $item, $comments );
}

sub solution_comments {
  my ($self, %args) = @_;

  my $sid = $args{sid};
  my $uid = $args{uid};

  my ($solution, $comments) = $self->_get_comments( $sid, 'solution' );

  return wantarray ? () : undef unless $solution;

  my $usr_id = bson_oid $solution->{user}{uid}->to_string;

  if( my $con = $solution->{task}{con} ) {
    my $perm = $self->app->model('task')->view_permissions($con, $uid);

    return wantarray ? () : undef if $perm == HIDE_TASK;
    $solution->{code} = '...' if $perm == HIDE_SOLUTIONS && $usr_id ne $uid;
  }

  return ( solution => $solution, comments => $comments );
}

sub task_comments {
  my ($self, %args) = @_;

  my $tid = $args{tid};
  my $uid = $args{uid};

  my ($task, $comments) = $self->_get_comments( $tid, 'task' );

  return wantarray ? () : undef unless $task;

  my $usr_id = bson_oid $task->{owner}{uid}->to_string;

  if( my $con = $task->{con} ) {
    my $perm = $self->app->model('task')->view_permissions($con, $uid);

    return wantarray ? () : undef if $perm == HIDE_TASK;
  }

  return ( task => $task, comments => $comments );
}

1;
