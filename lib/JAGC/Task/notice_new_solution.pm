package JAGC::Task::notice_new_solution;
use Mojo::Base -base;

use Mango::BSON ':bson';
use Mojo::URL;

sub call {
  my ($self, $job, $sid) = @_;

  my $db     = $job->app->db;
  my $config = $job->app->config;

  my $solution = $db->c('solution')->find_one($sid);
  my $notes = $db->c('notification')->find(bson_doc(tid => $solution->{task}{tid}, for => 'solution'))->all;
  my $users =
    $db->c('user')->find({_id => {'$in' => [map { $_->{uid} } @$notes]}}, {email => 1, login => 1})->all;

  my $c = $job->app->build_controller;
  $c->req->url->base(Mojo::URL->new($config->{site_url}));

  for my $user (@$users) {
    next if $user->{login} eq $solution->{user}{login};
    my $data = $c->render_to_string(
      'mail/new_solution',
      format => 'email',
      login  => $user->{login},
      user   => $solution->{user}{login},
      tname  => $solution->{task}{name},
      code   => $solution->{code},
      slink  => $c->url_for('task_view', id => $solution->{task}{tid})->fragment($sid)->to_abs,
      tlink  => $c->url_for('task_view', id => $solution->{task}{tid})->to_abs
    );

    my $tx = $job->app->ua->post(
      'https://mandrillapp.com/api/1.0/messages/send.json' => json => {
        key     => $config->{mail}{key},
        message => {
          html       => $data,
          subject    => "[JAGC] New solution in task $solution->{task}{name}",
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
