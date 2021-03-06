#!perl

use 5.006001;
use strict;
use warnings;

use English qw(-no_match_vars);

use PPI::Document;

use Perl::Refactor::Annotation;
use Perl::Refactor::TestUtils qw(bundled_enforcer_names);

use Test::More;

#-----------------------------------------------------------------------------

our $VERSION = '1.121';

#-----------------------------------------------------------------------------

Perl::Refactor::TestUtils::block_perlrefactorrc();

my @bundled_enforcer_names = bundled_enforcer_names();

plan( tests => 85 );

#-----------------------------------------------------------------------------
# Test Perl::Refactor::Annotation module interface

can_ok('Perl::Refactor::Annotation', 'new');
can_ok('Perl::Refactor::Annotation', 'create_annotations');
can_ok('Perl::Refactor::Annotation', 'element');
can_ok('Perl::Refactor::Annotation', 'effective_range');
can_ok('Perl::Refactor::Annotation', 'disabled_enforcers');
can_ok('Perl::Refactor::Annotation', 'disables_enforcer');
can_ok('Perl::Refactor::Annotation', 'disables_all_enforcers');
can_ok('Perl::Refactor::Annotation', 'disables_line');

annotate( <<"EOD", 0, 'Null case. Un-annotated document' );
#!/usr/local/bin/perl

print "Hello, world!\n";
EOD

annotate( <<"EOD", 1, 'Single block annotation for entire document' );

## no refactor

print "Hello, world!\n";

EOD
my $note = choose_annotation( 0 );
ok( $note, 'Single block annotation defined' );
SKIP: {
    $note or skip( 'No annotation found', 4 );
    ok( $note->disables_all_enforcers(),
        'Single block annotation disables all enforcers' );
    ok( $note->disables_line( 4 ),
        'Single block annotation disables line 4' );
    my( $start, $finish ) = $note->effective_range();
    is( $start, 2,
        'Single block annotation starts at 2' );
    is( $finish, 6,
        'Single block annotation runs through 6' );
}

annotate( <<"EOD", 1, 'Block annotation for block (sorry!)' );

{
    ## no refactor

    print "Hello, world!\n";
}

EOD
$note = choose_annotation( 0 );
ok( $note, 'Block annotation defined' );
SKIP: {
    $note or skip( 'No annotation found', 4 );
    ok( $note->disables_all_enforcers(),
        'Block annotation disables all enforcers' );
    ok( $note->disables_line( 5 ),
        'Block annotation disables line 5' );
    my( $start, $finish ) = $note->effective_range();
    is( $start, 3,
        'Block annotation starts at 3' );
    is( $finish, 6,
        'Block annotation runs through 6' );
}

SKIP: {
    foreach ( @bundled_enforcer_names ) {
        m/ FroBozzBazzle /smxi or next;
        skip( 'Enforcer FroBozzBazzle actually implemented', 6 );
        last;   # probably not necessary.
    }

    annotate( <<"EOD", 1, 'Bogus annotation' );

## no refactor ( FroBozzBazzle )

print "Goodbye, cruel world!\n";

EOD

    $note = choose_annotation( 0 );
    ok( $note, 'Bogus annotation defined' );

    SKIP: {
        $note or skip( 'Bogus annotation not found', 4 );
        ok( ! $note->disables_all_enforcers(),
            'Bogus annotation does not disable all enforcers' );
        ok( $note->disables_line( 3 ),
            'Bogus annotation disables line 3' );
        my( $start, $finish ) = $note->effective_range();
        is( $start, 2,
            'Bogus annotation starts at 2' );
        is( $finish, 6,
            'Bogus annotation runs through 6' );
    }
}

