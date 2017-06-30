#!/usr/bin/perl -w
#+---------------------------------------------------------------------------+
#| Copyright (C) Jacob Salomon - All Rights Reserved                         |
#| Unauthorized use of this file is strictly prohibited                      |
#| Unauthorized copying of this file, via any medium, is strictly prohibited |
#| Proprietary and confidential                                              |
#| Written by Jacob Salomon <jakesalomon@yahoo.com>                          |
#+---------------------------------------------------------------------------+
# check-dbspaces.pl - Job to check if any dbspace in the current server
# ($INFORMIXSERVER) is low on space.  This is determined by two criteria:
# 1. Is the space more than 90% full?
# 2. Does it have fewer than a 2-million MB free.
# If both answers are Yes, we need to alerted to a potential problem.
# Two exceptions, based on an assumption: The spaces containing the physical
# and logical logs.  We assume these spaces contain their respective logs and
# nothing else.  The plan is, therefore, to ignore the fullness of any dbspace
# containing one of these logs.
#
# There is an exception to the exception:  If the root dbspace fulfills the
# criteria, it will be flagged even if it contains logs.
#
# Author:   Jacob Salomon
#           jakesalomon@yahoo.com
# Released: 2014-07-01
#
# Revision History:
# 2016-05-23 Jacob Salomon:
# - Initial release: Copied code from check-space.pl and edited out most of
#   the code, leaving only the DBspace check.
# 2016-11-15 Jacob Salomon
# - After inadvertently implementing an imperfect object-oriented version
#   of DBspaces.pm, corrected the way I call dbspace-pages()
#
use strict;
use Carp;
use Data::Dumper;
use File::Basename;
use DBspaces;
use DBspaces qw(get_fs_info);
use Data::UNLreport;
#use List::Util;                # For the "in" function
#use List::MoreUtils "uniq";    # For the uniq function
use Getopt::Long;

my $ifmx_server = $ENV{INFORMIXSERVER};
my $me = basename($0);          #(To use program name w/o whole blessed path)

my $out_file = *STDOUT; # Target file descriptor/handle for messages
my %df_list;            # Hash of hashes - Each has info on a file system
                        # that contains at least one chunk if a dbspace I
                        # will display.  Key: The file system mount point
# Prepare for parsing command-line options
#
my $exitval = 0;                # Assume all will go well
my $def_pct_full_threshold = 90;    # Default threshold for %-full
my $pct_full_threshold;         # To be set by paramter or above default
my $def_min_free_pages = 1000000;   # Ignore %-full if 1-million pages are free
my $def_min_free_mb = 2000;         # Ignore %-full if 200 MB are free
my @warning_list = ();          # Accumulate warning messages here
my $warning_lc = 0;             # Count warning messages

#Getopt::Long::Configure("bundling");   # Allow single dash/single char
                                        # (Unable to get bundling to work)
#
# Define these variables for the parameter parsing:
# - $want_help                   # Need the man page
# - $sendmail                    # Default - don't send mail, send to stdout
# - $client     ;                # Client name in email subject line
# - $in_full_threshold           # User specified %-full threshold
# - $min_free_mb                 # User specified free pages to ignore %-full
#
my ($want_help, $sendmail, $client, $in_full_threshold,
    $min_free_pages, $min_free_mb);
GetOptions('help'        => \$want_help,    # Did user ask for how-to page?
           'threshold=f' => \$in_full_threshold,    # or the fullness threshold?
           'freepages=i' => \$min_free_pages,       # or a free-page minimum?
           'freemb=i' =>    \$min_free_mb,          # or a free-MB minimum?
           'mail:s'      => \$sendmail,     # Did user specify --mail?
           'client=s'    => \$client)       # Only relevant if mailing
  or die "Syntax error in command line options";

if ($want_help)
{
  usage();                      # Output usage text
  exit(0);                      # and ignore anything else
}

# Use default %-full threshold if user omitted --threshold
#
$pct_full_threshold = defined($in_full_threshold)
                    ? $in_full_threshold : $def_pct_full_threshold;

# Use default minumum required free pages if user omitted --freepages
#
$min_free_pages = defined($min_free_pages)
                ? $min_free_pages : $def_min_free_pages;
