#!perl

package Test::Perl::Refactor::Enforcer;

use 5.006001;
use strict;
use warnings;

use Carp qw< croak confess >;
use English qw< -no_match_vars >;
use List::MoreUtils qw< all none >;
use Readonly;

use Test::Builder qw<>;
use Test::More;

use Perl::Refactor::Violation;
use Perl::Refactor::TestUtils qw<
    prefactor_with_violations frefactor_with_violations subtests_in_tree
>;

#-----------------------------------------------------------------------------

our $VERSION = '1.121';

#-----------------------------------------------------------------------------

use Exporter 'import';

Readonly::Array our @EXPORT_OK      => qw< all_enforcers_ok >;
Readonly::Hash  our %EXPORT_TAGS    => (all => \@EXPORT_OK);

#-----------------------------------------------------------------------------

Perl::Refactor::Violation::set_format( "%m at line %l, column %c.  (%r)\n" );
Perl::Refactor::TestUtils::block_perlrefactorrc();

#-----------------------------------------------------------------------------

my $TEST = Test::Builder->new();

#-----------------------------------------------------------------------------

sub all_enforcers_ok {
    my (%args) = @_;
    my $wanted_enforcers = $args{-enforcers};
    my $test_dir        = $args{'-test-directory'} || 't';

    my $subtests_with_extras =  subtests_in_tree( $test_dir, 'include extras' );

    if ($wanted_enforcers) {
        _validate_wanted_enforcer_names($wanted_enforcers, $subtests_with_extras);
        _filter_unwanted_subtests($wanted_enforcers, $subtests_with_extras);
    }

    $TEST->plan( tests => _compute_test_count($subtests_with_extras) );
    my $enforcers_to_test = join q{, }, keys %{$subtests_with_extras};
    $TEST->note("Running tests for enforcers: $enforcers_to_test");

    for my $enforcer ( sort keys %{$subtests_with_extras} ) {

        my ($full_enforcer_name, $method) = ("Perl::Refactor::Enforcer::$enforcer", 'violates');
        my $can_ok_label = qq{Class '$full_enforcer_name' has method '$method'};
        $TEST->ok( $full_enforcer_name->can($method), $can_ok_label );

        for my $subtest ( @{ $subtests_with_extras->{$enforcer}{subtests} } ) {
            my $todo = $subtest->{TODO};
            if ($todo) { $TEST->todo_start( $todo ); }

            my ($error, @violations) = _run_subtest($enforcer, $subtest);
            my ($ok, @diag)= _evaluate_test_results($subtest, $error, \@violations);
            $TEST->ok( $ok, _create_test_name($enforcer, $subtest) );

            if (@diag) { $TEST->diag(@diag); }
            if ($todo) { $TEST->todo_end(); }
        }
    }

    return;
}

#-----------------------------------------------------------------------------

sub _validate_wanted_enforcer_names {
    my ($wanted_enforcers, $subtests_with_extras) = @_;
    return 1 if not $wanted_enforcers;
    my @all_testable_enforcers = keys %{ $subtests_with_extras };
    my @wanted_enforcers = @{ $wanted_enforcers };


    my @invalid = grep {my $p = $_; none {$_ =~ $p} @all_testable_enforcers}  @wanted_enforcers;
    croak( q{No tests found for enforcers matching: } . join q{, }, @invalid ) if @invalid;
    return 1;
}

#-----------------------------------------------------------------------------

sub _filter_unwanted_subtests {
    my ($wanted_enforcers, $subtests_with_extras) = @_;
    return 1 if not $wanted_enforcers;
    my @all_testable_enforcers = keys %{ $subtests_with_extras };
    my @wanted_enforcers = @{ $wanted_enforcers };

    for my $p (@all_testable_enforcers) {
        if (none {$p =~ m/$_/xism} @wanted_enforcers) {
            delete $subtests_with_extras->{$p}; # side-effects!
        }
    }
    return 1;
}

#-----------------------------------------------------------------------------

