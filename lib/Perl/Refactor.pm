package Perl::Refactor;

use 5.006001;
use strict;
use warnings;

use English qw(-no_match_vars);
use Readonly;

use Exporter 'import';

use File::Spec;
use List::MoreUtils qw< firstidx >;
use Scalar::Util qw< blessed >;

use Perl::Refactor::Exception::Configuration::Generic;
use Perl::Refactor::Config;
use Perl::Refactor::Violation;
use Perl::Refactor::Document;
use Perl::Refactor::Statistics;
use Perl::Refactor::Utils qw< :characters hashify shebang_line >;

#-----------------------------------------------------------------------------

our $VERSION = '1.121';

Readonly::Array our @EXPORT_OK => qw(refactor);

#=============================================================================
# PUBLIC methods

sub new {
    my ( $class, %args ) = @_;
    my $self = bless {}, $class;
    $self->{_config} = $args{-config} || Perl::Refactor::Config->new( %args );
    $self->{_stats} = Perl::Refactor::Statistics->new();
    return $self;
}

#-----------------------------------------------------------------------------

sub config {
    my $self = shift;
    return $self->{_config};
}

#-----------------------------------------------------------------------------

sub add_enforcer {
    my ( $self, @args ) = @_;
    #Delegate to Perl::Refactor::Config
    return $self->config()->add_enforcer( @args );
}

#-----------------------------------------------------------------------------

sub enforcers {
    my $self = shift;

    #Delegate to Perl::Refactor::Config
    return $self->config()->enforcers();
}

#-----------------------------------------------------------------------------

sub statistics {
    my $self = shift;
    return $self->{_stats};
}

#-----------------------------------------------------------------------------

sub refactor {  ## no refactor (ArgUnpacking)

    #-------------------------------------------------------------------
    # This subroutine can be called as an object method or as a static
    # function.  In the latter case, the first argument can be a
    # hashref of configuration parameters that shall be used to create
    # an object behind the scenes.  Note that this object does not
    # persist.  In other words, it is not a singleton.  Here are some
    # of the ways this subroutine might get called:
    #
    # #Object style...
    # $refactor->refactor( $code );
    #
    # #Functional style...
    # refactor( $code );
    # refactor( {}, $code );
    # refactor( {-foo => bar}, $code );
    #------------------------------------------------------------------

    my ( $self, $source_code ) = @_ >= 2 ? @_ : ( {}, $_[0] );
    $self = ref $self eq 'HASH' ? __PACKAGE__->new(%{ $self }) : $self;
    return if not defined $source_code;  # If no code, then nothing to do.

    my $config = $self->config();
    my $doc =
        blessed($source_code) && $source_code->isa('Perl::Refactor::Document')
            ? $source_code
            : Perl::Refactor::Document->new(
                '-source' => $source_code,
                '-program-extensions' => [$config->program_extensions_as_regexes()],
            );

    if ( 0 == $self->enforcers() ) {
        Perl::Refactor::Exception::Configuration::Generic->throw(
            message => 'There are no enabled enforcers.',
        )
    }

    return $self->_gather_violations($doc);
}

#=============================================================================
# PRIVATE methods

sub _gather_violations {
    my ($self, $doc) = @_;

    # Disable exempt code lines, if desired
    if ( not $self->config->force() ) {
        $doc->process_annotations();
    }

    # Evaluate each enforcer
    my @enforcers = $self->config->enforcers();
    my @ordered_enforcers = _futz_with_enforcer_order(@enforcers);
    my @violations = map { _refactor($_, $doc) } @ordered_enforcers;

    # Accumulate statistics
    $self->statistics->accumulate( $doc, \@violations );

    # If requested, rank violations by their severity and return the top N.
    if ( @violations && (my $top = $self->config->top()) ) {
        my $limit = @violations < $top ? $#violations : $top-1;
        @violations = Perl::Refactor::Violation::sort_by_severity(@violations);
        @violations = ( reverse @violations )[ 0 .. $limit ];  #Slicing...
    }

    # Always return violations sorted by location
    return Perl::Refactor::Violation->sort_by_location(@violations);
}

#=============================================================================
# PRIVATE functions

