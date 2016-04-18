package JAGC::Controller::Main;
use Mojo::Base 'Mojolicious::Controller';

use Mango::BSON ':bson';

sub index {
  my $c  = shift;
  my $db = $c->db;

  $c->delay(
    sub {
      my $d = shift;

      $db->c('task')->find({con => {'$exists' => 0}})->limit(20)->sort({ts => -1})
        ->fields({desc => 0, tests => 0})->all($d->begin);
      $db->c('task')->find({con => {'$exists' => 0}})->limit(20)->sort({'stat.all' => -1})
        ->fields({desc => 0, tests => 0})->all($d->begin);
      $db->c('stat')->find->fields({score => 1, pic => 1, login => 1})
        ->sort(bson_doc(score => -1, t_all => -1, t_ok => -1))->limit(-10)->all($d->begin);
      $db->c('solution')->aggregate([
          {'$match' => {s   => 'finished'}},
          {'$group' => {_id => '$lng', c => {'$sum' => 1}}},
          {'$sort' => bson_doc(c => -1, _id => 1)}
        ]
      )->all($d->begin);
    },
    sub {
      my ($d, $terr, $tasks, $pterr, $ptasks, $serr, $stats, $lerr, $languages) = @_;
      if (my $e = $terr || $pterr || $serr || $lerr) {
        return $c->reply->exception("Error while db query: $e");
      }

      $c->stash(tasks => $tasks, ptasks => $ptasks, stats => $stats, languages => $languages);
      $c->render;
    }
  );
}

sub logout {
  my $c = shift;
  $c->session(expires => 1);
  return $c->redirect_to('index');
}

sub admin {
  my $c = shift;

  my $uid = $c->session('uid');
  unless ($uid) {
    $c->reply->exception('Oops');
    return undef;
  }

  return $c->session('login') eq 'avkhozov';
}

sub verify {
  my $c = shift;

  my $uid = $c->session('uid');

  return 1 unless $uid;
  $uid = bson_oid $uid;

  $c->db->c('user')->find_one(
    ($uid, {ban => 1}) => sub {
      my ($col, $err, $user) = @_;
      return $c->reply->exception("Error in bridge verify: $err") if $err;

      unless ($user) {
        delete $c->session->{uid};
        delete $c->session->{login};
        delete $c->session->{pic};
        return $c->continue;
      }

      if ($user->{ban} == bson_true) {
        $c->flash(error => 'Your are banned');
        return $c->redirect_to('index');
      }

      $c->continue;
    }
  );
  return undef;
}

sub tasks {
  my $c = shift;

  my $limit = 20;
  my $page  = int $c->stash('page');

  my $db = $c->db;
  $c->delay(
    sub {
      my $d = shift;

      $db->c('task')->find({con => {'$exists' => 0}})->count($d->begin);
      $db->c('solution')->aggregate([
          {'$match' => {s   => 'finished', 'task.con' => {'$exists' => 0}}},
          {'$group' => {_id => '$lng',     c          => {'$sum'    => 1}}},
          {'$sort'  => {c   => -1,         _id        => 1}}
        ]
      )->all($d->begin);
    },
    sub {
      my ($d, $cerr, $tasks_number, $lerr, $languages) = @_;
      return $c->reply->exception("Error while count tasks: $cerr")   if $cerr;
      return $c->reply->exception("Error while get languages: $lerr") if $lerr;
      return $c->reply->not_found if (($page - 1) * $limit + 1 > $tasks_number);

      my $need_next_btn = 0;
      $need_next_btn = 1 if $page * $limit < $tasks_number;
      $c->stash(need_next_btn => $need_next_btn, languages => $languages);

      my $skip = ($page - 1) * $limit;
      $db->c('task')->find({con => {'$exists' => 0}})->sort({ts => -1})->skip($skip)->limit($limit)
        ->fields({desc => 0, tests => 0})->all($d->begin);
    },
    sub {
      my ($d, $terr, $tasks) = @_;
      return $c->reply->exception("Error while find tasks: $terr") if $terr;

      $c->stash(tasks => $tasks);
      return $c->render;
    }
  );
}

1;
