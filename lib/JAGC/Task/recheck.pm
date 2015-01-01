package JAGC::Task::recheck;
use Mojo::Base -base;

sub call {
  my ($self, $job, $tid) = @_;

  my $cursor =
    $job->app->db->collection('solution')->find({'task.tid' => $tid})->fields({_id => 1})->sort({ts => 1});

  while (my $s = $cursor->next) {
    $job->app->minion->enqueue(check => [$s->{_id}] => {priority => 0});
  }
  $job->finish;
}

1;