sub _refactor {
    my ($enforcer, $doc) = @_;

    return if not $enforcer->prepare_to_scan_document($doc);

    my $maximum_violations = $enforcer->get_maximum_violations_per_document();
    return if defined $maximum_violations && $maximum_violations == 0;

    my @violations = ();

  TYPE:
    for my $type ( $enforcer->applies_to() ) {
        my @elements;
        if ($type eq 'PPI::Document') {
            @elements = ($doc);
        }
        else {
            @elements = @{ $doc->find($type) || [] };
        }

      ELEMENT:
        for my $element (@elements) {

            # Evaluate the enforcer on this $element.  A enforcer may
            # return zero or more violations.  We only want the
            # violations that occur on lines that have not been
            # disabled.

          VIOLATION:
            for my $violation ( $enforcer->violates( $element, $doc ) ) {

                my $line = $violation->location()->[0];
                if ( $doc->line_is_disabled_for_enforcer($line, $enforcer) ) {
                    $doc->add_suppressed_violation($violation);
                    next VIOLATION;
                }

                $enforcer->can('enforce') and
                    $enforcer->enforce( $element, $doc );

                push @violations, $violation;
                last TYPE if defined $maximum_violations and @violations >= $maximum_violations;
            }
        }
    }

    return @violations;
}

#-----------------------------------------------------------------------------

sub _futz_with_enforcer_order {
    # The ProhibitUselessNoRefactor enforcer is another special enforcer.  It
    # deals with the violations that *other* Enforcers produce.  Therefore
    # it needs to be run *after* all the other Enforcers.  TODO: find
    # a way for Enforcers to express an ordering preference somehow.

    my @enforcer_objects = @_;
    my $magical_enforcer_name = 'Perl::Refactor::Enforcer::Miscellanea::ProhibitUselessNoRefactor';
    my $idx = firstidx {ref $_ eq $magical_enforcer_name} @enforcer_objects;
    push @enforcer_objects, splice @enforcer_objects, $idx, 1;
    return @enforcer_objects;
}

#-----------------------------------------------------------------------------

1;



__END__

=pod

=for stopwords DGR INI-style API -params pbp refactored ActivePerl ben Jore
Dolan's Twitter Alexandr Ciornii Ciornii's downloadable

=head1 NAME

Perl::Refactor - Critique Perl source code for best-practices.


=head1 SYNOPSIS

    use Perl::Refactor;
    my $file = shift;
    my $refactor = Perl::Refactor->new();
    my @violations = $refactor->refactor($file);
    print @violations;


=head1 DESCRIPTION

Perl::Refactor is an extensible framework for creating and applying
coding standards to Perl source code.  Essentially, it is a static
source code analysis engine.  Perl::Refactor is distributed with a
number of L<Perl::Refactor::Enforcer|Perl::Refactor::Enforcer> modules that
attempt to enforce various coding guidelines.  Most Enforcer modules are
based on Damian Conway's book B<Perl Best Practices>.  However,
Perl::Refactor is B<not> limited to PBP and will even support Enforcers
that contradict Conway.  You can enable, disable, and customize those
Polices through the Perl::Refactor interface.  You can also create new
Enforcer modules that suit your own tastes.

For a command-line interface to Perl::Refactor, see the documentation
for L<perlrefactor|perlrefactor>.  If you want to integrate Perl::Refactor
with your build process, L<Test::Perl::Refactor|Test::Perl::Refactor>
provides an interface that is suitable for test programs.  Also,
L<Test::Perl::Refactor::Progressive|Test::Perl::Refactor::Progressive> is
useful for gradually applying coding standards to legacy code.  For
the ultimate convenience (at the expense of some flexibility) see the
L<criticism|criticism> pragma.

Win32 and ActivePerl users can find PPM distributions of Perl::Refactor at
L<http://theoryx5.uwinnipeg.ca/ppms/> and Alexandr Ciornii's downloadable
executable at L<http://chorny.net/perl/perlrefactor.html>.

If you'd like to try L<Perl::Refactor|Perl::Refactor> without installing anything,
there is a web-service available at L<http://perlrefactor.com>.  The web-service
does not yet support all the configuration features that are available in the
native Perl::Refactor API, but it should give you a good idea of what it does.
You can also invoke the perlrefactor web-service from the command-line by doing
an HTTP-post, such as one of these:

    $> lwp-request -m POST http://perlrefactor.com/perl/refactor.pl < MyModule.pm
    $> wget -q -O - --post-file=MyModule.pm http://perlrefactor.com/perl/refactor.pl
    $> curl --data @MyModule.pm http://perlrefactor.com/perl/refactor.pl

Please note that the perlrefactor web-service is still alpha code.  The
URL and interface to the service are subject to change.

Also, ActivePerl includes a very slick graphical interface to Perl-Refactor
called C<perlrefactor-gui>.  You can get a free community edition of ActivePerl
from L<http://www.activestate.com>.


=head1 INTERFACE SUPPORT

This is considered to be a public class.  Any changes to its interface
will go through a deprecation cycle.


=head1 CONSTRUCTOR

=over

