package JAGC::Command::recheck;
use Mojo::Base 'Mojolicious::Command';

use Mango::BSON ':bson';

has description => 'Recheck all JAGC solutions.';
has usage => sub { shift->extract_usage };

sub run {
  my $self = shift;
  my $db   = $self->app->db;

  my $cursor = $db->collection('task')->find({})->fields({_id => 1, owner => 1});
  while (my $task = $cursor->next) {
    $db->collection('solution')
      ->update({'task.tid' => $task->{_id}}, {'$set' => {s => 'inactive'}}, {multi => 1});
    $db->collection('task')->update({_id => $task->{_id}}, {'$set' => {'stat.all' => 0, 'stat.ok' => 0}});

    my $cursor =
      $db->collection('solution')->find({'task.tid' => $task->{_id}})->fields({_id => 1})->sort({ts => 1});
    while (my $s = $cursor->next) {
      $self->app->minion->enqueue(check => [$s->{_id}] => {priority => 0});
    }
  }
}

1;

=encoding utf8

=head1 NAME

JAGC::Command::recheck - Recheck all JAGC solutions.

=head1 SYNOPSIS

  Usage: APPLICATION recheck

  ./script/jagc recheck

=cut
