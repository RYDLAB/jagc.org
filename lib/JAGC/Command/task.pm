package JAGC::Command::task;
use Mojo::Base 'Mojolicious::Command';

use Mango::BSON ':bson';

no if $] >= 5.018, warnings => 'experimental';

has description => 'Control JAGC tasks.';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, $command, $tid) = @_;
  my $db = $self->app->db;

  eval { $tid = bson_oid $tid };
  die "Invalid [ID]: $tid\n" if $@;

  given ($command) {
    when ('remove') {
      my $doc = $db->c('task')->remove({_id => $tid});
      unless ($doc->{n} > 0) {
        warn "Task [$tid] doesn't exist\n";
        break;
      }
      $db->c('solution')->remove({'task.tid' => $tid});
    }
    when ('recheck') {
      $db->c('solution')->update({'task.tid' => $tid}, {'$set' => {s => 'inactive'}}, {multi => 1});
      $db->c('task')
        ->update({_id => $tid}, {'$set' => {'stat.all' => 0, 'stat.ok' => 0}, '$unset' => {winner => 1}});
      $self->app->minion->enqueue(recheck => [$tid] => {priority => 0});
    }
    default {
      warn "Invalid COMMAND\n";
    }
  }
}

1;

=encoding utf8

=head1 NAME

JAGC::Command::task - Control JAGC tasks.

=head1 SYNOPSIS

  Usage: APPLICATION task [COMMAND] [ID]

  ./script/jagc task remove 533b4e2b5867b4c72b0a0000
  ./script/jagc task recheck 533b4e2b5867b4c72b0a0000

=cut