=item C<< new( [ -profile => $FILE, -severity => $N, -theme => $string, -include => \@PATTERNS, -exclude => \@PATTERNS, -top => $N, -only => $B, -profile-strictness => $PROFILE_STRICTNESS_{WARN|FATAL|QUIET}, -force => $B, -verbose => $N ], -color => $B, -pager => $string, -allow-unsafe => $B, -criticism-fatal => $B) >>

=item C<< new() >>

Returns a reference to a new Perl::Refactor object.  Most arguments are
just passed directly into
L<Perl::Refactor::Config|Perl::Refactor::Config>, but I have described
them here as well.  The default value for all arguments can be defined
in your F<.perlrefactorrc> file.  See the L<"CONFIGURATION"> section for
more information about that.  All arguments are optional key-value
pairs as follows:

B<-profile> is a path to a configuration file. If C<$FILE> is not
defined, Perl::Refactor::Config attempts to find a F<.perlrefactorrc>
configuration file in the current directory, and then in your home
directory.  Alternatively, you can set the C<PERLCRITIC> environment
variable to point to a file in another location.  If a configuration
file can't be found, or if C<$FILE> is an empty string, then all
Enforcers will be loaded with their default configuration.  See
L<"CONFIGURATION"> for more information.

B<-severity> is the minimum severity level.  Only Enforcer modules that
have a severity greater than C<$N> will be applied.  Severity values
are integers ranging from 1 (least severe violations) to 5 (most
severe violations).  The default is 5.  For a given C<-profile>,
decreasing the C<-severity> will usually reveal more Enforcer violations.
You can set the default value for this option in your F<.perlrefactorrc>
file.  Users can redefine the severity level for any Enforcer in their
F<.perlrefactorrc> file.  See L<"CONFIGURATION"> for more information.

If it is difficult for you to remember whether severity "5" is the
most or least restrictive level, then you can use one of these named
values:

    SEVERITY NAME   ...is equivalent to...   SEVERITY NUMBER
    --------------------------------------------------------
    -severity => 'gentle'                     -severity => 5
    -severity => 'stern'                      -severity => 4
    -severity => 'harsh'                      -severity => 3
    -severity => 'cruel'                      -severity => 2
    -severity => 'brutal'                     -severity => 1

The names reflect how severely the code is criticized: a C<gentle>
criticism reports only the most severe violations, and so on down to a
C<brutal> criticism which reports even the most minor violations.

B<-theme> is special expression that determines which Enforcers to
apply based on their respective themes.  For example, the following
would load only Enforcers that have a 'bugs' AND 'pbp' theme:

  my $refactor = Perl::Refactor->new( -theme => 'bugs && pbp' );

Unless the C<-severity> option is explicitly given, setting C<-theme>
silently causes the C<-severity> to be set to 1.  You can set the
default value for this option in your F<.perlrefactorrc> file.  See the
L<"POLICY THEMES"> section for more information about themes.


B<-include> is a reference to a list of string C<@PATTERNS>.  Enforcer
modules that match at least one C<m/$PATTERN/ixms> will always be
loaded, irrespective of all other settings.  For example:

    my $refactor = Perl::Refactor->new(-include => ['layout'] -severity => 4);

This would cause Perl::Refactor to apply all the C<CodeLayout::*> Enforcer
modules even though they have a severity level that is less than 4.
You can set the default value for this option in your F<.perlrefactorrc>
file.  You can also use C<-include> in conjunction with the
C<-exclude> option.  Note that C<-exclude> takes precedence over
C<-include> when a Enforcer matches both patterns.

B<-exclude> is a reference to a list of string C<@PATTERNS>.  Enforcer
modules that match at least one C<m/$PATTERN/ixms> will not be loaded,
irrespective of all other settings.  For example:

    my $refactor = Perl::Refactor->new(-exclude => ['strict'] -severity => 1);

This would cause Perl::Refactor to not apply the C<RequireUseStrict> and
C<ProhibitNoStrict> Enforcer modules even though they have a severity
level that is greater than 1.  You can set the default value for this
option in your F<.perlrefactorrc> file.  You can also use C<-exclude> in
conjunction with the C<-include> option.  Note that C<-exclude> takes
precedence over C<-include> when a Enforcer matches both patterns.

B<-single-enforcer> is a string C<PATTERN>.  Only one enforcer that
matches C<m/$PATTERN/ixms> will be used.  Enforcers that do not match
will be excluded.  This option has precedence over the C<-severity>,
C<-theme>, C<-include>, C<-exclude>, and C<-only> options.  You can
set the default value for this option in your F<.perlrefactorrc> file.

