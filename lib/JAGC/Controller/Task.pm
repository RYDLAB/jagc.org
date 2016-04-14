package JAGC::Controller::Task;
use Mojo::Base 'Mojolicious::Controller';

use HTML::StripScripts::Parser;
use Mojo::Util qw/encode decode trim/;
use Mango::BSON ':bson';
use Text::Markdown 'markdown';

sub add {
  my $c = shift;

  return $c->reply->not_found unless $c->session('uid');

  my %q = (validation => $c->validation, params => $c->req->params, session => $c->session);
  $q{con} = $c->param('con') if $c->param('con');

  my %res = $c->model('task')->add(%q);

  my $v = $res{validation};

  if ($v->has_error) {
    $c->stash(alert_error => 'You need create at least 5 tests') if $v->has_error('enough_tests');
    return $c->render(action => 'add');
  }

  return $c->reply->exception("Error while insert task: $res{err}") if $res{err};

  return $c->redirect_to('contest_task_view', id => $res{tid}) if $c->param('con');

  $c->app->minion->enqueue(notice_new_task => [$res{tid}]);
  $c->redirect_to('task_view', id => $res{tid});
}

sub add_view {
  my $c = shift;
  $c->render(action => 'add');
}

sub comments {
  my $c = shift;

  my $id = bson_oid $c->stash('id');
  my $db = $c->db;
  $c->delay(
    sub {
      my $d = shift;

      $db->c('task')->find_one($id => $d->begin);
      $db->c('comment')->find(bson_doc(type => 'task', tid => $id, del => bson_false))
        ->sort(bson_doc(ts => 1))->all($d->begin);
    },
    sub {
      my ($d, $terr, $task, $cerr, $comments) = @_;
      return $c->reply->exception("Error while find_one task with $id: $terr") if $terr;
      return $c->reply->not_found unless $task;
      return $c->reply->exception("Error while find comments: $cerr") if $cerr;

      $c->stash(task => $task, comments => $comments);
      $c->render(action => 'comments');
    }
  );
}

sub solution_comments {
  my $c = shift;

  my $id = bson_oid $c->stash('id');
  my $db = $c->db;
  $c->delay(
    sub {
      my $d = shift;

      $db->c('solution')->find_one($id => $d->begin);
      $db->c('comment')->find(bson_doc(type => 'solution', sid => $id, del => bson_false))
        ->sort(bson_doc(ts => 1))->all($d->begin);
    },
    sub {
      my ($d, $serr, $solution, $cerr, $comments) = @_;
      return $c->reply->exception("Error while find_one solution with $id: $serr") if $serr;
      return $c->reply->not_found unless $solution;
      return $c->reply->exception("Error while find comments: $cerr") if $cerr;

      $c->stash(solution => $solution, comments => $comments);
      $c->render(action => 'solution_comments');
    }
  );
}

sub view {
  my $c = shift;

  my %res = $c->model('task')->view(tid => $c->param('id'), s => $c->stash('s'), session => $c->session,);
  return $c->reply->not_found unless %res;

  $c->stash(%res);
  $c->render( 'task/view' );
}

sub edit_view {
  my $c = shift;

  my $uid = $c->session('uid');
  return $c->reply->not_found unless $uid;

  my $tid = bson_oid $c->stash('tid');
  my $db  = $c->db;
  $c->delay(
    sub {
      $db->c('task')->find_one($tid => shift->begin);
    },
    sub {
      my ($d, $terr, $task) = @_;
      return $c->reply->exception("Error while find_one task $tid: $terr") if $terr;
      return $c->reply->not_found unless $task;

      unless ($task->{owner}{uid} eq $uid) {
        $c->app->log->error("Error: not owner attempt to modify task");
        return $c->reply->not_found;
      }
      $c->stash(task => $task);
      $c->render(action => 'edit');
    }
  );
}

