package JAGC::Model::Task;

use Mojo::Base 'MojoX::Model';
use Mojo::Util qw/encode trim/;
use Mango::BSON ':bson';

sub _validate {
  my ($p, $v) = @_;

  my $hparams = $p->to_hash;
  my @test_fields = grep { /^test_/ } %{$hparams};

  for (@test_fields) {
    $hparams->{$_} =~ s/\r\n/\n/g;
    $hparams->{$_} =~ s/^\n*|\n*$//g;
  }

  my $to_validate = {name => trim($hparams->{name}), description => trim($hparams->{description})};
  $to_validate->{$_} = $hparams->{$_} for @test_fields;

  $v->input($to_validate);
  $v->required('name')->size(1, 50, 'Length of task name must be no more than 50 characters');
  $v->required('description')->size(1, 500, 'Length of description must be no more than 500 characters');
  $v->required($_)->size(1, 100000, 'Length of test must be no more than 100000 characters') for @test_fields;
  $v->enough_tests;

  return $v;
}

sub add {
  my ($self, %args) = @_;
  my $db = $self->app->db;

  my $s = $args{session};
  my $p = $args{params};    # Mojo::Parameters

  my $uid = bson_oid $s->{uid};

  my $v = _validate($p, $args{validation});
  my %res = (validation => $v);

  return %res if ($v->has_error);

  my @tests;
  for my $tin (grep { /^test_\d+_in$/ } @{$p->names}) {
    (my $tout = $tin) =~ s/in/out/;
    my $test_in  = $v->param($tin);
    my $test_out = $v->param($tout);
    my $test     = bson_doc(
      _id => bson_oid,
      in  => bson_bin(encode 'UTF-8', $test_in),
      out => bson_bin(encode 'UTF-8', $test_out),
      ts  => bson_time
    );
    push @tests, $test;
  }

  my $q = bson_doc(
    name  => $v->param('name'),
    desc  => $v->param('description'),
    owner => bson_doc(uid => $uid, login => $s->{login}, pic => $s->{pic}),
    stat  => bson_doc(all => 0, ok => 0),
    ts    => bson_time,
    tests => \@tests
  );

  $q->{con} = bson_oid($args{con}) if $args{con};
  my $oid = $db->c('task')->insert($q);

  unless ($oid) {
    $res{err} = "Error while insert task: $!";
    return %res;
  }

  $res{tid} = bson_oid $oid;
  return %res;
}

1;
