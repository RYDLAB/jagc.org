use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

BEGIN { $ENV{MOJO_MODE} = 'test' }

my $t = Test::Mojo->new('JAGC')->tap(
  sub {
    $_->ua->max_connections(0);
    $_->app->db->command({dropDatabase => 1});
  }
);

my $user_email = 'u1@jagc.org';
my $user_login = 'u1';

$t->get_ok("/oauth/test?id=1&name=${user_login}&pic=jagc.org/u1.png&email=${user_email}")->status_is(302)
  ->header_is(Location => '/register');
$t->get_ok('/register')->status_is(200)->element_exists('form[action="/user/register"][method="POST"]');
$t->post_ok('/user/register' => form => {email => $user_email, login => $user_login})->status_is(302)
  ->header_is(Location => '/');

my $confirm_link = $t->tx->res->headers->header('X-Confirm-Link');
like $confirm_link, qr/user.*${user_email}/, 'link ok';

$t->get_ok('/')->status_is(200)
  ->text_is('div.alert.alert-info strong' =>
    'To complete the registration and confirmation email address, go to the link from the mail.');

$t->get_ok($confirm_link)->status_is(302)->header_is(Location => '/');
$t->get_ok('/')->status_is(200)
  ->text_is('div.alert.alert-success strong' => 'You are successfully registered')
  ->text_like('ul.navbar-nav.navbar-right li a' => qr /${user_login}/);

done_testing();
