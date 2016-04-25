package JAGC::Plugin::Helpers;

use Mojo::Base 'Mojolicious::Plugin';
use Mango::BSON ':bson';
use Time::Piece;

my $format = '%d/%m/%Y %H:%M';

sub register {
  my ($self, $app) = @_;

  $app->helper( 'this_year' => sub { Time::Piece->new()->year });

  $app->helper( 'date_to_bson' => sub {
    my ( $self, $str ) = @_; 
    my $log = $self->app->log;

    my $time = eval { Time::Piece->strptime($str, $format) };

    if( $@ ) {
      $log->error("Can't convert string '$str' to Time::Piece object:  $@");
      return undef;
    }

    return bson_time $time->epoch * 1000;
  });
  $app->helper( 'bson_to_date' => sub {
    my ( $self, $bson ) = @_; 
    my $offset = localtime->tzoffset->seconds;
    return localtime( $bson->to_epoch - $offset )->strftime($format);
  });

  $app->helper( 'bson_to_text_date' => sub {
    my ( $self, $bson ) = @_; 
    my $format = "%e %m %H:%M %Y";

    my $offset = localtime->tzoffset->seconds;

    my $t = localtime( $bson->to_epoch - $offset );
    my $mon = (qw / Jan Feb Mar Apr May Jun Jul Aug Sept Oct Nov Dec /)[$t->mon -1];
    my $s = $t->strftime($format);
    $s =~ s/^ *(\d+) (\d+)/$1 $mon/;
    
    #return localtime( $bson->to_epoch - $offset )->strftime($format);
    return $s;
  });
}

1;