# Use default minumum required free MBytes if user omitted --freemb
#
$min_free_mb = defined($min_free_mb)
                ? $min_free_mb : $def_min_free_mb;
$client = "" unless (defined($client)); # Null client is better than undefined

# Now determine where to send the output warnings, if any
#
my $mail_target;                    # If I *do* send email, to whom?
if (defined($sendmail))             # If user requested to mail my findings     
{                                   # well, find out to whom to mail them       
  if (! $sendmail)                  # If it's an empty string i.e. user said    
  {                                 # --mail, without a target name             
    if (defined($ENV{DBA}))         # Environment had better define this        
    { $mail_target = $ENV{DBA}; }   # env variable - a target email address     
    else                            # Bad environment!                          
    {                                                                           
     carp "Require env variable DBA for --mail with no parameter. Using stdout";
      $sendmail = undef;            # And pretend --mail was not specified      
                                    # so that the output code will use
                                    # stdout   
    }                                                                           
  }                                                                             
  else {$mail_target = $sendmail; } # Hey, user *did* specify a recipient       
#
  # Regardless of how user specified mail, I can now piece together a mailx
  # command line, including the repient.
  #
    # Start piecing together the subject line for email:
    # - Client name, if supplied
    # - Informix Monitoring
    # - Server
    # - Warning
    # - Nature of the warning
    my $subject
       = sprintf("%s: Informix Monitoring: Server %s: %s",
                  $client, $ifmx_server,
                  "DBspaces, File System and Zpools Report");

    # What if no client was supplied? The line starts with awkward ": ".
    #
    $subject =~ s/^:\s//;       # Lose that leading colon: if it's there
    my $mail_cmd = sprintf("| mailx -s \"%s\" %s", $subject, $mail_target); 
    open($out_file, $mail_cmd)
      or die "Error <$!> starting mail command <$mail_cmd>";
}                                                                               
#else { $out_file = *STDOUT;}  # Not mailing - send to stdout
# So if user omitted --mail, $sendmail will remain undefined
#
dbspaces:
my $dbspace_info = dbspace_pages();    # Get right down to business!
my ($spaces, $chunks) = @{$dbspace_info}{qw(dbspaces chunks)};
# My apologies: I have not completely implemented DBspaces.pm and this
# utility in the proper object-oriented model.  -- JS

# In each @spaces entry, I have the number of free pages and the page size.
# Let's translate that into free MBytes in each space.  That is free_pages
# times size of a page (free KB) divided by 1K for MB
#
map {$spaces->[$_]{free_mb} = $spaces->[$_]{free_pages}
                            * $spaces->[$_]{pgsize} / 1024
     if (defined($spaces->[$_]{free_pages}))} 1 .. $#{$spaces} ;
$dbspace_info->expand_symlinks();            # I will need the PATH info

my @overfull = grep {   defined($spaces->[$_]{pct_full})
                     && ($spaces->[$_]{pct_full}   > $pct_full_threshold)
                     && ($spaces->[$_]{free_pages} < $min_free_pages)
                     && ($spaces->[$_]{free_mb}    < $min_free_mb) }
                    0 ..  $#{$spaces};

# So @overfull is an array of index-keys into the @{$spaces} array
#
my $nfull = @overfull;          # See how many spaces raise an eyebrow
#
# Still here: Now see if any of those have the logs.
# A simple grep won't do it for us now.
#
my @ignore_list = locate_logs($chunks); # Get list of dbspaces to ignore
foreach my $lc (@overfull)              # Loop to check each overfull dbspace
{                                       # to see if I should ignore it.
  my $space = $spaces->[$lc]{name};     # Name of the overfull dbspace

  # No need to report this full dbspace if its name appears in the ignore list.
  #
  next if (inlist($space, \@ignore_list));

  # Not on the list. Do not ignore it - report it!
  #
  $warning_list[$warning_lc++]
    = sprintf("DBspace %-18s is %6.2f%% full with %4d MB (%7d %2dK-pages) free",
              $space, $spaces->[$lc]{pct_full},
              $spaces->[$lc]{free_mb}, $spaces->[$lc]{free_pages},
              $spaces->[$lc]{pgsize});
}
#printf $out_file ("DBspaces Report:\n");    # Show the world what I found
if ($warning_lc > 0)            # If I generated even one warning
{                               # issue those warnings.  But where?
  # Send the warnings to the target stream
  #
  foreach my $warning (@warning_list)
  {
    printf $out_file ("%s\n", $warning);
  }
}
else                                # If no spaces are above %-threshold
{                                   # AND below free space thresholds
  printf $out_file ("There are no DBspaces in the alert zone.\n");
}