sub edit {
  my $c = shift;

  my $uid = $c->session('uid');
  return $c->reply->not_found unless $uid;

  my $tid    = bson_oid $c->stash('tid');
  my $db     = $c->db;
  my $params = $c->req->body_params;
  $c->delay(
    sub {
      $db->c('task')->find_one($tid => shift->begin);
    },
    sub {
      my ($d, $terr, $task) = @_;
      return $c->reply->exception("Error while find_one task $tid: $terr") if $terr;
      return $c->reply->not_found unless $task;

      unless ($task->{owner}{uid} eq $uid) {
        $c->app->log->error("Error: not owner attempt to modify task");
        return $c->reply->not_found;
      }

      my $hparams = $params->to_hash;
      my @test_fields = grep { /^test_/ } @{$params->names};

      for (@test_fields) {
        $hparams->{$_} =~ s/\r\n/\n/g;
        $hparams->{$_} =~ s/^\n*|\n*$//g;
      }

      my $to_validate = {name => trim($hparams->{name}), description => trim($hparams->{description})};
      $to_validate->{$_} = $hparams->{$_} for @test_fields;

      my $v = $c->validation;
      $v->input($to_validate);
      $v->required('name')->size(1, 50, 'Length of task name must be no more than 50 characters');
      $v->required('description')->size(1, 500, 'Length of description must be no more than 500 characters');
      $v->required($_)->size(1, 100000, 'Length of test must be no more than 100000 characters')
        for @test_fields;

      my $tnum = grep { /^test_\d+_in$/ } @{$params->names};
      if ($v->has_error || $tnum < 5) {
        $c->stash(alert_error => 'You need add at least 5 tests') if $tnum < 5;
        return $c->edit_view;
      }

      my $is_change_tests = 0;
      my $test_cnt = scalar grep { /^test_\d+_in$/ } @{$params->names};
      $is_change_tests = 1 unless (scalar(@{$task->{tests}}) == $test_cnt);
      if ($is_change_tests == 0) {
        for (1 .. $test_cnt) {
          my $in_o  = decode 'UTF-8', $task->{tests}->[$_ - 1]->{in};
          my $out_o = decode 'UTF-8', $task->{tests}->[$_ - 1]->{out};
          my $in_n  = $v->param('test_' . $_ . '_in');
          my $out_n = $v->param('test_' . $_ . '_out');
          unless ($in_o eq $in_n && $out_o eq $out_n) { $is_change_tests = 1; last }
        }
      }

      my @tests;
      if ($is_change_tests) {

        for my $tin (grep { /^test_\d+_in$/ } @{$params->names}) {
          (my $tout = $tin) =~ s/in/out/;
          my $test_in  = $v->param($tin);
          my $test_out = $v->param($tout);
          my $test     = bson_doc(
            _id => bson_oid,
            in  => bson_bin(encode 'UTF-8', $test_in),
            out => bson_bin(encode 'UTF-8', $test_out),
            ts  => bson_time
          );
          push @tests, $test;
        }
      }

      $d->data(tname           => $v->param('name'));
      $d->data(is_change_tests => $is_change_tests);

      my $tupdate_opt =
        {'$set' => {name => $v->param('name'), desc => $v->param('description'), ts => bson_time}};
      if ($is_change_tests) {
        $tupdate_opt->{'$set'}{tests}      = \@tests;
        $tupdate_opt->{'$set'}{'stat.all'} = 0;
        $tupdate_opt->{'$set'}{'stat.ok'}  = 0;
        $tupdate_opt->{'$unset'}{'winner'} = 1;
      }
      $db->c('task')->update(({_id => $tid}, $tupdate_opt) => $d->begin);

      my $supdate_opt = {'task.name' => $v->param('name')};
      $supdate_opt->{s} = 'inactive' if $is_change_tests;
      $db->c('solution')->update({'task.tid' => $tid}, {'$set' => $supdate_opt}, {multi => 1} => $d->begin);
    },
    sub {
      my ($d, $err, $num, $uerr, $update) = @_;
      return $c->reply->exception("Error while update task: $err")       if $err;
      return $c->reply->exception("Error while update solutions: $uerr") if $uerr;

      $c->minion->enqueue(recheck => [$tid] => {priority => 0}) if $d->data('is_change_tests');

      return $c->redirect_to('task_view', id => $tid);
    }
  );
}

sub view_solutions {
  my $c = shift;

  my $id    = bson_oid $c->stash('id');
  my $page  = int $c->stash('page');
  my $limit = 30;
  my $skip  = ($page - 1) * $limit;

  my $db = $c->db;
  $c->delay(
    sub {
      my $d = shift;

      my $collection = $db->c('solution');
      my $cursor;
      if ($c->stash('s') == 1) {
        $cursor = $collection->find(bson_doc('task.tid' => $id, s => 'finished'));
      } elsif ($c->stash('s') == 0) {
        $cursor =
          $collection->find(bson_doc('task.tid' => $id, s => {'$in' => [qw/incorrect timeout error/]}));
      }
      $d->data(cursor => $cursor);
      $cursor->count($d->begin);
    },
    sub {
      my ($d, $cerr, $count) = @_;
      return $c->reply->exception("Error while count solutions: $cerr") if $cerr;
      return $c->reply->not_found if $count <= $skip;

      $c->stash(need_next_btn => ($count - $skip > $limit ? 1 : 0));
      $d->data('cursor')->all($d->begin);
      $db->c('task')->find_one($id, {tests => 1} => $d->begin);
    },
    sub {
      my ($d, $serr, $solutions, $terr, $task) = @_;
      return $c->reply->exception("Error while find solution: $serr")     if $serr;
      return $c->reply->exception("Error while find_one task $id: $terr") if $terr;
      return $c->reply->not_found unless $task;

      $c->stash(solutions => $solutions, task => $task);
      $c->render(action => 'solution');
    }
  );
}

