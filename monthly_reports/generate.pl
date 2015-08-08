
use Data::Dumper;
use Date::Parse;
use DateTime;
use Text::CSV_XS;
use Text::Template;
use strict;

my $MONTH = DateTime->now->subtract( months => 1 )->month;
my $YEAR = DateTime->now->year;

# reporting period
my $dt = DateTime->new(  year => $YEAR, month => $MONTH, day => 1 );
my $RPSTART = $dt->epoch;
my $RPEND = $dt->add( months => 1 )->subtract( seconds => 1 )->epoch;

# incident targets
my %TARGETS = (
    "1 - Critical" => '', # 4 hours
    "2 - High" => '', # 1 business day
    "3 - Moderate" => '', # 4 business days
    "4 - Low" => '', # 10 business days
    "5" => '', # ?
);

# other constants
my $SUPPORT_HOURS_PER_DAY = 7;

# load service data
my %CUSTOMERS;
my %SERVICES_BY_CUST;
my %SERVICES;
my $service_file = $ARGV[0];
open( my $service_fh, "<", $service_file ) or die "Error opening $service_file: $!";
&load_services( $service_fh );
close $service_fh;

# load outage data
my $outage_file = $ARGV[1];
open( my $outage_fh, "<", $outage_file ) or die "Error opening $outage_file: $!";
&load_outages( $outage_fh );
close $outage_fh;

# load incident data
my $incident_file = $ARGV[2];
open( my $incident_fh, "<:encoding(cp1252)", $incident_file ) or die "Error opening $incident_file: $!";
&load_incidents( $incident_fh );
close $incident_fh;

# output directory for reports
my $OUTDIR = $ARGV[3];

# template directory
my $TEMPLATEDIR = "templates";

# create summary
my $template = Text::Template->new( SOURCE => "$TEMPLATEDIR/report.tmpl" ) or die "Couldn't construct template: $Text::Template::ERROR";
foreach my $customer ( values %CUSTOMERS )
{
    # support balance panel
    $customer->{_balance_total} = $customer->{"Support Allocation Days"} * $SUPPORT_HOURS_PER_DAY; # hours
    $customer->{_balance_current} = $customer->{_support_used_since_start_date} / 3600; # hours
    my $ratio = ( $customer->{_balance_current} / $customer->{_balance_total} ) * 100;
    $customer->{_balance_ratio} = $ratio;
    $customer->{_balance_state} = $ratio <= 75 ? "success" : $ratio <= 90 ? "warning" : "danger";

    # support target panel
    $customer->{_target_total} = $customer->{_incidents_closed_in_period};
    $customer->{_target_current} = $customer->{_incidents_closed_within_target_in_period};
    if( $customer->{_target_total} )
    {
        $ratio = ( $customer->{_target_current} / $customer->{_target_total} ) * 100;
        $customer->{_target_ratio} = $ratio;
        $customer->{_target_state} = $ratio >= 95 ? "success" : $ratio >= 85 ? "warning" : "danger";
    }

    foreach my $service ( @{ $SERVICES_BY_CUST{$customer->{"Customer Name"}} } )
    {

        # service storage panel
        $service->{_storage_total} = $service->{"Storage Allocation GB"};
        $service->{_storage_current} = $service->{"Storage Used GB"};
        $ratio = ( $service->{_storage_current} / $service->{_storage_total} ) * 100;
        $service->{_storage_ratio} = $ratio;
        $service->{_storage_state} = $ratio <= 75 ? "success" : $ratio <= 90 ? "warning" : "danger";

        # service availability panel
        $service->{_avail_total} = $RPEND - $RPSTART; # secs in reporting period
        $service->{_avail_current} = $service->{_avail_total} - $service->{_total_outage_in_period};
        $ratio = ( $service->{_avail_current} / $service->{_avail_total} ) * 100;
        $service->{_avail_ratio} = $ratio;
        $service->{_avail_state} = $ratio >= 95 ? "success" : $ratio >= 85 ? "warning" : "danger";
    }

    my $vars = {
        customer => \$customer,
        period => \( DateTime->new( year => $YEAR, month => $MONTH ) ),
        services => \( $SERVICES_BY_CUST{$customer->{"Customer Name"}} ),
        templatedir => \$TEMPLATEDIR,
    };

    my $report_file = sprintf( "%s/%s.html", $OUTDIR, lc $customer->{"Customer Code"} );
    open( my $fh, ">:encoding(utf8)", $report_file ) or die "Could not write to $report_file: $!";
    if( $template->fill_in( HASH => $vars, OUTPUT => $fh ) )
    {
        print "Wrote: $report_file\n";
    }
    else
    {
        die "Couldn't fill in template: $Text::Template::ERROR";
    }
    close $fh;
}

sub load_services
{
    my( $fh ) = @_;

    my $csv = &_init_csv;

	$csv->column_names( @{ $csv->getline( $fh ) } );

	while( my $row = $csv->getline_hr( $fh ) )
	{
        my $customer = $row->{"Customer Name"};
        my $service = $row->{Service};
        # 3 ways to access the same service hashref
        $CUSTOMERS{$customer} = $row; # by customer name
        push @{ $SERVICES_BY_CUST{$customer} }, $row; # by customer name and service
        $SERVICES{$service} = $row; # by service
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
        $SERVICES{$service}{_total_outage_in_period} += $duration;
        push @{ $SERVICES{$service}{_outages} }, $row;
    }
}

sub load_incidents
{
    my( $fh ) = @_;

    my $csv = &_init_csv;

	$csv->column_names( @{ $csv->getline( $fh ) } );

	while( my $row = $csv->getline_hr( $fh ) ) 
	{
        # convert DD-MM-YYYY HH:MM to YYYY-MM-DD HH:SS
        # BUG: When both the month and the date are specified in the date as numbers they are always parsed assuming that the month number comes before the date.
        $row->{"opened_at"} =~ m|^([0-9]{2})-([0-9]{2})-([0-9]{4})\s([0-9]{2}):([0-9]{2})|; # 10-04-2015 10:36:26
        my $opened = str2time( "$3-$2-$1 $4:$5" );

        # filter incidents which didn't get opened in the contract period
        # TODO does an incident opened in a contract period apply to that contract period?
        my $company = $row->{company};
        next unless $CUSTOMERS{$company};

        my $cpstart = str2time( $CUSTOMERS{$company}{"Start Date"} );
        unless( defined $cpstart )
        {
            #warn "No contract start date for $company"; # TODO better error reporting
            next;
        }
        next unless ( $cpstart <= $opened && $opened <= $RPEND );

        my $time_worked = $row->{category} eq "Incident" ? 0 : $row->{"time_worked"};
        $CUSTOMERS{$company}{_support_used_since_start_date} += $time_worked;

        # filter incidents not relevant to reporting period
        $row->{"closed_at"} =~ m|^([0-9]{2})/([0-9]{2})/([0-9]{4})\s([0-9]{2}):([0-9]{2})|;
        my $closed = str2time( "$3-$2-$1 $4:$5" );
        my $state = $row->{state};
        next unless
            ( defined $closed && $RPSTART <= $closed && $closed <= $RPEND ) # incident closed in reporting period
            ||
            ( $state ne "Closed" ) # incident is not closed
        ;

        if( $state eq "Resolved" || $state eq "Closed" )
        {
            $CUSTOMERS{$company}{_incidents_closed_in_period}++;
            # TODO count incidnts closed with target
            $CUSTOMERS{$company}{_incidents_closed_within_target_in_period}++;
        }

        push @{ $CUSTOMERS{$company}{_incidents} }, $row;
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
