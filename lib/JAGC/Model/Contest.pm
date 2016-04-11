package JAGC::Model::Contest;

use Mojo::Base 'MojoX::Model';
use Mango::BSON ':bson';

sub upsert {    # create new contest or update existing one
  my ($self, %args) = @_;
  my $db = $self->app->db;

  my $s = $args{session};
  my $p = $args{params};                               # Mojo::Parameters
  my $v = _validate($args{validation}, $p->to_hash);

  my %res = (validation => $v);

  my $langs = $p->every_param('langs');

  # if only one language selected
  $langs = [$langs] unless ref $langs;

  return %res if ($v->has_error);

  my $start_date = $self->app->date_to_bson($v->param('start_date'));
  my $end_date   = $self->app->date_to_bson($v->param('end_date'));

  if ($end_date < $start_date) {
    $res{err} = 'Bad end date!';
    return %res;
  }

  my $oid;
  my $uid = bson_oid($s->{uid});

  if ($args{con}) {
    $oid = bson_oid $args{con};

    $db->c('contest')->update(
      {'owner.uid' => $uid, _id => $oid},
      {
        '$set' => bson_doc(
          name       => $v->param('name'),
          desc       => $v->param('description'),
          owner      => bson_doc(uid => $uid, login => $s->{login}, pic => $s->{pic}),
          ts         => bson_time,
          start_date => $start_date,
          end_date   => $end_date,
          langs      => $langs,
        )
      }
    );
  } else {
    $oid = $db->c('contest')->insert(
      bson_doc(
        name       => $v->param('name'),
        desc       => $v->param('description'),
        owner      => bson_doc(uid => $uid, login => $s->{login}, pic => $s->{pic}),
        ts         => bson_time,
        start_date => $start_date,
        end_date   => $end_date,
        langs      => $langs,
      )
    );
  }

  return (validation => $v, con => $oid);
}

sub edit_view {
  my ($self, %args) = @_;
  my $db = $self->app->db;

  my $s   = $args{session};
  my $con = bson_oid $args{con};
  my $uid = bson_oid $s->{uid};

  my $contest = $db->c('contest')->find_one($con);
  my $langs   = $db->c('language')->find->all;

  return wantarray ? () : undef unless $contest;

  my %langs = ();

  $langs{$_->{name}} = 0 foreach @$langs;
  exists $langs{$_} && $langs{$_}++ foreach @{$contest->{langs}};

  unless ($contest->{owner}{uid} eq $uid) {
    $self->app->log->error("Error: not owner attempt to modify contest");
    return wantarray ? () : undef;
  }

  $contest->{start_date} = $self->app->bson_to_date($contest->{start_date});
  $contest->{end_date}   = $self->app->bson_to_date($contest->{end_date});

  my %res = (contest => $contest, langs => \%langs);

  return %res if !exists $contest->{tasks} || !@{$contest->{tasks}};

  my $qery = {_id => {'$in' => $contest->{tasks}}};
  my $projection = {_id => bson_true, name => bson_true};

  my $tasks = $db->c('contest.task')->find($qery, $projection)->all;

  $res{tasks} = $tasks if (defined $tasks);

  return %res;
}

sub _validate {
  my ($v, $p) = @_;

  $v->input($p);
  $v->required('name')->size(1, 50, 'Length of contest name must be no more than 50 characters');
  $v->required('description')->size(1, 500, 'Length of description must be no more than 500 characters');
  $v->required('start_date');
  $v->required('end_date');
  $v->check_dates;
  $v->required('langs');

  return $v;
}

1;