B<-top> is the maximum number of Violations to return when ranked by
their severity levels.  This must be a positive integer.  Violations
are still returned in the order that they occur within the file.
Unless the C<-severity> option is explicitly given, setting C<-top>
silently causes the C<-severity> to be set to 1.  You can set the
default value for this option in your F<.perlrefactorrc> file.

B<-only> is a boolean value.  If set to a true value, Perl::Refactor
will only choose from Enforcers that are mentioned in the user's
profile.  If set to a false value (which is the default), then
Perl::Refactor chooses from all the Enforcers that it finds at your site.
You can set the default value for this option in your F<.perlrefactorrc>
file.

B<-profile-strictness> is an enumerated value, one of
L<Perl::Refactor::Utils::Constants/"$PROFILE_STRICTNESS_WARN"> (the
default),
L<Perl::Refactor::Utils::Constants/"$PROFILE_STRICTNESS_FATAL">, and
L<Perl::Refactor::Utils::Constants/"$PROFILE_STRICTNESS_QUIET">.  If set
to L<Perl::Refactor::Utils::Constants/"$PROFILE_STRICTNESS_FATAL">,
Perl::Refactor will make certain warnings about problems found in a
F<.perlrefactorrc> or file specified via the B<-profile> option fatal.
For example, Perl::Refactor normally only C<warn>s about profiles
referring to non-existent Enforcers, but this value makes this
situation fatal.  Correspondingly,
L<Perl::Refactor::Utils::Constants/"$PROFILE_STRICTNESS_QUIET"> makes
Perl::Refactor shut up about these things.

B<-force> is a boolean value that controls whether Perl::Refactor
observes the magical C<"## no refactor"> annotations in your code.
If set to a true value, Perl::Refactor will analyze all code.  If set to
a false value (which is the default) Perl::Refactor will ignore code
that is tagged with these annotations.  See L<"BENDING THE RULES"> for
more information.  You can set the default value for this option in
your F<.perlrefactorrc> file.

B<-verbose> can be a positive integer (from 1 to 11), or a literal
format specification.  See
L<Perl::Refactor::Violation|Perl::Refactor::Violation> for an explanation
of format specifications.  You can set the default value for this
option in your F<.perlrefactorrc> file.

B<-unsafe> directs Perl::Refactor to allow the use of Enforcers that are marked
as "unsafe" by the author.  Such enforcers may compile untrusted code or do
other nefarious things.

B<-color> and B<-pager> are not used by Perl::Refactor but is provided for the benefit
of L<perlrefactor|perlrefactor>.

B<-criticism-fatal> is not used by Perl::Refactor but is provided for
the benefit of L<criticism|criticism>.

B<-color-severity-highest>, B<-color-severity-high>,
B<-color-severity-medium>, B<-color-severity-low>, and
B<-color-severity-lowest> are not used by Perl::Refactor, but are provided for
the benefit of L<perlrefactor|perlrefactor>. Each is set to the Term::ANSIColor
color specification to be used to display violations of the corresponding
severity.

B<-files-with-violations> and B<-files-without-violations> are not used by
Perl::Refactor, but are provided for the benefit of L<perlrefactor|perlrefactor>, to
cause only the relevant filenames to be displayed.

=back


=head1 METHODS

=over

=item C<refactor( $source_code )>

Runs the C<$source_code> through the Perl::Refactor engine using all the
Enforcers that have been loaded into this engine.  If C<$source_code>
is a scalar reference, then it is treated as a string of actual Perl
code.  If C<$source_code> is a reference to an instance of
L<PPI::Document|PPI::Document>, then that instance is used directly.
Otherwise, it is treated as a path to a local file containing Perl
code.  This method returns a list of
L<Perl::Refactor::Violation|Perl::Refactor::Violation> objects for each
violation of the loaded Enforcers.  The list is sorted in the order
that the Violations appear in the code.  If there are no violations,
this method returns an empty list.

=item C<< add_enforcer( -enforcer => $enforcer_name, -params => \%param_hash ) >>

Creates a Enforcer object and loads it into this Refactor.  If the object
cannot be instantiated, it will throw a fatal exception.  Otherwise,
it returns a reference to this Refactor.

B<-enforcer> is the name of a
L<Perl::Refactor::Enforcer|Perl::Refactor::Enforcer> subclass module.  The
C<'Perl::Refactor::Enforcer'> portion of the name can be omitted for
brevity.  This argument is required.

B<-params> is an optional reference to a hash of Enforcer parameters.
The contents of this hash reference will be passed into to the
constructor of the Enforcer module.  See the documentation in the
relevant Enforcer module for a description of the arguments it supports.

