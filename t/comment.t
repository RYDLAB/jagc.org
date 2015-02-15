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
$t->app->db->c('language')->insert({name => 'test', path => '/usr/bin/test'});

my $user_email = 'u4@jagc.org';
my $user_login = 'u4';

$t->get_ok("/oauth/test?id=4&name=${user_login}&pic=jagc.org/u4.png&email=${user_email}");
$t->post_ok('/user/register' => form => {email => $user_email, login => $user_login});
$t->get_ok($t->tx->res->headers->header('X-Confirm-Link'));

my @tests = (
  test_1_in  => 1,
  test_1_out => 2,
  test_2_in  => 2,
  test_2_out => 3,
  test_3_in  => 3,
  test_3_out => 4,
  test_4_in  => 4,
  test_4_out => 5,
  test_5_in  => 5,
  test_5_out => 6
);
$t->post_ok('/task/add' => form => {name => 't', description => 't', @tests});
my $turl = $t->tx->res->headers->location;
$t->post_ok("$turl/solution/add" => form => {code => '1', language => 'test'});

$t->app->minion->perform_jobs;

$t->get_ok("$turl/comments")->status_is(200);
$t->get_ok($turl)->status_is(200)->text_is('p.text-right > a[href*="/comments"] > span.badge' => '');

my $comment = 'test. comment!';
$t->post_ok("$turl/comment" => form => {text => $comment})->status_is(302)
  ->header_is(Location => "$turl/comments");
$t->get_ok("$turl/comments")->status_is(200)->content_like(qr/\Q$comment\E/);
$t->get_ok($turl)->status_is(200)->text_is('p.text-right > a[href*="/comments"] > span.badge' => 1);
$t->post_ok("$turl/comment" => form => {text => 'comment #2'});
$t->get_ok($turl)->status_is(200)->text_is('p.text-right > a[href*="/comments"] > span.badge' => 2);

done_testing();
