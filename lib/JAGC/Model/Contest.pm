package JAGC::Model::Contest;

use Mojo::Base 'MojoX::Model';
use Mango::BSON ':bson';

use constant {MATCH_INDEX => 0, SORT_INDEX => 1};


sub upsert {    # create new contest or update existing one
  my ($self, %args) = @_;
  my $db = $self->app->db;

  my $s = $args{session};
  my $p = $args{params};                               # Mojo::Parameters
  my $v = _validate($args{validation}, $p->to_hash);

  my %res = (validation => $v);

  $res{con} = $args{con} if $args{con};

  my $langs = $p->every_param('langs');

  # if only one language selected
  $langs = [$langs] unless ref $langs;

  return %res if ($v->has_error);

  my $start_date = $self->app->date_to_bson($v->param('start_date'));
  my $end_date   = $self->app->date_to_bson($v->param('end_date'));

  if ($end_date < $start_date) {
    $res{err} = 'Bad end date!';
    return %res;
  }

  my $oid;
  my $uid = bson_oid($s->{uid});

  if ($args{con}) {
    $oid = bson_oid $args{con};

    $db->c('contest')->update(
      {'owner.uid' => $uid, _id => $oid},
      {
        '$set' => bson_doc(
          name       => $v->param('name'),
          desc       => $v->param('description'),
          owner      => bson_doc(uid => $uid, login => $s->{login}, pic => $s->{pic}),
          ts         => bson_time,
          start_date => $start_date,
          end_date   => $end_date,
          langs      => $langs,
        )
      }
    );
  } else {
    $oid = $db->c('contest')->insert(
      bson_doc(
        name       => $v->param('name'),
        desc       => $v->param('description'),
        owner      => bson_doc(uid => $uid, login => $s->{login}, pic => $s->{pic}),
        ts         => bson_time,
        start_date => $start_date,
        end_date   => $end_date,
        langs      => $langs,
      )
    );
  }

  return (validation => $v, con => $oid);
}

sub edit_view {
  my ($self, %args) = @_;
  my $db = $self->app->db;

  my $s   = $args{session};
  my $con = bson_oid $args{con};
  my $uid = bson_oid $s->{uid};

  my $contest = $db->c('contest')->find_one($con);
  my $langs   = $db->c('language')->find->all;

  return wantarray ? () : undef unless $contest;

  my %langs = ();

  $langs{$_->{name}} = 0 foreach @$langs;
  exists $langs{$_} && $langs{$_}++ foreach @{$contest->{langs}};

  unless ($contest->{owner}{uid} eq $uid) {
    $self->app->log->error("Error: not owner attempt to modify contest");
    return wantarray ? () : undef;
  }

  $contest->{start_date} = $self->app->bson_to_date($contest->{start_date});
  $contest->{end_date}   = $self->app->bson_to_date($contest->{end_date});
  my %res = (contest => $contest, langs => \%langs);

  my $tasks = $db->c('task')->find({con => $con})->all;

  $res{tasks} = $tasks if (@$tasks);

  return %res;
}

sub _validate {
  my ($v, $p) = @_;

  $v->input($p);
  $v->required('name')->size(1, 50, 'Length of contest name must be no more than 50 characters');
  $v->required('description')->size(1, 500, 'Length of description must be no more than 500 characters');
  $v->required('start_date');
  $v->required('end_date');
  $v->check_dates;
  $v->required('langs');

  return $v;
}

sub contest_stuff {
  my ($self, $oid) = @_;
  my $db = $self->app->db;

  my $contest = $db->c('contest')->find_one(bson_oid $oid);

  unless ($contest) {
    $self->app->log->error("Contest $oid not found!");
    return wantarray ? () : undef;
  }

  my $t = bson_time;

  my $active = 1 if $t >= $contest->{start_date} && $t <= $contest->{end_date};

  return ($contest->{langs}, $active);
}

