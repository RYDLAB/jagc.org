package JAGC::Helpers::SendNotify;

use strict;
use warnings;

use Exporter;
our @ISA       = qw( Exporter );
our @EXPORT_OK = qw( send_notify );

use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP;
use Mojo::Util 'encode';

my $app;

sub set_app {
  $app = pop;
}

sub send_notify {
  my ($addr, $data, $subj) = @_;    # addr, data, subj

  die 'Please attach app to the package first!' unless $app;

  my $config = $app->config->{mail};

  my $email = Email::Simple->create(
    header =>
      ['Content-Type' => 'text/html; charset=utf-8', To => $addr, From => $config->{from}, Subject => $subj,],
    body => encode 'UTF-8',
    $data,
  );

  my $transport = Email::Sender::Transport::SMTP->new({
      host          => $config->{host},
      ssl           => 1,
      sasl_username => $config->{login},
      sasl_password => $config->{password},
    }
  );

  eval { sendmail($email, {transport => $transport}) };

  if ($@) {
    $app->log->error("Can't send email: $@");
    return 0;
  }

  return 1;
}

1;
