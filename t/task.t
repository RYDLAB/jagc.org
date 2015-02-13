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

my $user_email = 'u2@jagc.org';
my $user_login = 'u2';

$t->get_ok("/oauth/test?id=2&name=${user_login}&pic=jagc.org/u2.png&email=${user_email}");
$t->post_ok('/user/register' => form => {email => $user_email, login => $user_login});
$t->get_ok($t->tx->res->headers->header('X-Confirm-Link'));

$t->get_ok('/task/add')->status_is(200)->element_exists('form[action="/task/add"][method="POST"]');

my $task_name        = 'Example';
my $task_description = 'Simple task from test';

$t->post_ok('/task/add' => form =>
    {name => $task_name, description => $task_description, test_1_in => 'Hi', test_1_out => '42'})
  ->status_is(200)->text_is('div.alert strong' => 'You need create at least 5 tests');
$t->post_ok(
  '/task/add' => form => {
    name        => $task_name,
    description => $task_description,
    test_1_in   => 'Hi',
    test_1_out  => '42',
    test_2_in   => 't2',
    test_2_out  => '2',
    test_3_in   => 't333',
    test_3_out  => '333',
    test_4_in   => 't4',
    test_4_out  => '4',
    test_5_in   => 't5',
    test_5_out  => '5'
  }
)->status_is(302);
$t->get_ok($t->tx->res->headers->location)->status_is(200)->text_is('blockquote > h3' => $task_name)
  ->text_is('blockquote pre.text_description' => $task_description);

done_testing();
