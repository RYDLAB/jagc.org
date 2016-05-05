use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

BEGIN { $ENV{MOJO_MODE} = 'test' }

plan skip_all => 'Set $ENV{DOCKER} to run this test.' unless $ENV{DOCKER};

my $t = Test::Mojo->new('JAGC')->tap(
  sub {
    $_->ua->max_connections(0);
    $_->app->db->command({dropDatabase => 1});
    $_->app->commands->run('db', 'init');
  }
);


my $user_email = 'u2@jagc.org';
my $user_login = 'u2';

$t->get_ok("/oauth/test?id=2&name=${user_login}&pic=jagc.org/u2.png&email=${user_email}");
$t->post_ok('/user/register' => form => {email => $user_email, login => $user_login});
$t->get_ok($t->tx->res->headers->header('X-Confirm-Link'));

$t->get_ok('/contest/add')->status_is(200)->element_exists('form[action="/contest/add"][method="POST"]');

my $contest_name = "Example";
my $contest_description = "Simple contest for test";

my ($sd, $ed) = ('09/12/1970 00:00', '05/10/2100 00:00');


my $i = 1;
foreach my $d ($sd, $ed) {
  my $d_tmp = $t->app->date_to_bson($d);
  $d_tmp = $t->app->bson_to_date($d_tmp);
  cmp_ok($d_tmp, 'eq', $d, 'date conversions '.$i++);
}

$t->post_ok('/contest/add' => form => { description => $contest_description, name => $contest_name,
  langs => ['perl', 'lua' ], start_date => $sd, end_date => $ed})->status_is(302);

my $curl = $t->tx->res->headers->location;

my ($text_sd, $text_ed) = map { $t->app->bson_to_text_date( $t->app->date_to_bson($_) )  } ($sd, $ed);

$t->get_ok('/contests')->text_is('html head title' => 'Contests')
  ->text_is('table > tr > td:first-child > a' => 'Example')
  ->element_exists('table > tr > td:first-child > span[class^=glyphicon]') # play mark for ongoing contests
  ->text_is('table > tr > td:nth-child(6)' => $text_sd)
  ->text_is('table > tr > td:nth-child(7)' => $text_ed);

my $turl = $curl;
$turl =~ s'edit'task/add';

my @tests = ();

for(1..5) { push @tests, "test_${_}_in" => '1', "test_${_}_out" => '1' }

$t->post_ok($turl => form => {name => 't', description => 't', @tests })->status_is(302);

$t->get_ok($curl);
$turl = $t->tx->res->dom->at('table > tr > td:first-child > a')->attr('href');

my $surl = "$turl/solution/add";

$t->post_ok($surl => form => {code => 'Obey!', language => 'Kzer-Za'})->status_is(200)
  ->text_like('span.help-inline' => qr/Kzer-Za.*not available for this contest!/);

$t->post_ok($surl => form => {code => 'print 1', language => 'perl'})->status_is(302);
my $eurl = $t->tx->res->headers->location;

$user_email = 'u3@jagc.org';
$user_login = 'u3';

$t->get_ok("/oauth/test?id=2&name=${user_login}&pic=jagc.org/u3.png&email=${user_email}");
$t->post_ok('/user/register' => form => {email => $user_email, login => $user_login});
$t->get_ok($t->tx->res->headers->header('X-Confirm-Link'));

# hide solution source from another users
$t->get_ok($eurl)->text_is('#collapse0 > div > pre', '...');

$t->post_ok($surl => form => {code => 'print ("1");', language => 'lua'})->status_is(302);

$t->app->minion->perform_jobs;
$t->app->commands->run('stat');
$curl =~ s'/edit'/users';

$t->get_ok($curl)->text_is('table.table > tr:nth-child(2) > td:nth-child(2)', '10')
  ->get_ok($curl)->text_is('table.table > tr:nth-child(3) > td:nth-child(2)', '9');

# Archive contests tests

$ed = '09/12/1970 00:01';
$t->post_ok('/contest/add' => form => { description => "$contest_description 2", name => "$contest_name 2",
  langs => ['perl', 'lua' ], start_date => $sd, end_date => $ed})->status_is(302);

$curl = $t->tx->res->headers->location;
$turl = $curl;
$turl =~ s'edit'task/add';

$t->post_ok($turl => form => {name => 't', description => 't', @tests })->status_is(302);

$t->get_ok($curl);
$turl = $t->tx->res->dom->at('table > tr > td:first-child > a')->attr('href');

$surl = "$turl/solution/add";

$t->get_ok($turl)->element_exists_not('textarea[name=code]');
$t->post_ok($surl => form => {code => 'print 1', language => 'perl'})->status_is(404);

done_testing();
