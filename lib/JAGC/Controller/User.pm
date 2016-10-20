package JAGC::Controller::User;
use Mojo::Base 'Mojolicious::Controller';

use Mango::BSON ':bson';
use Mojo::Template;
use Mojo::Home;
use Mojo::Util qw/md5_sum trim/;

sub info {
  my $c = shift;

  my $login = $c->stash('login');
  my $db    = $c->db;
  $c->delay(
    sub {
      $db->c('stat')->find_one({login => $login} => shift->begin);
    },
    sub {
      my ($d, $serr, $user_stat) = @_;
      return $c->reply->exception("Error while find user $login: $serr") if $serr;

      if ($user_stat) {
        $c->stash(user_stat => $user_stat);
        return $c->render;
      }

      $db->c('user')->find_one({login => $login}, {login => 1, pic => 1} => $d->begin);
    },
    sub {
      my ($d, $uerr, $user_stat) = @_;
      return $c->reply->exception("Error while find user $login: $uerr") if $uerr;
      return $c->reply->not_found unless $user_stat;

      $user_stat->{score} = 0;
      $user_stat->{tasks} = [];
      $c->stash(user_stat => $user_stat);
      $c->render;
    }
  );
}

sub tasks_owner {
  my $c = shift;

  my $login = $c->stash('login');
  my $db    = $c->db;
  $c->delay(
    sub {
      my $d = shift;

      $db->c('user')->find_one({login => $login}, {login => 1, pic => 1} => $d->begin);
      $db->c('task')->find({'owner.login' => $login})->sort({ts => -1})->fields({name => 1})->all($d->begin);
    },
    sub {
      my ($d, $uerr, $owner, $terr, $tasks) = @_;
      return $c->reply->exception("Error while find user by login: $uerr") if $uerr;
      return $c->reply->exception("Error while find tasks by uid: $terr")  if $terr;
      return $c->reply->not_found unless $owner;
      return $c->reply->not_found unless $tasks;

      $c->stash(owner => $owner, tasks => $tasks);
      $db->c('solution')->aggregate([
          {'$match' => {s => 'finished', 'task.tid' => {'$in' => [map { $_->{_id} } @$tasks]}}},
          {'$group' => {_id => {t => '$task.tid', u => '$user.uid'}}},
          {'$group' => {_id => '$_id.t', u => {'$sum' => 1}}}
        ]
      )->all($d->begin);
    },
    sub {
      my ($d, $err, $tcount) = @_;

      my %tcount;
      map { $tcount{$_->{_id}} = $_->{u} } @$tcount;

      $c->stash(tcount => \%tcount);
      $c->render(action => 'tasks');
    }
  );
}

sub settings {
  my $c = shift;

  return $c->reply->not_found unless my $uid = $c->session('uid');
  $uid = bson_oid $uid;

  my $login  = $c->stash('login');
  my $rlogin = $c->session('login');
  return $c->reply->not_found if ($login ne $rlogin);

  my $db = $c->db;
  $c->delay(
    sub {
      $db->c('user')->find_one($uid => shift->begin);
    },
    sub {
      my ($d, $uerr, $user) = @_;
      return $c->reply->exception("Error while find user $uid: $uerr") if $uerr;
      return $c->reply->not_found unless $user;

      $c->stash(user => $user);
      $c->render;
    }
  );
}

sub notification_new {
  my $c = shift;

  return $c->reply->not_found unless my $uid = $c->session('uid');
  $uid = bson_oid $uid;

  my $db = $c->db;
  $c->delay(
    sub {
      $db->c('user')->find_one($uid => shift->begin);
    },
    sub {
      my ($d, $uerr, $user) = @_;
      return $c->reply->exception("Error while find user $uid: $uerr") if $uerr;
      return $c->reply->not_found unless $user;

      $d->data(login => $user->{login});
      $db->c('user')->update({_id => $uid},
        {'$set' => {'notice.new' => $user->{notice}{new} ? bson_false : bson_true}} => $d->begin);
    },
    sub {
      my ($d, $err, $doc) = @_;
      return $c->reply->exception("Error while update user $uid: $err") if $err;

      $c->redirect_to('user_settings', login => $d->data('login'));
    }
  );
}

