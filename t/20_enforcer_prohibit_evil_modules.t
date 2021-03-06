#!perl

use 5.006001;
use strict;
use warnings;

use Perl::Refactor::TestUtils qw< prefactor >;
use Perl::Refactor::Utils     qw< $EMPTY >;

use Test::More tests => 1;

#-----------------------------------------------------------------------------

our $VERSION = '1.121';

#-----------------------------------------------------------------------------

Perl::Refactor::TestUtils::block_perlrefactorrc();

# This is in addition to the regular .run file.

my $enforcer = 'Modules::ProhibitEvilModules';

my $code = <<'END_PERL';

use Evil::Module qw(bad stuff);
use Super::Evil::Module;

END_PERL

my $result = eval { prefactor( $enforcer, \$code, {modules => $EMPTY} ); 1; };
ok(
    ! $result,
    "$enforcer does not run if there are no evil modules configured.",
);


#-----------------------------------------------------------------------------

# Local Variables:
#   mode: cperl
#   cperl-indent-level: 4
#   fill-column: 78
#   indent-tabs-mode: nil
#   c-indentation-style: bsd
# End:
# ex: set ts=8 sts=4 sw=4 tw=78 ft=perl expandtab shiftround :
