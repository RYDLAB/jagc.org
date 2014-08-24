package JAGC::Controller::Oauth;
use Mojo::Base 'Mojolicious::Controller';

use Mango::BSON ':bson';
use Twitter::Helper;

sub github {
  my $c = shift;

  my $code = $c->param('code');
  unless ($code) {
    $c->flash(error => '[github] Authentication failed, try later');
    return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
  }

  my $github = $c->app->config->{oauth}{github};
  Mojo::IOLoop->delay(
    sub {
      $c->ua->post($github->{url_token} => {Accept => 'application/json'} => form =>
          {client_id => $github->{client_id}, client_secret => $github->{client_secret}, code => $code} =>
          shift->begin);
    },
    sub {
      my ($delay, $tx) = @_;

      if (my $err = $tx->error) {
        $c->flash(error => "[github] $err->{code} response: $err->{message}") if $err->{code};
        $c->flash(error => "[github] Connection error: $err->{message}");
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }

      my $token = $tx->res->json->{access_token};

      unless ($token) {
        $c->flash(error => '[github] Authentication error, try later');
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }

      $c->ua->get(Mojo::URL->new($github->{url_user})->query(access_token => $token) => $delay->begin);
    },
    sub {
      my ($delay, $tx) = @_;

      if (my $err = $tx->error) {
        $c->flash(error => "[github] $err->{code} response: $err->{message}") if $err->{code};
        $c->flash(error => "[github] Connection error: $err->{message}");
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }

      my $profile = $tx->res->json;
      my ($id, $name, $login, $pic, $email) = @{$profile}{'id', 'name', 'login', 'avatar_url', 'email'};
      my $jagc_name = $login // $name // $id;
      $c->_user('github', $id, $jagc_name, $pic, $email);
    }
  );
}

sub twitter {
  my $c = shift;

  my $oauth_token    = $c->param('oauth_token');
  my $oauth_verifier = $c->param('oauth_verifier');

  my $twitter            = $c->app->config->{oauth}{twitter};
  my $consumer_key       = $twitter->{consumer_key};
  my $consumer_secret    = $twitter->{consumer_secret};
  my $oauth_token_secret = delete $c->session->{oauth_token_secret};
  my $url_access_token   = $twitter->{url_access_token};

  unless ($oauth_token and $oauth_verifier) {
    $c->flash(error => '[twitter] Authentication failed, try later');
    return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
  }

  my $th = Twitter::Helper->new($consumer_key, $consumer_secret);
  $th->set_token($oauth_token, $oauth_token_secret);
  $th->sign('post', $url_access_token, {oauth_verifier => $oauth_verifier}, 1);
  my $auth_header = $th->auth_header({}, 1);

  Mojo::IOLoop->delay(
    sub {
      my $delay = shift;
      $c->ua->post($url_access_token => {Authorization => $auth_header} => form =>
          {oauth_verifier => $oauth_verifier} => $delay->begin);
    },
    sub {
      my ($delay, $tx) = @_;

      if (my $err = $tx->error) {
        $c->flash(error => "[twitter] $err->{code} response: $err->{message}") if $err->{code};
        $c->flash(error => "[twitter] Connection error: $err->{message}");
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }

      my $params             = Mojo::Parameters->new($tx->res->body);
      my $oauth_token        = $params->param('oauth_token');
      my $oauth_token_secret = $params->param('oauth_token_secret');
      my $user_id            = $params->param('user_id');
      my $screen_name        = $params->param('screen_name');

      unless ($oauth_token and $oauth_token_secret) {
        $c->flash(error => '[twitter] Authentication failed, try later');
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }

      my $url_user = $twitter->{url_user};
      $th = Twitter::Helper->new($consumer_key, $consumer_secret);
      $th->set_token($oauth_token, $oauth_token_secret);
      $th->sign('get', $url_user, {user_id => $user_id}, 1);
      $auth_header = $th->auth_header({}, 1);

      $c->ua->get(Mojo::URL->new($url_user)->query(user_id => $user_id) => {Authorization => $auth_header} =>
          $delay->begin);
    },
    sub {
      my ($delay, $tx) = @_;

      if (my $err = $tx->error) {
        $c->flash(error => "[twitter] $err->{code} response: $err->{message}") if $err->{code};
        $c->flash(error => "[twitter] Connection error: $err->{message}");
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }

      my $profile = $tx->res->json;
      my ($id, $name, $screen_name, $pic) = @{$profile}{'id', 'name', 'screen_name', 'profile_image_url'};
      my $jagc_name = $screen_name // $name // $id;
      $c->_user('twitter', $id, $jagc_name, $pic, undef);
    }
  );
}