sub notification_contests {
  my $c = shift;

  return $c->reply->not_found unless my $uid = $c->session('uid');
  $uid = bson_oid $uid;

  $c->model('notification')->contests($uid, sub {
      my %res = @_;
      return $c->reply->not_found unless %res;
      return $c->reply->exception($res{err}) if $res{err};

      $c->redirect_to('user_settings', login => $res{login});
  });
}

sub notification {
  my $c = shift;

  return $c->reply->not_found unless my $uid = $c->session('uid');
  my $type = $c->stash('type');

  $uid = $c->session('uid');
  my $tid = $c->stash('tid');

  my $action = $type eq 'comment' ? 'comments' : 'solutions';

  my %res = $c->model('notification')->$action(uid => $uid, tid => $tid);

  return $c->reply->exception($res{err}) if exists $res{err};
  $c->redirect_to('task_view', id => $res{tid});
}

sub register_view {
  my $c = shift;

  my $stype  = $c->session('stype');
  my $sid    = $c->session('sid');
  my $sname  = $c->session('sname') // '';
  my $spic   = $c->session('spic');
  my $semail = $c->session('semail') // '';

  unless ($stype && $sid) {
    $c->flash(error => 'Authentication data not found');
    return $c->redirect_to(delete $c->session->{base_url} // 'index');
  }

  $c->render(action => 'register', email => $semail, login => $sname);
}

sub register {
  my $c = shift;

  my $params = $c->req->body_params;
  my $to_validate = {login => trim($params->param('login')), email => trim($params->param('email'))};

  my $v = $c->validation;
  $v->input($to_validate);
  $v->required('login')
    ->like(qr/^[^.\/]{1,20}$/, 'Login must not contain "." and "/". Length must not exceed 20 symbols');
  $v->required('email')->size(1, 100, 'Length must be from 1 to 100')->email('Invalid email');

  return $c->register_view() if $v->has_error;

  my $stype  = $c->session('stype');
  my $sid    = $c->session('sid');
  my $sname  = $c->session('sname') // '';
  my $spic   = $c->session('spic');
  my $semail = $c->session('semail') // '';

  my $login = $v->param('login');
  my $email = $v->param('email');

  my $code = md5_sum(time . rand . $$);

  my $db = $c->db;
  $c->delay(
    sub {
      my $user_opt = {
        login  => $login,
        pic    => $spic,
        type   => $stype,
        email  => $email,
        ban    => bson_false,
        social => [
          bson_doc(
            _id   => bson_oid,
            type  => $stype,
            id    => $sid,
            name  => $sname,
            pic   => $spic,
            email => $semail
          )
        ],
        code => {confirm => bson_false, c => $code, tss => bson_time, tsc => bson_time}
      };

      $db->c('user')->insert($user_opt => shift->begin);
    },
    sub {
      my ($d, $err, $uid) = @_;

      if ($err) {
        if ($err =~ /11000/) {
          return $db->c('user')->find({'$or' => [{login => $login}, {email => $email}]})->next($d->begin);
        }
        return $c->reply->exception("Error while insert new user: $err");
      }

      delete $c->session->{stype};
      delete $c->session->{sid};
      delete $c->session->{sname};
      delete $c->session->{spic};
      delete $c->session->{semail};

      my $link = $c->url_for('user_confirmation', uid => "$uid", email => $email, code => $code)->to_abs;
      $c->res->headers->header('X-Confirm-Link' => $link) if $c->app->mode eq 'test';
      $c->app->minion->enqueue(email => [$login, $email, $link]);
      $c->flash(
        info => 'To complete the registration and confirmation email address, go to the link from the mail.');
      $c->redirect_to(delete $c->session->{base_url} // 'index');
    },
    sub {
      my ($d, $err, $user) = @_;
      return $c->reply->exception("Error while find user by login or email: $err") if $err;
      return $c->reply->exception("Error: user not exist but it must be") unless $user;

      my $socials = join ', ', (map { $_->{type} } @{$user->{social}});
      $c->flash(error =>
"This email or login already exist in JAGC. If this is you, you can login through the following social networks: $socials."
      );
      $c->redirect_to('user_register_view');
    }
  );
}

sub confirmation {
  my $c  = shift;
  my $db = $c->db;

  my $uid = $c->stash('uid');

  $c->delay(
    sub {
      my $user_opt = {
        query => {_id => bson_oid($uid), email => $c->stash('email'), 'code.c' => $c->stash('code')},
        update => {'$set' => {'code.confirm' => bson_true, 'code.tsc' => bson_time}}
      };

      $db->c('user')->find_and_modify($user_opt => shift->begin);
    },
    sub {
      my ($d, $err, $user) = @_;
      return $c->reply->exception("Error while insert new user: $err") if $err;
      return $c->reply->not_found unless $user;

      $c->session(uid => "$user->{_id}", pic => $user->{pic}, login => $user->{login});
      $c->flash(success => 'You are successfully registered');
      $c->redirect_to('index');
    }
  );
}

sub all {
  my $c = shift->render_later;

  my $con  = $c->param('con');
  my $page = $c->param('page');

  my $cb = sub {
    my %res = @_;

    return $c->reply->not_found unless %res;
    return $c->reply->exception($res{err}) if $res{err};

    $c->render(%res);
  };

  return $c->model('user')->contest_all($con, $page, $cb) if $con;

  $c->model('user')->all($page, $cb);
}

sub change_name {
  my $c = shift;

  my $login  = $c->stash('login');
  my $rlogin = $c->session('login');
  return $c->reply->not_found unless $rlogin;

  my $nlogin = trim $c->param('name');

  unless ($nlogin) {
    $c->flash(error => "Error: field screen name must be not empty");
    return $c->redirect_to('user_settings', login => $rlogin);
  }

  my $v = $c->validation;
  $v->input({login => $nlogin});
  my $login_topic = $v->required('login')
    ->like(qr/^[^.\/]{1,20}$/, 'Login must not contain "." and "/". Its length must not exceed 20');

  if ($v->has_error) {
    $c->flash(error => 'Login must not contain "." and "/". Its length must not exceed 20');
    return $c->redirect_to('user_settings', login => $rlogin);
  }

  my $db = $c->db;
  $c->delay(
    sub {
      $db->c('user')->update({login => $rlogin}, {'$set' => {login => $nlogin}} => shift->begin);
    },
    sub {
      my ($d, $uerr, $unum) = @_;
      if ($uerr) {
        if ($uerr =~ m/E11000/) {
          $c->flash(error => "Error: this login already exist.");
          return $c->redirect_to('user_settings', login => $rlogin);
        }
        return $c->reply->exception("Error while update user login: $uerr");
      }

      $c->session(login => $nlogin);

      $db->c('stat')->update({login => $rlogin}, {'$set' => {login => $nlogin}} => $d->begin);
      $db->c('solution')
        ->update(
        ({'user.login' => $rlogin}, {'$set' => {'user.login' => $nlogin}}, {multi => 1}) => $d->begin);
      $db->c('task')
        ->update(
        ({'owner.login' => $rlogin}, {'$set' => {'owner.login' => $nlogin}}, {multi => 1}) => $d->begin);
      $db->c('task')
        ->update(
        ({'winner.login' => $rlogin}, {'$set' => {'winner.login' => $nlogin}}, {multi => 1}) => $d->begin);
      $db->c('comment')
        ->update(
        ({'user.login' => $rlogin}, {'$set' => {'user.login' => $nlogin}}, {multi => 1}) => $d->begin);
      $db->c('contest')
        ->update(
        ({'owner.login' => $rlogin}, {'$set' => {'owner.login' => $nlogin}}, {multi => 1}) => $d->begin);
    },
    sub {
      my ($d, $serr, $snum, $soerr, $sonum, $toerr, $tonum, $twerr, $twnum, $cerr, $cnum, $coerr, $conum) =
        @_;
      return $c->reply->exception("Error while update user login: $serr")                    if $serr;
      return $c->reply->exception("Error while update solution when update user: $soerr")    if $soerr;
      return $c->reply->exception("Error while update task owner when update user: $toerr")  if $toerr;
      return $c->reply->exception("Error while update task winner when update user: $twerr") if $twerr;
      return $c->reply->exception("Error while update comment when update user: $cerr")      if $cerr;
      return $c->reply->exception("Error while update contest when update user: $coerr")     if $coerr;

      return $c->redirect_to('user_settings', login => $nlogin);
    }
  );
}

1;
