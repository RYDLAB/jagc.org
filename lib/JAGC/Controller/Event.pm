package JAGC::Controller::Event;
use Mojo::Base 'Mojolicious::Controller';

use Mango::BSON ':bson';
use Mojo::Util 'xml_escape';
use XML::RSS;

sub info {
  my $c = shift->render_later;

  $c->model('event')->info(
    page => $c->param('page'),
    login => $c->param('login'),
    cb => sub {
      my %res = @_;
      return $c->reply->not_found unless %res;
      return $c->reply->exception($res{err}) if $res{err};

      $c->stash(@_);

      return $c->render unless  $res{login};
      $c->render('action' => 'user');
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
