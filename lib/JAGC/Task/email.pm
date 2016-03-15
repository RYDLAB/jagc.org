package JAGC::Task::email;

use Mojo::Base -base;
use JAGC::Helpers::SendNotify qw( send_notify );

sub call {
  my ($self, $job, $login, $addr, $link) = @_;

  my $config = $job->app->config;

  my $data = $job->app->build_controller->render_to_string(
    'register',
    format => 'email',
    login  => $login,
    link   => $link,
  );

  $job->fail unless send_notify($addr, $data, 'Welcome to JAGC');

}

1;
