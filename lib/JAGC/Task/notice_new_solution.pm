package JAGC::Task::notice_new_solution;
use Mojo::Base -base;
use Mango::BSON ':bson';
use Mojo::URL;
use JAGC::Helpers::SendNotify qw( send_notify );

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

    send_notify($user->{email}, $data, "[JAGC] New solution in task $solution->{task}{name}");
  }

  $job->finish;
}

1;
