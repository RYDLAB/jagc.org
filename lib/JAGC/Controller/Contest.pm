package JAGC::Controller::Contest;

use Mojo::Base 'Mojolicious::Controller';
use Mango::BSON ':bson';

sub add_view {
  my $c = shift;

  my $db = $c->db;

  my $cur = $db->c('language')->find({}, {name => bson_true});
  my %langs = ();

  while (my $lng = $cur->next) {
    $langs{$lng->{name}}++;
  }

  my $last_langs = $c->stash('langs');

  if ($last_langs) {
    foreach my $lng (keys %langs) {
      $langs{$lng} = $last_langs->{$lng} ? 1 : 0;
    }
  }

  $c->stash(langs => \%langs);
  $c->render(action => 'add');
}

sub upsert {
  my $c = shift;

  return $c->reply->not_found unless $c->session('uid');

  my $params = $c->req->body_params;

  my %q = (session => $c->session, validation => $c->validation, params => $params);

  $q{con} = bson_oid $c->param('con') if $c->param('con');    # update existing contest if defined contest id

  my %res = $c->model('contest')->upsert(%q);

  return $c->reply->exception($res{err}) if exists $res{err};

  my $langs = $params->every_param('langs');

  # if only one language selected
  $langs = [$langs] unless ref $langs;

  if ($res{validation}->has_error) {

    # save checkboxes state
    $c->stash(langs => {map { $_ => 1 } @$langs});

    return $c->add_view;
  }

  return $c->redirect_to('contest_edit_view', con => $res{con});

}

sub edit_view {
  my $c = shift;

  return $c->reply->not_found unless $c->session('uid');

  my %res = $c->model('contest')->edit_view(session => $c->session, con => $c->param('con'));
  return $c->reply->not_found unless %res;

  $c->stash(%res);

  $c->render(action => 'edit');
}

sub contests {
  my $c = shift->render_later;

  $c->model('contest')->digest(
    sub {
      my %res = @_;

      return $c->reply->exception($res{err}) if $res{err};
      $c->render('contest/index' => @_);
    }
  );
}

sub view {
  my $c = shift->render_later;

  $c->model('contest')->view(
    $c->param('con'),
    sub {
      my %res = @_;

      return $c->reply->not_found unless $res{contest};
      return $c->reply->exception($res{err}) if $res{err};
      $c->render('/contest/view' => @_);
    }
  );
}

sub user_info {
  my $c = shift->render_later;

  $c->model('contest')->user_info(
    $c->param('con'),
    $c->param('login'),
    sub {
      my %res = @_;

      return $c->reply->not_found unless $res{user_stat};
      return $c->reply->exception($res{err}) if $res{err};
      $c->render('/user/contest_info' => @_);
    }
  );
}

sub events {
  my $c = shift->render_later;

  $c->model('event')->info(
    session => $c->session,
    page => $c->param('page'),
    con => $c->param('con'),
    login => $c->param('login'),
    cb => sub {
      my %res = @_;
      return $c->reply->not_found unless %res;
      return $c->reply->exception($res{err}) if $res{err};

      $c->render('/contest/event' => @_);
    }
  );
}

1;
