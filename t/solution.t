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
$t->app->db->collection('language')->insert({name => 'test', path => '/usr/bin/test'});

my $user_email = 'u3@jagc.org';
my $user_login = 'u3';

$t->get_ok("/oauth/test?id=3&name=${user_login}&pic=jagc.org/u3.png&email=${user_email}");
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
$t->post_ok('/task/add' => form => {name => 't', description => 't', @tests})->status_is(302);
my $turl = $t->tx->res->headers->location;
my $surl = "$turl/solution/add";

$t->post_ok($surl => form => {code => '1', language => 'test'})->status_is(302)
  ->header_is(Location => '/user/u3/events');
$t->get_ok('/user/u3/events')->status_is(200)
  ->text_is('div.panel-group div.row:nth-child(1) div.col-sm-3 a'        => 't')
  ->text_is('div.panel-group div.row:nth-child(1) div:nth-child(4) span' => 'Not tested yet')
  ->text_is('div.panel-group div.row:nth-child(1) div:nth-child(5)'      => 'test');

$t->app->minion->perform_jobs;

$t->get_ok('/user/u3/events')
  ->text_is('div.panel-group div.row:nth-child(1) div:nth-child(4) a' => 'Success');

# Recheck solution
$tests[-1] = 7;
$t->post_ok("$turl/edit" => form => {name => 't2', description => 't2', @tests})->status_is(302);
$t->get_ok('/user/u3/events')->status_is(200)
  ->text_is('div.panel-group div.row:nth-child(1) div.col-sm-3 a'        => 't2')
  ->text_is('div.panel-group div.row:nth-child(1) div:nth-child(4) span' => 'Not tested yet')
  ->text_is('div.panel-group div.row:nth-child(1) div:nth-child(5)'      => 'test');

$t->app->minion->perform_jobs;

$t->get_ok('/user/u3/events')
  ->text_is('div.panel-group div.row:nth-child(1) div:nth-child(4) a' => 'Success');

done_testing();
