package JAGC::Controller::Task;
use Mojo::Base 'Mojolicious::Controller';

use HTML::StripScripts::Parser;
use Mojo::Util qw/encode decode trim/;
use Mango::BSON ':bson';
use Text::Markdown 'markdown';

sub add {
  my $c = shift;
  $c->render_later;
  my $db = $c->db;

  return $c->render_not_found unless my $uid = $c->session('uid');
  $uid = bson_oid($uid);

  my $login = $c->session('login');
  my $pic   = $c->session('pic');

  my $params      = $c->req->body_params;
  my $hparams     = $params->to_hash;
  my @test_fields = grep { /^test_/ } $params->param;

  for (@test_fields) {
    $hparams->{$_} =~ s/\r\n/\n/g;
    $hparams->{$_} =~ s/^\n*|\n*$//g;
  }

  my $name        = trim $hparams->{name};
  my $description = trim $hparams->{description};
  my $to_validate = {name => $name, description => $description};
  $to_validate->{$_} = $hparams->{$_} for @test_fields;

  my $validation = $c->validation;
  $validation->input($to_validate);
  $validation->required('name')->size(1, 50, 'Length of task name must be no more than 50 characters');
  $validation->required('description')
    ->size(1, 500, 'Length of description must be no more than 500 characters');
  $validation->required($_)->size(1, 100000, 'Length of test must be no more than 100000 characters')
    for @test_fields;

  if ($validation->has_error || scalar @test_fields == 0) {
    $c->stash(alert_error => 'You must add at least one test') if scalar @test_fields == 0;
    return $c->add_view;
  }

  my @tests;
  for my $tin (grep { /^test_\d+_in$/ } $params->param) {
    (my $tout = $tin) =~ s/in/out/;
    my $test_in  = $validation->param($tin);
    my $test_out = $validation->param($tout);
    my $test     = bson_doc(
      _id => bson_oid,
      in  => bson_bin(encode 'UTF-8', $test_in),
      out => bson_bin(encode 'UTF-8', $test_out),
      ts  => bson_time
    );
    push @tests, $test;
  }

  $db->collection('task')->insert(
    bson_doc(
      name  => $validation->param('name'),
      desc  => $validation->param('description'),
      owner => bson_doc(uid => $uid, login => $login, pic => $pic),
      stat  => bson_doc(all => 0, ok => 0),
      ts    => bson_time,
      tests => \@tests
      ) => sub {
      my ($collection, $err, $oid) = @_;
      return $c->render_exception("Error while insert task: $err") if $err;

      $c->app->minion->enqueue(notice_new_task => [$oid] => sub { });
      return $c->redirect_to('task_view', id => $oid);
    }
  );
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
      my $delay = shift;

      $db->collection('task')->find_one($id => $delay->begin);
      $db->collection('comment')->find(bson_doc(type => 'task', tid => $id, del => bson_false))
        ->sort(bson_doc(ts => 1))->all($delay->begin);
    },
    sub {
      my ($delay, $terr, $task, $cerr, $comments) = @_;
      return $c->render_exception("Error while find_one task with $id: $terr") if $terr;
      return $c->render_not_found unless $task;
      return $c->render_exception("Error while find comments: $cerr") if $cerr;

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
      my $delay = shift;

      $db->collection('solution')->find_one($id => $delay->begin);
      $db->collection('comment')->find(bson_doc(type => 'solution', sid => $id, del => bson_false))
        ->sort(bson_doc(ts => 1))->all($delay->begin);
    },
    sub {
      my ($delay, $serr, $solution, $cerr, $comments) = @_;
      return $c->render_exception("Error while find_one solution with $id: $serr") if $serr;
      return $c->render_not_found unless $solution;
      return $c->render_exception("Error while find comments: $cerr") if $cerr;

      $c->stash(solution => $solution, comments => $comments);
      $c->render(action => 'solution_comments');
    }
  );
}

