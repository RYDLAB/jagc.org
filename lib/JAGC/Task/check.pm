package JAGC::Task::check;
use Mojo::Base -base;

use File::Copy 'cp';
use File::Path 'remove_tree';
use File::Temp 'tempdir';
use Mango::BSON ':bson';
use Mojo::Util qw ( spurt encode);

sub prepare_container {
  my ($self, $app, $data, $sid, $lng) = @_;

  my @bin = ($lng->{path});
  push @bin, @{$lng->{args}} if $lng->{args};

  my $config = $app->config->{worker};
  my $log    = $app->log;

  # just checking if the container exists
  my $tx = $app->ua->get("$config->{api_server}/containers/solution_$sid/changes");
  return undef if $tx->success;

  my $tmp_dir = $self->{tmp_dir} = eval { tempdir DIR => $config->{shared_volume_dir} };
  $log->error("Can't create temp dir: $@") and return undef if $@;

  eval { spurt encode ('UTF-8', $data), "$tmp_dir/code" };
  $log->error("$@") and return undef if $@;

  $log->error("Can't copy starter: $!") and return undef
    unless cp $app->home->rel_file('script/starter'), $tmp_dir;

  $log->error("Can't set permissions for starter! $!") and return undef
    if 2 > chmod 0755, $tmp_dir, "$tmp_dir/starter";

  srand;
  my $opts = $config->{docker_opts};
  $opts->{User}  = (1024 + int rand 1024 * 10) . '';
  $opts->{Binds} = ["$tmp_dir:/opt/share"];
  push @{$opts->{Cmd}}, @bin;

  $tx = $app->ua->post("$config->{api_server}/containers/create?name=solution_$sid" => json => $opts);
  $log->error("Can't create container ". $tx->res->code ." ".$tx->res->body) and return undef unless $tx->success;

  $self->{container_id} = $tx->res->json->{Id};
  return 1;
}

sub destroy_container {
  my ($self, $app) = @_;

  remove_tree $self->{tmp_dir}, {error => \my $err};
  $app->log->warn("Can't remove directory $self->{tmp_dir}: " . $app->dumper($err)) if @$err;

  my $api_server = $app->config->{worker}{api_server};

  if (my $cid = $self->{container_id}) {
    my $tx = $app->ua->delete("$api_server/containers/$cid?v=1&force=1");
    return $app->log->error("Can't delete container '$cid'") unless $tx->success;
    $app->log->debug('Container was successfully destroyed!');
  }
}

sub run_test {
  my ($self, $app, $test) = @_;

  my $api_server = $app->config->{worker}{api_server};
  my $log        = $app->log;
  my $cid        = $self->{container_id};

  eval { spurt $test->{in}, "$self->{tmp_dir}/input" };
  $log->warn($@) and return undef if $@;

  $log->debug(sprintf 'Run test %s', $test->{_id});

  my $result;

  $app->ua->websocket(
    "$api_server/containers/$cid/attach/ws?stream=1&stdout=1" => sub {
      my ($ua, $tx) = @_;


      my $start_tx = $ua->post("$api_server/containers/$cid/start");

      $log->error("Can't start container! Status: " . $start_tx->res->body) and Mojo::IOLoop->stop
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

  my $app = $job->app;
  my $log = $app->log;
  my $db  = $app->db;

  my $solution =
    $db->c('solution')->find_and_modify({query => {_id => $sid}, update => {'$set' => {s => 'testing'}}});
  my $language = $db->c('language')->find_one({name => $solution->{lng}});
  my $task = $db->c('task')->find_one($solution->{task}{tid});

  unless ($self->prepare_container($app, $solution->{code}, $sid, $language)) {
    $db->c('solution')
      ->update({_id => $sid}, {'$set' => {s => 'fail', terr => undef, err => "Can't prepare container"}});
    $self->destroy_container($app);
    return $job->fail("Can't prepare container");
  }

  my ($status, $s) = 1;

  for my $test (@{$task->{tests}}) {
    my $result = $self->run_test($app, $test);
    $log->debug(sprintf 'Finish test %s with result %s', $test->{_id}, $app->dumper($result));

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

    $app->minion->enqueue(notice_new_solution => [$sid]);

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

  $self->destroy_container($app);
}

1;
