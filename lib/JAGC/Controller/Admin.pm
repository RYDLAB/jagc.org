package JAGC::Controller::Admin;
use Mojo::Base 'Mojolicious::Controller';

sub index {
  shift->render;
}

1;
