package Perl::Refactor::Annotation;

use 5.006001;
use strict;
use warnings;

use Carp qw(confess);
use English qw(-no_match_vars);

use Perl::Refactor::EnforcerFactory;
use Perl::Refactor::Utils qw(:characters hashify);
use Readonly;

#-----------------------------------------------------------------------------

our $VERSION = '1.121';

Readonly::Scalar my $LAST_ELEMENT => -1;

#=============================================================================
# CLASS methods

sub create_annotations {
    my ($class, $doc) = @_;

    my @annotations = ();
    my $comment_elements_ref  = $doc->find('PPI::Token::Comment') || return;
    my $annotation_rx  = qr{\A (?: [#]! .*? )? \s* [#][#] \s* no  \s+ refactor}xms;
    for my $annotation_element ( grep { $_ =~ $annotation_rx } @{$comment_elements_ref} ) {
        push @annotations, Perl::Refactor::Annotation->new( -element => $annotation_element);
    }

    return @annotations;
}

#-----------------------------------------------------------------------------

sub new {
    my ($class, @args) = @_;
    my $self = bless {}, $class;
    $self->_init(@args);
    return $self;
}

#=============================================================================
# OBJECT methods

sub _init {
    my ($self, %args) = @_;
    my $annotation_element = $args{-element} || confess '-element argument is required';
    $self->{_element} = $annotation_element;

    my %disabled_enforcers = _parse_annotation( $annotation_element );
    $self->{_disables_all_enforcers} = %disabled_enforcers ? 0 : 1;
    $self->{_disabled_enforcers} = \%disabled_enforcers;

    # Grab surrounding nodes to determine the context.
    # This determines whether the annotation applies to
    # the current line or the block that follows.
    my $annotation_line = $annotation_element->logical_line_number();
    my $parent = $annotation_element->parent();
    my $grandparent = $parent ? $parent->parent() : undef;

    # Handle case when it appears on the shebang line.  In this
    # situation, it only affects the first line, not the whole doc
    if ( $annotation_element =~ m{\A [#]!}xms) {
        $self->{_effective_range} = [$annotation_line, $annotation_line];
        return $self;
    }

    # Handle single-line usage on simple statements.  In this
    # situation, it only affects the line that it appears on.
    if ( _is_single_line_annotation_on_simple_statement( $annotation_element )
    ) {
        $self->{_effective_range} = [$annotation_line, $annotation_line];
        return $self;
    }

    # Handle single-line usage on compound statements.  In this
    # situation -- um -- I'm not sure how this works, but it does.
    if ( ref $parent eq 'PPI::Structure::Block' ) {
        if ( ref $grandparent eq 'PPI::Statement::Compound'
            || ref $grandparent eq 'PPI::Statement::Sub' ) {
            if ( $parent->logical_line_number() == $annotation_line ) {
                my $grandparent_line = $grandparent->logical_line_number();
                $self->{_effective_range} = [$grandparent_line, $grandparent_line];
                return $self;
            }
        }
    }


    # Handle multi-line usage.  This is either a "no refactor" ..
    # "use refactor" region or a block where "no refactor" is in effect
    # until the end of the scope.  The start is the always the "no
    # refactor" which we already found.  So now we have to search for the end.
    my $end = $annotation_element;
    my $use_refactor = qr{\A \s* [#][#] \s* use \s+ refactor}xms;

  SIB:
    while ( my $esib = $end->next_sibling() ) {
        $end = $esib; # keep track of last sibling encountered in this scope
        last SIB if $esib->isa('PPI::Token::Comment') && $esib =~ $use_refactor;
    }

    # PPI parses __END__ as a PPI::Statement::End, and everything following is
    # a child of that statement. That means if we encounter an __END__, we
    # need to descend into it and continue the analysis.
    if ( $end->isa( 'PPI::Statement::End' ) and my $kid = $end->child( 0 ) ) {
        $end = $kid;
      SIB:
        while ( my $esib = $end->next_sibling() ) {
            $end = $esib;
            last SIB if $esib->isa( 'PPI::Token::Comment' ) &&
                $esib->content() =~ $use_refactor;
        }
    }

    # We either found an end or hit the end of the scope.
    my $ending_line = $end->logical_line_number();
    $self->{_effective_range} = [$annotation_line, $ending_line];
    return $self;
}

#-----------------------------------------------------------------------------

sub element {
    my ($self) = @_;
    return $self->{_element};
}

#-----------------------------------------------------------------------------

sub effective_range {
    my $self = shift;
    return @{ $self->{_effective_range} };
}

#-----------------------------------------------------------------------------

sub disabled_enforcers {
    my $self = shift;
    return keys %{ $self->{_disabled_enforcers} };
}

#-----------------------------------------------------------------------------

sub disables_enforcer {
    my ($self, $enforcer_name) = @_;
    return 1 if $self->{_disabled_enforcers}->{$enforcer_name};
    return 1 if $self->disables_all_enforcers();
    return 0;
}

#-----------------------------------------------------------------------------

sub disables_all_enforcers {
    my ($self) = @_;
    return $self->{_disables_all_enforcers};
}

#-----------------------------------------------------------------------------

sub disables_line {
    my ($self, $line_number) = @_;
    my $effective_range = $self->{_effective_range};
    return 1 if $line_number >= $effective_range->[0]
        and $line_number <= $effective_range->[$LAST_ELEMENT];
    return 0;
}

#-----------------------------------------------------------------------------

# Recognize a single-line annotation on a simple statement.
sub _is_single_line_annotation_on_simple_statement {
    my ( $annotation_element ) = @_;
    my $annotation_line = $annotation_element->logical_line_number();

    # If there is no sibling, we are clearly not a single-line annotation of
    # any sort.
    my $sib = $annotation_element->sprevious_sibling()
        or return 0;

    # The easy case: the sibling (whatever it is) is on the same line as the
    # annotation.
    $sib->logical_line_number() == $annotation_line
        and return 1;

    # If the sibling is a node, we may have an annotation on one line of a
    # statement that was split over multiple lines. So we descend through the
    # children, keeping the last significant child of each, until we bottom
    # out. If the ultimate significant descendant is on the same line as the
    # annotation, we accept the annotation as a single-line annotation.
    if ( $sib->isa( 'PPI::Node' ) &&
        $sib->logical_line_number() < $annotation_line
    ) {
        my $neighbor = $sib;
        while ( $neighbor->isa( 'PPI::Node' )
                and my $kid = $neighbor->schild( $LAST_ELEMENT ) ) {
            $neighbor = $kid;
        }
        if ( $neighbor &&
            $neighbor->logical_line_number() == $annotation_line
        ) {
            return 1;
        }
    }

    # We do not understand any other sort of single-line annotation. Accepting
    # the annotation as such (if it is) is Someone Else's Problem.
    return 0;
}

#-----------------------------------------------------------------------------

sub _parse_annotation {

    my ($annotation_element) = @_;

    ############################################################################
    # This regex captures the list of Enforcer name patterns that are to be
    # disabled.  It is generally assumed that the element has already been
    # verified as a no-refactor annotation.  So if this regex does not match,
    # then it implies that all Enforcers are to be disabled.
    #
    my $no_refactor = qr{\#\# \s* no \s+ refactor \s* (?:qw)? [("'] ([\s\w:,]+) }xms;
    #                  -------------------------- ------- ----- -----------
    #                                 |              |      |        |
    #   "## no refactor" with optional spaces          |      |        |
    #                                                |      |        |
    #             Enforcer list may be prefixed with "qw"     |        |
    #                                                       |        |
    #         Optional Enforcer list must begin with one of these      |
    #                                                                |
    #                 Capture entire Enforcer list (with delimiters) here
    #
    ############################################################################

    my @disabled_enforcer_names = ();
    if ( my ($patterns_string) = $annotation_element =~ $no_refactor ) {

        # Compose the specified modules into a regex alternation.  Wrap each
        # in a no-capturing group to permit "|" in the modules specification.

        my @enforcer_name_patterns = grep { $_ ne $EMPTY }
            split m{\s *[,\s] \s*}xms, $patterns_string;
        my $re = join $PIPE, map {"(?:$_)"} @enforcer_name_patterns;
        my @site_enforcer_names = Perl::Refactor::EnforcerFactory::site_enforcer_names();
        @disabled_enforcer_names = grep {m/$re/ixms} @site_enforcer_names;

        # It is possible that the Enforcer patterns listed in the annotation do not
        # match any of the site enforcer names.  This could happen when running
        # on a machine that does not have the same set of Enforcers as the author.
        # So we must return something here, otherwise all Enforcers will be
        # disabled.  We probably need to add a mechanism to (optionally) warn
        # about this, just to help the author avoid writing invalid Enforcer names.

        if (not @disabled_enforcer_names) {
            @disabled_enforcer_names = @enforcer_name_patterns;
        }
    }

    return hashify(@disabled_enforcer_names);
}

#-----------------------------------------------------------------------------

1;

__END__

=pod

=head1 NAME

Perl::Refactor::Annotation - A "## no refactor" annotation in a document.


=head1 SYNOPSIS

  use Perl::Refactor::Annotation;
  $annotation = Perl::Refactor::Annotation->new( -element => $no_refactor_ppi_element );

  $bool = $annotation->disables_line( $number );
  $bool = $annotation->disables_enforcer( $enforcer_object );
  $bool = $annotation->disables_all_enforcers();

  ($start, $end) = $annotation->effective_range();
  @disabled_enforcer_names = $annotation->disabled_enforcers();


=head1 DESCRIPTION

C<Perl::Refactor::Annotation> represents a single C<"## no refactor">
annotation in a L<PPI:Document>.  The Annotation takes care of parsing
the annotation and keeps track of which lines and Enforcers it affects.
It is intended to encapsulate the details of the no-refactor
annotations, and to provide a way for Enforcer objects to interact with
the annotations (via a L<Perl::Refactor::Document|Perl::Refactor::Document>).


=head1 INTERFACE SUPPORT

This is considered to be a non-public class.  Its interface is subject
to change without notice.


=head1 CLASS METHODS

=over

=item create_annotations( -doc => $doc )

Given a L<Perl::Refactor::Document|Perl::Refactor::Document>, finds all the C<"## no refactor">
annotations and constructs a new C<Perl::Refactor::Annotation> for each
one and returns them.  The order of the returned objects is not
defined.  It is generally expected that clients will use this
interface rather than calling the C<Perl::Refactor::Annotation>
constructor directly.


=back


=head1 CONSTRUCTOR

=over

=item C<< new( -element => $ppi_annotation_element ) >>

Returns a reference to a new Annotation object.  The B<-element>
argument is required and should be a C<PPI::Token::Comment> that
conforms to the C<"## no refactor"> syntax.


=back


=head1 METHODS

=over

=item C<< disables_line( $line ) >>

Returns true if this Annotation disables C<$line> for any (or all)
Enforcers.


=item C<< disables_enforcer( $enforcer_object ) >>

=item C<< disables_enforcer( $enforcer_name ) >>

Returns true if this Annotation disables C<$enforcer_object> or
C<$enforcer_name> at any (or all) lines.


=item C<< disables_all_enforcers() >>

Returns true if this Annotation disables all Enforcers at any (or all)
lines.  If this method returns true, C<disabled_enforcers> will return
an empty list.


=item C<< effective_range() >>

Returns a two-element list, representing the first and last line
numbers where this Annotation has effect.


=item C<< disabled_enforcers() >>

Returns a list of the names of the Enforcers that are affected by this
Annotation.  If this list is empty, then it means that all Enforcers
are affected by this Annotation, and C<disables_all_enforcers()> should
return true.


=item C<< element() >>

Returns the L<PPI::Element|PPI::Element> where this annotation started.  This is
typically an instance of L<PPI::Token::Comment|PPI::Token::Comment>.


=back


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
