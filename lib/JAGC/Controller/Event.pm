package JAGC::Controller::Event;
use Mojo::Base 'Mojolicious::Controller';

use Mango::BSON ':bson';
use Mojo::Util 'xml_escape';
use XML::RSS;

sub info {
  my $c = shift;

  my $page = int $c->stash('page');
  return $c->reply->not_found if $page < 1;

  my $login = $c->stash('login');
  my $event_opt = $login ? {'user.login' => $login} : {};

  my $limit = 20;
  my $skip  = ($page - 1) * $limit;

  my $db = $c->db;
  $c->delay(
    sub { $db->c('solution')->find($event_opt)->count(shift->begin) },
    sub {
      my ($d, $err, $count) = @_;
      return $c->reply->exception("Error while get count of elements in solution: $err") if $err;
      return $c->reply->not_found if $count > 0 && $count <= $skip;

      $c->stash(need_next_btn => ($count - $skip > $limit ? 1 : 0));
      $db->c('solution')->find($event_opt)->sort({ts => -1})->skip($skip)->limit($limit)->all($d->begin);
    },
    sub {
      my ($d, $qerr, $events) = @_;
      return $c->reply->exception("Error while get solutions: $qerr") if $qerr;

      my %sid;
      map { $sid{$_->{task}{tid}} = undef } @{$events // []};
      $c->stash(events => $events // []);

      $db->c('task')->find({_id => {'$in' => [map { bson_oid $_ } keys %sid]}})->all($d->begin);
    },
    sub {
      my ($d, $terr, $tasks) = @_;
      return $c->reply->exception("Error while get tasks for solutions: $terr") if $terr;

      my %tasks;
      map { $tasks{$_->{_id}} = $_ } @$tasks;
      $c->stash(tasks => \%tasks);

      return $c->render unless $login;

      if (@{$c->stash('events')}) {
        return $c->render(action => 'user', user => $c->stash('events')->[0]->{user});
      }
      $db->c('user')->find_one({login => $login}, {login => 1, pic => 1} => $d->begin);
    },
    sub {
      my ($d, $uerr, $user) = @_;
      return $c->reply->exception("Error get user: $uerr") if $uerr;
      return $c->reply->not_found unless $user;

      $c->render(action => 'user', user => $user);
    }
  );
}

sub rss {
  my $c = shift;

  $c->delay(
    sub { $c->db->c('solution')->find->sort({ts => -1})->limit(40)->all(shift->begin) },
    sub {
      my ($d, $err, $events) = @_;
      return $c->reply->exception("Error while get events: $err") if $err;

      my $rss = XML::RSS->new(version => '2.0');
      $rss->channel(
        title       => 'Events for JAGC',
        link        => $c->url_for('event_info')->to_abs,
        language    => 'en',
        description => 'New solutions for tasks on JAGC',
        ttl         => 1
      );
      for my $event (@{$events // []}) {
        $rss->add_item(
          title => sprintf('Solution for "%s" by %s' => $event->{task}{name}, $event->{user}{login}),
          permaLink => $c->url_for($event->{s} eq 'finished' ? 'task_view' : 'task_view_incorrect',
            id => $event->{task}{tid})->fragment($event->{_id})->to_abs,
          description => sprintf('<![CDATA[<html><pre>%s</pre></html>]]>', xml_escape $event->{code}),
          pubDate     => $event->{ts}->to_datetime
        );
      }

      $c->res->headers->content_type('application/rss+xml');
      $c->render(text => $rss->as_string);
    }
  );
}

1;
