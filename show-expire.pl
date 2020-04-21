#!/usr/bin/perl

use strict;
use Data::Dumper;
use Date::Calc qw(Add_Delta_Days check_date);
use Getopt::Long;

main();

# init globals vars and objects 
sub _init {

    # binary locations
    my $sendmail = "/usr/lib/sendmail";

    # load the date object
    my $date = get_date();
   
    # email recipients
    my $recipients = 'your.recipients@email.org'; 

    return {
        'sendmail'      =>  $sendmail,
        'recipients'    =>  $recipients,
        'days_after'    =>  7,
        'days_before'   =>  7,
        'ca_text_db'    =>  '/CA/log/path/index.txt',
        'date'          =>  $date,

    };
}


sub main {

    my $g = _init();

    # get options
    get_options($g);

    # build the data
    process_cadb($g);

    # report the data
    process_reports($g);
}


sub process_reports {
    
    my $g = shift;
    my $sendmail = "$g->{sendmail} -t";

    my $valid_report;       #output buffer for our valid report
    my $expired_report;     #output buffer for our expired report
    my $renewed_report;     #output buffer for our renewed report
  
    # Build a brief report header, date etc...

    # build expired
    $expired_report .= "Expired Certificates since $g->{start_date} ($g->{days_before} days ago) listed by OU\n";
    $expired_report .= build_report($g, $g->{expired});    

    # build valid
    $valid_report .= "Valid Certificates that will be expired on $g->{end_date} ($g->{days_after} days), listed by OU\n";
    $valid_report .= build_report($g, $g->{valid});    

    # build renewed
    $renewed_report .= "Renewed Certificates that would have expired by $g->{end_date} ($g->{days_after} days), listed by OU\n";
    $renewed_report .= build_report($g, $g->{renewed});    


    # print report to stdout or email it

    if ($g->{opts}->{noemail}) {
        print $expired_report;
        print $valid_report;
        print $renewed_report;
    } else {
        open( SENDMAIL, "|$sendmail") or die("Cannot open $sendmail: $!");
        print SENDMAIL "To: $g->{recipients}\n";
        print SENDMAIL "Subject: EXPIRATION-REPORT START=$g->{start_date} END=$g->{end_date} \n";

        print SENDMAIL $expired_report;
        print SENDMAIL $valid_report;
        print SENDMAIL $renewed_report;

        close(SENDMAIL);

        print "A report has been sent to $g->{recipients}\n";
    }
}

sub build_report{

    my $g = shift;
    my $cert_href = shift;

    # put all our output into this var
    my $report;

    my @ous = sort( keys( %$cert_href) );

    for my $ou (@ous) {
        $report .= "===$ou===\n"; 

        my $ou_href = $cert_href->{$ou};
        for my $index ( sort( keys( %$ou_href ) ) ) {

            # mark certs that are renewed with a star
            my $renewed;
            if ($cert_href->{$ou}->{$index}->{renewed}) {$renewed = "*";}

            # optional extended data
            my ($subject, $time);
            if ($g->{opts}->{extended}) {
                $subject = "\t$cert_href->{$ou}->{$index}->{subject}";
                $time = "$cert_href->{$ou}->{$index}->{time} ";
            }

            $report .= "$cert_href->{$ou}->{$index}->{date} " . 
                       $time . 
                       "$cert_href->{$ou}->{$index}->{serial}" . "$renewed" .  "\t" .   
                       "$cert_href->{$ou}->{$index}->{cn}" . "\t" .
                       "$cert_href->{$ou}->{$index}->{email}" . 
                       $subject . "\n";
        } 
        $report .= "\n";
    }

    if ($report) {
        return $report;
    } else {
        return "No certs match this criteria\n\n";
    }
}



