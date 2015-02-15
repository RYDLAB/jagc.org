package JAGC::Command::solution;
use Mojo::Base 'Mojolicious::Command';

use Mango::BSON ':bson';

no if $] >= 5.018, warnings => 'experimental';

has description => 'Control JAGC solutions.';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, $command, $sid) = @_;
  my $db = $self->app->db;

  eval { $sid = bson_oid $sid };
  die "Invalid [ID]: $sid\n" if $@;

  given ($command) {
    when ('remove') {
      my $doc = $db->c('solution')->remove({_id => $sid});
      warn "Solution [$sid] doesn't exist\n" unless $doc->{n} > 0;
    }
    default {
      warn "Invalid COMMAND\n";
    }
  }
}

1;

=encoding utf8

=head1 NAME

JAGC::Command::solution - Control JAGC solutions.

=head1 SYNOPSIS

  Usage: APPLICATION solution [COMMAND] [ID]

  ./script/jagc solution remove 533b4e2b5867b4c72b0a0000

=cut
