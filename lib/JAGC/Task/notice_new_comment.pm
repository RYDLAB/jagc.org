package JAGC::Task::notice_new_comment;
use Mojo::Base -base;

use Mango::BSON ':bson';

sub call {
  my ($self, $job, $cid, $tname) = @_;

  my $db     = $job->app->db;
  my $config = $job->app->config;

  my $comment = $db->collection('comment')->find_one($cid);
  my $notes = $db->collection('notification')->find(bson_doc(tid => $comment->{tid}, for => 'comment'))->all;
  my $users =
    $db->collection('user')->find({_id => {'$in' => [map { $_->{uid} } @$notes]}}, {email => 1, login => 1})
    ->all;

  my $c    = $job->app->build_controller;
  my $base = Mojo::URL->new($config->{site_url});

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
      ? $c->url_for('solution_comments', id => $comment->{sid})->to_abs($base)
      : $c->url_for('task_comments',     id => $comment->{tid})->to_abs($base),
      tlink => $c->url_for('task_view', id => $comment->{tid})->to_abs($base),
    );

    my $tx = $job->app->ua->post(
      'https://mandrillapp.com/api/1.0/messages/send.json' => json => {
        key     => $config->{mail}{key},
        message => {
          html       => $data,
          subject    => "[JAGC] New comment in task $tname",
          from_email => $job->app->config->{mail}{from},
          from_name  => 'JAGC',
          to         => [{email => $user->{email}, type => 'to'}]
        }
      }
    );

    if (my $err = $tx->error) {
      my $error =
        $err->{code}
        ? "[mandrill] $err->{code} response: $err->{message}"
        : "[mandrill] Connection error: $err->{message}";
      $job->app->log->error($error);
    }
  }

  $job->finish;
}

1;
