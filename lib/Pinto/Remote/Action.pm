# ABSTRACT: Base class for remote Actions

package Pinto::Remote::Action;

use Moose;
use MooseX::StrictConstructor;
use MooseX::MarkAsMethods (autoclean => 1);
use MooseX::Types::Moose qw(Str Maybe);

use URI;
use JSON;
use HTTP::Request::Common;

use Pinto::Result;
use Pinto::Constants qw(:server);
use Pinto::Types qw(Uri);

#------------------------------------------------------------------------------

# VERSION

#------------------------------------------------------------------------------

with qw(Pinto::Role::Plated);

#------------------------------------------------------------------------------

has name      => (
    is        => 'ro',
    isa       => Str,
    required  => 1,
);


has root => (
    is       => 'ro',
    isa      => Uri,
    required => 1,
);


has args     => (
    is       => 'ro',
    isa      => 'HashRef',
    default  => sub { {} },
);


has username => (
    is       => 'ro',
    isa      => Str,
    required => 1
);


has password => (
    is       => 'ro',
    isa      => Maybe[ Str ],
    required => 1,
);


has ua        => (
    is        => 'ro',
    isa       => 'LWP::UserAgent',
    required  => 1,
);

#------------------------------------------------------------------------------

=method execute

Runs this Action on the remote server by serializing itself and
sending a POST request to the server.  Returns a L<Pinto::Result>.

=cut

sub execute {
    my ($self) = @_;

    my $request = $self->_make_request;
    my $result  = $self->_send_request(req => $request);

    return $result;
}

#------------------------------------------------------------------------------

sub _make_request {
    my ($self, %args) = @_;

    my $action_name  = $args{name} || $self->name;
    my $request_body = $args{body} || $self->_make_request_body;

    my $url = URI->new( $self->root );
    $url->path_segments('', 'action', lc $action_name);

    my $request = POST( $url, Content_Type => 'form-data',
                              Content      => $request_body );

    if ( defined $self->password ) {
        $request->authorization_basic( $self->username, $self->password );
    }

    return $request;
}


#------------------------------------------------------------------------------

sub _make_request_body {
    my ($self) = @_;

    return [ $self->_chrome_args, $self->_pinto_args, $self->_action_args ];
}


#------------------------------------------------------------------------------

sub _chrome_args {
    my ($self) = @_;

    my $chrome_args = { verbose  => $self->chrome->verbose,
                        no_color => $self->chrome->no_color,
                        quiet    => $self->chrome->quiet };

    return ( chrome => encode_json($chrome_args) );

}

#------------------------------------------------------------------------------

sub _pinto_args {
    my ($self) = @_;

    my $pinto_args = { username  => $self->username };

    return ( pinto => encode_json($pinto_args) );
}

#------------------------------------------------------------------------------

sub _action_args {
    my ($self) = @_;

    my $action_args = $self->args;

    return ( action => encode_json($action_args) );
}

#------------------------------------------------------------------------------

sub _send_request {
    my ($self, %args) = @_;

    my $request = $args{req} || $self->_make_request;
    my $status  = 0;

    # Currying in some extra args to the callback...
    my $callback = sub { $self->_response_callback(\$status, @_) };
    my $response = $self->ua->request($request, $callback);

    if (not $response->is_success) {
        $self->error($response->content);
        return Pinto::Result->new(was_successful => 0);
    }

    return Pinto::Result->new(was_successful => $status);
}

#------------------------------------------------------------------------------

sub _response_callback { 
    my ($self, $status, $data) = @_;

    # Each data chunk will be one line of text ending with \n
    chomp $data;

    if ($data eq $PINTO_SERVER_STATUS_OK) {
        ${ $status } = 1;
    }
    elsif($data eq $PINTO_SERVER_PROGRESS_MESSAGE) {
        $self->chrome->show_progress;
    }
    elsif ($data eq $PINTO_SERVER_NULL_MESSAGE) {
         # Do nothing, discard message
    }
    elsif ($data =~ m{^ \Q$PINTO_SERVER_DIAG_PREFIX\E (.*)}x) {
        $self->chrome->diag($1);
    }
    else {
        $self->chrome->show($data);
    }

    return 1;
}

#-----------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;

#------------------------------------------------------------------------------
1;

__END__
