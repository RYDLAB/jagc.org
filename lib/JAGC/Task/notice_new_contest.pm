package JAGC::Task::notice_new_contest;
use Mojo::Base -base;

use Mango::BSON ':bson';
use Mojo::URL;

sub call {
  my ($self, $job, $con) = @_;

  my $db     = $job->app->db;
  my $config = $job->app->config;

  my $contest = $db->c('contest')->find_one($con);
  my $users = $db->c('user')->find({'notice.contests' => bson_true}, {email => 1, login => 1})->all;

  my $c = $job->app->build_controller;
  $c->req->url->base(Mojo::URL->new($config->{site_url}));

  for my $user (@$users) {
    my $data = $c->render_to_string(
      'mail/new_contest',
      format  => 'email',
      login   => $user->{login},
      cname   => $contest->{name},
      clink   => $c->url_for('contest_view', con => $contest->{_id})->to_abs,
      profile => $c->url_for('user_settings', login => $user->{login})->to_abs
    );

    $job->app->send_notify($user->{email}, $data, "[JAGC] New contest: $contest->{name}");
  }

  $job->finish;
}

1;
