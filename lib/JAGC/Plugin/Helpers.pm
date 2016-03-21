package JAGC::Plugin::Helpers;

use Mojo::Base 'Mojolicious::Plugin';
use Time::Piece;

sub register {
  my ($self, $app) = @_;

  $app->helper( 'this_year' => sub { Time::Piece->new()->year })
}

1;