sub view {
  my $c = shift;

  my $id = bson_oid $c->stash('id');
  my $db = $c->db;
  $c->delay(
    sub {
      my $delay = shift;

      $db->collection('task')->find_one($id => $delay->begin);
      $db->collection('language')->find({})->fields({name => 1, _id => 0})->all($delay->begin);
    },
    sub {
      my ($delay, $terr, $task, $lerr, $languages) = @_;
      return $c->render_exception("Error while find_one task with $id: $terr") if $terr;
      return $c->render_not_found unless $task;
      return $c->render_exception("Error while find languages: $lerr") if $lerr;

      $c->stash(task => $task, languages => [map { $_->{name} } @$languages]);

      my $collection = $db->collection('solution');
      my $cursor;
      if ($c->stash('s') == 1) {
        $cursor = $collection->find(bson_doc('task.tid' => $id, s => 'finished'))->fields({task => 0})
          ->sort(bson_doc(size => 1, ts => 1))->limit(20);
      } elsif ($c->stash('s') == 0) {
        $cursor =
          $collection->find(bson_doc('task.tid' => $id, s => {'$in' => [qw/incorrect timeout error/]}))
          ->fields({task => 0})->sort(bson_doc(ts => 1))->limit(20);
      }
      $cursor->all($delay->begin);
      $db->collection('comment')->find(bson_doc(type => 'task', tid => $id, del => bson_false))
        ->count($delay->begin);
      $db->collection('comment')->aggregate([
          {'$match' => bson_doc(tid => $id, type => 'solution', del => bson_false)},
          {'$group' => bson_doc(_id => '$sid', count => {'$sum' => 1})}
        ]
      )->all($delay->begin);
      if (my $uid = $c->session('uid')) {
        $db->collection('notification')
          ->find_one(bson_doc(uid => bson_oid($uid), tid => $id), {for => 1}, $delay->begin);
      }
    },
    sub {
      my ($delay, $err, $solutions, $cerr, $comments_count, $ccerr, $solution_comments, $nerr, $notice) = @_;
      return $c->render_exception("Error while find solution: $err")                if $err;
      return $c->render_exception("Error while count comments for $id: $cerr")      if $cerr;
      return $c->render_exception("Error while find comments for solution: $ccerr") if $ccerr;
      return $c->render_exception("Error while find notification for task: $nerr")  if $nerr;

      my %solution_comments;
      map { $solution_comments{$_->{_id}} = $_->{count} } @$solution_comments;

      $c->stash(
        solutions         => $solutions,
        comments_count    => $comments_count,
        solution_comments => \%solution_comments,
        notice            => $notice
      );
      $c->render(action => 'view');
    }
  );
}

sub edit_view {
  my $c = shift;

  my $uid = $c->session('uid');
  return $c->render_not_found unless $uid;

  my $tid = bson_oid $c->stash('tid');
  my $db  = $c->db;
  $c->delay(
    sub {
      $db->collection('task')->find_one($tid => shift->begin);
    },
    sub {
      my ($delay, $terr, $task) = @_;
      return $c->render_exception("Error while find_one task $tid: $terr") if $terr;
      return $c->render_not_found unless $task;

      unless ($task->{owner}{uid} eq $uid) {
        $c->app->log->error("Error: not owner attempt to modify task");
        return $c->render_not_found;
      }
      $c->stash(task => $task);
      $c->render(action => 'edit');
    }
  );
}