sub _run_subtest {
    my ($enforcer, $subtest) = @_;

    my @violations;
    my $error;
    if ( $subtest->{filename} ) {
        eval {
            @violations =
                frefactor_with_violations(
                    $enforcer,
                    \$subtest->{code},
                    $subtest->{filename},
                    $subtest->{parms},
                );
            1;
        } or do {
            $error = $EVAL_ERROR || 'An unknown problem occurred.';
        };
    }
    else {
        eval {
            @violations =
                prefactor_with_violations(
                    $enforcer,
                    \$subtest->{code},
                    $subtest->{parms},
                );
            1;
        } or do {
            $error = $EVAL_ERROR || 'An unknown problem occurred.';
        };
    }

    return ($error, @violations);
}

#-----------------------------------------------------------------------------

sub _evaluate_test_results {
    my ($subtest, $error, $violations) = @_;

    if ($subtest->{error}) {
        return _evaluate_error_case($subtest, $error);
    }
    elsif ($error) {
        confess $error;
    }
    else {
        return _evaluate_violation_case($subtest, $violations);
    }
}

#-----------------------------------------------------------------------------

sub _evaluate_violation_case {
    my ($subtest, $violations) = @_;
    my ($ok, @diagnostics);

    my @violations = @{$violations};
    my $have = scalar @violations;
    my $want = _compute_wanted_violation_count($subtest);
    if ( not $ok = $have == $want ) {
        my $msg = qq(Expected $want violations, got $have. );
        if (@violations) { $msg .= q(Found violations follow...); }
        push @diagnostics, $msg . "\n";
        push @diagnostics, map { qq(Found violation: $_) } @violations;
    }

    return ($ok, @diagnostics)
}

#-----------------------------------------------------------------------------

