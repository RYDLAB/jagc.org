package JAGC::Task::check;
use Mojo::Base -base;

use Mango::BSON ':bson';
use Mojo::JSON 'decode_json';
use File::Temp 'tempdir';
use File::Copy 'cp';
use Mojo::IOLoop::Delay;

has [qw/ app container tmp_dir /];

sub prepare_container {
  my ($self, $job, $data, $sid, $bin) = @_;
  my $api_server = $self->app->config->{worker}{api_server};
  my $log        = $self->app->log;

  return 1 if $self->app->mode eq 'test';

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

    my $q = $self->app->config->{worker}{create_container_query};
    $q->{Binds} = ["$tmp_dir:/opt/share"];
    push @{$q->{Cmd}}, $bin;

    $tx = $self->app->ua->post("$api_server/containers/create?name=solution_$sid" => json => $q);
  }

  $log->error(q(Can't create container!)) and return undef unless $tx->success;
  $self->container($tx->res->json->{Id});

  open my $code, '>', $self->tmp_dir . '/code' or do {
    my $error = q{Can't create code inside shared volume};
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
  return if $self->app->mode eq 'test';
  my $log = $self->app->log;
  my $cid = $self->container;

  $log->debug('Finish check solution');

  unlink map { "$self->{tmp_dir}/$_" } (qw/ input code starter /);

  my $tmp_dir = $self->{tmp_dir};

  $log->warn("Can't remove directory $tmp_dir: $!") unless rmdir($tmp_dir);

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

  return {status => 'ok', stderr => '', stdout => "$test->{out}"} if $self->app->mode eq 'test';

  open my $input, '>', "$self->{tmp_dir}/input" or do {
    $self->app->log->warn("Can't create input test file: $!");
    return;
  };

  binmode $input;
  print $input $test->{in};
  close $input;

  $log->debug(sprintf 'Run test %s', $test->{_id});

  my $delay = Mojo::IOLoop::Delay->new;

  my $message = '';
  my $end     = $delay->begin;
  $self->app->ua->websocket(
    "$api_server/containers/$cid/attach/ws?stream=1&stdout=1" => sub {
      my ($ua, $tx) = @_;

      $log->warn('WebSocket handshake failed!') and return unless $tx->is_websocket;

      my $start_tx = $ua->post("$api_server/containers/$cid/start");

      $log->error(q(Can't start container! Status code: ) . $start_tx->res->body) and return
        unless $start_tx->success;

      $tx->on(
        finish => sub {
          my ($tx, $code, $reason) = @_;
          $self->app->ua->post("$api_server/containers/$cid/stop?t=1");
          $end->();
        }
      );

      $tx->on(
        message => sub {
          my ($tx, $msg) = @_;
          $message = $msg;
          $tx->finish;
        }
      );
    }
  );

  $delay->wait();

  my $res_json = eval { decode_json $message };

  if ($@) {
    $log->error("Attempt to parse json respons has failed: $@");
    return undef;
  }

  $log->debug(sprintf 'Run test %s', $test->{_id});

  return $res_json;
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

    $status = 0 && last unless $result;
    my $rs = $result->{status};

    $log->debug(sprintf 'Finish test %s with status %s and error %s', $test->{_id}, $rs, $result->{stderr});
    my $err = substr $result->{stderr}, 0, 1024;

    $result->{stdout}|= '';
    (my $stdout = $result->{stdout}) =~ s/^\n*|\n*$//g;

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
