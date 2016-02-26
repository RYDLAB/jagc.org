package JAGC::Task::check;
use Mojo::Base -base;

use File::Copy 'cp';
use File::Path 'remove_tree';
use File::Temp 'tempdir';
use Mango::BSON ':bson';

has [qw/app container tmp_dir/];

sub prepare_container {
  my ($self, $job, $data, $sid, $bin) = @_;

  my $api_server = $self->app->config->{worker}{api_server};
  my $log        = $self->app->log;

  # just checking if the container exists
  my $tx = $self->app->ua->get("$api_server/containers/solution_$sid/changes");

  unless ($tx->success) {

    my $tmp_dir = eval { tempdir(DIR => $self->app->config->{worker}{shared_volume_dir}) };

    $log->error("Can't create temp dir! $@") and return undef if $@;
    $self->tmp_dir($tmp_dir);

    unless (cp($self->app->home->rel_file('script/starter'), $tmp_dir)) {
      $log->error("Can't copy starter! $!");
      return undef;
    }

    if (chmod(0755, $tmp_dir, "$tmp_dir/starter") < 2) {
      $log->error("Can't set permissions for starter! $!");
      return undef;
    }

    my $opts = $self->app->config->{worker}{docker_opts};
    $opts->{User}  = (1024 + int rand 1024 * 10) . '';
    $opts->{Binds} = ["$tmp_dir:/opt/share"];
    push @{$opts->{Cmd}}, $bin;

    $tx = $self->app->ua->post("$api_server/containers/create?name=solution_$sid" => json => $opts);
  }

  $log->error("Can't create container!") and return undef unless $tx->success;
  $self->container($tx->res->json->{Id});

  open my $code, '>', $self->tmp_dir . '/code' or do {
    my $error = "Can't create code inside shared volume";
    $self->app->db->c('solution')
      ->update({_id => $sid}, {'$set' => {s => 'fail', terr => undef, err => $error}});
    $job->fail($error);
    return;
  };
  print $code $data;
  close $code;
  return 1;
}

sub destroy_container {
  my $self = shift;

  my $log = $self->app->log;
  my $cid = $self->container;

  remove_tree $self->{tmp_dir}, {error => \my $err};
  $log->warn("Can't remove directory $self->{tmp_dir}: " . $self->app->dumper($err)) if @$err;

  my $api_server = $self->app->config->{worker}{api_server};

  if ($cid) {
    my $tx = $self->app->ua->delete("$api_server/containers/$cid?v=1");
    return $log->error("Can't delete container '$cid'!") unless $tx->success;
    $log->debug('Container was successfully destroyed!');
  }
}

sub run_test {
  my ($self, $test) = @_;

  my $api_server = $self->app->config->{worker}{api_server};
  my $log        = $self->app->log;
  my $cid        = $self->container;

  open my $input, '>', "$self->{tmp_dir}/input" or do {
    $log->warn("Can't create input test file: $!");
    return;
  };

  binmode $input;
  print $input $test->{in};
  close $input;

  $log->debug(sprintf 'Run test %s', $test->{_id});

  my $result;

  $self->app->ua->websocket(
    "$api_server/containers/$cid/attach/ws?stream=1&stdout=1" => sub {
      my ($ua, $tx) = @_;

      my $start_tx = $ua->post("$api_server/containers/$cid/start");
      $log->error("Can't start container! Status code: " . $start_tx->res->code) and Mojo::IOLoop->stop
        unless $start_tx->success;

      $tx->on(finish => sub { $ua->post("$api_server/containers/$cid/stop?t=1"); Mojo::IOLoop->stop; });
      $tx->on(json => sub { my ($tx, $json) = @_; $result = $json; });
    }
  );
  Mojo::IOLoop->start;

  return $result;
}

sub call {
  my ($self, $job, $sid) = @_;

  $job->on(failed => sub { $self->destroy_container });

  my $log    = $job->app->log;
  my $config = $job->app->config->{worker};
  my $db     = $job->app->db;

  $self->app($job->app);

  my $solution =
    $db->c('solution')->find_and_modify({query => {_id => $sid}, update => {'$set' => {s => 'testing'}}});
  my $language = $db->c('language')->find_one({name => $solution->{lng}});
  return $job->fail("Invalid language: $solution->{lng}") unless $language;

  my $task = $db->c('task')->find_one($solution->{task}{tid});

  unless ($self->prepare_container($job, $solution->{code}, $sid, $language->{path})) {
    $job->fail(q(Can't prepare container!));
    return;
  }

  my ($status, $s) = 1;

  for my $test (@{$task->{tests}}) {
    my $result = $self->run_test($test);
    $log->debug(sprintf 'Finish test %s with result %s', $test->{_id}, $job->app->dumper($result));

    do { $status = 0; last } unless $result;
    my $rs = $result->{status};
    my $err = substr $result->{stderr}, 0, 1024;
    (my $stdout = ($result->{stdout} // '')) =~ s/^\n*|\n*$//g;

    if ($rs eq 'ok') {
      next if $test->{out} eq $stdout;
      $log->debug("'$test->{out}' VS '$stdout'");
      $s = 'incorrect', $status = 0;
    } elsif ($rs eq 'error') {
      $log->debug('Client code failed');
      $s = 'error', $status = 0;
    } elsif ($err =~ m/IPC::Run: timeout on timer/) {
      $log->debug('Client code works long');
      $s = 'timeout', $status = 0;
    } else {
      $s = 'fail', $status = 0;
    }

    unless ($status) {
      $db->c('solution')
        ->update({_id => $sid}, {'$set' => {s => $s, terr => $test->{_id}, err => $err, out => $stdout}});
      $db->c('task')
        ->find_and_modify({query => {_id => $task->{_id}}, update => {'$inc' => {'stat.all' => 1}}});
      last;
    }
  }

  if ($status) {
    $db->c('solution')->update({_id => $sid}, {'$set' => {s => 'finished'}});
    $db->c('task')
      ->find_and_modify(
      {query => {_id => $task->{_id}}, update => {'$inc' => {'stat.all' => 1, 'stat.ok' => 1}}});

    $job->app->minion->enqueue(notice_new_solution => [$sid]);

    my $winner = $solution->{user};
    $winner->{size} = $solution->{size};
    $winner->{ts}   = $solution->{ts};

    $db->c('task')->find_and_modify({
        query => {
          _id   => $task->{_id},
          '$or' => [
            {'winner.size' => {'$exists' => bson_false}},
            {'winner.size' => {'$gt'     => $solution->{size}}},
            {'$and' => [{'winner.size' => $solution->{size}}, {'winner.ts' => {'$gt' => $solution->{ts}}}]}
          ]
        },
        update => {'$set' => {winner => $winner}}
      }
    );
  }

  $self->destroy_container;
  $job->finish;
}

1;
