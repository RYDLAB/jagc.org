package JAGC::Task::notice_new_task;
use Mojo::Base -base;

use Mango::BSON ':bson';
use Mojo::URL;

sub call {
  my ($self, $job, $tid) = @_;

  my $db     = $job->app->db;
  my $config = $job->app->config;

  my $task = $db->c('task')->find_one($tid);
  my $users = $db->c('user')->find({'notice.new' => bson_true}, {email => 1, login => 1})->all;

  my $c = $job->app->build_controller;
  $c->req->url->base(Mojo::URL->new($config->{site_url}));

  for my $user (@$users) {
    my $data = $c->render_to_string(
      'mail/new_task',
      format  => 'email',
      login   => $user->{login},
      tname   => $task->{name},
      tlink   => $c->url_for('task_view', id => $task->{_id})->to_abs,
      profile => $c->url_for('user_settings', login => $user->{login})->to_abs
    );

    $job->app->send_notify($user->{email}, $data, "[JAGC] New task: $task->{name}");
  }

  $job->finish;
}

1;
