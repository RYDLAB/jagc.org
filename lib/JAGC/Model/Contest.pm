package JAGC::Model::Contest;

use Mojo::Base 'MojoX::Model';
use Mango::BSON ':bson';

use constant {
  MATCH_INDEX => 0,
  SORT_INDEX => 1
};


sub upsert {    # create new contest or update existing one
  my ($self, %args) = @_;
  my $db = $self->app->db;

  my $s = $args{session};
  my $p = $args{params};                               # Mojo::Parameters
  my $v = _validate($args{validation}, $p->to_hash);

  my %res = (validation => $v);

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

  my $stats = $db->c('stat')->find({con => $con})->fields({score => 1, pic => 1, login => 1})
    ->sort(bson_doc(score => -1, t_all => -1, t_ok => -1))->limit(-10)->all;

  $res{stats} = $stats if @$stats;

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

sub contest_languages {
  my ($self, $oid) = @_;
  my $db = $self->app->db;

  my $contest = $db->c('contest')->find_one(bson_oid $oid);

  unless ($contest) {
    $self->app->log->error("Contest $oid not found!");
    return wantarray ? () : undef;
  }

  return $contest->{langs};
}

sub digest {
  my ($self, $cb) = @_;

  my $tnow = bson_time;

  my $db = $self->app->db;
  Mojo::IOLoop->delay(
    sub {
      my $d = shift;
  
      my $q = [
        undef, undef, # place for match and sort operators
        {'$limit' => 20},
        {'$lookup' => {from => 'task',    localField => '_id', foreignField => 'con', as => 'tasks'}},
        {
          '$project' => {
            name => 1,
            start_date => 1,
            end_date => 1,
            tasks      => {'$size' => '$tasks'},
            owner => 1,
          }
        }
      ];

      @$q[MATCH_INDEX] = { '$match' => { end_date => { '$lte' => $tnow }}};
      @$q[SORT_INDEX] = { '$sort' => {end_date => -1 }};
      $db->c('contest')->aggregate($q)->all($d->begin);

      @$q[MATCH_INDEX] = { '$match' => { '$and' => [
        { start_date => { '$lte' => $tnow }},
        { end_date => { '$gte' => $tnow }}]}};

      @$q[SORT_INDEX] = { '$sort' => {start_date => -1 }};
      $db->c('contest')->aggregate($q)->all($d->begin);

      @$q[MATCH_INDEX] = { '$match' => { start_date => { '$lte' => $tnow }}};
      $db->c('contest')->aggregate($q)->all($d->begin);
    },
    sub {
      my ($d, $aerr, $archive, $cerr, $current, $ferr, $future) = @_;

       if (my $e = $aerr || $cerr || $ferr) {
         return $cb->(err => "Error while db query: $e");
       }

      my @contests =  map { $_->{_id} } ( @$archive, @$current, @$future );

      # count solutions for contest
      $db->c('solution')->aggregate([
        { '$match' => { 'task.con' => {
          '$in' => [ @contests ]
        }}},
        { '$group' =>
          {
            _id => '$task.con',
            ok  => {'$sum' => {'$cond' => [{'$eq' => ['$s', "finished"]}, 1, 0]}},
            all => {'$sum' => 1},
          }
        }
      ])->all($d->begin);

      $d->data( archive => $archive, current => $current, future  => $future);

      $db->c('stat')->aggregate([
        {'$match' => {con => {'$in' => [ @contests ]}}},
        {'$sort' => {score => -1, t_ok => -1}},
        { '$group' => {
              _id => {con => '$con', t_all => '$t_all', score => '$score'},
              usr => {'$addToSet' => {login => '$login', pic => '$pic'}}
        }},
        {'$project' => {_id => '$_id.con', usr => 1,}}
      ])->all($d->begin);

    },
    sub {
      my ($d, $serr, $solutions, $werr, $winners) = @_;

      if (my $e = $serr || $werr) {
        return $cb->(err => "Error while db query: $e");
      }

      my %solutions;
      foreach my $s ( @$solutions ) {
        $solutions{$s->{_id}} = { ok => $s->{ok}, all => $s->{all} };
      }

      my %winners;

      foreach my $w ( @$winners ) {
        $winners{$w->{_id}} = $w->{usr};
      }

use Data::Dumper;
warn Dumper \%winners;

      $cb->(
        contests_archive => $d->data('archive'),
        contests_current => $d->data('current'),
        solutions => \%solutions,
        winners => \%winners,
      );
    }
  );
}

1;
