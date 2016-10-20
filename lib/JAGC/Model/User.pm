package JAGC::Model::User;

use Mojo::Base 'MojoX::Model';
use Mango::BSON ':bson';

use constant RECS_ON_PAGE => 50;

sub all {
  my ($self, $page, $cb) = @_;

  my $skip = ($page - 1) * RECS_ON_PAGE;
  my $q    = {con => {'$exists' => bson_false}};
  my $db   = $self->app->db;

  my $count;

  Mojo::IOLoop->delay(
    sub {
      my $d = shift;

      $db->c('stat')->find($q)->count($d->begin);
      $db->c('stat')->find($q)->sort(bson_doc(score => -1, t_all => -1, t_ok => -1))->limit(RECS_ON_PAGE)
        ->skip($skip)->fields({tasks => 0})->all($d->begin);
    },
    sub {
      my ($d, $serr, $ctr, $uerr, $users) = @_;

      if (my $e = $serr || $uerr) {
        return $cb->(err => $e);
      }

      $cb->(users => $users, skip => $skip, next_btn => ($ctr - $skip > RECS_ON_PAGE) ? 1 : 0);
    }
  );
}

sub contest_all {
  my ($self, $con, $page, $cb) = @_;

  my $db = $self->app->db;
  $con = bson_oid $con;

  my $skip = ($page - 1) * RECS_ON_PAGE;

  Mojo::IOLoop->delay(
    sub {
      $db->c('stat')->aggregate([
        {'$match' => {con => $con}},
        { '$sort' => { rank => 1 }},
        { '$skip' => $skip },
        { '$limit' => (RECS_ON_PAGE +1) }
      ])->all(shift->begin);
    },
    sub {
      my ($d, $serr, $stats) = @_;

      return $cb->(err => $serr) if $serr;

      my $next_btn = 0;

      if (@$stats > RECS_ON_PAGE) {
        $next_btn = 1;
        pop @$stats;
      }

      $cb->(users => $stats, skip => $skip, next_btn => $next_btn);
    }
  );
}

1;
