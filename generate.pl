
use Data::Dumper;
use Date::Parse;
use DateTime;
use Text::CSV_XS;
use strict;

my $month = DateTime->now->subtract( months => 1 )->month;
my $year = DateTime->now->year;

# reporting period
my $dt = DateTime->new( year => $year, month => $month, day => 1 );
my $START = $dt->epoch;
my $END = $dt->add( months => 1 )->subtract( seconds => 1 )->epoch;

my $OUTAGES;
my $outage_file = $ARGV[0];
open( my $outage_fh, "<", $outage_file ) or die "Error opening $outage_file: $!";
&import_outages( $outage_fh );

print Dumper( $OUTAGES );

sub import_outages
{
    my( $fh ) = @_;

    my $csv = &_init_csv;

	$csv->column_names( @{ $csv->getline( $fh ) } );

	while( my $row = $csv->getline_hr( $fh ) ) 
	{
        my $start = str2time( $row->{"Start Time"} );
        my $end = $start + $row->{"Duration (Seconds)"};

        # filter outages which didnt start or end in the reporting period
        next unless ( $START <= $start && $start <= $END ) || ( $START <= $end && $end <= $END );

        # work out duration relative to reporting period
        $start = $START if $start < $START;
        $end = $END if $end > $END;
        my $duration = $end - $start;

        my $service = $row->{Server};
        # running total of outage duration (secs) during this period
        $OUTAGES->{$service}{duration_in_period} += $duration;
        push @{ $OUTAGES->{$service}{summary} }, $row;
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
