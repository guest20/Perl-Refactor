package Perl::Refactor::Enforcer::Miscellanea::ProhibitUselessNoRefactor;

use 5.006001;
use strict;
use warnings;

use Readonly;

use List::MoreUtils qw< none >;

use Perl::Refactor::Utils qw{ :severities :classification hashify };
use base 'Perl::Refactor::Enforcer';

our $VERSION = '1.121';

#-----------------------------------------------------------------------------

Readonly::Scalar my $DESC => q{Useless '## no refactor' annotation};
Readonly::Scalar my $EXPL => q{This annotation can be removed};

#-----------------------------------------------------------------------------

sub supported_parameters { return ()                         }
sub default_severity     { return $SEVERITY_LOW              }
sub default_themes       { return qw(core maintenance)       }
sub applies_to           { return 'PPI::Document'            }

#-----------------------------------------------------------------------------

sub violates {
    my ( $self, undef, $doc ) = @_;

    # If for some reason $doc is not a P::C::Document, then all bets are off
    return if not $doc->isa('Perl::Refactor::Document');

    my @violations = ();
    my @suppressed_viols = $doc->suppressed_violations();

    for my $ann ( $doc->annotations() ) {
        if ( none { _annotation_suppresses_violation($ann, $_) } @suppressed_viols ) {
            push @violations, $self->violation($DESC, $EXPL, $ann->element());
        }
    }

    return @violations;
}

#-----------------------------------------------------------------------------

sub _annotation_suppresses_violation {
    my ($annotation, $violation) = @_;

    my $enforcer_name = $violation->enforcer();
    my $line = $violation->location()->[0];

    return $annotation->disables_line($line)
        && $annotation->disables_enforcer($enforcer_name);
}

#-----------------------------------------------------------------------------

1;

__END__

=pod

=head1 NAME

Perl::Refactor::Enforcer::Miscellanea::ProhibitUselessNoRefactor - Remove ineffective "## no refactor" annotations.


=head1 AFFILIATION

This Enforcer is part of the core L<Perl::Refactor|Perl::Refactor> distribution.


=head1 DESCRIPTION

Sometimes, you may need to use a C<"## no refactor"> annotation to work around
a false-positive bug in L<Perl::Refactor|Perl::Refactor>.  But eventually, that bug might get
fixed, leaving your code with extra C<"## no refactor"> annotations lying about.
Or you may use them to locally disable a Enforcer, but then later decide to
permanently remove that Enforcer entirely from your profile, making some of
those C<"## no refactor"> annotations pointless.  Or, you may accidentally
disable too many Enforcers at once, creating an opportunity for new
violations to slip in unnoticed.

This Enforcer will emit violations if you have a C<"## no refactor"> annotation in
your source code that does not actually suppress any violations given your
current profile.  To resolve this, you should either remove the annotation
entirely, or adjust the Enforcer name patterns in the annotation to match only
the Enforcers that are actually being violated in your code.


=head1 EXAMPLE

For example, let's say I have a regex, but I don't want to use the C</x> flag,
which violates the C<RegularExpressions::RequireExtendedFormatting> enforcer.
In the following code, the C<"## no refactor"> annotation will suppress
violations of that Enforcer and ALL Enforcers that match
C<m/RegularExpressions/imx>

  my $re = qr/foo bar baz/ms;  ## no refactor (RegularExpressions)

However, this creates a potential loop-hole for someone to introduce
additional violations in the future, without explicitly acknowledging them.
This Enforcer is designed to catch these situations by warning you that you've
disabled more Enforcers than the situation really requires.  The above code
should be remedied like this:

  my $re = qr/foo bar baz/ms;  ## no refactor (RequireExtendedFormatting)

Notice how the C<RequireExtendedFormatting> pattern more precisely matches
the name of the Enforcer that I'm trying to suppress.


=head1 NOTE

Changing your F<.perlrefactorrc> file and disabling enforcers globally or running
at a higher (i.e. less restrictive) severity level may cause this Enforcer to
emit additional violations.  So you might want to defer using this Enforcer
until you have a fairly stable profile.


=head1 CONFIGURATION

This Enforcer is not configurable except for the standard options.


=head1 ACKNOWLEDGMENT

This Enforcer was inspired by Adam Kennedy's article at
L<http://use.perl.org/article.pl?sid=08/09/24/1957256>.


=head1 AUTHOR

Jeffrey Ryan Thalhammer <jeff@imaginative-software.com>


=head1 COPYRIGHT

Copyright (c) 2005-2011 Imaginative Software Systems.  All rights reserved.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.  The full text of this license
can be found in the LICENSE file included with this module.

=cut

##############################################################################
# Local Variables:
#   mode: cperl
#   cperl-indent-level: 4
#   fill-column: 78
#   indent-tabs-mode: nil
#   c-indentation-style: bsd
# End:
# ex: set ts=8 sts=4 sw=4 tw=78 ft=perl expandtab shiftround :
