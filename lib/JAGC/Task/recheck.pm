package JAGC::Task::recheck;
use Mojo::Base -base;

sub call {
  my ($self, $job, $tid) = @_;

  my $db = $job->app->db;

  $db->collection('solution')->update({'task.tid' => $tid}, {'$set' => {s => 'inactive'}}, {multi => 1});
  $db->collection('task')
    ->update({_id => $tid}, {'$set' => {'stat.all' => 0, 'stat.ok' => 0}, '$unset' => {winner => 1}});

  my $cursor = $db->collection('solution')->find({'task.tid' => $tid})->fields({_id => 1})->sort({ts => 1});
  while (my $s = $cursor->next) {
    $self->app->minion->enqueue(check => [$s->{_id}] => {priority => 0});
  }
  $job->finish;
}

1;