sub _evaluate_error_case {
    my ($subtest, $error) = @_;
    my ($ok, @diagnostics);

    if ( 'Regexp' eq ref $subtest->{error} ) {
        $ok = $error =~ $subtest->{error}
          or push @diagnostics, qq(Error message '$error' doesn't match $subtest->{error}.);
    }
    else {
        $ok = $subtest->{error}
          or push @diagnostics, q(Didn't get an error message when we expected one.);
    }

    return ($ok, @diagnostics);
}

#-----------------------------------------------------------------------------

sub _compute_test_count {
    my ($subtests_with_extras) = @_;

    # one can_ok() for each enforcer
    my $nenforcers = scalar keys %{ $subtests_with_extras };

    my $nsubtests = 0;
    for my $subtest_with_extras ( values %{$subtests_with_extras} ) {
        # one [pf]refactor() test per subtest
        $nsubtests += @{ $subtest_with_extras->{subtests} };
    }

    return $nsubtests + $nenforcers;
}

#-----------------------------------------------------------------------------

sub _compute_wanted_violation_count {
    my ($subtest) = @_;

    # If any optional modules are NOT available, then there should be no violations.
    return 0 if not _all_optional_modules_are_available($subtest);
    return $subtest->{failures};
}

#-----------------------------------------------------------------------------

sub _all_optional_modules_are_available {
    my ($subtest) = @_;
    my $optional_modules = $subtest->{optional_modules} or return 1;
    return all {eval "require $_;" or 0;} split m/,\s*/xms, $optional_modules;
}

#-----------------------------------------------------------------------------

sub _create_test_name {
    my ($enforcer, $subtest) = @_;
    return join ' - ', $enforcer, "line $subtest->{lineno}", $subtest->{name};
}

#-----------------------------------------------------------------------------
1;

__END__

#-----------------------------------------------------------------------------

=pod

=for stopwords subtest subtests RCS

=head1 NAME

Test::Perl::Refactor::Enforcer - A framework for testing your custom Enforcers

=head1 SYNOPSIS

    use Test::Perl::Refactor::Enforcer qw< all_enforcers_ok >;

    # Assuming .run files are inside 't' directory...
    all_enforcers_ok()

    # Or if your .run files are in a different directory...
    all_enforcers_ok( '-test-directory' => 'run' );

    # And if you just want to run tests for some polices...
    all_enforcers_ok( -enforcers => ['Some::Enforcer', 'Another::Enforcer'] );

    # If you want your test program to accept short Enforcer names as
    # command-line parameters...
    #
    # You can then test a single enforcer by running
    # "perl -Ilib t/enforcer-test.t My::Enforcer".
    my %args = @ARGV ? ( -enforcers => [ @ARGV ] ) : ();
    all_enforcers_ok(%args);


=head1 DESCRIPTION

This module provides a framework for function-testing your custom
L<Perl::Refactor::Enforcer|Perl::Refactor::Enforcer> modules.  Enforcer testing usually
involves feeding it a string of Perl code and checking its behavior.  In the
old days, those strings of Perl code were mixed directly in the test script.
That sucked.

B<NOTE:> This module is alpha code -- interfaces and implementation are
subject to major changes.  This module is an integral part of building and
testing L<Perl::Refactor|Perl::Refactor> itself, but you should not write any code
against this module until it has stabilized.


=head1 IMPORTABLE SUBROUTINES

=over

=item all_enforcers_ok('-test-directory' => $path, -enforcers => \@enforcer_names)

Loads all the F<*.run> files beneath the C<-test-directory> and runs the
tests.  If C<-test-directory> is not specified, it defaults to F<t/>.
C<-enforcers> is an optional reference to an array of shortened Enforcer names.
If C<-enforcers> specified, only the tests for Enforcers that match one of the
C<m/$POLICY_NAME/imx> will be run.


=back


=head1 CREATING THE *.run FILES

Testing a enforcer follows a very simple pattern:

    * Enforcer name
        * Subtest name
        * Optional parameters
        * Number of failures expected
        * Optional exception expected
        * Optional filename for code

Each of the subtests for a enforcer is collected in a single F<.run>
file, with test properties as comments in front of each code block
that describes how we expect Perl::Refactor to react to the code.  For
example, say you have a enforcer called Variables::ProhibitVowels:

    (In file t/Variables/ProhibitVowels.run)

    ## name Basics
    ## failures 1
    ## cut

    my $vrbl_nm = 'foo';    # Good, vowel-free name
    my $wango = 12;         # Bad, pronouncable name


    ## name Sometimes Y
    ## failures 1
    ## cut

    my $yllw = 0;       # "y" not a vowel here
    my $rhythm = 12;    # But here it is

These are called "subtests", and two are shown above.  The beauty of
incorporating multiple subtests in a file is that the F<.run> is
itself a (mostly) valid Perl file, and not hidden in a HEREDOC, so
your editor's color-coding still works, and it is much easier to work
with the code and the POD.

If you need to pass any configuration parameters for your subtest, do
so like this:

    ## parms { allow_y => '0' }

Note that all the values in this hash must be strings because that's
what Perl::Refactor will hand you from a F<.perlrefactorrc>.

If it's a TODO subtest (probably because of some weird corner of PPI
that we exercised that Adam is getting around to fixing, right?), then
make a C<##TODO> entry.

    ## TODO Should pass when PPI 1.xxx comes out

If the code is expected to trigger an exception in the enforcer,
indicate that like so:

    ## error 1

If you want to test the error message, mark it with C</.../> to
indicate a C<like()> test:

    ## error /Can't load Foo::Bar/

If the enforcer you are testing cares about the filename of the code,
you can indicate that C<frefactor> should be used like so (see
C<frefactor> for more details):

    ## filename lib/Foo/Bar.pm

The value of C<parms> will get C<eval>ed and passed to C<prefactor()>,
so be careful.

In general, a subtest document runs from the C<## cut> that starts it to
either the next C<## name> or the end of the file. In very rare circumstances
you may need to end the test document earlier. A second C<## cut> will do
this. The only known need for this is in
F<t/Miscellanea/RequireRcsKeywords.run>, where it is used to prevent the RCS
keywords in the file footer from producing false positives or negatives in the
last test.

Note that nowhere within the F<.run> file itself do you specify the
enforcer that you're testing.  That's implicit within the filename.


=head1 BUGS AND CAVEATS AND TODO ITEMS

Add enforcer_ok() method for running subtests in just a single TODO file.

Can users mark this entire test as TODO or SKIP, using the normal mechanisms?

Allow us to specify the nature of the failures, and which one.  If there are
15 lines of code, and six of them fail, how do we know they're the right six?

Consolidate code from L<Perl::Refactor::TestUtils|Perl::Refactor::TestUtils> and possibly deprecate some
functions there.

Write unit tests for this module.

Test that we have a t/*/*.run for each lib/*/*.pm

=head1 AUTHOR

Andy Lester, Jeffrey Ryan Thalhammer <thaljef@cpan.org>

=head1 COPYRIGHT

Copyright (c) 2009-2011 Andy Lester.  All rights reserved.

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
