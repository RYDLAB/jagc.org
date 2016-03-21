package JAGC::Plugin::SendNotify;

use Mojo::Base 'Mojolicious::Plugin';
use Email::Sender::Transport::SMTP;
use Email::Stuffer;

sub register {
  my ($self, $app) = @_;

  $app->helper(
    'send_notify' => sub {
      my ($c, $addr, $data, $subj) = @_;    # addr, data, subj

      my $config = $app->config->{mail};

      my $msg =
        Email::Stuffer->to($addr)->from($config->{from})->subject($subj)->html_body($data)->transport(
        'SMTP', {
          host          => $config->{host},
          ssl           => 1,
          sasl_username => $config->{login},
          sasl_password => $config->{password},
        }
        );

      eval { $msg->send_or_die };

      if ($@) {
        $app->log->error("Can't send email to $addr: $@");
        return 0;
      }

      return 1;
    }
  );
}

1;