=item C< enforcers() >

Returns a list containing references to all the Enforcer objects that
have been loaded into this engine.  Objects will be in the order that
they were loaded.

=item C< config() >

Returns the L<Perl::Refactor::Config|Perl::Refactor::Config> object that
was created for or given to this Refactor.

=item C< statistics() >

Returns the L<Perl::Refactor::Statistics|Perl::Refactor::Statistics>
object that was created for this Refactor.  The Statistics object
accumulates data for all files that are analyzed by this Refactor.

=back


=head1 FUNCTIONAL INTERFACE

For those folks who prefer to have a functional interface, The
C<refactor> method can be exported on request and called as a static
function.  If the first argument is a hashref, its contents are used
to construct a new Perl::Refactor object internally.  The keys of that
hash should be the same as those supported by the C<Perl::Refactor::new>
method.  Here are some examples:

    use Perl::Refactor qw(refactor);

    # Use default parameters...
    @violations = refactor( $some_file );

    # Use custom parameters...
    @violations = refactor( {-severity => 2}, $some_file );

    # As a one-liner
    %> perl -MPerl::Refactor=refactor -e 'print refactor(shift)' some_file.pm

None of the other object-methods are currently supported as static
functions.  Sorry.


=head1 CONFIGURATION

Most of the settings for Perl::Refactor and each of the Enforcer modules
can be controlled by a configuration file.  The default configuration
file is called F<.perlrefactorrc>.  Perl::Refactor will look for this file
in the current directory first, and then in your home directory.
Alternatively, you can set the C<PERLCRITIC> environment variable to
explicitly point to a different file in another location.  If none of
these files exist, and the C<-profile> option is not given to the
constructor, then all the modules that are found in the
Perl::Refactor::Enforcer namespace will be loaded with their default
configuration.

The format of the configuration file is a series of INI-style blocks
that contain key-value pairs separated by '='. Comments should start
with '#' and can be placed on a separate line or after the name-value
pairs if you desire.

Default settings for Perl::Refactor itself can be set B<before the first
named block.> For example, putting any or all of these at the top of
your configuration file will set the default value for the
corresponding constructor argument.

    severity  = 3                                     #Integer or named level
    only      = 1                                     #Zero or One
    force     = 0                                     #Zero or One
    verbose   = 4                                     #Integer or format spec
    top       = 50                                    #A positive integer
    theme     = (pbp || security) && bugs             #A theme expression
    include   = NamingConventions ClassHierarchies    #Space-delimited list
    exclude   = Variables  Modules::RequirePackage    #Space-delimited list
    criticism-fatal = 1                               #Zero or One
    color     = 1                                     #Zero or One
    allow-unsafe = 1                                  #Zero or One
    pager     = less                                  #pager to pipe output to

The remainder of the configuration file is a series of blocks like
this:

    [Perl::Refactor::Enforcer::Category::EnforcerName]
    severity = 1
    set_themes = foo bar
    add_themes = baz
    maximum_violations_per_document = 57
    arg1 = value1
    arg2 = value2

C<Perl::Refactor::Enforcer::Category::EnforcerName> is the full name of a
module that implements the enforcer.  The Enforcer modules distributed
with Perl::Refactor have been grouped into categories according to the
table of contents in Damian Conway's book B<Perl Best Practices>. For
brevity, you can omit the C<'Perl::Refactor::Enforcer'> part of the module
name.

C<severity> is the level of importance you wish to assign to the
Enforcer.  All Enforcer modules are defined with a default severity value
ranging from 1 (least severe) to 5 (most severe).  However, you may
disagree with the default severity and choose to give it a higher or
lower severity, based on your own coding philosophy.  You can set the
C<severity> to an integer from 1 to 5, or use one of the equivalent
names:

    SEVERITY NAME ...is equivalent to... SEVERITY NUMBER
    ----------------------------------------------------
    gentle                                             5
    stern                                              4
    harsh                                              3
    cruel                                              2
    brutal                                             1

The names reflect how severely the code is criticized: a C<gentle>
criticism reports only the most severe violations, and so on down to a
C<brutal> criticism which reports even the most minor violations.

C<set_themes> sets the theme for the Enforcer and overrides its default
theme.  The argument is a string of one or more whitespace-delimited
alphanumeric words.  Themes are case-insensitive.  See L<"POLICY
THEMES"> for more information.

C<add_themes> appends to the default themes for this Enforcer.  The
argument is a string of one or more whitespace-delimited words.
Themes are case-insensitive.  See L<"POLICY THEMES"> for more
information.