sub edit {
  my $c = shift;

  my $uid = $c->session('uid');
  return $c->render_not_found unless $uid;

  my $tid    = bson_oid $c->stash('tid');
  my $db     = $c->db;
  my $params = $c->req->body_params;
  $c->delay(
    sub {
      $db->collection('task')->find_one($tid => shift->begin);
    },
    sub {
      my ($delay, $terr, $task) = @_;
      return $c->render_exception("Error while find_one task $tid: $terr") if $terr;
      return $c->render_not_found unless $task;

      unless ($task->{owner}{uid} eq $uid) {
        $c->app->log->error("Error: not owner attempt to modify task");
        return $c->render_not_found;
      }

      my $hparams = $params->to_hash;
      my @test_fields = grep { /^test_/ } $params->param;

      for (@test_fields) {
        $hparams->{$_} =~ s/\r\n/\n/g;
        $hparams->{$_} =~ s/^\n*|\n*$//g;
      }

      my $name        = trim $hparams->{name};
      my $description = trim $hparams->{description};
      my $to_validate = {name => $name, description => $description};
      $to_validate->{$_} = $hparams->{$_} for @test_fields;

      my $v = $c->validation;
      $v->input($to_validate);
      $v->required('name')->size(1, 50, 'Length of task name must be no more than 50 characters');
      $v->required('description')->size(1, 500, 'Length of description must be no more than 500 characters');
      $v->required($_)->size(1, 100000, 'Length of test must be no more than 100000 characters')
        for @test_fields;

      if ($v->has_error || scalar @test_fields == 0) {
        $c->stash(alert_error => 'You must add at least one test') if scalar @test_fields == 0;
        return $c->edit_view();
      }

      my $is_change_tests = 0;
      my $test_cnt = scalar grep { /^test_\d+_in$/ } $params->param;
      $is_change_tests = 1 unless (scalar(@{$task->{tests}}) == $test_cnt);
      if ($is_change_tests == 0) {
        for (1 .. $test_cnt) {
          my $in_o  = decode 'UTF-8', $task->{tests}->[$_ - 1]->{in};
          my $out_o = decode 'UTF-8', $task->{tests}->[$_ - 1]->{out};
          my $in_n  = $v->param('test_' . $_ . '_in');
          my $out_n = $v->param('test_' . $_ . '_out');
          unless ($in_o eq $in_n && $out_o eq $out_n) {
            $is_change_tests = 1;
            last;
          }
        }
      }

      my @tests;
      if ($is_change_tests) {
        for my $tin (grep { /^test_\d+_in$/ } $params->param) {
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

      $delay->data(tname           => $v->param('name'));
      $delay->data(is_change_tests => $is_change_tests);

      my $tupdate_opt =
        {'$set' => {name => $v->param('name'), desc => $v->param('description'), ts => bson_time}};
      if ($is_change_tests) {
        $tupdate_opt->{'$set'}{tests}      = \@tests;
        $tupdate_opt->{'$set'}{'stat.all'} = 0;
        $tupdate_opt->{'$set'}{'stat.ok'}  = 0;
        $tupdate_opt->{'$unset'}{'winner'} = 1;
      }
      $db->collection('task')->update(({_id => $tid}, $tupdate_opt) => $delay->begin);

      my $supdate_opt = {'task.name' => $v->param('name')};
      $supdate_opt->{s} = 'inactive' if $is_change_tests;
      $db->collection('solution')
        ->update({'task.tid' => $tid}, {'$set' => $supdate_opt}, {multi => 1} => $delay->begin);
    },
    sub {
      my ($delay, $err, $num, $uerr, $update) = @_;
      return $c->render_exception("Error while update task: $err")       if $err;
      return $c->render_exception("Error while update solutions: $uerr") if $uerr;

      $c->minion->enqueue(recheck => [$tid] => {priority => 0}) if $delay->data('is_change_tests');

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
      my $delay = shift;

      my $collection = $db->collection('solution');
      my $cursor;
      if ($c->stash('s') == 1) {
        $cursor = $collection->find(bson_doc('task.tid' => $id, s => 'finished'));
      } elsif ($c->stash('s') == 0) {
        $cursor =
          $collection->find(bson_doc('task.tid' => $id, s => {'$in' => [qw/incorrect timeout error/]}));
      }
      $delay->data(cursor => $cursor);
      $cursor->count($delay->begin);
    },
    sub {
      my ($delay, $cerr, $count) = @_;
      return $c->render_exception("Error while count solutions: $cerr") if $cerr;
      return $c->render_not_found if $count <= $skip;

      $c->stash(need_next_btn => ($count - $skip > $limit ? 1 : 0));
      $delay->data('cursor')->all($delay->begin);
      $db->collection('task')->find_one($id, {tests => 1} => $delay->begin);
    },
    sub {
      my ($delay, $serr, $solutions, $terr, $task) = @_;
      return $c->render_exception("Error while find solution: $serr")     if $serr;
      return $c->render_exception("Error while find_one task $id: $terr") if $terr;
      return $c->render_not_found unless $task;

      $c->stash(solutions => $solutions, task => $task);
      $c->render(action => 'solution');
    }
  );
}

sub comment_add {
  my $c = shift;

  my $uid = $c->session('uid');
  return $c->render_not_found unless $uid;

  my $id = bson_oid $c->stash('id');

  my $db = $c->db;
  $c->delay(
    sub {
      $db->collection('task')->find_one($id => shift->begin);
    },
    sub {
      my ($delay, $err, $task) = @_;
      return $c->render_exception("Error while find_one task with $id: $err") if $err;
      return $c->render_not_found unless $task;

      $c->stash(task => $task);
      my $v = $c->validation;
      $v->required('text')->size(1, 100000, 'Length of comment must be no more than 100000 characters');

      if ($v->has_error) {
        return $c->comments;
      }

      my $html = markdown $v->param('text');
      my $hss  = HTML::StripScripts::Parser->new;
      $html = $hss->filter_html($html);
      $db->collection('comment')->insert(
        bson_doc(
          type => 'task',
          tid  => $id,
          sid  => undef,
          ts   => bson_time,
          del  => bson_false,
          edit => bson_false,
          user =>
            bson_doc(uid => $c->session('uid'), login => $c->session('login'), pic => $c->session('pic')),
          text => $v->param('text'),
          html => $html
        ) => $delay->begin
      );
    },
    sub {
      my ($delay, $err, $cid) = @_;
      return $c->render_exception("Error while insert comment: $err") if $err;

      $c->minion->enqueue(notice_new_comment => [$cid, $c->stash('task')->{name}] => sub { });
      $c->redirect_to('task_comments', id => $id);
    }
  );
}

sub solution_comment_add {
  my $c = shift;

  my $uid = $c->session('uid');
  return $c->render_not_found unless $uid;

  my $id = bson_oid $c->stash('id');
  my $db = $c->db;
  $c->delay(
    sub {
      $db->collection('solution')->find_one($id => shift->begin);
    },
    sub {
      my ($delay, $err, $solution) = @_;
      return $c->render_exception("Error while find_one solution with $id: $err") if $err;
      return $c->render_not_found unless $solution;

      $c->stash(solution => $solution);
      my $v = $c->validation;
      $v->required('text')->size(1, 100000, 'Length of comment must be no more than 100000 characters');

      if ($v->has_error) {
        return $c->solution_comments;
      }

      my $html = markdown $v->param('text');
      my $hss  = HTML::StripScripts::Parser->new;
      $html = $hss->filter_html($html);
      $db->collection('comment')->insert(
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
        ) => $delay->begin
      );
    },
    sub {
      my ($delay, $err, $cid) = @_;
      return $c->render_exception("Error while insert comment: $err") if $err;

      $c->minion->enqueue(notice_new_comment => [$cid, $c->stash('solution')->{task}{name}] => sub { });
      $c->redirect_to('solution_comments', id => $id);
    }
  );
}

sub solution_add {
  my $c = shift;

  return $c->render_not_found unless my $uid = $c->session('uid');
  $uid = bson_oid $uid;

  my $login = $c->session('login');
  my $pic   = $c->session('pic');
  my $tid   = bson_oid $c->stash('id');

  my $max_code_len = 1000000;

  my $db = $c->db;
  $c->delay(
    sub {
      my $delay = shift;
      $db->collection('task')->find_one($tid => $delay->begin);
      $db->collection('language')->find({})->all($delay->begin);
    },
    sub {
      my ($delay, $terr, $task, $lerr, $languages) = @_;
      return $c->render_exception("Error while find_one task with $tid: $terr") if $terr;
      return $c->render_exception("Error while find languages: $lerr")          if $lerr;
      return $c->render_not_found unless $task;

      my $langs = [map { $_->{name} } @$languages];
      $delay->data(languages => $langs);
      $delay->data(tname     => $task->{name});

      my $code = $c->param('code');
      $code =~ s/\r\n?/\n/g;

      my $v = $c->validation;
      $v->input({language => trim($c->param('language')), code => $code});
      $v->required('language')->in(\@$langs, 'Language not exist');
      $v->required('code')
        ->code_size(1, $max_code_len,
        'The length of the source code must be less than ' . ($max_code_len + 1));
      if ($v->has_error) {
        $c->stash(s => 1);
        return $c->view();
      }

      my ($used_lang) = grep { $_->{name} eq $v->param('language') } @$languages;

      $code = $v->param('code');
      my $code_length = length $code;

      if ($code =~ m/^#!/) {
        $code =~ s/^#![^\s]+[\t ]*//;
        $code_length = length($code) - 1;
        $code_length++ unless $code =~ m/\n/;
        $v->output->{code} =~ s/^#![^\s]+/#!$used_lang->{path}/;
      }

      $delay->data(code => $v->param('code'));
      $c->session(lang => $v->param('language'));

      $db->collection('solution')->insert(
        bson_doc(
          task => {tid => $tid, name  => $task->{name}},
          user => {uid => $uid, login => $login, pic => $pic},
          code => $v->param('code'),
          lng  => $v->param('language'),
          size => $code_length,
          s    => 'inactive',
          ts   => bson_time
        ) => $delay->begin
      );
    },
    sub {
      my ($delay, $serr, $sid) = @_;
      return $c->render_exception("Error while insert solution: $serr") if $serr;

      $c->minion->enqueue(check => [$sid] => {priority => 1} => sub { });
      return $c->redirect_to('event_user_info', login => $login);
    }
  );
}

1;
