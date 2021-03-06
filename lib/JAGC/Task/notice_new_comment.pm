package JAGC::Task::notice_new_comment;
use Mojo::Base -base;
use Mango::BSON ':bson';
use Mojo::URL;

sub call {
  my ($self, $job, $cid, $tname) = @_;

  my $db     = $job->app->db;
  my $config = $job->app->config;

  my $comment = $db->c('comment')->find_one($cid);
  my $notes = $db->c('notification')->find(bson_doc(tid => $comment->{tid}, for => 'comment'))->all;
  my $users =
    $db->c('user')->find({_id => {'$in' => [map { $_->{uid} } @$notes]}}, {email => 1, login => 1})->all;

  my $c = $job->app->build_controller;
  $c->req->url->base(Mojo::URL->new($config->{site_url}));

  for my $user (@$users) {
    next if $user->{login} eq $comment->{user}{login};
    my $data = $c->render_to_string(
      'mail/new_comment',
      format  => 'email',
      login   => $user->{login},
      user    => $comment->{user}{login},
      tname   => $tname,
      comment => $comment->{html},
      clink   => $comment->{sid}
      ? $c->url_for('solution_comments', id => $comment->{sid})->to_abs
      : $c->url_for('task_comments',     id => $comment->{tid})->to_abs,
      tlink => $c->url_for('task_view', id => $comment->{tid})->to_abs
    );

    $job->app->send_notify($user->{email}, $data, "[JAGC] New comment in task $tname");

  }

  $job->finish;
}

1;
