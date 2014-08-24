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
      $db->collection('stat')->find_one({login => $login} => shift->begin);
    },
    sub {
      my ($delay, $serr, $user_stat) = @_;
      return $c->render_exception("Error while find user $login: $serr") if $serr;

      if ($user_stat) {
        $c->stash(user_stat => $user_stat);
        return $c->render;
      }

      $db->collection('user')->find_one({login => $login}, {login => 1, pic => 1} => $delay->begin);
    },
    sub {
      my ($delay, $uerr, $user_stat) = @_;
      return $c->render_exception("Error while find user $login: $uerr") if $uerr;
      return $c->render_not_found unless $user_stat;

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
      my $delay = shift;

      $db->collection('user')->find_one({login => $login}, {login => 1, pic => 1} => $delay->begin);
      $db->collection('task')->find({'owner.login' => $login})->sort({ts => -1})->fields({name => 1})
        ->all($delay->begin);
    },
    sub {
      my ($delay, $uerr, $owner, $terr, $tasks) = @_;
      return $c->render_exception("Error while find user by login: $uerr") if $uerr;
      return $c->render_exception("Error while find tasks by uid: $terr")  if $terr;
      return $c->render_not_found unless $owner;
      return $c->render_not_found unless $tasks;

      $c->stash(owner => $owner, tasks => $tasks);
      $db->collection('solution')->aggregate([
          {'$match' => {s => 'finished', 'task.tid' => {'$in' => [map { $_->{_id} } @$tasks]}}},
          {'$group' => {_id => {t => '$task.tid', u => '$user.uid'}}},
          {'$group' => {_id => '$_id.t', u => {'$sum' => 1}}}
        ]
      )->all($delay->begin);
    },
    sub {
      my ($delay, $err, $tcount) = @_;

      my %tcount;
      map { $tcount{$_->{_id}} = $_->{u} } @$tcount;

      $c->stash(tcount => \%tcount);
      $c->render(action => 'tasks');
    }
  );
}

sub settings {
  my $c = shift;

  return $c->render_not_found unless my $uid = $c->session('uid');
  $uid = bson_oid $uid;

  my $login  = $c->stash('login');
  my $rlogin = $c->session('login');
  return $c->render_not_found if ($login ne $rlogin);

  my $db = $c->db;
  $c->delay(
    sub {
      $db->collection('user')->find_one($uid => shift->begin);
    },
    sub {
      my ($delay, $uerr, $user) = @_;
      return $c->render_exception("Error while find user $uid: $uerr") if $uerr;
      return $c->render_not_found unless $user;

      $c->stash(user => $user);
      $c->render;
    }
  );
}

sub notification_new {
  my $c = shift;

  return $c->render_not_found unless my $uid = $c->session('uid');
  $uid = bson_oid $uid;

  my $db = $c->db;
  $c->delay(
    sub {
      $db->collection('user')->find_one($uid => shift->begin);
    },
    sub {
      my ($delay, $uerr, $user) = @_;
      return $c->render_exception("Error while find user $uid: $uerr") if $uerr;
      return $c->render_not_found unless $user;

      $delay->data(login => $user->{login});
      $db->collection('user')->update({_id => $uid},
        {'$set' => {'notice.new' => $user->{notice}{new} ? bson_false : bson_true}} => $delay->begin);
    },
    sub {
      my ($delay, $err, $doc) = @_;
      return $c->render_exception("Error while update user $uid: $err") if $err;

      $c->redirect_to('user_settings', login => $delay->data('login'));
    }
  );
}

sub notification {
  my $c = shift;

  return $c->render_not_found unless my $uid = $c->session('uid');
  $uid = bson_oid $uid;
  my $tid  = bson_oid $c->stash('tid');
  my $type = $c->stash('type');

  my $db = $c->db;
  $c->delay(
    sub {
      $db->collection('notification')->find_one(bson_doc(uid => $uid, tid => $tid) => shift->begin);
    },
    sub {
      my ($delay, $err, $notification) = @_;
      return $c->render_exception("Error while find notification $uid: $err") if $err;

      my $action = '$addToSet';
      if ($notification) {
        $action = '$pull' if grep { $_ eq $type } @{$notification->{for}};
      }

      $db->collection('notification')->update(
        bson_doc(uid => $uid, tid => $tid),
        {$action => {for => $type}},
        {upsert  => 1}   => $delay->begin
      );
    },
    sub {
      my ($delay, $err, $doc) = @_;
      return $c->render_exception("Error while upsert notification: $err") if $err;

      $c->redirect_to('task_view', id => $tid);
    }
  );
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

      $db->collection('user')->insert($user_opt => shift->begin);
    },
    sub {
      my ($delay, $err, $uid) = @_;

      if ($err) {
        if ($err =~ /11000/) {
          return $db->collection('user')->find({'$or' => [{login => $login}, {email => $email}]})
            ->next($delay->begin);
        }
        return $c->render_exception("Error while insert new user: $err");
      }

      delete $c->session->{stype};
      delete $c->session->{sid};
      delete $c->session->{sname};
      delete $c->session->{spic};
      delete $c->session->{semail};

      my $link = $c->url_for('user_confirmation', uid => "$uid", email => $email, code => $code)->to_abs;
      $c->app->minion->enqueue(
        email => [$login, $email, $link] => sub {
          $c->flash(info =>
              'To complete the registration and confirmation email address, go to the link from the mail.');
          $c->redirect_to(delete $c->session->{base_url} // 'index');
        }
      );
    },
    sub {
      my ($delay, $err, $user) = @_;
      return $c->render_exception("Error while find user by login or email: $err") if $err;
      return $c->render_exception("Error: user not exist but it must be") unless $user;

      my $socials = join ', ', (map { $_->{type} } @{$user->{social}});
      $c->flash(error =>
"This email or login already exist in JAGC. If this is you, you can login through the following social networks: $socials."
      );
      $c->redirect_to('user_register_view');
    }
  );
}

