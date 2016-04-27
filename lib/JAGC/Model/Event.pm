package JAGC::Model::Event;

use Mojo::Base 'MojoX::Model';
use Mango::BSON ':bson';

sub info {
  my ( $self, %args ) = @_;

  my $page = $args{page};
  my $login = $args{login};
  my $cb = $args{cb};
  my $con = $args{con} ? bson_oid $args{con} : undef; 

  my $event_opt = { 'task.con' => { '$exists' => bson_false }};
  my %res = ();

  if( $login ) {
    $event_opt->{'user.login'} = $res{login} = $login;
    $event_opt->{'task.con'} = $con if $con;
  }

  my $limit = 20;
  my $skip = ($page - 1) * $limit;

  my $db = $self->app->db;

  Mojo::IOLoop->delay(
    sub {
      my $d = shift;

      return $db->c('contest')->find_one($con => $d->begin) if $con;
      $d->pass;
    },
    sub {
      my ($d, $cerr, $contest) = @_;
      return $cb->( err => "Error while get contest: $cerr" ) if( $cerr );
      
      if( $con ) {
        my $t = bson_time;
        
        $res{hide_code} = 1 if( $args{session}->{login} ne $login && $t < $contest->{end_date});
      }

      $db->c('solution')->find($event_opt)->count(shift->begin);
    },
    sub {
      my ($d, $err, $count) = @_;
      return $cb->(err => "Error while get count of elements in solution: $err") if $err;
      return $cb->() if $count > 0 && $count <= $skip; # 404

      $res{need_next_btn} = ($count - $skip > $limit ? 1 : 0);
      $db->c('solution')->find($event_opt)->sort({ts => -1})->skip($skip)->limit($limit)->all($d->begin);
    },
    sub {
      my ($d, $qerr, $events) = @_;
      return $cb->( err => "Error while get solutions: $qerr" ) if $qerr;

      my %sid;
      map { $sid{$_->{task}{tid}} = undef } @{$events // []};
      $res{events} = $events // [];

      $db->c('task')->find({_id => {'$in' => [map { bson_oid $_ } keys %sid]}})->all($d->begin);
    },
    sub {
      my ($d, $terr, $tasks) = @_;
      return $cb->( err => "Error while get tasks for solutions: $terr" ) if $terr;

      my %tasks;
      map { $tasks{$_->{_id}} = $_ } @$tasks;
      $res{tasks} = \%tasks;

      return $cb->(%res) unless $login;

      return $cb->( %res, user => $res{events}->[0]->{user}) if @{$res{events}};
      $db->c('user')->find_one({login => $login}, {login => 1, pic => 1} => $d->begin);
    },
    sub {
      my ($d, $uerr, $user) = @_;
      return $cb->( err => "Error get user: $uerr" ) if $uerr;
      return $cb->() unless $user; # 404

      $cb->(%res, user => $user);
    }
  );

}

1;
