# ABSTRACT: Responder for action requests

package Pinto::Server::Responder::Action;

use Moose;

use Carp;
use JSON;
use IO::Pipe;
use IO::Select;
use Try::Tiny;
use File::Temp;
use File::Copy;
use Proc::Fork;
use Path::Class;
use Plack::Response;

use Pinto;
use Pinto::Result;
use Pinto::Chrome::Term;
use Pinto::Constants qw(:server);

#-------------------------------------------------------------------------------

# VERSION

#-------------------------------------------------------------------------------

extends qw(Pinto::Server::Responder);

#-------------------------------------------------------------------------------

sub respond {
    my ($self) = @_;

    # path_info always has a leading slash, e.g. /action/list
    my (undef, undef, $action_name) = split '/', $self->request->path_info;

    my %params      = %{ $self->request->parameters }; # Copying
    my $chrome_args = $params{chrome} ? decode_json( $params{chrome} ) : {};
    my $pinto_args  = $params{pinto}  ? decode_json( $params{pinto} )  : {};
    my $action_args = $params{action} ? decode_json( $params{action} ) : {};

    for my $upload_name ( $self->request->uploads->keys ) {
        my $upload    = $self->request->uploads->{$upload_name};
        my $basename  = $upload->filename;
        my $localfile = file($upload->path)->dir->file($basename);
        File::Copy::move($upload->path, $localfile); #TODO: autodie
        $action_args->{$upload_name} = $localfile;
    }

    my $response;
    my $pipe = IO::Pipe->new;

    run_fork {
        child  { $self->child_proc($pipe, $chrome_args, $pinto_args, $action_name, $action_args) }
        parent { $response = $self->parent_proc($pipe, shift) }
        error  { croak "Failed to fork: $!" }
    };

    return $response;
 }

#-------------------------------------------------------------------------------

sub child_proc {
    my ($self, $pipe, $chrome_args, $pinto_args, $action_name, $action_args) = @_;

    my $writer = $pipe->writer;
    $writer->autoflush;

    # I'm not sure why, but cleanup isn't happening when we get
    # a TERM signal from the parent process.  I suspect it
    # has something to do with File::NFSLock messing with %SIG
    local $SIG{TERM} = sub { File::Temp::cleanup; die 'Got sig TERM' };

    ## no critic qw(PackageVar)
    local $Pinto::Globals::is_interactive = 0;  
    local $Pinto::Globals::current_username    = delete $pinto_args->{username};
    local $Pinto::Globals::current_time_offset = delete $pinto_args->{time_offset};
    ## use critic;

    $chrome_args->{stdout} = $writer;
    $chrome_args->{stderr} = $writer;
    $chrome_args->{diag_prefix} = $PINTO_SERVER_DIAG_PREFIX;

    my $chrome = Pinto::Chrome::Term->new($chrome_args); 
    my $pinto  = Pinto->new(chrome => $chrome, root => $self->root);

    my $result =
        try   { $pinto->run(ucfirst $action_name => %{ $action_args }) }
        catch { print { $writer } $_; Pinto::Result->new->failed };

    print { $writer } $PINTO_SERVER_STATUS_OK . "\n" if $result->was_successful;
    
    exit $result->was_successful ? 0 : 1;
}

#-------------------------------------------------------------------------------

sub parent_proc {
    my ($self, $pipe, $child_pid) = @_;

    my $reader    = $pipe->reader;
    my $select    = IO::Select->new($reader);
    $reader->blocking(0);


    my $response  = sub {
        my $responder = shift;
        my $headers = ['Content-Type' => 'text/plain'];
        my $writer  = $responder->( [200, $headers] );
        my $socket  = $self->request->env->{'psgix.io'};
        my $nullmsg = $PINTO_SERVER_NULL_MESSAGE . "\n";

        while (1) {

            my $input;
            if ( $select->can_read(0.5) ) {
                $input = <$reader>;  # Will block until \n
                last if not defined $input; # We reached eof
            }

            $writer->write( $input || $nullmsg );

            if ($socket && not getpeername($socket)) {
                kill 'TERM', $child_pid and wait; 
                last;
            }
        }

        $writer->close;
    };

    return $response;
}

#-------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;

#-------------------------------------------------------------------------------

1;