C<maximum_violations_per_document> limits the number of Violations the
Enforcer will return for a given document.  Some Enforcers have a default
limit; see the documentation for the individual Enforcers to see
whether there is one.  To force a Enforcer to not have a limit, specify
"no_limit" or the empty string for the value of this parameter.

The remaining key-value pairs are configuration parameters that will
be passed into the constructor for that Enforcer.  The constructors for
most Enforcer objects do not support arguments, and those that do should
have reasonable defaults.  See the documentation on the appropriate
Enforcer module for more details.

Instead of redefining the severity for a given Enforcer, you can
completely disable a Enforcer by prepending a '-' to the name of the
module in your configuration file.  In this manner, the Enforcer will
never be loaded, regardless of the C<-severity> given to the
Perl::Refactor constructor.

A simple configuration might look like this:

    #--------------------------------------------------------------
    # I think these are really important, so always load them

    [TestingAndDebugging::RequireUseStrict]
    severity = 5

    [TestingAndDebugging::RequireUseWarnings]
    severity = 5

    #--------------------------------------------------------------
    # I think these are less important, so only load when asked

    [Variables::ProhibitPackageVars]
    severity = 2

    [ControlStructures::ProhibitPostfixControls]
    allow = if unless  # My custom configuration
    severity = cruel   # Same as "severity = 2"

    #--------------------------------------------------------------
    # Give these enforcers a custom theme.  I can activate just
    # these enforcers by saying `perlrefactor -theme larry`

    [Modules::RequireFilenameMatchesPackage]
    add_themes = larry

    [TestingAndDebugging::RequireTestLables]
    add_themes = larry curly moe

    #--------------------------------------------------------------
    # I do not agree with these at all, so never load them

    [-NamingConventions::Capitalization]
    [-ValuesAndExpressions::ProhibitMagicNumbers]

    #--------------------------------------------------------------
    # For all other Enforcers, I accept the default severity,
    # so no additional configuration is required for them.

For additional configuration examples, see the F<perlrefactorrc> file
that is included in this F<examples> directory of this distribution.

Damian Conway's own Perl::Refactor configuration is also included in
this distribution as F<examples/perlrefactorrc-conway>.


=head1 THE POLICIES

A large number of Enforcer modules are distributed with Perl::Refactor.
They are described briefly in the companion document
L<Perl::Refactor::EnforcerSummary|Perl::Refactor::EnforcerSummary> and in more
detail in the individual modules themselves.  Say C<"perlrefactor -doc
PATTERN"> to see the perldoc for all Enforcer modules that match the
regex C<m/PATTERN/ixms>

There are a number of distributions of additional enforcers on CPAN.
If L<Perl::Refactor|Perl::Refactor> doesn't contain a enforcer that you
want, some one may have already written it.  See the L</"SEE ALSO">
section below for a list of some of these distributions.


=head1 POLICY THEMES

Each Enforcer is defined with one or more "themes".  Themes can be used
to create arbitrary groups of Enforcers.  They are intended to provide
an alternative mechanism for selecting your preferred set of Enforcers.
For example, you may wish disable a certain subset of Enforcers when
analyzing test programs.  Conversely, you may wish to enable only a
specific subset of Enforcers when analyzing modules.

The Enforcers that ship with Perl::Refactor have been broken into the
following themes.  This is just our attempt to provide some basic
logical groupings.  You are free to invent new themes that suit your
needs.

    THEME             DESCRIPTION
    --------------------------------------------------------------------------
    core              All enforcers that ship with Perl::Refactor
    pbp               Enforcers that come directly from "Perl Best Practices"
    bugs              Enforcers that that prevent or reveal bugs
    certrec           Enforcers that CERT recommends
    certrule          Enforcers that CERT considers rules
    maintenance       Enforcers that affect the long-term health of the code
    cosmetic          Enforcers that only have a superficial effect
    complexity        Enforcers that specificaly relate to code complexity
    security          Enforcers that relate to security issues
    tests             Enforcers that are specific to test programs


Any Enforcer may fit into multiple themes.  Say C<"perlrefactor -list"> to
get a listing of all available Enforcers and the themes that are
associated with each one.  You can also change the theme for any
Enforcer in your F<.perlrefactorrc> file.  See the L<"CONFIGURATION">
section for more information about that.

Using the C<-theme> option, you can create an arbitrarily complex rule
that determines which Enforcers will be loaded.  Precedence is the same
as regular Perl code, and you can use parentheses to enforce
precedence as well.  Supported operators are:

    Operator    Altertative    Example
    -----------------------------------------------------------------
    &&          and            'pbp && core'
    ||          or             'pbp || (bugs && security)'
    !           not            'pbp && ! (portability || complexity)'

