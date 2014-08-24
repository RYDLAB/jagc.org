package JAGC::Task::notice_new_task;
use Mojo::Base -base;

use Mango::BSON ':bson';

sub call {
  my ($self, $job, $tid) = @_;

  my $db     = $job->app->db;
  my $config = $job->app->config;

  my $task = $db->collection('task')->find_one($tid);
  my $users = $db->collection('user')->find({'notice.new' => bson_true}, {email => 1, login => 1})->all;

  my $c    = $job->app->build_controller;
  my $base = Mojo::URL->new($config->{site_url});

  for my $user (@$users) {
    my $data = $c->render_to_string(
      'mail/new_task',
      format  => 'email',
      login   => $user->{login},
      tname   => $task->{name},
      tlink   => $c->url_for('task_view', id => $task->{_id})->to_abs($base),
      profile => $c->url_for('user_settings', login => $user->{login})->to_abs($base)
    );

    my $tx = $job->app->ua->post(
      'https://mandrillapp.com/api/1.0/messages/send.json' => json => {
        key     => $config->{mail}{key},
        message => {
          html       => $data,
          subject    => "[JAGC] New task: $task->{name}",
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