sub comment_delete {
  my $c = shift;

  my $uid = $c->session('uid');
  return $c->reply->not_found unless $uid;

  my $id = bson_oid $c->stash('id');
  $c->db->c('comment')->update(
    {_id => $id, 'user.uid' => $uid},
    {'$set' => {del => bson_true}},
    sub {
      my ($db, $err, $upd) = @_;
      return $c->reply->exception("Error while update comment with $id: $err") if $err;

      $c->redirect_to($c->req->headers->referrer);
    }
  );
}

sub comment_add {
  my $c = shift;

  my $uid = $c->session('uid');
  return $c->reply->not_found unless $uid;

  my $id = bson_oid $c->stash('id');

  my $db = $c->db;
  $c->delay(
    sub {
      $db->c('task')->find_one($id => shift->begin);
    },
    sub {
      my ($d, $err, $task) = @_;
      return $c->reply->exception("Error while find_one task with $id: $err") if $err;
      return $c->reply->not_found unless $task;

      $c->stash(task => $task);
      my $v = $c->validation;
      $v->required('text')->size(1, 100000, 'Length of comment must be no more than 100000 characters');

      return $c->comments if $v->has_error;

      my $html = markdown $v->param('text');
      my $hss  = HTML::StripScripts::Parser->new;
      $html = $hss->filter_html($html);

      if (my $cid = $c->req->param('cid')) {
        $d->data(update => 1);
        $db->c('comment')->update({_id => bson_oid($cid), 'user.uid' => $uid},
          {'$set' => {text => $v->param('text'), html => $html, edit => bson_true}} => $d->begin);
      } else {
        $db->c('comment')->insert(
          bson_doc(
            type => 'task',
            tid  => $id,
            sid  => undef,
            ts   => bson_time,
            del  => bson_false,
            edit => bson_false,
            user => bson_doc(uid => $uid, login => $c->session('login'), pic => $c->session('pic')),
            text => $v->param('text'),
            html => $html
          ) => $d->begin
        );
      }
    },
    sub {
      my ($d, $err, $cid) = @_;
      return $c->reply->exception("Error while insert comment: $err") if $err;

      $c->minion->enqueue(notice_new_comment => [$cid, $c->stash('task')->{name}]) unless $d->data('update');
      $c->redirect_to('task_comments', id => $id);
    }
  );
}

sub solution_comment_add {
  my $c = shift;

  my $uid = $c->session('uid');
  return $c->reply->not_found unless $uid;

  my $id = bson_oid $c->stash('id');
  my $db = $c->db;
  $c->delay(
    sub {
      $db->c('solution')->find_one($id => shift->begin);
    },
    sub {
      my ($d, $err, $solution) = @_;
      return $c->reply->exception("Error while find_one solution with $id: $err") if $err;
      return $c->reply->not_found unless $solution;

      $c->stash(solution => $solution);
      my $v = $c->validation;
      $v->required('text')->size(1, 100000, 'Length of comment must be no more than 100000 characters');

      return $c->solution_comments if $v->has_error;

      my $html = markdown $v->param('text');
      my $hss  = HTML::StripScripts::Parser->new;
      $html = $hss->filter_html($html);

      if (my $cid = $c->req->param('cid')) {
        $d->data(update => 1);
        $db->c('comment')->update({_id => bson_oid($cid), 'user.uid' => $c->session('uid')},
          {'$set' => {text => $v->param('text'), html => $html, edit => bson_true}} => $d->begin);
      } else {
        $db->c('comment')->insert(
          bson_doc(
            type => 'solution',
            tid  => $solution->{task}{tid},
            sid  => $solution->{_id},
            ts   => bson_time,
            del  => bson_false,
            edit => bson_false,
            user =>
              bson_doc(uid => $c->session('uid'), login => $c->session('login'), pic => $c->session('pic')),
            text => $v->param('text'),
            html => $html
          ) => $d->begin
        );
      }
    },
    sub {
      my ($d, $err, $cid) = @_;
      return $c->reply->exception("Error while insert comment: $err") if $err;

      $c->minion->enqueue(notice_new_comment => [$cid, $c->stash('solution')->{task}{name}])
        unless $d->data('update');
      $c->redirect_to('solution_comments', id => $id);
    }
  );
}

sub solution_add {
  my $c = shift;

  return $c->reply->not_found unless $c->session('uid');

  my %res = $c->model('solution')->add( validation => $c->validation, params => $c->req->params, session => $c->session, tid => $c->param('id') );
  return $c->reply->not_found unless %res;
  return $c->reply->exception( $res{err} ) if $res{err};

  if ($res{validation}->has_error) {
    $c->stash(s => 1);
    return $c->view;
  }

  # remember last language
  $c->session( lang => $c->param('language'));
  return $c->redirect_to('event_user_info', login => $c->session->{login});
}

1;