Theme names are case-insensitive.  If the C<-theme> is set to an empty
string, then it evaluates as true all Enforcers.


=head1 BENDING THE RULES

Perl::Refactor takes a hard-line approach to your code: either you
comply or you don't.  In the real world, it is not always practical
(nor even possible) to fully comply with coding standards.  In such
cases, it is wise to show that you are knowingly violating the
standards and that you have a Damn Good Reason (DGR) for doing so.

To help with those situations, you can direct Perl::Refactor to ignore
certain lines or blocks of code by using annotations:

    require 'LegacyLibaray1.pl';  ## no refactor
    require 'LegacyLibrary2.pl';  ## no refactor

    for my $element (@list) {

        ## no refactor

        $foo = "";               #Violates 'ProhibitEmptyQuotes'
        $barf = bar() if $foo;   #Violates 'ProhibitPostfixControls'
        #Some more evil code...

        ## use refactor

        #Some good code...
        do_something($_);
    }

The C<"## no refactor"> annotations direct Perl::Refactor to ignore the remaining
lines of code until a C<"## use refactor"> annotation is found. If the C<"## no
refactor"> annotation is on the same line as a code statement, then only that
line of code is overlooked.  To direct perlrefactor to ignore the C<"## no
refactor"> annotations, use the C<--force> option.

A bare C<"## no refactor"> annotation disables all the active Enforcers.  If
you wish to disable only specific Enforcers, add a list of Enforcer names
as arguments, just as you would for the C<"no strict"> or C<"no
warnings"> pragmas.  For example, this would disable the
C<ProhibitEmptyQuotes> and C<ProhibitPostfixControls> enforcers until
the end of the block or until the next C<"## use refactor"> annotation
(whichever comes first):

    ## no refactor (EmptyQuotes, PostfixControls)

    # Now exempt from ValuesAndExpressions::ProhibitEmptyQuotes
    $foo = "";

    # Now exempt ControlStructures::ProhibitPostfixControls
    $barf = bar() if $foo;

    # Still subjected to ValuesAndExpression::RequireNumberSeparators
    $long_int = 10000000000;

Since the Enforcer names are matched against the C<"## no refactor">
arguments as regular expressions, you can abbreviate the Enforcer names
or disable an entire family of Enforcers in one shot like this:

    ## no refactor (NamingConventions)

    # Now exempt from NamingConventions::Capitalization
    my $camelHumpVar = 'foo';

    # Now exempt from NamingConventions::Capitalization
    sub camelHumpSub {}

