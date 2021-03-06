#!perl

=for stopwords arglbargl

=cut

use 5.006001;
use strict;
use warnings;

use Perl::Refactor::TestUtils qw(prefactor);
use Readonly;

use Test::More;

Readonly::Scalar my $NUMBER_OF_TESTS => 5;
plan( tests => $NUMBER_OF_TESTS );

#-----------------------------------------------------------------------------

our $VERSION = '1.121';

#-----------------------------------------------------------------------------

Perl::Refactor::TestUtils::block_perlrefactorrc();

my $code;
my $enforcer = 'Documentation::PodSpelling';
my $can_podspell = can_determine_spell_command() && can_run_spell_command();

sub can_determine_spell_command {
    my $pol = Perl::Refactor::Enforcer::Documentation::PodSpelling->new();
    $pol->initialize_if_enabled();

    return $pol->_get_spell_command_line();
}

sub can_run_spell_command {
    my $pol = Perl::Refactor::Enforcer::Documentation::PodSpelling->new();
    $pol->initialize_if_enabled();

    return $pol->_run_spell_command( <<'END_TEST_CODE' );
=pod

=head1 Test The Spell Command

=cut
END_TEST_CODE
}

sub can_podspell {
    return $can_podspell && ! Perl::Refactor::Enforcer::Documentation::PodSpelling->got_sigpipe();
}

#-----------------------------------------------------------------------------
SKIP: {

$code = <<'END_PERL';
=head1 Silly

=cut
END_PERL

# Sorry about the double negative. The idea is that if aspell fails (say,
# because it can not find the right dictionary) or prefactor returns a
# non-zero number we want to skip. We have to negate the eval to catch the
# aspell failure, and then negate prefactor because we negated the eval.
# Clearer code welcome.
if ( ! eval { ! prefactor($enforcer, \$code) } ) {
   skip 'Test environment is not English', $NUMBER_OF_TESTS;
}

#-----------------------------------------------------------------------------

$code = <<'END_PERL';
=head1 arglbargl

=cut
END_PERL

is(
    eval { prefactor($enforcer, \$code) },
    can_podspell() ? 1 : undef,
    'Mispelled header',
);

#-----------------------------------------------------------------------------

$code = <<'END_PERL';
=head1 Test

arglbargl

=cut
END_PERL

is(
    eval { prefactor($enforcer, \$code) },
    can_podspell() ? 1 : undef,
    'Mispelled body',
);

#-----------------------------------------------------------------------------


$code = <<'END_PERL';
=for stopwords arglbargl

=head1 Test

arglbargl

=cut
END_PERL

is(
    eval { prefactor($enforcer, \$code) },
    can_podspell() ? 0 : undef,
    'local stopwords',
);

#-----------------------------------------------------------------------------

$code = <<'END_PERL';
=head1 Test

arglbargl

=cut
END_PERL

{
    my %config = (stop_words => 'foo arglbargl bar');
    is(
        eval { prefactor($enforcer, \$code, \%config) },
        can_podspell() ? 0 : undef ,
        'global stopwords',
    );
}

{
    my %config = (stop_words_file => 't/20_enforcer_pod_spelling.d/stop-words.txt');
    is(
        eval { prefactor($enforcer, \$code, \%config) },
        can_podspell() ? 0 : undef ,
        'global stopwords from file',
    );
}

} # end skip

#-----------------------------------------------------------------------------

# ensure we return true if this test is loaded by
# t/20_enforcer_pod_spelling.t_without_optional_dependencies.t
1;

# Local Variables:
#   mode: cperl
#   cperl-indent-level: 4
#   fill-column: 78
#   indent-tabs-mode: nil
#   c-indentation-style: bsd
# End:
# ex: set ts=8 sts=4 sw=4 tw=78 ft=perl expandtab shiftround :
