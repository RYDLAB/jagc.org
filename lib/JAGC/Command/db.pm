package JAGC::Command::db;
use Mojo::Base 'Mojolicious::Command';

use Mango::BSON ':bson';

no if $] >= 5.018, warnings => 'experimental';

has description => 'Control JAGC database.';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, $command) = @_;
  my $db = $self->app->db;

  given ($command) {
    when ('init') {
      $db->c('language')->update({name => 'perl'}, {name => 'perl', path => '/usr/bin/perl'}, {upsert => 1});
      $db->c('language')
        ->update({name => 'python3'}, {name => 'python3', path => '/usr/bin/python3'}, {upsert => 1});
      $db->c('language')
        ->update({name => 'python2'}, {name => 'python2', path => '/usr/bin/python2.7'}, {upsert => 1});
      $db->c('language')
        ->update({name => 'erlang'}, {name => 'erlang', path => '/usr/bin/escript'}, {upsert => 1});
      $db->c('language')
        ->update({name => 'ruby1.9'}, {name => 'ruby1.9', path => '/usr/bin/ruby1.9.1'}, {upsert => 1});
      $db->c('language')
        ->update({name => 'ruby2.0'}, {name => 'ruby2.0', path => '/usr/bin/ruby2.0'}, {upsert => 1});
      $db->c('language')
        ->update({name => 'nodejs'}, {name => 'nodejs', path => '/usr/bin/nodejs'}, {upsert => 1});
      $db->c('language')
        ->update({name => 'haskell'}, {name => 'haskell', path => '/usr/bin/runhaskell'}, {upsert => 1});
      $db->c('language')->update({name => 'bash'}, {name => 'bash', path => '/bin/bash'},    {upsert => 1});
      $db->c('language')->update({name => 'php'},  {name => 'php',  path => '/usr/bin/php'}, {upsert => 1});
    }
    when ('indexes') {
      $db->c('user')->ensure_index({email => 1}, {unique => bson_true});
      $db->c('user')->ensure_index({login => 1}, {unique => bson_true});
      $db->c('solution')->ensure_index({s => 1});
    }
    default {
      warn "Invalid COMMAND\n";
    }
  }
}

1;

=encoding utf8

=head1 NAME

JAGC::Command::db - Control JAGC database.

=head1 SYNOPSIS

  Usage: APPLICATION db [COMMAND]

  ./script/jagc db init
  ./script/jagc db indexes

=cut
