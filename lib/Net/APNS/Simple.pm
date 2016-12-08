package Net::APNS::Simple;
use 5.008001;
use strict;
use warnings;
use Carp ();
use Crypt::JWT ();
use JSON;
use Moo;
use Protocol::HTTP2::Client;
use IO::Select;
use IO::Socket::SSL qw(debug4);

our $VERSION = "0.01";

has [qw/auth_key key_id team_id bundle_id development/] => (
    is => 'rw',
);

has apns_expiration => (
    is => 'rw',
    default => 0,
);

has apns_priority => (
    is => 'rw',
    default => 10,
);

sub algorithm {'ES256'}

sub _host {
    my ($self) = @_;
    return 'api.' . ($self->development ? 'development.' : '') . 'push.apple.com'
}

sub _port {443}

sub _secret {
    my ($self) = @_;
    if (!$self->{_secret}){
        $self->{_secret} = `openssl pkcs8 -nocrypt -in @{[$self->auth_key]}`;
        $? == 0
            or Carp::croak("Cannot read auth_key file. $!");
    }
    return $self->{_secret};
}

sub _socket {
    my ($self) = @_;
    if (!$self->{_socket} || !$self->{_socket}->opened){
        # TLS transport socket
        $self->{_socket} = IO::Socket::SSL->new(
            PeerHost => $self->_host,
            PeerPort => $self->_port,
            # openssl 1.0.1 support only NPN
            SSL_npn_protocols => ['h2'],
            # openssl 1.0.2 also have ALPN
            SSL_alpn_protocols => ['h2'],
            SSL_version => 'TLSv1_2',
        ) or die $!||$SSL_ERROR;

        # non blocking
        $self->{_socket}->blocking(0);
    }
    return $self->{_socket};
}

sub _client {
    my ($self) = @_;
    $self->{_client} ||= Protocol::HTTP2::Client->new(keepalive => 1);
    return $self->{_client};
}

sub prepare {
    my ($self, $device_token, $aps, $cb) = @_;
    defined $device_token && $device_token ne ''
        or Carp::croak("Empty parameter 'device_token'");
    ref $aps eq 'HASH'
        or Carp::croak("Parameter 'aps' is not HASHREF");
    my $secret = $self->_secret;
    my $craims = {
        iss => $self->team_id,
        iat => time,
    };
    my $jwt = Crypt::JWT::encode_jwt(
        payload => $craims,
        key => \$secret,
        alg => $self->algorithm,
        extra_headers => {
            kid => $self->key_id,
        },
    );
    my $path = sprintf '/3/device/%s', $device_token;
    push @{$self->{_request}}, {
        ':scheme' => 'https',
        ':authority' => join(":", $self->_host, $self->_port),
        ':path' => $path,
        ':method' => 'POST',
        headers => [
            'apns-expiration' => $self->apns_expiration,
            'apns-priority' => $self->apns_priority,
            'apns-topic' => $self->bundle_id,
            'authorization'=> sprintf('bearer %s', $jwt),
        ],
        data => JSON::encode_json({aps => $aps}),
        on_done => $cb,
    };
    return $self;
}

sub _make_client_request_single {
    my ($self) = @_;
    if (my $req = shift @{$self->{_request}}){
        my $done_cb = delete $req->{on_done};
        $self->_client->request(
            %$req,
            on_done => sub {
                ref $done_cb eq 'CODE'
                    and $done_cb->(@_);
                $self->_make_client_request_single();
            },
        );
    }
    else {
        $self->_client->close;
    }
}

sub notify {
    my ($self) = @_;
    $self->_make_client_request_single();
    my $io = IO::Select->new($self->_socket);
    # send/recv frames until request is done
    while ( !$self->_client->shutdown ) {
        $io->can_write;
        while ( my $frame = $self->_client->next_frame ) {
            syswrite $self->_socket, $frame;
        }
        $io->can_read;
        while ( sysread $self->_socket, my $data, 4096 ) {
            $self->_client->feed($data);
        }
    }
    undef $self->{_client};
    $self->_socket->close(SSL_ctx_free => 1);
}

1;
__END__

=encoding utf-8

=head1 NAME

Net::APNS::Simple - APNS Perl implementation

=head1 SYNOPSIS

    use Net::APNS::Simple;
    my $apns = Net::APNS::Simple->new(
        # enable if development
        # development => 1,
        auth_key => '/path/to/auth_key.p8',
        key_id => 'AUTH_KEY_ID',
        team_id => 'APP_PREFIX',
        bundle_id => 'APP_ID',
        apns_expiration => 0,
        apns_priority => 10,
    );
    $apns->prepare('DEVICE_ID',{
            alert => 'APNS message: HELLO!',
            badge => 1,
            sound => "default",
            # SEE: https://developer.apple.com/jp/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/Chapters/TheNotificationPayload.html,
        }, sub {
            my ($header, $content) = @_;
            require Data::Dumper;
            print Dumper $header;

            # $VAR1 = [
            #           ':status',
            #           '200',
            #           'apns-id',
            #           '791DE8BA-7CAA-B820-BD2D-5B12653A8DF3'
            #         ];

            print Dumper $content;

            # $VAR1 = undef;
        }
    );

    # $apns->prepare(1st request)->prepare(2nd request)....

    $apns->notify();

=head1 DESCRIPTION

Net::APNS::Simple is APNS Perl implementation.

=head1 LICENSE

Copyright (C) Tooru Tsurukawa.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Tooru Tsurukawa E<lt>rockbone.g at gmail.comE<gt>

=cut

