package Twitter::Helper;

use Digest::SHA 'hmac_sha1';
use MIME::Base64;
use Mojo::Util qw/url_escape md5_sum/;

sub new {
  my $class = shift;
  my $self = {consumer_key => shift, consumer_secret => shift};
  bless $self, $class;
  $self->{_parameters} = $self->generate_default_params;
  return $self;
}

sub generate_default_params {
  my $self = shift;
  return {
    oauth_consumer_key     => $self->{consumer_key},
    oauth_nonce            => $self->generate_nonce,
    oauth_signature_method => 'HMAC-SHA1',
    oauth_timestamp        => time,
    oauth_version          => '1.0'
  };
}

sub set_token {
  my $self = shift;
  my ($token, $token_secret) = @_;
  $self->{token}        = $token;
  $self->{token_secret} = $token_secret;
}

sub set_time {
  my ($self, $time) = @_;
  $self->{_parameters}->{oauth_timestamp} = $time // time;
}

sub delete_token {
  my $self = shift;
  delete $self->{token};
  delete $self->{token_secret};
}

sub generate_nonce {
  return md5_sum rand . time . $$;
}

sub set_nonce {
  my ($self, $nonce) = @_;
  $self->{_parameters}->{oauth_nonce} = $nonce // $self->generate_nonce;
}

sub sign {
  my $self = shift;
  my ($method, $url, $add_params, $is_need_token) = @_;
  my %all_params = (%{$self->{_parameters}}, %$add_params);
  $all_params{oauth_token} = $self->{token} if $is_need_token;

  my $params = join '&', map { join '=', $_ => url_escape($all_params{$_}) } sort keys %all_params;
  my $signature_text = join '&', uc($method), url_escape($url), url_escape($params);
  my $token = $self->{token_secret} // '';
  my $key = join '&', map url_escape($_), $self->{consumer_secret}, $token;

  $self->{signature} = encode_base64 hmac_sha1($signature_text, $key), '';
}

sub auth_header {
  my $self = shift;
  my ($add_params, $is_need_token) = @_;
  my %all_params = (%{$self->{_parameters}}, %$add_params);
  $all_params{oauth_token} = $self->{token} if $is_need_token;
  $all_params{oauth_signature} = $self->{signature};

  return 'OAuth ' . join ', ', map { $_ . '="' . url_escape($all_params{$_}) . '"' } keys %all_params;
}

1;