sub vk {
  my $c = shift;

  my $code = $c->param('code');
  unless ($code) {
    $c->flash(error => '[vk] Authentication failed, try later');
    return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
  }

  my $vk = $c->app->config->{oauth}{vk};
  Mojo::IOLoop->delay(
    sub {
      my $delay = shift;
      my $url   = Mojo::URL->new($vk->{url_token})->query(
        client_id     => $vk->{client_id},
        client_secret => $vk->{client_secret},
        code          => $code,
        redirect_uri  => $c->url_for('oauth_vk')->to_abs
      );
      $c->ua->get($url => $delay->begin);
    },
    sub {
      my ($delay, $tx) = @_;

      if (my $err = $tx->error) {
        $c->flash(error => "[vk] $err->{code} response: $err->{message}") if $err->{code};
        $c->flash(error => "[vk] Connection error: $err->{message}");
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }

      my $token = $tx->res->json->{access_token};
      my $uid   = $tx->res->json->{user_id};

      unless ($token) {
        $c->flash(error => '[vk] Authentication failed, try later');
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }

      my $user_url =
        Mojo::URL->new($vk->{url_user})->query(uids => $uid, fields => 'photo_medium, screen_name');
      $c->ua->get($user_url => $delay->begin);
    },
    sub {
      my ($delay, $tx) = @_;

      if (my $err = $tx->error) {
        $c->flash(error => "[vk] $err->{code} response: $err->{message}") if $err->{code};
        $c->flash(error => "[vk] Connection error: $err->{message}");
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }

      my $user = $tx->res->json->{response}->[0];
      my ($id, $screen_name, $fname, $lname, $pic) =
        @{$user}{'uid', 'screen_name', 'first_name', 'last_name', 'photo_medium'};
      my $name = $screen_name // ($fname || $lname) ? "$fname $lname" : undef // $id;
      $c->_user('vk', $id, $name, $pic, undef);
    }
  );
}

sub linkedin {
  my $c = shift;

  my $code  = $c->param('code');
  my $state = $c->param('state');
  unless ($code and $state eq delete $c->session->{state}) {
    $c->flash(error => '[linkedin] Authentication failed, try later');
    return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
  }

  my $linkedin = $c->app->config->{oauth}{linkedin};
  Mojo::IOLoop->delay(
    sub {
      my $delay = shift;
      my $url   = Mojo::URL->new($linkedin->{url_token})->query(
        grant_type    => 'authorization_code',
        code          => $code,
        redirect_uri  => $c->url_for('oauth_linkedin')->to_abs,
        client_id     => $linkedin->{client_id},
        client_secret => $linkedin->{client_secret}
      );
      $c->ua->post($url => $delay->begin);
    },
    sub {
      my ($delay, $tx) = @_;

      if (my $err = $tx->error) {
        $c->flash(error => "[linkedin] $err->{code} response: $err->{message}") if $err->{code};
        $c->flash(error => "[linkedin] Connection error: $err->{message}");
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }

      my $token = $tx->res->json->{access_token};

      unless ($token) {
        $c->flash(error => '[linkedin] Authentication failed, try later');
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }

      my $user_url = Mojo::URL->new($linkedin->{url_user} . ':(id,first-name,last-name,picture-url)')
        ->query(oauth2_access_token => $token, format => 'json');
      $c->ua->get($user_url => $delay->begin);
    },
    sub {
      my ($delay, $tx) = @_;

      if (my $err = $tx->error) {
        $c->flash(error => "[linkedin] $err->{code} response: $err->{message}") if $err->{code};
        $c->flash(error => "[linkedin] Connection error: $err->{message}");
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }

      my $user = $tx->res->json;
      my ($id, $fname, $lname, $pic) = @{$user}{'id', 'firstName', 'lastName', 'pictureUrl'};
      my $name = "$fname $lname";
      $c->_user('linkedin', $id, $name, $pic);
    }
  );
}

sub fb {
  my $c = shift;

  my $code  = $c->param('code');
  my $state = $c->param('state');

  unless ($code && $state eq delete $c->session->{state}) {
    $c->flash(error => '[fb] Authentication failed, try later');
    return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
  }

  my $fb = $c->app->config->{oauth}{fb};
  Mojo::IOLoop->delay(
    sub {
      my $delay = shift;
      my $url   = Mojo::URL->new($fb->{url_token})->query(
        code          => $code,
        redirect_uri  => $c->url_for('oauth_fb')->to_abs,
        client_id     => $fb->{client_id},
        client_secret => $fb->{client_secret}
      );
      $c->ua->get($url => $delay->begin);
    },
    sub {
      my ($delay, $tx) = @_;

      if (my $err = $tx->error) {
        $c->flash(error => "[fb] $err->{code} response: $err->{message}") if $err->{code};
        $c->flash(error => "[fb] Connection error: $err->{message}");
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }

      my $params = Mojo::Parameters->new($tx->res->body);
      my $token  = $params->param('access_token');

      unless ($token) {
        $c->flash(error => '[fb] Authentication failed, try later');
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }

      my $user_url = Mojo::URL->new($fb->{url_user})
        ->query(access_token => $token, fields => 'id,name,last_name,first_name,picture,email');
      $c->ua->get($user_url => $delay->begin);
    },
    sub {
      my ($delay, $tx) = @_;

      if (my $err = $tx->error) {
        $c->flash(error => "[fb] $err->{code} response: $err->{message}") if $err->{code};
        $c->flash(error => "[fb] Connection error: $err->{message}");
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }

      my $user = $tx->res->json;
      my ($id, $name, $fname, $lname, $picture, $email) =
        @{$user}{'id', 'name', 'first_name', 'last_name', 'picture', 'email'};
      my $jagc_name = $name // $id;
      my $pic = $picture->{data}->{url};
      $c->_user('fb', $id, $jagc_name, $pic, $email);
    }
  );
}

