package JAGC::Task::check;
use Mojo::Base -base;

use Mango::BSON ':bson';
use Mojo::JSON 'decode_json';
use File::Temp 'tempfile';

has [qw/app image lxc_root lxc_backup/];

sub check_container {
  my $self = shift;
  return 1 if $self->app->mode eq 'test';

  my $state = `lxc-info -n $self->{image} 2>/dev/null`;
  return ($state // '') =~ /STOPPED/;
}

sub prepare_container {
  my ($self, $job, $data, $sid) = @_;
  return 1 if $self->app->mode eq 'test';

  open my $code, '>', "$self->{lxc_root}/home/guest/code" or do {
    my $error = q{Can't create code inside container};
    $self->app->db->collection('solution')
      ->update({_id => $sid}, {'$set' => {s => 'fail', terr => undef, err => $error}});
    $job->fail($error);
    return;
  };
  print $code $data;
  close $code;
  return 1;
}

sub reset_container {
  my $self = shift;
  return if $self->app->mode eq 'test';

  $self->app->log->debug('Finish check solution');
  `rsync -aAX --delete $self->{lxc_backup} $self->{lxc_root} 2>/dev/null`;
  $self->app->log->debug('Finish restore image from backup');
}

sub run_test {
  my ($self, $test, $bin) = @_;
  return {status => 'ok', stderr => '', stdout => "$test->{out}"} if $self->app->mode eq 'test';

  open my $input, '>', "$self->{lxc_root}/home/guest/input" or do {
    $self->app->log->warn("Can't create input test file: $!");
    return;
  };
  binmode $input;
  print $input $test->{in};
  close $input;

  my ($out, $filename) = tempfile;

  $self->app->log->debug(sprintf 'Run test %s', $test->{_id});
  my $cmd = join ' ', 'lxc-start', '-L', $filename, '-n', $self->image, '/usr/bin/env', 'LANG=en_US.UTF-8',
    'LC_ALL=en_US.UTF-8', 'HOME=/home/guest/', '/usr/bin/perl', '/starter', $bin;
  system $cmd;

  my $result = decode_json <$out>;
  unlink $filename;
  return $result;
}

sub call {
  my ($self, $job, $sid) = @_;

  my $log    = $job->app->log;
  my $config = $job->app->config->{worker};
  my $db     = $job->app->db;

  $self->app($job->app);
  $self->image($config->{image});
  $self->lxc_root(sprintf '%s%s/rootfs', $config->{lxc_base}, $config->{image});
  $self->lxc_backup($config->{backup});

  return $job->fail('LXC container is missing') unless $self->check_container;

  my $solution = $db->collection('solution')
    ->find_and_modify({query => {_id => $sid}, update => {'$set' => {s => 'testing'}}});
  my $language = $db->collection('language')->find_one({name => $solution->{lng}});
  return $job->fail("Invalid language: $solution->{lng}") unless $language;

  my $task = $db->collection('task')->find_one($solution->{task}{tid});

  return unless $self->prepare_container($job, $solution->{code}, $sid);

  my ($status, $s) = 1;
  for my $test (@{$task->{tests}}) {
    my $result = $self->run_test($test, $language->{path});
    $status = 0 && last unless $result;
    my $rs = $result->{status};

    $log->debug(sprintf 'Finish test %s with status %s and error %s', $test->{_id}, $rs, $result->{stderr});
    my $err = substr $result->{stderr}, 0, 1024;
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
      $db->collection('solution')
        ->update({_id => $sid}, {'$set' => {s => $s, terr => $test->{_id}, err => $err, out => $stdout}});
      $db->collection('task')
        ->find_and_modify({query => {_id => $task->{_id}}, update => {'$inc' => {'stat.all' => 1}}});
      last;
    }
  }

  if ($status) {
    $db->collection('solution')->update({_id => $sid}, {'$set' => {s => 'finished'}});
    $db->collection('task')
      ->find_and_modify(
      {query => {_id => $task->{_id}}, update => {'$inc' => {'stat.all' => 1, 'stat.ok' => 1}}});

    $job->app->minion->enqueue(notice_new_solution => [$sid]);

    my $winner = $solution->{user};
    $winner->{size} = $solution->{size};
    $winner->{ts}   = $solution->{ts};

    $db->collection('task')->find_and_modify({
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

  $self->reset_container;
  $job->finish;
}

1;
