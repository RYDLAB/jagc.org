package JAGC::Controller::Event;
use Mojo::Base 'Mojolicious::Controller';

use Mango::BSON ':bson';

sub info {
  my $c = shift;

  my $page = int $c->stash('page');
  return $c->render_not_found if $page < 1;

  my $login = $c->stash('login');
  my $event_opt = $login ? {'user.login' => $login} : {};

  my $limit = 20;
  my $skip  = ($page - 1) * $limit;

  my $db = $c->db;
  $c->delay(
    sub {
      $db->collection('solution')->find($event_opt)->count(shift->begin);
    },
    sub {
      my ($d, $err, $count) = @_;
      return $c->render_exception("Error while get count of elements in solution : $err") if $err;
      return $c->render_not_found if $count > 0 && $count <= $skip;

      $c->stash(need_next_btn => ($count - $skip > $limit ? 1 : 0));
      $db->collection('solution')->find($event_opt)->sort({ts => -1})->skip($skip)->limit($limit)
        ->all($d->begin);
    },
    sub {
      my ($d, $qerr, $events) = @_;
      return $c->render_exception("Error while get solutions: $qerr") if $qerr;

      my %sid;
      map { $sid{$_->{task}{tid}} = undef } @{$events // []};
      $c->stash(events => $events // []);

      $db->collection('task')->find({_id => {'$in' => [map { bson_oid $_ } keys %sid]}})->all($d->begin);
    },
    sub {
      my ($d, $terr, $tasks) = @_;
      return $c->render_exception("Error while get tasks for solutions: $terr") if $terr;

      my %tasks;
      map { $tasks{$_->{_id}} = $_ } @$tasks;
      $c->stash(tasks => \%tasks);

      return $c->render unless $login;

      if (@{$c->stash('events')}) {
        return $c->render(action => 'user', user => $c->stash('events')->[0]->{user});
      }
      $db->collection('user')->find_one({login => $login}, {login => 1, pic => 1} => $d->begin);
    },
    sub {
      my ($d, $uerr, $user) = @_;
      return $c->render_exception("Error get user: $uerr") if $uerr;
      return $c->render_not_found unless $user;

      $c->render(action => 'user', user => $user);
    }
  );
}

1;
