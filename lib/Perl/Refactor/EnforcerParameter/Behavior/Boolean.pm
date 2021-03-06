package Perl::Refactor::EnforcerParameter::Behavior::Boolean;

use 5.006001;
use strict;
use warnings;
use Perl::Refactor::Utils;

use base qw{ Perl::Refactor::EnforcerParameter::Behavior };

our $VERSION = '1.121';

#-----------------------------------------------------------------------------

sub _parse {
    my ($enforcer, $parameter, $config_string) = @_;

    my $value;
    my $value_string = $parameter->get_default_string();

    if (defined $config_string) {
        $value_string = $config_string;
    }

    if ( $value_string ) {
        $value = $TRUE;
    } else {
        $value = $FALSE;
    }

    $enforcer->__set_parameter_value($parameter, $value);

    return;
}

#-----------------------------------------------------------------------------

sub initialize_parameter {
    my ($self, $parameter, $specification) = @_;

    $parameter->_set_parser(\&_parse);

    return;
}

#-----------------------------------------------------------------------------

1;

__END__

#-----------------------------------------------------------------------------

=pod

=for stopwords

=head1 NAME

Perl::Refactor::EnforcerParameter::Behavior::Boolean - Actions appropriate for a boolean parameter.


=head1 DESCRIPTION

Provides a standard set of functionality for a boolean
L<Perl::Refactor::EnforcerParameter|Perl::Refactor::EnforcerParameter> so that
the developer of a enforcer does not have to provide it her/himself.

NOTE: Do not instantiate this class.  Use the singleton instance held
onto by
L<Perl::Refactor::EnforcerParameter|Perl::Refactor::EnforcerParameter>.


=head1 INTERFACE SUPPORT

This is considered to be a non-public class.  Its interface is subject
to change without notice.


=head1 METHODS

=over

=item C<initialize_parameter( $parameter, $specification )>

Plug in the functionality this behavior provides into the parameter.
At present, this behavior isn't customizable by the specification.


=back


=head1 AUTHOR

Elliot Shank <perl@galumph.com>


=head1 COPYRIGHT

Copyright (c) 2006-2011 Elliot Shank.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.  The full text of this license
can be found in the LICENSE file included with this module.

=cut

# Local Variables:
#   mode: cperl
#   cperl-indent-level: 4
#   fill-column: 78
#   indent-tabs-mode: nil
#   c-indentation-style: bsd
# End:
# ex: set ts=8 sts=4 sw=4 tw=78 ft=perl expandtab shiftround :