sub process_cadb {

    my $g = shift;
    
    # read the datafile into an array first
    open (CADB, $g->{ca_text_db});
    my @cadb = <CADB>;
    close (CADB);

    my $expired;    #anon hash ref to model the data
    my $renewed;    #anon hash ref to model the data
    my $valid;      #anon hash ref to model the data
    my $all_certs;      #anon hash ref to model the data

    # get the valid intervals that we are searching within
    my ($past, $future) = get_date_intervals($g);

    # process the entire cadb so we can do lookups while checking the interval
    for my $preline (@cadb) {
        # dont bother using the line less it is valid
        if ($preline =~ /^V/) {

            # take off the newline
            chomp($preline);

            # split out the line so we can use the data
            my @vars = split( /\t/, $preline);
            
            # take the "Z" off our input
            chop $vars[1];

            # split out the cert info
            my $ou = $vars[5];
            $ou =~ s/.*\/OU=(.*)\/CN.*/$1/; 

            my $cn = $vars[5];
            $cn =~ s/.*\/CN=(.*)/$1/;
    
            # this will grab the email address if available
            ($cn, my $email) = split( /\/emailAddress=/, $cn); 
            
            # explode the date from the serial
            my ($year, $month, $day, $hour, $min, $sec) = ( $vars[1] =~ /^(..)(..)(..)(..)(..)(..)$/);
            $year = "20" . $year;

            # building the hash this way will only catch the most recent subject added
            $all_certs->{$ou}->{$vars[5]}->{serial} = $vars[3];
            $all_certs->{$ou}->{$vars[5]}->{datetime} = $vars[1];
            $all_certs->{$ou}->{$vars[5]}->{cn} = $cn;
            $all_certs->{$ou}->{$vars[5]}->{subject} = $vars[5];
            $all_certs->{$ou}->{$vars[5]}->{date} = "$year-$month-$day";
            $all_certs->{$ou}->{$vars[5]}->{time} = "$hour:$min:$sec";
            if ($email) {$all_certs->{$ou}->{$vars[5]}->{email} = $email;}
        }
    }

    # run through the array to calc the certs for our interval
    for my $line (@cadb) {
        # dont bother using the line less it is valid
        if ($line =~ /^V/) {

            # take off the newline
            chomp($line);

            # split out the line so we can use the data
            my @vars = split( /\t/, $line);
            
            # take the "Z" off our input
            chop $vars[1];

            # split out the cert info
            my $ou = $vars[5];
            $ou =~ s/.*\/OU=(.*)\/CN.*/$1/; 

            my $cn = $vars[5];
            $cn =~ s/.*\/CN=(.*)/$1/;
    
            # this will grab the email address if available
            ($cn, my $email) = split( /\/emailAddress=/, $cn); 
            
            # explode the date from the serial
            my ($year, $month, $day, $hour, $min, $sec) = ( $vars[1] =~ /^(..)(..)(..)(..)(..)(..)$/);
            # fix the year
            $year = "20" . $year;

            if (($vars[1] > $past) && ($vars[1] < $future)) {
                if (cert_renewed($g, $all_certs, $ou, $vars[5], $future)) {
                    $renewed->{$ou}->{$vars[1]}->{serial} = $vars[3];
                    $renewed->{$ou}->{$vars[1]}->{datetime} = $vars[1];
                    $renewed->{$ou}->{$vars[1]}->{cn} = $cn;
                    $renewed->{$ou}->{$vars[1]}->{subject} = $vars[5];
                    $renewed->{$ou}->{$vars[1]}->{date} = "$year-$month-$day";
                    $renewed->{$ou}->{$vars[1]}->{time} = "$hour:$min:$sec";
                    $renewed->{$ou}->{$vars[1]}->{renewed} = 1;
                    if ($email) {$renewed->{$ou}->{$vars[1]}->{email} = $email;}
                } elsif ($vars[1] > $g->{date}->{p_yymmdd}) {
                    $valid->{$ou}->{$vars[1]}->{serial} = $vars[3];
                    $valid->{$ou}->{$vars[1]}->{datetime} = $vars[1];
                    $valid->{$ou}->{$vars[1]}->{cn} = $cn;
                    $valid->{$ou}->{$vars[1]}->{subject} = $vars[5];
                    $valid->{$ou}->{$vars[1]}->{date} = "$year-$month-$day";
                    $valid->{$ou}->{$vars[1]}->{time} = "$hour:$min:$sec";
                    if ($email) {$valid->{$ou}->{$vars[1]}->{email} = $email;}
                } else {
                    $expired->{$ou}->{$vars[1]}->{serial} = $vars[3];
                    $expired->{$ou}->{$vars[1]}->{datetime} = $vars[1];
                    $expired->{$ou}->{$vars[1]}->{cn} = $cn;
                    $expired->{$ou}->{$vars[1]}->{subject} = $vars[5];
                    $expired->{$ou}->{$vars[1]}->{date} = "$year-$month-$day";
                    $expired->{$ou}->{$vars[1]}->{time} = "$hour:$min:$sec";
                    $expired->{$ou}->{$vars[1]}->{renewed} = cert_renewed($g, $all_certs, $ou, $vars[5], $future);
                    if ($email) {$expired->{$ou}->{$vars[1]}->{email} = $email;}
                }
            }
        }
    }
# put our new objects back into the global
$g->{valid} = $valid;
$g->{expired} = $expired;
$g->{renewed} = $renewed;
}

sub cert_renewed {
    my $g         = shift;
    my $all_certs = shift;
    my $ou        = shift;
    my $subject   = shift;
    my $future    = shift;

    if ($all_certs->{$ou}->{$subject}->{datetime} > $future) {
    #if ($all_certs->{$ou}->{$subject}->{datetime} > $g->{date}->{r_yymmdd}) {
        return 1;
    } else {
        return 0;
    }
}

