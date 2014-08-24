package JAGC::Task::email;
use Mojo::Base -base;

sub call {
  my ($self, $job, $login, $email, $link) = @_;

  my $data = $job->app->build_controller->render_to_string(
    'register',
    format => 'email',
    login  => $login,
    link   => $link
  );

  my $tx = $job->app->ua->post(
    'https://mandrillapp.com/api/1.0/messages/send.json' => json => {
      key     => $job->app->config->{mail}{key},
      message => {
        html       => $data,
        subject    => 'Welcome to JAGC',
        from_email => $job->app->config->{mail}{from},
        from_name  => 'JAGC',
        to         => [{email => $email, type => 'to'}]
      }
    }
  );

  if (my $err = $tx->error) {
    $job->app->log->error("[mandrill] $err->{code} response: $err->{message}") if $err->{code};
    $job->app->log->error("[mandrill] Connection error: $err->{message}");
  }

  $job->finish;
}

1;
