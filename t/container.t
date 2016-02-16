use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use Mojo::JSON 'decode_json';
use File::Temp 'tempdir';
use File::Copy 'cp';
use Mojo::IOLoop::Delay;

plan skip_all => 'Run this test only after docker configuration';

my $t = Test::Mojo->new('JAGC');

my $c = $t->app->build_controller;

my @scripts = (
  {bin => '/usr/bin/perl',   in => "665\n2", out => "667", src => $c->render_to_string('perl')},
  {bin => '/bin/bash',       in => "665\n2", out => "667", src => $c->render_to_string('bash')},
  {bin => '/usr/bin/nodejs', in => "665\n2", out => "667", src => $c->render_to_string('nodejs')},
  {bin => '/usr/bin/ruby',   in => "665\n2", out => "667", src => $c->render_to_string('ruby')},

  #  {
  #    bin => '/usr/bin/escript',
  #    in  => "665\n2",
  #    out => "667",
  #    src => $c->render_to_string('erlang')
  #  },
  {bin => '/usr/bin/php',        in => "665\n2", out => "667", src => $c->render_to_string('php')},
  {bin => '/usr/bin/runhaskell', in => "665\n2", out => "667", src => $c->render_to_string('haskell')}
);

plan tests => 5 + @scripts;


my $shvd       = $t->app->config->{worker}{shared_volume_dir};
my $api_server = $t->app->config->{worker}{api_server};
my $cid        = 'test_container';

ok(-d $shvd, 'shared volume exists');

my $tmp_dir = tempdir(DIR => $shvd, CLEANUP => 1);
ok(chmod(0755, $tmp_dir), 'create mount point on host system');

my $q = $t->app->config->{worker}{create_container_query};
$q->{Binds} = ["$tmp_dir:/opt/share"];


$t->post_ok("$api_server/containers/create?name=$cid" => json => $q);
$t->delete_ok("$api_server/containers/$cid?v=1");

ok(cp($t->app->home->rel_file('script/starter'), $tmp_dir), 'make starter copy');

foreach my $s (@scripts) {
  $q->{Cmd} = ['/usr/bin/perl', '/opt/share/starter', $s->{bin}];

  open(my $fh, ">$tmp_dir/input");
  print $fh $s->{in};
  close($fh);

  open($fh, ">$tmp_dir/code");
  print $fh $s->{src};
  close($fh);

  $t->app->ua->post("$api_server/containers/create?name=$cid" => json => $q);

  my $delay = Mojo::IOLoop::Delay->new;

  my $message;
  my $end = $delay->begin;

  $t->app->ua->websocket(
    "$api_server/containers/$cid/attach/ws?stream=1&stdout=1" => sub {
      my ($ua, $tx) = @_;

      return unless $tx->is_websocket;

      my $start_tx = $t->app->ua->post("$api_server/containers/$cid/start");

      return unless $start_tx->success;

      $tx->on(
        finish => sub {
          my ($tx, $code, $reason) = @_;
          $t->app->ua->post("$api_server/containers/$cid/stop?t=1");

          $end->();
        }
      );

      $tx->on(
        message => sub {
          my ($tx, $msg) = @_;
          $message = $msg;
          $tx->finish;
        }
      );
    }
  );

  $delay->wait;
  $t->app->ua->delete("$api_server/containers/$cid?v=1");

  my $res_json = eval { decode_json $message };

  chomp $res_json->{stdout};
  ok($res_json->{stdout} eq $s->{out}, "$s->{bin} : $message");
}


done_testing();

__DATA__
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
