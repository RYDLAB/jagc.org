package JAGC::Model::User;

use Mojo::Base 'MojoX::Model';
use Mango::BSON ':bson';

use constant RECS_ON_PAGE => 50;

sub all {
  my ($self, %args) = @_;

  my $con = $args{con} || '';

  my $skip   = ($args{page} - 1) * RECS_ON_PAGE;
  my $filter = $con ? {con => bson_oid $con } : {con => {'$exists' => 0}};
  my $col    = $self->app->db->c('stat');

  my $count;
  eval { $count = $col->find($filter)->count };

  return (err => "Error while count users: $@") if $@;
  return wantarray ? () : undef if $count <= $skip;

  my $users;
  eval {
    $users = $col->find($filter)->sort(bson_doc(score => -1, t_all => -1, t_ok => -1))->limit(RECS_ON_PAGE)
      ->skip($skip)->fields({tasks => 0})->all;
  };
  return (err => "Error while find users: $@") if $@;

  return (users => $users, skip => $skip, next_btn => ($count - $skip > RECS_ON_PAGE) ? 1 : 0);
}

1;
