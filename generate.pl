

use Text::CSV_XS;
use strict;

my $outage_file = $ARGV[0];
open( my $outage_fh, "<", $outage_file ) or die "Error opening $outage_file: $!";
&import_outages( $outage_fh );

sub import_outages
{
    my( $fh ) = @_;

    my $csv = &_init_csv;

	$csv->column_names( @{ $csv->getline( $fh ) } );

	while( my $row = $csv->getline_hr( $fh ) ) 
	{
        print $row->{Server} . "\n";
        
    }

}

sub _init_csv
{
    my $csv = Text::CSV_XS->new;

    $csv->auto_diag( 1 );
    $csv->binary( 1 );
    $csv->empty_is_undef( 1 );

    return $csv;
}