The argument list must be enclosed in parentheses and must contain one
or more comma-separated barewords (e.g. don't use quotes).  The
C<"## no refactor"> annotations can be nested, and Enforcers named by an
inner annotation will be disabled along with those already disabled an
outer annotation.

Some Enforcers like C<Subroutines::ProhibitExcessComplexity> apply to
an entire block of code.  In those cases, C<"## no refactor"> must
appear on the line where the violation is reported.  For example:

    sub complicated_function {  ## no refactor (ProhibitExcessComplexity)
        # Your code here...
    }

Enforcers such as C<Documentation::RequirePodSections> apply to the
entire document, in which case violations are reported at line 1.

Use this feature wisely.  C<"## no refactor"> annotations should be used in the
smallest possible scope, or only on individual lines of code. And you
should always be as specific as possible about which Enforcers you want
to disable (i.e. never use a bare C<"## no refactor">).  If Perl::Refactor
complains about your code, try and find a compliant solution before
resorting to this feature.


=head1 THE L<Perl::Refactor|Perl::Refactor> PHILOSOPHY

Coding standards are deeply personal and highly subjective.  The goal
of Perl::Refactor is to help you write code that conforms with a set of
best practices.  Our primary goal is not to dictate what those
practices are, but rather, to implement the practices discovered by
others.  Ultimately, you make the rules -- Perl::Refactor is merely a
tool for encouraging consistency.  If there is a enforcer that you think
is important or that we have overlooked, we would be very grateful for
contributions, or you can simply load your own private set of enforcers
into Perl::Refactor.


=head1 EXTENDING THE CRITIC

The modular design of Perl::Refactor is intended to facilitate the
addition of new Enforcers.  You'll need to have some understanding of
L<PPI|PPI>, but most Enforcer modules are pretty straightforward and
only require about 20 lines of code.  Please see the
L<Perl::Refactor::DEVELOPER|Perl::Refactor::DEVELOPER> file included in
this distribution for a step-by-step demonstration of how to create
new Enforcer modules.

If you develop any new Enforcer modules, feel free to send them to C<<
<jeff@imaginative-software.com> >> and I'll be happy to put them into the
Perl::Refactor distribution.  Or if you would like to work on the
Perl::Refactor project directly, check out our repository at
L<http://perlrefactor.tigris.org>.  To subscribe to our mailing list,
send a message to L<mailto:dev-subscribe@perlrefactor.tigris.org>.

The Perl::Refactor team is also available for hire.  If your
organization has its own coding standards, we can create custom
Enforcers to enforce your local guidelines.  Or if your code base is
prone to a particular defect pattern, we can design Enforcers that will
help you catch those costly defects B<before> they go into production.
To discuss your needs with the Perl::Refactor team, just contact C<<
<jeff@imaginative-software.com> >>.


=head1 PREREQUISITES

Perl::Refactor requires the following modules:

L<B::Keywords|B::Keywords>

L<Config::Tiny|Config::Tiny>

L<Email::Address|Email::Address>

L<Exception::Class|Exception::Class>

L<File::Spec|File::Spec>

L<File::Spec::Unix|File::Spec::Unix>

L<IO::String|IO::String>

L<List::MoreUtils|List::MoreUtils>

L<List::Util|List::Util>

L<Module::Pluggable|Module::Pluggable>

L<Perl::Tidy|Perl::Tidy>

L<Pod::Spell|Pod::Spell>

L<PPI|PPI>

L<Pod::PlainText|Pod::PlainText>

L<Pod::Select|Pod::Select>

L<Pod::Usage|Pod::Usage>

L<Readonly|Readonly>

L<Scalar::Util|Scalar::Util>

L<String::Format|String::Format>

L<Task::Weaken|Task::Weaken>

L<Text::ParseWords|Text::ParseWords>

L<version|version>


The following modules are optional, but recommended for complete
functionality:

L<File::HomeDir|File::HomeDir>

L<File::Which|File::Which>


=head1 CONTACTING THE DEVELOPMENT TEAM

You are encouraged to subscribe to the mailing list; send a message to
L<mailto:users-subscribe@perlrefactor.tigris.org>.  See also the archives at
L<http://perlrefactor.tigris.org/servlets/SummarizeList?listName=users>.
You can also contact the author at C<< <jeff@imaginative-software.com> >>.

At least one member of the development team has started hanging around
in L<irc://irc.perl.org/#perlrefactor>.

You can also follow Perl::Refactor on Twitter, at
L<https://twitter.com/perlrefactor>.


=head1 SEE ALSO

There are a number of distributions of additional Enforcers available.
A few are listed here:

L<Perl::Refactor::More|Perl::Refactor::More>

L<Perl::Refactor::Bangs|Perl::Refactor::Bangs>

L<Perl::Refactor::Lax|Perl::Refactor::Lax>

L<Perl::Refactor::StricterSubs|Perl::Refactor::StricterSubs>

L<Perl::Refactor::Swift|Perl::Refactor::Swift>

L<Perl::Refactor::Tics|Perl::Refactor::Tics>

These distributions enable you to use Perl::Refactor in your unit tests:

L<Test::Perl::Refactor|Test::Perl::Refactor>

L<Test::Perl::Refactor::Progressive|Test::Perl::Refactor::Progressive>

There is also a distribution that will install all the Perl::Refactor related
modules known to the development team:

L<Task::Perl::Refactor|Task::Perl::Refactor>

If you want to make sure you have absolutely everything, you can use this:

L<Task::Perl::Refactor::IncludingOptionalDependencies|Task::Perl::Refactor::IncludingOptionalDependencies>


=head1 BUGS

Scrutinizing Perl code is hard for humans, let alone machines.  If you
find any bugs, particularly false-positives or false-negatives from a
Perl::Refactor::Enforcer, please submit them to
L<https://github.com/Perl-Refactor/Perl-Refactor/issues>.  Thanks.

Most enforcers will produce false-negatives if they cannot understand a
particular block of code.


=head1 CREDITS

Adam Kennedy - For creating L<PPI|PPI>, the heart and soul of
L<Perl::Refactor|Perl::Refactor>.

Damian Conway - For writing B<Perl Best Practices>, finally :)

Chris Dolan - For contributing the best features and Enforcer modules.

Andy Lester - Wise sage and master of all-things-testing.

Elliot Shank - The self-proclaimed quality freak.

Giuseppe Maxia - For all the great ideas and positive encouragement.

and Sharon, my wife - For putting up with my all-night code sessions.

Thanks also to the Perl Foundation for providing a grant to support
Chris Dolan's project to implement twenty PBP enforcers.
L<http://www.perlfoundation.org/april_1_2007_new_grant_awards>


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