sub confirmation {
  my $c = shift;


  my $uid   = $c->stash('uid');
  my $email = $c->stash('email');
  my $code  = $c->stash('code');

  my $db = $c->db;
  $c->delay(
    sub {
      my $user_opt = {
        query => {_id => bson_oid($uid), email => $email, 'code.c' => $code},
        update => {'$set' => {'code.confirm' => bson_true, 'code.tsc' => bson_time}}
      };

      $db->collection('user')->find_and_modify($user_opt => shift->begin);
    },
    sub {
      my ($delay, $err, $user) = @_;
      return $c->render_exception("Error while insert new user: $err") if $err;
      return $c->render_not_found unless $user;

      $c->session(uid => "$user->{_id}", pic => $user->{pic}, login => $user->{login});
      $c->flash(success => 'You are successfully registered');
      $c->redirect_to('index');
    }
  );
}

sub all {
  my $c = shift;

  my $page  = int $c->stash('page');
  my $limit = 50;
  my $skip  = ($page - 1) * $limit;

  my $db = $c->db;
  $c->delay(
    sub {
      $db->collection('stat')->find({})->count(shift->begin);
    },
    sub {
      my ($delay, $err, $count) = @_;
      return $c->render_exception("Error while find users: $err") if $err;
      return $c->render_not_found if $count <= $skip;

      $delay->pass($count);
      $db->collection('stat')->find({})->sort(bson_doc(score => -1, t_all => -1, t_ok => -1))->skip($skip)
        ->fields({tasks => 0})->all($delay->begin);
    },
    sub {
      my ($delay, $count, $err, $users) = @_;
      return $c->render_exception("Error while find users: $err") if $err;

      $c->stash(users => $users, next_btn => ($count - $skip > $limit) ? 1 : 0);
      $c->render;
    }
  );
}

sub change_name {
  my $c = shift;

  my $login  = $c->stash('login');
  my $rlogin = $c->session('login');
  return $c->render_not_found unless $rlogin;

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
      $db->collection('user')->update({login => $rlogin}, {'$set' => {login => $nlogin}} => shift->begin);
    },
    sub {
      my ($delay, $uerr, $unum) = @_;
      if ($uerr) {
        if ($uerr =~ m/E11000/) {
          $c->flash(error => "Error: this login already exist.");
          return $c->redirect_to('user_settings', login => $rlogin);
        }
        return $c->render_exception("Error while update user login: $uerr");
      }

      $c->session(login => $nlogin);

      $db->collection('stat')->update({login => $rlogin}, {'$set' => {login => $nlogin}} => $delay->begin);
      $db->collection('solution')
        ->update(
        ({'user.login' => $rlogin}, {'$set' => {'user.login' => $nlogin}}, {multi => 1}) => $delay->begin);
      $db->collection('task')
        ->update(
        ({'owner.login' => $rlogin}, {'$set' => {'owner.login' => $nlogin}}, {multi => 1}) => $delay->begin);
      $db->collection('task')
        ->update(({'winner.login' => $rlogin}, {'$set' => {'winner.login' => $nlogin}}, {multi => 1}) =>
          $delay->begin);
      $db->collection('comment')
        ->update(
        ({'user.login' => $rlogin}, {'$set' => {'user.login' => $nlogin}}, {multi => 1}) => $delay->begin);
    },
    sub {
      my ($delay, $serr, $snum, $soerr, $sonum, $toerr, $tonum, $twerr, $twnum, $cerr, $cnum) = @_;
      return $c->render_exception("Error while update user login: $serr")                    if $serr;
      return $c->render_exception("Error while update solution when update user: $soerr")    if $soerr;
      return $c->render_exception("Error while update task owner when update user: $toerr")  if $toerr;
      return $c->render_exception("Error while update task winner when update user: $twerr") if $twerr;
      return $c->render_exception("Error while update comment when update user: $cerr")      if $cerr;

      return $c->redirect_to('user_settings', login => $nlogin);
    }
  );
}

1;
