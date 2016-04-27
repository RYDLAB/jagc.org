package JAGC::Model::Solution;

use Mojo::Base 'MojoX::Model';
use Mango::BSON ':bson';
use Mojo::Util 'trim';

use constant MAX_CODE_LEN => 10_000;

sub add {
  my ($self, %args) = @_;

  my $s = $args{session};
  my $p = $args{params};
  return wantarray ? () : undef unless $s;

  my $db = $self->app->db;

  my $user = {login => $s->{login}, pic => $s->{pic}, uid => bson_oid $s->{uid}};
  my $tid = bson_oid $args{tid};

  my $task      = $db->c('task')->find_one($tid);
  my $languages = $db->c('language')->find({})->all;
  return wantarray ? () : undef if !$task || !$languages;

  my $langs = [map { $_->{name} } @$languages];

  my $code = $p->param('code');
  $code =~ s/\r\n?/\n/g;

  my $v = $args{validation};
  $v->input({language => trim($p->param('language')), code => $code});
  $v->required('language')->in($langs, 'Language not exist');
  $v->required('code')
    ->code_size(1, MAX_CODE_LEN, 'The length of the source code must be less than ' . (MAX_CODE_LEN + 1));

  my $task_doc = {tid => $tid, name => $task->{name}};

  if ($task->{con}) {
    $task_doc->{con} = $task->{con};

    my $langs = $self->app->model('contest')->contest_languages($task->{con});
    $v->required('language')
      ->in($langs, 'Language "' . $v->param('language') . '" not available for this contest!');
  }


  return (s => 1, validation => $v) if ($v->has_error);

  my ($used_lang) = grep { $_->{name} eq $v->param('language') } @$languages;

  $code = $v->param('code');
  my $code_length = length $code;

  if ($code =~ m/^#!/) {
    $code =~ s/^#![^\s]+[\t ]*//;
    $code_length = length($code) - 1;
    $code_length++ unless $code =~ m/\n/;
    $v->output->{code} =~ s/^#![^\s]+/#!$used_lang->{path}/;
  }

  my $sid = eval {
    $db->c('solution')->insert(
      bson_doc(
        task => $task_doc,
        user => $user,
        code => $v->output->{code},
        lng  => $v->param('language'),
        size => $code_length,
        s    => 'inactive',
        ts   => bson_time
      )
    );
  };

  return (validation => $v, err => "Error while insert solution: $@") if $@;
  $self->app->minion->enqueue(check => [$sid] => {priority => 1});

  return (validation => $v);
}

1;