SKIP: {
    @bundled_enforcer_names >= 8
        or skip( 'Need at least 8 bundled enforcers', 49 );
    my $max = 0;
    my $doc;
    my @annot;
    foreach my $fmt ( '(%s)', '( %s )', '"%s"', q<'%s'> ) {
        my $enforcer_name = $bundled_enforcer_names[$max++];
        $enforcer_name =~ s/ .* :: //smx;
        $note = sprintf "no refactor $fmt", $enforcer_name;
        push @annot, $note;
        $doc .= "## $note\n## use refactor\n";
        $enforcer_name = $bundled_enforcer_names[$max++];
        $enforcer_name =~ s/ .* :: //smx;
        $note = sprintf "no refactor qw$fmt", $enforcer_name;
        push @annot, $note;
        $doc .= "## $note\n## use refactor\n";
    }

    annotate( $doc, $max, 'Specific enforcers in various formats' );
    foreach my $inx ( 0 .. $max - 1 ) {
        $note = choose_annotation( $inx );
        ok( $note, "Specific annotation $inx ($annot[$inx]) defined" );
        SKIP: {
            $note or skip( "No annotation $inx found", 5 );
            ok( ! $note->disables_all_enforcers(),
                "Specific annotation $inx does not disable all enforcers" );
            my ( $enforcer_name ) = $bundled_enforcer_names[$inx] =~
                m/ ( \w+ :: \w+ ) \z /smx;
            ok ( $note->disables_enforcer( $bundled_enforcer_names[$inx] ),
                "Specific annotation $inx disables $enforcer_name" );
            my $line = $inx * 2 + 1;
            ok( $note->disables_line( $line ),
                "Specific annotation $inx disables line $line" );
            my( $start, $finish ) = $note->effective_range();
            is( $start, $line,
                "Specific annotation $inx starts at line $line" );
            is( $finish, $line + 1,
                "Specific annotation $inx runs through line " . ( $line + 1 ) );
        }
    }
}

annotate( <<"EOD", 1, 'Annotation on split statement' );

my \$foo =
    'bar'; ## no refactor ($bundled_enforcer_names[0])

my \$baz = 'burfle';
EOD
$note = choose_annotation( 0 );
ok( $note, 'Split statement annotation found' );
SKIP: {
    $note or skip( 'Split statement annotation not found', 4 );
    ok( ! $note->disables_all_enforcers(),
        'Split statement annotation does not disable all enforcers' );
    ok( $note->disables_line( 3 ),
        'Split statement annotation disables line 3' );
    my( $start, $finish ) = $note->effective_range();
    is( $start, 3,
        'Split statement annotation starts at line 3' );
    is( $finish, 3,
        'Split statement annotation runs through line 3' );
}

annotate (<<'EOD', 1, 'Ensure annotations can span __END__' );
## no refactor (RequirePackageMatchesPodName)

package Foo;

__END__

=head1 NAME

Bar - The wrong name for this package

=cut
EOD
$note = choose_annotation( 0 );
ok( $note, 'Annotation (hopefully spanning __END__) found' );
SKIP: {
    skip( 'Annotation (hopefully spanning __END__) not found', 1 )
    if !$note;
    ok( $note->disables_line( 7 ),
        'Annotation disables the POD after __END__' );
}


#-----------------------------------------------------------------------------

{
    my $doc;            # P::C::Document, held to prevent annotations from
                        # going away due to garbage collection of the parent.
    my @annotations;    # P::C::Annotation objects

    sub annotate {  ## no refactor (RequireArgUnpacking)
        my ( $source, $count, $title ) = @_;
        $doc = PPI::Document->new( \$source ) or do {
            @_ = ( "Can not make PPI::Document for $title" );
            goto &fail;
        };
        $doc = Perl::Refactor::Document->new( -source => $doc ) or do {
            @_ = ( "Can not make Perl::Refactor::Document for $title" );
            goto &fail;
        };
        @annotations = Perl::Refactor::Annotation->create_annotations( $doc );
        @_ = ( scalar @annotations, $count, $title );
        goto &is;
    }

    sub choose_annotation {
        my ( $index ) = @_;
        return $annotations[$index];
    }

}

#-----------------------------------------------------------------------------

# ensure we return true if this test is loaded by
# t/00_modules.t_without_optional_dependencies.t
1;

# Local Variables:
#   mode: cperl
#   cperl-indent-level: 4
#   fill-column: 78
#   indent-tabs-mode: nil
#   c-indentation-style: bsd
# End:
# ex: set ts=8 sts=4 sw=4 tw=78 ft=perl expandtab shiftround :
