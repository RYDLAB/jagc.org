package JAGC::Command::stat;
use Mojo::Base 'Mojolicious::Command';

use Mango::BSON ':bson';

no if $] >= 5.018, warnings => 'experimental';

has description => 'Statistic JAGC.';
has usage => sub { shift->extract_usage };

sub run {
  my $self = shift;

  my $log = $self->app->log;

  $log->debug('Start calculate statistic');
  
  $self->app->model('stat')->calculate;
  $log->debug('Finish script');
}

1;

=encoding utf8

=head1 NAME

JAGC::Command::stat - Calculate statistics for JAGC.

=head1 SYNOPSIS

  Usage: APPLICATION stat

  ./script/jagc stat

=cut