sub digest {
  my ($self, $cb) = @_;

  my $tnow = bson_time;

  my $db = $self->app->db;
  Mojo::IOLoop->delay(
    sub {
      my $d = shift;

      my $q = [
        undef, undef,    # place for match and sort operators
        {'$limit'  => 20},
        {'$lookup' => {from => 'task', localField => '_id', foreignField => 'con', as => 'tasks'}},
        {
          '$project' =>
            {name => 1, start_date => 1, end_date => 1, tasks => {'$size' => '$tasks'}, owner => 1,}
        }
      ];

      @$q[MATCH_INDEX] = {'$match' => {end_date => {'$lte' => $tnow}}};
      @$q[SORT_INDEX] = {'$sort' => {end_date => -1}};
      $db->c('contest')->aggregate($q)->all($d->begin);

      @$q[MATCH_INDEX] = {'$match' => {end_date => {'$gte' => $tnow}}};

      @$q[SORT_INDEX] = {'$sort' => {start_date => -1}};
      $db->c('contest')->aggregate($q)->all($d->begin);
    },
    sub {
      my ($d, $aerr, $archive, $cerr, $current) = @_;

      if (my $e = $aerr || $cerr) {
        return $cb->(err => "Error while db query: $e");
      }

      my @contests = map { $_->{_id} } (@$archive, @$current);

      # count solutions for contest
      $db->c('solution')->aggregate([
          {'$match' => {'task.con' => {'$in' => [@contests]}}},
          {
            '$group' => {
              _id => '$task.con',
              ok  => {'$sum' => {'$cond' => [{'$eq' => ['$s', "finished"]}, 1, 0]}},
              all => {'$sum' => 1},
            }
          }
        ]
      )->all($d->begin);

      $d->data(archive => $archive, current => $current);

      $db->c('stat')->aggregate([
          {'$match' => {con => {'$in' => [@contests]}}},
          {'$sort' => {score => -1, t_ok => -1}},
          {
            '$group' => {
              _id => {con => '$con', t_all => '$t_all', score => '$score'},
              usr => {'$addToSet' => {login => '$login', pic => '$pic'}}
            }
          },
          {'$project' => {_id => '$_id.con', usr => 1,}}
        ]
      )->all($d->begin);

    },
    sub {
      my ($d, $serr, $solutions, $werr, $winners) = @_;

      if (my $e = $serr || $werr) {
        return $cb->(err => "Error while db query: $e");
      }

      my %solutions;
      foreach my $s (@$solutions) {
        $solutions{$s->{_id}} = {ok => $s->{ok}, all => $s->{all}};
      }

      my %winners;

      foreach my $w (@$winners) {
        $winners{$w->{_id}} = $w->{usr};
      }

      $cb->(
        contests_archive => $d->data('archive'),
        contests_current => $d->data('current'),
        solutions        => \%solutions,
        winners          => \%winners,
        today            => bson_time
      );
    }
  );
}

sub view {
  my ($self, $id, $cb) = @_;

  $id = bson_oid $id;
  my $db = $self->app->db;

  Mojo::IOLoop->delay(
    sub {
      my $d = shift;
      $db->c('contest')->find_one($id => $d->begin);
      $db->c('task')->find({con => $id})->all($d->begin);
      $db->c('stat')->aggregate([
          {'$match' => {con => $id}},
          {'$limit' => 20},
          {
            '$group' => {
              _id => {score => '$score', t_ok => '$t_ok'},
              users => {'$addToSet' => {login => '$login', 'pic' => '$pic'}}
            }
          },
          {'$sort'    => {'_id.score' => -1,           '_id.t_ok' => -1}},
          {'$project' => {score       => '$_id.score', users      => '$users'}}
        ]
      )->all($d->begin);
    },
    sub {
      my ($d, $cerr, $contest, $terr, $tasks, $serr, $stats) = @_;

      if (my $e = $cerr || $terr || $serr) {
        return $cb->(err => "Error while db query: $e");
      }

      $cb->(contest => $contest, tasks => $tasks, stats => $stats);
    }
  );
}

sub user_info {
  my ($self, $id, $login, $cb) = @_;
  my $db = $self->app->db;

  Mojo::IOLoop->delay(
    sub { $db->c('stat')->find_one({con => bson_oid($id), login => $login} => shift->begin) },
    sub {
      my ($d, $serr, $stats) = @_;

      return $cb->(err => $serr) if $serr;

      return $db->c('user')->find_one({login => $login} => shift->begin) unless defined $stats;
      $cb->(user_stat => $stats);
    },
    sub {    # if score for a user was not calculated yet
      my ($d, $uerr, $user) = @_;

      return $cb->(err => $uerr) if $uerr;

      @{$user}{'score', 'tasks'} = (0, []);
      $cb->(user_stat => $user);
    }
  );
}

1;
