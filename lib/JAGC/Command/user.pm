package JAGC::Command::user;
use Mojo::Base 'Mojolicious::Command';

use Mango::BSON ':bson';

no if $] >= 5.018, warnings => 'experimental';

has description => 'Control JAGC user.';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, $command, $uid, $options) = @_;
  my $db = $self->app->db;

  eval { $uid = bson_oid $uid; };
  die "Invalid [UID]: $uid\n" if $@;

  given ($command) {
    when ('rename') {
      die "Set new login for user\n" unless $options;

      $db->collection('user')->update({_id => $uid}, {'$set' => {login => $options}});
      $db->collection('solution')
        ->update({'user.uid' => $uid}, {'$set' => {'user.login' => $options}}, {multi => 1});
      $db->collection('task')
        ->update({'winner.uid' => $uid}, {'$set' => {'winner.login' => $options}}, {multi => 1});
      $db->collection('task')
        ->update({'owner.uid' => $uid}, {'$set' => {'owner.login' => $options}}, {multi => 1});
      $db->collection('stat')->update({'_id' => $uid}, {'$set' => {'login' => $options}});
      $db->collection('comment')
        ->update({'user.uid' => $uid}, {'$set' => {'user.login' => $options}}, {multi => 1});

      print "User [$uid] renamed to $options\n";
    }
    when ('remove') {
      $db->collection('user')->remove({_id => $uid});
      $db->collection('solution')->remove({'user.uid' => $uid});
      $db->collection('task')->update({'winner.uid' => $uid}, {'$unset' => {winner => ''}}, {multi => 1});
      $db->collection('task')->remove({'owner.uid' => $uid});
      $db->collection('stat')->remove({_id         => $uid});
      $db->collection('comment')->remove({'user.uid' => $uid});

      print "User [$uid] removed\n";
    }
    default {
      warn "Invalid COMMAND\n";
    }
  }
}

1;

=encoding utf8

=head1 NAME

JAGC::Command::user - Control (rename/remove) JAGC user.

=head1 SYNOPSIS

  Usage: APPLICATION user [COMMAND] [UID] [OPTIONS]

  ./script/jagc user rename 533b4e2b5867b4c72b0a0000 login
  ./script/jagc user remove 533b4e2b5867b4c72b0a0000

=cut
