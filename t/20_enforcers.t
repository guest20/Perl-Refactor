#!perl

use 5.006001;
use strict;
use warnings;

use Test::Perl::Refactor::Enforcer qw< all_enforcers_ok >;

#-----------------------------------------------------------------------------

our $VERSION = '1.121';

#-----------------------------------------------------------------------------
# Notice that you can pass arguments to this test, which limit the testing to
# specific enforcers.  The arguments must be shortened enforcer names. When using
# prove(1), any arguments that follow '::' will be passed to the test script.

my %args = @ARGV ? ( -enforcers => [ @ARGV ] ) : ();
all_enforcers_ok(%args);

#-----------------------------------------------------------------------------
# ensure we return true if this test is loaded by
# 20_enforcers.t_without_optional_dependencies.t

1;

#-----------------------------------------------------------------------------
# Local Variables:
#   mode: cperl
#   cperl-indent-level: 4
#   fill-column: 78
#   indent-tabs-mode: nil
#   c-indentation-style: bsd
# End:
# ex: set ts=8 sts=4 sw=4 tw=78 ft=perl expandtab shiftround :
