package JAGC::Task::check;
use Mojo::Base -base;

use Mango::BSON ':bson';
use Mojo::JSON 'decode_json';
use File::Temp 'tempfile';

sub call {
  my ($self, $job, $sid) = @_;

  my $log    = $job->app->log;
  my $config = $job->app->config->{worker};
  my $db     = $job->app->db;

  my $image      = $config->{image};
  my $lxc_root   = sprintf '%s%s/rootfs', $config->{lxc_base}, $image;
  my $lxc_backup = $config->{backup};

  my $state = join '', `lxc-info -n $image 2>/dev/null`;
  $state //= '';
  return $job->fail('LXC container is missing') if $state !~ m/STOPPED/;

  my $solution = $db->collection('solution')
    ->find_and_modify({query => {_id => $sid}, update => {'$set' => {s => 'testing'}}});
  my $language = $db->collection('language')->find_one({name => $solution->{lng}});
  return $job->fail("Invalid language: $solution->{lng}") unless $language;
  my $task = $db->collection('task')->find_one({_id => $solution->{task}{tid}});

  open my $code, '>', "${lxc_root}/home/guest/code" or do {
    my $error = q{Can't create code inside container};
    $db->collection('solution')
      ->update({_id => $sid}, {'$set' => {s => 'fail', terr => undef, err => $error}});
    return $job->fail($error);
  };
  print $code $solution->{code};
  close $code;

  my ($status, $s) = 1;
  for my $test (@{$task->{tests}}) {
    open my $input, '>', "${lxc_root}/home/guest/input" or do {
      $log->warn("Can't create input test file: $!");
      $status = 0 && last;
    };
    binmode $input;
    print $input $test->{in};
    close $input;

    my ($out, $filename) = tempfile;

    $log->debug(sprintf 'Run test %s', $test->{_id});
    my $cmd = join ' ', 'lxc-start', '-L', $filename, '-n', $image, '/usr/bin/env', 'LANG=en_US.UTF-8',
      'LC_ALL=en_US.UTF-8', 'HOME=/home/guest/', '/usr/bin/perl', '/starter', $language->{path};
    system $cmd;

    my $result = decode_json <$out>;
    unlink $filename;
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

  $log->debug('Finish check solution');
  `rsync -aAX --delete $lxc_backup $lxc_root 2>/dev/null`;
  $log->debug('Finish restore image from backup');
  $job->finish;
}

1;