exit $exitval;
#
sub usage
{
  print <<EOH

This utility checks the current server ($ifmx_server) for any dbspaces that
may be getting uncomfortably full.

By default, $me generates a warning for any dbspace that is:
- Over 90% full, AND
- Has fewer than 1 million pages free.

For example:
\$ check-space
Warning: dbspace agencydbs is  90.28% full with 305633 pages free

(We can still be comfortable with that.)


Usage
  $me --help
  $me [--mail] [--client "client name"] [--threshold nn] [--freepages nnnnnn]
  $me [-m]     [-t nn]          [-f nnnnn]

--help: Display this text and exit.  Ignores other parameters
--mail:
  By default $me will display these warning messages to STDOUT. However, it
  was written to be used as a periodic (once or twice a day) cron job where
  STDOUT output is not guaranteed to be seen.  Hence, the --mail option, which
  tell $me to send email to the DBA group.
  Note: In order for this to work, the environment variable DBA *must* be
  set to the email address of a recipient (or group).  If you specify --mail
  but have not set that env variable, $me will carp and send output to
  stdout.

--mail <recipient>: Now $me will send the mail only to the repient onthe
  command line, overriding the \$DBA environment variable (if it was set)

  The subject line of the email will
  look like this:
  Server <server name>: Space monitoring has detected filling dbspace(s) 

--client "client name" This is totally optional and relevant only if the
  --mail option was chosen.  If you specify a client name, the name will
  appear in the mail subjetc line.
  NOTE: If the client name is more than one word, you must enclose the whole
  string in quotes.

--threshold nn where nn is a percentage full. If the dbspace is more than
  that percentage full AND the dbspace has fewer than some number of free
  pages, $me will generate the warning message.  (Yes, you can use a decimal
  percentage like 85.71 but you're just being silly at that point.)

--freepages nnnnn Where nnnnn is a reasonably low number.  Even a space that
  is more than (threshold)-% full will not generate a warning unless the free
  page count for the dbspace is below this count.  For example, a dbspace with
  80 chunks may be 95% full but if it has 2 million pages free, we are not in
  any impending danger of having the space fill up.  The default free-page
  count is 1 million. You can set it lower or higher using the --freepages
  option.

--freemb nnn Where nnn is a reasonably low number.  Even a space that is more
  than (threshold)-% full will not generate a warning unless the free MB count
  for the dbspace is below this count.  For example, a dbspace with 80 chunks
  at 2GB each may be 95% full but if it has a million MB free (i.e. ~ a GB),
  we are not in any impending danger of having the space fill up.
  
  The default free-MB count is 2000, that is a million 2K pages. You can set it
  lower or higher using the --freemb option.

Example:
\$ check-space --mail --client "Chronix" --freemb 2000 --threshold 85.71
(Yes, being silly about the threshold.)

Run on a server named yummy, it generates an email with the subject line:
  Chronix: Informix Monitoring: Server yummy: Warning: DBspace(s) with low free space

The message body contains the following report:

DBspace fpdbs          is  96.86% full with  963 MB ( 493508  2K-pages) free
DBspace rtrr_01        is  95.37% full with 1328 MB ( 679958  2K-pages) free
DBspace rtrr_02        is  95.37% full with 1328 MB ( 679958  2K-pages) free
DBspace rtrr_03        is  95.37% full with 1328 MB ( 679958  2K-pages) free
DBspace rtrr_04        is  95.37% full with 1328 MB ( 679958  2K-pages) free
DBspace rtrr_05        is  95.37% full with 1328 MB ( 679958  2K-pages) free
DBspace rt16_dbs3      is  92.16% full with 1530 MB (  97947 16K-pages) free

---
EOH
}
#
__END__

=pod

=head1 Program Name

check-dbspaces (or check-dbspaces.pl if you have not create the symlink)

=head2 Author

  Jacob Salomon
  jakesalomon@yahoo.com

=head2 Dependencies

=over 2

=item * Data::UNLreport.pm: A Perl module that formats test output into neat
columns for reports.  This is available from CPAN at L<Data::UNLreport.pm
|https://metacpan.org/pod/Data::UNLreport>

=item * DBspaces.pm: The Perl module with the functions and methods used by
all of the utilities in this package.  Of course, it comes with this package.
At this time available only on IIUG, not on CPAN.  Note that this module
also depends on modules DBI and DBD::Informix; see the perldoc on DBspaces.pm
for more information on that.

=back

=head2  Environment Variables

DBA - a list of email addresses to receive the warnings by email.

=head2 Some preliminary discussion about this utility

This utility, check-dbspaces, checks the fullness of DBspaces and issues a
warning about any spaces that are more full than some arbitrary percentage.
By default, that default is 90%.

However, a very large DBspace be 95% full and still have millions of pages free
and hence, far from being in danger of filling in the near future.  In such a
case, we would be raising a false alarm.  For that reason there is another
threshold, actually two: The number of free pages remaining and the number for
free MBytes remaining in the DBspace. (A bit of feature creep in there, I
think. ;-) By default, the free page count to generate a warning is one million
pages while the free MB count is set at 2 million. (Either one is a crude
approximation of 2GB.)  Of course, there will command-line options to override
these defaults.

This utility was written with the intent of using it in a cron job
directly.  Hence it has options dealing with an e-mail recipient and
subject line.

=head2 Synopsis of basic options

 check-dbspaces --help      # Generate help text; suggest you pipe to more
 check-dbspaces --threshold <nn.nn> {--freepages <nnn> | --freemb <nnn>}

E-mail options:
 --mail <recipient>
 --client "client name" If you do send email, this will be part of the
 subject line, for clarity.

If you omit the --email option, then the report goes to STDOUT. If you
specify --email but omit the recipient, it will send to the use list inthe
environment variable $DBA.  If you did not set this variable,
check-dbspaces will carp about it and output to STDOUT.

=over 2

=item * --threshold I<nn.nn> Where you specify a decimal number.  However, I
agree it would look silly if you specified a threshold of 87.314% full.
(Feature creep again.  Guilty ;-) The default is 90%.

=item * --freepages I<nnnn> where nnnn is a reasonably low number.  As explained
above, a 95% fullness does not herald imminent danger of filling up a DBspace;
there may still be millions of free pages. Hence, the DBspace must actually
have a low free-page count (or free MB count; see next option) in addition to
the high %-full ratio.  The default of a million pages is not reasonably low
in the author's opinion, especially if the DBspace in question has 16K pages.

=item * --freemb I<nnnn> where nnnn is a reasonably low number.  And, like
the above option, the default million-page threshold is not reasonably low,
unless you run insane batch processes that load a gadzillion rows. (Which
B<has> been known to happen.)

It does seem impractical to specify both --freepages and --freemb.  Hence
the {option | option} notation.

=back

=head2 Example

 $ check-space --mail --client "Chronix" --freemb 2000 --threshold 85.71
 (Yes, being silly about the threshold.)

Run on a server named yummy, it generates an email to the users listed in the
$DBA environment variable, with the subject line:

  Chronix: Informix Monitoring: Server yummy: Warning: DBspace(s) with low free space

The message body contains the following report:

 DBspace fpdbs          is  96.86% full with  963 MB ( 493508  2K-pages) free
 DBspace rtrr_01        is  95.37% full with 1328 MB ( 679958  2K-pages) free
 DBspace rtrr_02        is  95.37% full with 1328 MB ( 679958  2K-pages) free
 DBspace rtrr_03        is  95.37% full with 1328 MB ( 679958  2K-pages) free
 DBspace rtrr_04        is  95.37% full with 1328 MB ( 679958  2K-pages) free
 DBspace rtrr_05        is  95.37% full with 1328 MB ( 679958  2K-pages) free
 DBspace rt16_dbs3      is  92.16% full with 1530 MB (  97947 16K-pages) free

---

=cut