sub _user {
  my $c = shift;
  my ($type, $id, $name, $pic, $email) = @_;
  my $db = $c->db;

  if ((my $uid = $c->session('uid')) && ($c->session('add_social'))) {
    delete $c->session->{add_social};

    Mojo::IOLoop->delay(
      sub {
        my $delay = shift;
        $db->collection('user')->find_one(bson_oid($uid) => $delay->begin);
        $db->collection('user')
          ->find_one({social => {'$elemMatch' => bson_doc(type => $type, id => $id)}} => $delay->begin);
      },
      sub {
        my ($delay, $err, $user, $ex_err, $ex_user) = @_;
        return $c->render_exception("Error while find user: $err")                if $err;
        return $c->render_exception("Error while find user by user id:  $ex_err") if $ex_err;
        return $c->render_exception("Error user $uid not exist") unless $user;

        if ($ex_user) {
          $c->flash(error => 'Error: this social account already exist');
          $c->_profile($user, $type);
          return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
        }

        my $user_opt = {
          query  => {_id => bson_oid $uid},
          update => {
            '$push' => {
              social => bson_doc(
                _id   => bson_oid,
                type  => $type,
                id    => $id,
                name  => $name,
                pic   => $pic,
                email => $email
              )
            }
          },
          new => bson_true
        };
        $db->collection('user')->find_and_modify($user_opt => $delay->begin);
      },
      sub {
        my ($delay, $err, $user) = @_;
        return $c->render_exception("Error while find_one user: $err") if $err;

        $c->_profile($user, $type);
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }
    );
  } else {
    Mojo::IOLoop->delay(
      sub {
        $db->collection('user')->find_one(
          {social => {'$elemMatch' => bson_doc(type => $type, id => $id)}},
          {login => 1, pic => 1, code => 1, type => 1} => shift->begin
        );
      },
      sub {
        my ($delay, $err, $user) = @_;
        return $c->render_exception("Error while find_one user: $err") if $err;

        unless ($user) {
          $c->session(
            stype  => $type,
            sid    => $id,
            sname  => $name,
            spic   => ($pic // ''),
            semail => ($email // '')
          );
          return $c->redirect_to('user_register_view');
        }

        if ($user->{code}{confirm} eq bson_false) {
          $c->flash(error => 'Account is not confirmed.');
          return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
        }

        my $set_opt = {'social.$.name' => $name, 'social.$.pic' => $pic, 'social.$.email' => $email};
        $set_opt->{pic} = $pic if ($type eq $user->{type} && $pic ne $user->{pic});

        $db->collection('user')->find_and_modify({
            query  => {social => {'$elemMatch' => bson_doc(type => $type, id => $id)}},
            update => {'$set' => $set_opt},
            new    => bson_true
          } => $delay->begin
        );

        if ($type eq $user->{type} && $pic ne $user->{pic}) {
          $db->collection('task')
            ->update(({'winner.login' => $user->{login}}, {'$set' => {'winner.pic' => $pic}}, {multi => 1}) =>
              $delay->begin);
          $db->collection('task')
            ->update(({'owner.login' => $user->{login}}, {'$set' => {'owner.pic' => $pic}}, {multi => 1}) =>
              $delay->begin);
          $db->collection('solution')
            ->update(({'user.login' => $user->{login}}, {'$set' => {'user.pic' => $pic}}, {multi => 1}) =>
              $delay->begin);
          $db->collection('stat')
            ->update(({login => $user->{login}}, {'$set' => {pic => $pic}}) => $delay->begin);
          $db->collection('comment')
            ->update(({'user.login' => $user->{login}}, {'$set' => {'user.pic' => $pic}}, {multi => 1}) =>
              $delay->begin);
        }
      },
      sub {
        my ($delay, $err, $user) = (shift, shift, shift);
        return $c->render_exception("Error while find_and_modify user: $err") if $err;
        for (1 .. (scalar @_) / 2) {
          my ($err, $num) = (shift, shift);
          return $c->render_exception("Error while update user pic: $err") if $err;
        }

        $c->_profile($user, $type);
        return $c->redirect_to(delete $c->session->{'base_url'} // 'index');
      }
    );
  }
}

sub _profile {
  my ($c, $user, $type) = @_;
  $c->session(uid => $user->{_id}, pic => $user->{pic}, login => $user->{login});
}

1;
