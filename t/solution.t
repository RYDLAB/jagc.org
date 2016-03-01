use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

BEGIN { $ENV{MOJO_MODE} = 'test' }

plan skip_all => 'Set $ENV{DOCKER} to run this test.' unless $ENV{DOCKER};

my $t = Test::Mojo->new('JAGC')->tap(
  sub {
    $_->ua->max_connections(0);
    $_->app->db->command({dropDatabase => 1});
  }
);

my @langs = qw/python3 python2 php ruby2.0 perl bash ruby haskell nodejs erlang golfscript pyth/;

for ($t->app->db->c('language')) {
  $_->insert({name => 'perl',       path => '/usr/bin/perl'});
  $_->insert({name => 'python3',    path => '/usr/bin/python3.5'});
  $_->insert({name => 'python2',    path => '/usr/bin/python2.7'});
  $_->insert({name => 'bash',       path => '/bin/bash'});
  $_->insert({name => 'ruby2.0',    path => '/usr/bin/ruby2.2'});
  $_->insert({name => 'erlang',     path => '/usr/bin/escript'});
  $_->insert({name => 'haskell',    path => '/usr/bin/runhaskell'});
  $_->insert({name => 'php',        path => '/usr/bin/php'});
  $_->insert({name => 'nodejs',     path => '/usr/bin/nodejs'});
  $_->insert({name => 'ruby',       path => '/usr/bin/ruby'});
  $_->insert({name => 'golfscript', path => '/usr/bin/golfscript.rb'});
  $_->insert({name => 'befunge',    path => '/usr/bin/bef', args => '-q'});
  $_->insert({name => 'pyth',       path => '/usr/bin/pyth.py'});
  $_->insert({name => 'test',       path => '/usr/bin/test'});
}

my $user_email = 'u3@jagc.org';
my $user_login = 'u3';

$t->get_ok("/oauth/test?id=3&name=${user_login}&pic=jagc.org/u3.png&email=${user_email}");
$t->post_ok('/user/register' => form => {email => $user_email, login => $user_login});
$t->get_ok($t->tx->res->headers->header('X-Confirm-Link'));

my @tests = (
  test_1_in  => "1\n2",
  test_1_out => 3,
  test_2_in  => "4\n4",
  test_2_out => 8,
  test_3_in  => "3\n3",
  test_3_out => 6,
  test_4_in  => "19\n22",
  test_4_out => "41",
  test_5_in  => "5\n6",
  test_5_out => 11
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

my $c = $t->app->build_controller;

foreach my $lng (@langs) {
  my $code = $c->render_to_string($lng);
  $t->ua->post($surl => form => {code => $code, language => $lng});
}

$t->app->minion->perform_jobs;

$t->get_ok('/user/u3/events')
  ->text_is('div.panel-group div.row:nth-child(1) div:nth-child(4) a' => 'Success');

# Recheck solution
push @tests, (test_6_in => "25\n6", test_6_out => 31);

$t->post_ok("$turl/edit" => form => {name => 't2', description => 't2', @tests})->status_is(302);
$t->get_ok('/user/u3/events')->status_is(200)
  ->text_is('div.panel-group div.row:nth-child(1) div.col-sm-3 a'        => 't2')
  ->text_is('div.panel-group div.row:nth-child(1) div:nth-child(4) span' => 'Not tested yet')
  ->text_is('div.panel-group div.row:nth-child(1) div:nth-child(5)'      => $langs[-1]);

$t->app->minion->perform_jobs;

for my $i (1 .. @langs) {
  $t->get_ok('/user/u3/events')->text_is("div.panel:nth-child($i) div.col-sm-2:nth-child(4) a" => 'Success');
}

done_testing();

__DATA__
@@ ruby2.0.html.ep
puts gets.to_i+gets.to_i
@@ perl.html.ep
#!/usr/bin/perl -p
$_+=<>
@@ bash.html.ep
read a;read b;let a=a+b;echo $a
@@ ruby.html.ep
a = Integer(gets)+Integer(gets)
puts a
@@ haskell.html.ep
import System.IO
main :: IO ()
main  = do
        a <- getLine
        b <- getLine
        let aa = read a :: Int
        let bb = read b :: Int
        let cc = aa + bb
        putStr . show $ cc
@@ php.html.ep
<?php
$n1 = trim(fgets(STDIN));
$n2 = trim(fgets(STDIN));
print $n1 + $n2;
?>
@@ erlang.html.ep
#!/usr/bin/env escript
main(_) ->
        {ok, [A,B]} = io:fread("","~d~d"),
        C=A+B,
        io:fwrite("~p",[C]).
@@ nodejs.html.ep
String.prototype.trim=function(){return this.replace(/^\s+|\s+$/g, '');};

process.stdin.resume();
var sum = 0;

process.stdin.on('data', function(chunk) {
        var arr = chunk.toString().trim().split("\n");
        for (i =0; i < arr.length; ++i)
             sum+=parseInt(arr[i]);
});

process.stdin.on('end', function() {
  process.stdout.write(sum.toString());
});

@@ python2.html.ep
print input()+input()
@@ python3.html.ep
a = int (input(''))
b = int (input(''))
print(a+b, end="")
@@ golfscript.html.ep
~+
@@ befunge.html.ep
&&+.@
@@ pyth.html.ep
+Qsw