sub get_options {
    my $g = shift;

    my @options =    ( 'days=s{1,}',
                       'days-from-now=s{1,}',
                       'days-ago=s{1,}',
                       'date=s{1,}',
                       'noemail',
                       'help',
                       'extended'
                     );  
    
    # anon hash for options
    my $opts;

    GetOptions( \%$opts, @options );

    # help/usage
    if ($opts->{help}) {
        print_usage($g);
        exit();
    }

    # directly modify global vars as well
    if ($opts->{date}) { 
        my ($year, $month, $day) = split( /-/, $opts->{date});
        if ( check_date($year, $month, $day) ) {
            $g->{date}->{year} = $year;
            $g->{date}->{mon} = $month;
            $g->{date}->{mday} = $day;

            #change the yymmdd vals too
            my $yy = substr( $year, 2, 2);
            my $yymmdd = $yy . sprintf("%02d",$month) . sprintf("%02d",$day);
            $g->{date}->{p_yymmdd} = $yymmdd . "000000";
            $g->{date}->{r_yymmdd} =~ s/^......(.*)/$yymmdd$1/;

        } else {
            die("$opts->{date} is not a valid date");
        }
    } 

    if ($opts->{days}) {
        if ( $opts->{'days-from-now'} or $opts->{'days-ago'} ) {
            die("Do not use the --days option with other time intervals specified");
        } elsif ( check_positive_int($opts->{days}) ) {
            $g->{days_before} = $opts->{days};
            $g->{days_after} = $opts->{days};
        } else {
            die("option must be a positive integer");
        }
    }

    if ( $opts->{'days-from-now'} or $opts->{'days-ago'} ) {
        if ($opts->{days}) {
            die("Do not use the --days option with other time intervals specified");
        } 

        if ( $opts->{'days-ago'} ) {
            if ( check_positive_int($opts->{'days-ago'}) ) {
                $g->{days_before} = $opts->{'days-ago'};
            } else {
                die("option must be a positive integer");
            }
        }

        if ( $opts->{'days-from-now'} ) {
            if ( check_positive_int($opts->{'days-from-now'}) ) {
                $g->{days_after} = $opts->{'days-from-now'};
            } else {
                die("option must be a positive integer");
            }
        }
    }
 
    # put the options hash into the global
    $g->{opts} = $opts;


}

sub check_positive_int {
    my $num = shift;
    
    if (($num =~ /\d+/) && ($num > 0) ) {
        return 1;
    } else {
        return 0;
    }
}

sub print_usage {

        my $g = shift;
    # print our standard usage
    print qq[Usage: show-expire.pl [options]
    
Options:
    --help          Prints this message
    --days          Number of days to search forward and backward
    --days-from-now Number of days to search forward
    --days-ago      Number of days to search backward
    --date          Date to base the search from, use yyyy-mm-dd
    --noemail       Report output to stdout only, no email is sent  
    --extended      Times and Certificate subjects are included in report

Notes:
    Option --days can not be used when --days-ago or --days-from-now is used and vice versa

];
}

sub get_date_intervals {

    my $g = shift;

    # calculate the start time
    my ($year_b, $month_b, $day_b) = Add_Delta_Days( $g->{date}->{year},
                                                     $g->{date}->{mon},
                                                     $g->{date}->{mday},
                                                     (-1 * $g->{days_before}));
    my $yy_b = substr($year_b, 2, 2);
    my $time_before = $yy_b . sprintf("%02d",$month_b) . sprintf("%02d",$day_b) . "000000";
    # also put the start date into the global object
    $g->{start_date} = sprintf("%4d", $year_b) . "-" . 
                       sprintf("%02d",$month_b) . "-" . 
                       sprintf("%02d",$day_b);

    # calculate the end time
    my ($year_a, $month_a, $day_a) = Add_Delta_Days( $g->{date}->{year},
                                                     $g->{date}->{mon},
                                                     $g->{date}->{mday},
                                                     $g->{days_after});
    my $yy_a = substr($year_a, 2, 2);
    my $time_after = $yy_a . sprintf("%02d",$month_a) . sprintf("%02d",$day_a) . "000000";
    # also put the end date into the global object
    $g->{end_date} = sprintf("%4d", $year_a) . "-" . 
                       sprintf("%02d",$month_a) . "-" .
                       sprintf("%02d",$day_a);
 
    return ($time_before, $time_after);
 

}


sub get_date {

    my ($sec,   $min,   $hour,
        $mday,  $mon,   $year,
        $wday,  $yday,  $isdst) = localtime(time);

    # return our basic date values into an href
    return {
        'sec'      => sprintf("%02d",$sec),
        'min'      => sprintf("%02d",$min),
        'hour'     => sprintf("%02d",$hour),
        'mday'     => sprintf("%02d",$mday),
        'wday'     => $wday, 
        'mon'      => sprintf("%02d",$mon + 1),
        'year'     => sprintf("%4d",$year + 1900),
        'yy'       => sprintf("%02d",$year - 100),
        'yyyymmdd' => sprintf("%4d%02d%02d",$year + 1900, $mon + 1, $mday), 
        'p_yymmdd' => sprintf("%2d%02d%02d000000", $year - 100, $mon + 1, $mday), # padded date
        'r_yymmdd' => sprintf("%2d%02d%02d%02d%02d%02d", $year - 100, $mon + 1, $mday, $hour, $min, $sec), # padded date
    };
}

