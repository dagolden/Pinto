package Pinto::Action::Remove;

# ABSTRACT: An action to remove one local distribution from the repository

use Moose;
use MooseX::Types::Moose qw( Str );

use Pinto::Util;
use Pinto::Exception;

extends 'Pinto::Action';

use namespace::autoclean;

#------------------------------------------------------------------------------

# VERSION

#------------------------------------------------------------------------------
# Attributes

has dist_name  => (
    is       => 'ro',
    isa      => Str,
    required => 1,
);

#------------------------------------------------------------------------------

with qw( Pinto::Role::Authored );

#------------------------------------------------------------------------------


override execute => sub {
    my ($self) = @_;

    my $dist_name  = $self->dist_name();
    my $author     = $self->author();
    my $cleanup    = !$self->config->nocleanup();

    my $path = $dist_name =~ m{/}mx ?
      $dist_name : Pinto::Util::author_dir($author)->file($dist_name)->as_foreign('Unix');

    my $dist = $self->db->get_distribution($path)
      or Pinto::Exception->throw("No such distribution: $path");

    my $file = $dist->physical_path( $self->config->repos() );

    $self->db->remove_distribution($dist);
    $self->store->remove( file => $file ) if $cleanup;
    $self->add_message( Pinto::Util::removed_dist_message( $dist ) );

    return 1;
};

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable();

#------------------------------------------------------------------------------

1;

__END__
