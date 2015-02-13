package JAGC::Controller::Login;
use Mojo::Base 'Mojolicious::Controller';

use Mango::BSON ':bson';
use Mojo::Util qw/url_escape md5_sum/;
use Twitter::Helper;

sub as {
  my $c = shift;
  $c->render_later;

  $c->db->collection('user')->find_one(
    bson_oid($c->param('uid')) => sub {
      my ($collection, $err, $user) = @_;
      return $c->reply->exception("Error while find user: $err") if $err;

      $c->session(uid => $user->{_id}, pic => $user->{pic}, login => $user->{login});
      return $c->redirect_to('index');
    }
  );
}

sub twitter {
  my $c = shift;

  $c->session(base_url => $c->req->headers->referrer);
  my $twitter = $c->app->config->{oauth}{twitter};

  my $oauth_callback = $c->url_for('oauth_twitter')->to_abs->to_string;
  my $th = Twitter::Helper->new($twitter->{consumer_key}, $twitter->{consumer_secret});
  $th->sign('post', $twitter->{url_request_token}, {oauth_callback => $oauth_callback}, 0);
  my $auth_header = $th->auth_header({oauth_callback => $oauth_callback}, 0);

  $c->delay(
    sub {
      $c->ua->post($twitter->{url_request_token} => {Authorization => $auth_header} => shift->begin);
    },
    sub {
      my ($d, $tx) = @_;

      if (my $res = $tx->success) {
        my $params      = Mojo::Parameters->new($res->body);
        my $oauth_token = $params->param('oauth_token');
        $c->session(oauth_token_secret => $params->param('oauth_token_secret'));

        if ($params->param('oauth_callback_confirmed') eq 'true') {
          my $url = Mojo::URL->new($twitter->{url_redirect_auth})->query(oauth_token => $oauth_token);
          return $c->redirect_to($url);
        } else {
          return $c->reply->exception;
        }
      } else {
        my $err = $tx->error;
        return $c->render(text => "[twitter] $err->{code} response: $err->{message}") if $err->{code};
        return $c->render(text => "[twitter] Connection error: $err->{message}");
      }
    }
  );
}

sub vk {
  my $c = shift;
  $c->session(base_url => $c->req->headers->referrer);
  my $vk  = $c->app->config->{oauth}{vk};
  my $url = Mojo::URL->new($vk->{url_auth})->query(
    client_id     => $vk->{client_id},
    response_type => 'code',
    redirect_uri  => $c->url_for('oauth_vk')->to_abs
  );
  $c->redirect_to($url);
}

sub github {
  my $c = shift;
  $c->session(base_url => $c->req->headers->referrer);
  my $github = $c->app->config->{oauth}{github};
  my $url = Mojo::URL->new($github->{url_auth})->query(client_id => $github->{client_id});
  $c->redirect_to($url);
}

sub linkedin {
  my $c = shift;
  $c->session(base_url => $c->req->headers->referrer);
  my $linkedin = $c->app->config->{oauth}{linkedin};
  my $state    = md5_sum(time . rand . $$);
  my $url      = Mojo::URL->new($linkedin->{url_auth})->query(
    client_id     => $linkedin->{client_id},
    response_type => 'code',
    scope         => 'r_basicprofile',
    state         => $state,
    redirect_uri  => $c->url_for('oauth_linkedin')->to_abs
  );
  $c->session(state => $state);
  $c->redirect_to($url);
}

sub fb {
  my $c = shift;
  $c->session(base_url => $c->req->headers->referrer);
  my $fb    = $c->app->config->{oauth}{fb};
  my $state = md5_sum(time . rand . $$);
  my $url   = Mojo::URL->new($fb->{url_auth})
    ->query(client_id => $fb->{client_id}, state => $state, redirect_uri => $c->url_for('oauth_fb')->to_abs);
  $c->session(state => $state);
  $c->redirect_to($url);
}

sub add_social {
  my $c   = shift;
  my $uid = $c->session('uid');
  return $c->reply->not_found unless $uid;
  return $c->reply->not_found unless $c->param('social');

  my $url_name = 'login_' . $c->param('social');

  $c->session(add_social => 1);
  $c->redirect_to($c->url_for($url_name));
}

sub remove_social {
  my $c = shift;

  my $uid   = $c->session('uid');
  my $login = $c->session('login');
  return $c->reply->not_found unless $uid;
  return $c->reply->not_found unless $c->param('social');
  $uid = bson_oid $uid;

  my $social = $c->param('social');
  my $db     = $c->db;
  $c->delay(
    sub {
      $db->collection('user')->find_one($uid => shift->begin);
    },
    sub {
      my ($d, $err, $user) = @_;
      return $c->reply->exception("Error while get user: $err") if $err;
      return $c->reply->not_found unless $user;
      return $c->reply->not_found if @{$user->{social}} == 1;

      my @socials = grep { !($social eq $_->{type}) } @{$user->{social}};
      $db->collection('user')->update(({_id => $uid}, {'$set' => {social => \@socials}}) => $d->begin);
    },
    sub {
      my ($d, $err, $num) = @_;
      return $c->reply->exception("Error while update user: $err") if $err;

      return $c->redirect_to('user_settings', login => $login);
    }
  );
}

1;
