package JAGC::Command::ban;
use Mojo::Base 'Mojolicious::Command';

use Mango::BSON ':bson';

has description => 'Ban user by uid.';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, $uid) = @_;
  my $db = $self->app->db;

  eval { $uid = bson_oid $uid; };
  die "Invalid [UID]: $uid\n" if $@;

  my $doc = $db->collection('user')->update({_id => $uid}, {'$set' => {ban => bson_true}});
  unless ($doc->{n} > 0) {
    warn "User [UID] doesn't exist";
  } else {
    print "User [$uid] banned\n";
  }
}

1;

=encoding utf8

=head1 NAME

JAGC::Command::ban - Ban JAGC user by uid.

=head1 SYNOPSIS

  Usage: APPLICATION ban [UID]

  ./script/jagc ban 533b4e2b5867b4c72b0a0000

=cut
