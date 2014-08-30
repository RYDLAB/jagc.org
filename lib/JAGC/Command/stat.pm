package JAGC::Command::stat;
use Mojo::Base 'Mojolicious::Command';

use Mango::BSON ':bson';

no if $] >= 5.018, warnings => 'experimental';

has description => 'Statistic JAGC.';
has usage => sub { shift->extract_usage };

sub run {
  my $self = shift;

  my $db  = $self->app->db;
  my $log = $self->app->log;

  $log->debug('Start calculate statistic');

  my $tasks = $db->collection('solution')->aggregate([
      {'$match' => {s => 'finished'}},
      {'$sort' => bson_doc(size => 1, ts => 1)},
      {
        '$group' => {
          _id  => {tid => '$task.tid', name => '$task.name'},
          user => {
            '$push' => {
              uid   => '$user.uid',
              pic   => '$user.pic',
              login => '$user.login',
              size  => '$size',
              sid   => '$_id'
            }
          }
        }
      }
    ]
  )->all;

  my $users_cnt = $db->collection('solution')->aggregate([{
        '$group' => {
          _id   => {uid      => '$user.uid', tid => '$task.tid'},
          ts    => {'$max'   => '$ts'},
          tname => {'$first' => '$task.name'}
        }
      },
      {'$sort' => {ts => -1}},
      {
        '$group' => {
          _id        => '$_id.uid',
          sum        => {'$sum' => 1},
          ts         => {'$first' => '$ts'},
          last_tname => {'$first' => '$tname'},
          last_tid   => {'$first' => '$_id.tid'}
        }
      }
    ]
  )->all;

  my %users_cnt;
  $users_cnt{$_->{_id}} =
    {all => $_->{sum}, last_ts => $_->{ts}, last_tname => $_->{last_tname}, last_tid => $_->{last_tid}}
    for @$users_cnt;


  my %users;
  for my $task (@$tasks) {
    my ($score, $pos) = (10, 1);
    for my $user (@{$task->{user}}) {
      my $uid = $user->{uid};
      $users{$uid}{login} = $user->{login};
      $users{$uid}{pic}   = $user->{pic};
      unless ($users{$uid}{tasks}{$task->{_id}{tid}}) {
        $users{$uid}{t_ok}  += 1;
        $users{$uid}{score} += $score--;
        $score = 0 if $score < 0;
        $users{$uid}{tasks}{$task->{_id}{tid}}{pos}  = $pos++;
        $users{$uid}{tasks}{$task->{_id}{tid}}{sid}  = $user->{sid};
        $users{$uid}{tasks}{$task->{_id}{tid}}{name} = $task->{_id}{name};
      }
    }
  }

  for my $uid (sort keys %users) {
    my $u = $users{$uid};
    my @tasks;
    for my $tid (sort keys %{$u->{tasks}}) {
      my $t = $u->{tasks}{$tid};
      push @tasks, {tid => bson_oid($tid), pos => $t->{pos}, sid => $t->{sid}, name => $t->{name}};
    }

    $db->collection('stat_tmp')->insert(
      bson_doc(
        _id    => bson_oid($uid),
        login  => $u->{login},
        pic    => $u->{pic},
        t_ok   => $u->{t_ok},
        t_all  => $users_cnt{$uid}{all},
        s_last => bson_doc(
          tid   => $users_cnt{$uid}{last_tid},
          tname => $users_cnt{$uid}{last_tname},
          ts    => $users_cnt{$uid}{last_ts}
        ),
        score => $u->{score},
        tasks => \@tasks
      )
    );
  }

  my $admin = $db->mango->db('admin');
  $admin->command(
    bson_doc(
      renameCollection => $db->collection('stat_tmp')->full_name,
      to               => $db->collection('stat')->full_name,
      dropTarget       => bson_true
    )
  );
  $log->debug('Finish script');
}

1;

=encoding utf8

=head1 NAME

JAGC::Command::stat - Calculate statistics for JAGC.

=head1 SYNOPSIS

  Usage: APPLICATION stat

  ./script/jagc stat

=cut
