package JAGC::Model::Stat;

use Mojo::Base 'MojoX::Model';
use Mango::BSON ':bson';

sub _tasks_query {
  return [
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

}

sub _build_userlist {
  my $tasks = pop;
  
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

  return \%users;
}

sub _store_stats {
  my ($self, $users, $users_cnt, $con) = @_;
  my $db = $self->app->db;

  for my $uid (sort keys %$users) {
    my $u = $users->{$uid};
    my @tasks;
    for my $tid (sort keys %{$u->{tasks}}) {
      my $t = $u->{tasks}{$tid};
      push @tasks, {tid => bson_oid($tid), pos => $t->{pos}, sid => $t->{sid}, name => $t->{name}};
    }
    my $q = bson_doc(
      uid    => bson_oid($uid),
      login  => $u->{login},
      pic    => $u->{pic},
      t_ok   => $u->{t_ok},
      t_all  => $users_cnt->{$uid}{all},
      s_last => bson_doc(
        tid   => $users_cnt->{$uid}{last_tid},
        tname => $users_cnt->{$uid}{last_tname},
        ts    => $users_cnt->{$uid}{last_ts}
      ),
      score => $u->{score},
      tasks => \@tasks
    );

    $q->{con} = bson_oid $con if $con;
    $db->c('stat_tmp')->insert($q);
  }
}

sub _standalone_tasks {
  my $self = shift;
  my $col = $self->app->db->c('solution');

  my $q = _tasks_query;

  my $match = {'$match' => {s => 'finished', 'task.con' => { '$exists' => 0 }}};
  unshift @$q, $match;
  
  my $tasks = $col->aggregate($q)->all;
}

sub _contest_tasks {
  my ( $self, $con ) = @_;
  $con = bson_oid $con;

  my $col = $self->app->db->c('solution');

  my $q = _tasks_query;

  my $match = {'$match' => {s => 'finished', 'task.con' => $con}};
  unshift @$q, $match;
  
  my $tasks = $col->aggregate($q)->all;
}

sub _copy_old_stats {
  ...
}

sub _users_content_query {
  my ($self, $match) = @_;

  my $cnt = $self->app->db->c('solution')->aggregate([
        {'$match' => $match },
        {
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

  my %cnt;
  $cnt{$_->{_id}} =
    {all => $_->{sum}, last_ts => $_->{ts}, last_tname => $_->{last_tname}, last_tid => $_->{last_tid}}
    for @$cnt;

  return \%cnt;

}

sub calculate {
  my $self = shift;
  my $log = $self->app->log;
  my $db = $self->app->db;

  my $users_cnt = $self->_users_content_query({'task.con' => { '$exists' => 0 }});

  my $tasks = $self->_standalone_tasks;
  my $users = _build_userlist($tasks);
  $self->_store_stats($users, $users_cnt);

  my $contests = $db->c('contest')->find->all;
  my $tnow = bson_time;

  foreach my $cn ( @$contests ) {
    my $id = $cn->{_id};

#    if( $cn->{end_date} < $tnow ) {
#      $self->_copy_old_stats($id);
#      next;
#    }
    
    $tasks = $self->_contest_tasks($id);
    my $users = _build_userlist($tasks);
    my $users_cnt = $self->_users_content_query({'task.con' => $cn->{_id}});
    $self->_store_stats($users, $users_cnt, $id);
  }

  my $admin = $db->mango->db('admin');
  $admin->command(
    bson_doc(
      renameCollection => $db->c('stat_tmp')->full_name,
      to               => $db->c('stat')->full_name,
      dropTarget       => bson_true
    )
  );
}

1;
