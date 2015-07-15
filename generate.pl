
use Data::Dumper;
use Date::Parse;
use DateTime;
use Text::CSV_XS;
use strict;

my $MONTH = DateTime->now->subtract( months => 1 )->month;
my $YEAR = DateTime->now->year;

# reporting period
my $dt = DateTime->new(  year => $YEAR, month => $MONTH, day => 1 );
my $RPSTART = $dt->epoch;
my $RPEND = $dt->add( months => 1 )->subtract( seconds => 1 )->epoch;

# load service data
my $SERVICES;
my $service_file = $ARGV[0];
open( my $service_fh, "<", $service_file ) or die "Error opening $service_file: $!";
&load_services( $service_fh );

# load outage data
my $OUTAGES;
my $outage_file = $ARGV[1];
open( my $outage_fh, "<", $outage_file ) or die "Error opening $outage_file: $!";
&load_outages( $outage_fh );

# load incident data
my $INCIDENTS;
my $incident_file = $ARGV[1];
open( my $incident_fh, "<", $incident_file ) or die "Error opening $incident_file: $!";
&load_incidents( $incident_fh );

sub load_services
{
    my( $fh ) = @_;

    my $csv = &_init_csv;

	$csv->column_names( @{ $csv->getline( $fh ) } );

	while( my $row = $csv->getline_hr( $fh ) ) 
	{
        my $customer = $row->{Customer};
        my $service = $row->{Service};
        my $start = str2time( $row->{"Start Date"} );
        push @{ $SERVICES->{$customer} }, {
            url => $service,
            start => $start,
            # TODO warn if start date more than a year ago?
        };
    }
}

sub load_outages
{
    my( $fh ) = @_;

    my $csv = &_init_csv;

	$csv->column_names( @{ $csv->getline( $fh ) } );

	while( my $row = $csv->getline_hr( $fh ) ) 
	{
        my $start = str2time( $row->{"Start Time"} );
        my $end = $start + $row->{"Duration (Seconds)"};

        # filter outages which didnt start or end in the reporting period
        next unless ( $RPSTART <= $start && $start <= $RPEND ) || ( $RPSTART <= $end && $end <= $RPEND );

        # work out duration relative to reporting period
        $start = $RPSTART if $start < $RPSTART;
        $end = $RPEND if $end > $RPEND;
        my $duration = $end - $start;

        my $service = $row->{Server};
        # running total of outage duration (secs) during this period
        $OUTAGES->{$service}{duration_in_period} += $duration;
        push @{ $OUTAGES->{$service}{summary} }, $row;
    }
}

sub load_incidents
{
    my( $fh ) = @_;

    my $csv = &_init_csv;

	$csv->column_names( @{ $csv->getline( $fh ) } );

	while( my $row = $csv->getline_hr( $fh ) ) 
	{
        # convert DD/MM/YYYY HH:MM to YYYY-MM-DD HH:SS
        # BUG: When both the month and the date are specified in the date as numbers they are always parsed assuming that the month number comes before the date.
        $row->{"opened_at"} =~ m|^([0-9]{2})/([0-9]{2})/([0-9]{4})\s([0-9]{2}):([0-9]{2})|;
        my $opened = str2time( "$3-$2-$1 $4:$5" );

        # filter incidents which didn't get opened in the contract period
        # TODO does an incident opened in a contract period apply to that contract period?
        my $company = $row->{company};
        my $cpstart = $SERVICES->{$company};
        warn "No contract start date for $company\n" && last unless defined $cpstart; # TODO better error reporting
        next unless ( $cpstart <= $opened && $opened <= $RPEND );

        my $time_worked = $row->{category} eq "Incident" ? 0 : $row->{"time_worked"};
        $INCIDENTS->{$company}{balance_used} += $time_worked;

        # filter incidents not relevant to reporting period
        $row->{"closed_at"} =~ m|^([0-9]{2})/([0-9]{2})/([0-9]{4})\s([0-9]{2}):([0-9]{2})|;
        my $closed = str2time( "$3-$2-$1 $4:$5" );
        my $state = $row->{state};
        next unless
            ( defined $closed && $RPSTART <= $closed && $closed <= $RPEND ) # incident closed in reporting period
            ||
            ( $state ne "Closed" ) # incident is not closed
        ;

        push @{ $INCIDENTS->{$company}{summary} }, $row;
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
