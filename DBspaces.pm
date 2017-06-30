#!/usr/bin/perl -w
#+---------------------------------------------------------------------------+
#| Copyright (C) Jacob Salomon - All Rights Reserved                         |
#| Unauthorized use of this file is strictly prohibited                      |
#| Unauthorized copying of this file, via any medium, is strictly prohibited |
#| Proprietary and confidential                                              |
#| Written by Jacob Salomon <jakesalomon@yahoo.com>                          |
#+---------------------------------------------------------------------------+
# DBspaces.pm
#   Perl module to obtain a summary of disk space used by all dbspaces in
#   the current Informix instance
#
# Author:   Jacob Salomon
#           JakeSalomon@yahoo.com
# Date:     2014-06-25 (Initial)
# Release:  1.6
# ---------------------------------
# Release history:
# Release 1.0:
#   Initial release
# Release 1.1: 2014-10-01
#   - Minor fix: Added the chunk number as a member {item} of each array
#     entry.  This is to facilitate sorting by the caller. And while I was at
#     it, I added the dbspace number to each member of the dbspaces array
#   - Added longer comments to function dbspace_pages() to explicitly name
#     the member items of both hashes.
# Release 1.2: 2015-02-24
#   - Added function order_chunks() to get the true order of chunks within
#     a DBspace
# Release 1.5: 2015-05-21
#   - Moved validate_file() and validate_symlink() subroutines out of the
#     utilities that use them: new-dbspace.pl and add-chunk.pl.  Of course
#     they were effectively identical in function already; I merely smoothed
#     over some minor differences.
# Release 1.6: 2015-05-27
#   - Added functions dbspace_inuse(), raw_file_inuse() and symlink_inuse()
#   - Some debugging of code that had never been exercised by new-dbspace.pl
#     and likely some of the other utilities.
# Release 1.7: 2016-11-15
#   - First attempt to make this module object oriented.  Imperfect but at
#     least it's a start.
# Release 1.71: 2017-03-21
#   - Changed the behavior of dbspace_inuse(): Instead of returning a 1 or
#     0, it now returns the DBspace number if the DBspace exists.  Still
#     returns 0 otherwise.
# Release 1.72: 2017-05-09
#   - Changed symlink_path() to call readlink() instead of abs_path(). This
#     would allow for the display of a complete chainof symlinks.
# Release 1.73: 2017-06-13
#   - Added code into bBEGIN block to catch if the server is not running.
#     That is, if the word Version does not appear in the output of
#     onstsat -
#----------------------------------
#
package DBspaces;

use strict;
use Carp;
use Data::Dumper;
use Pod::Usage;
use Cwd 'abs_path';
use File::Basename;
use Scalar::Util qw(looks_like_number);

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(dbspace_pages large_chunks_enabled
                 dbspace_totals locate_logs round_down_size round_up_size
                 symlink_path symlink_chain expand_symlinks next_file_num
                 inlist dbspace_inuse raw_file_inuse symlink_inuse);
our @EXPORT_OK = qw(dbspace_defaults get_fs_info my_df order_chunks
                    validate_file validate_symlink);
my %defaults;

our $big_chunks_enabled = undef;        # This must be set by dbspace_pages().
our $UID = $<;                          # UID and GID of this user process
our $GID = $(;
our $mirror_flag_pos = 64;      # In onstat -d output, where do the Mirror
our $blob_flag_pos   = 66;      # and Blob-space flags appear in each line?
                                # Similarly where do the S, T, U for SBspace,
                                # Temp space or Temp-SBspace, respectively
#
BEGIN
{
# $DB::single = 1;  # Uncomment this to debug BEGIN block
  %defaults
  = (
     symlink_path     => "/ifmxdev",    # Top directory for symlinks to
                                        # chunk files
     symlink_sub_path => "",            # Subdirectory to locate those symlinks
     primary_path     => "/ifmxdevp",   # Top directory for raw chunk files,
                                        # targets of above symlinks
     primary_sub_path => "",            # Subdirectory for those raw 
     mirror_path      => "/ifmxdevm",   # Top dir for raw mirror chunk files
     mirror_sub_path  => "",            # Subdir for those raw mirror files
     chunk_decimals   => 3,             # Decimal places for chunk number
                                        # within a DBspace; Top value: 999
     raw_decimals     => 5,             # Decimal paces for file number
                                        # within a host/zone
     chunk_size       => 2097150,       # 2GB - 1 2K page
     data_page_size   => 2,      # That is 2K, of course. For -k option
     blob_page_size   => 1       # For -g option on blob pages; page multiplier
    );

  # Those above are the default defaults.  However, there is a configuration
  # file to set them and that should be used rather than the above.
  #
  my $cfg_file = "/ifmx-work/dbspace-defaults.cfg";

  # Ah, but there may be an environment variable for that..
  #
  my $CFG_ENV = "DBSPACE_DEFAULTS";
  $cfg_file = $ENV{DBSPACE_DEFAULTS}
    if (defined($ENV{DBSPACE_DEFAULTS}));   # Override default location
  
  # If that config file exists, use those setting instead of my hard-coded
  # defaults.
  #
  my $cfg_fd;                       # File descriptor for config file
  my $open_ok = 1;                  # Assume, for now, we can read the file
  if (-f $cfg_file)                 # So if the config file exists
  {                                 # read the setting from there.
    open ($cfg_fd, "<", $cfg_file)
      or do
         {
           carp "Error <$!> opening defaults file <$cfg_file>;
                 using hard-coded defaults";
           $open_ok = 0;            # Well, htere goes that assumption..`
         }

  }
  else {$open_ok = 0;}              # Kinda nothing to open
#
  if ($open_ok)
  {
    while (my $cfg_line = <$cfg_fd>)    # Start reading the file and
    {                                   # resetting my defaults accordingly
      chomp($cfg_line);
      $cfg_line =~ s/#.*//;             # Remove comment from end of the line
      $cfg_line =~ s/\s+$//;            # Remove any trailing white spaces
                                        # Note: I may have emptied the line
      next if ($cfg_line eq "");        # Skip empty line
      my @cfg_split = split /\s+/, $cfg_line;    # Now I have it in
                                                # <variable value> layout
      $defaults{$cfg_split[0]} = $cfg_split[1]; # Overwrite hard-code default
    }
  }
  close ($cfg_fd) if ($open_ok);    # (Put away toys we're not playing with)

  # This concludes our dabbling in default values.

  # Now what release are we running? It makes a difference for the positions
  # of some flags.
  #
  my $version_cmd = "onstat - | grep Version";  # I want only that one line
  my $version_line = `$version_cmd`;            # This gets the line
  chomp($version_line);
  die "No can do; I don't believe server $ENV{INFORMIXSERVER} is running\n"
    if ($version_line eq "");
  my @split_version = split(/\s+/, $version_line);
  my @ver_posns = grep {$split_version[$_] eq "Version"}
                       (0 .. $#split_version);
  my $ver_pos = $ver_posns[0];          # Pull my location from 1-item array
  my $full_version = $split_version[++$ver_pos];
  my @split_ver = split(/\./, $full_version);   # Separate parts of version
  my $version = $split_ver[0];                  # Either 11 or 12 as of today
  if ($version == 11)
  {
    ($mirror_flag_pos, $blob_flag_pos) = (63,66);
  }
  elsif ($version == 12)
  {
    ($mirror_flag_pos, $blob_flag_pos) = (64,66);
  }
  else { die "This package needs adaptation to release $version"; }
}
#----------------------------------------------------------------------------
# dbspace_defaults() - Tells the caller what the default values are for the
# above settings.  Returns hash-pointer
#
sub dbspace_defaults
{
  return \%defaults;
}
# I am considering adding a set of closures - one 1-liner function to
# return each of the above defaults, rather than the whole structure. But
# getting the functionality right is the higher priority. Another day..
#
#-----------------------------------------------------------------------
# dbspace_pages() - Funtion to extract and tally page totals and percentages
#                   for all dbspaces in the current server
# Parameters: None, although the the behavior depends heavily on the
#             current server environment
# Returns: A hash with a pair of references:
# - {dbspaces}: A reference to an array of hashes, one row per dbspaces, with
#               information on each DBspace in the current server
# - {chunks}:   A reference to an array of hashes, one row per chunk, with
#               information on each chunk in the current server
# What informatio is that?
# The fields in the {dbspaces} hash are:
#   o {address}     #(Not necessarily useful)
#   o {dbs_num}
#   o {fchunk}
#   o {nchunks}
#   o {pgsize}      # In KB (onstat -d gives this in bytes)
#   o {dbs_type}    # Blob space, temp space, sbspace etc
#   o {mirrored}    # M if mirrored, N otherwise
#   o {name}
#   o {pages}
#   o {free_pages}
#
# The fields in the {chunks} hash are:
#   The fields in the chunk hash are:
#   o {address}     #(Not necessarily useful)
#   o {chunknum}
#   o {dbsnum}
#   o {dbsname}     # Need to derive this from dbspaces entry
#   o {offset}      # Offset into the file path for the chunk. (Normally 0)
#   o {size}        # Size, in pages, of the chunk. (Multiply by pgsize)
#   o {free}        # Number of free pages
#   o {symlink}
#   o {is_first}    # 1 (Yes) or 0 (no): Us this chunk first in its dbspace?
#   o {m_offset} and {m_path} if the corresponding dbspace is mirrored
#
# Side effect:
# - This will set the semi-global variable $big_chunks_enabled
#
sub dbspace_pages
{
  my $spaces = {};  # Just to set the atmosphere correctly: This is the
  bless $spaces;    # object I will return to the user.

  # Some preliminary setup:
  #
  my $def_page_size  = $defaults{data_page_size};   # Default page size: 2K?
  my $ifmx_server = $ENV{INFORMIXSERVER};
 #my $UID = $<;                     # $UID not available in this Perl release
  my $hex_pattern =  qr/^[0-9a-f]+\s+/; # Recognize hex address when I see one
  my $addr_pattern = qr/^[0-9a-f]+/;    # Same idea but without the whole line
  my $dec_pattern = qr/^\d+$/;          # Match a regular decimal number
  my $run_user = getpwuid($UID);    # Name of user running this. Need not be
                                    # informix but BLOB info will be accurate
                                    # because informix may use update option.
  my $onstat_cmd = ($run_user eq "informix")
                 ? "onstat -d update" : "onstat -d";
  $onstat_cmd .= " |";              # Command line to open for input
  my $onstat;                       # The file descriptor
  open ($onstat, $onstat_cmd)
    or die "Unable to run <$onstat>: Error <$!>";
# 
  # Still alive: Set up some basics:
  #
  my ($in_dbspaces, $in_chunks) = (0, 0);   # Not in either section yet
  my $onstat_buf;               # Buffer to read lines into
  my $dbspaces;                 # ->Arrays to be filled in with array and
  my $chunks;                   # ->chunk info as I read through the lines
  my $line_count = 0;           # Debugging aid
  my $high_dbspace = 0;         # So I'll know where to stop display loop

  while ($onstat_buf = <$onstat>)
  {                             # Skim over all lines until I see Dbspaces
    chomp $onstat_buf;          # (Lose line terminator)
    #D-printf("Line %3d: <%s>\n", ++$line_count, $onstat_buf);
    last if ($onstat_buf =~ /^Expanded/); # Last output line says if "Expanded
                                          # chunk capacity" is enabled
    if (($in_dbspaces == 0) && ($in_chunks == 0))   # In neither section yet
    {                                               # Check for section change
      if ($onstat_buf =~ /^Dbspaces/)
      {
        $in_dbspaces = 1;       # Indicate I'm in DBspaces section
        next;                   # but nothing else to do now
      }
    }
    # OK, at some time I entered the DBspaces section.  But not forever..
    #
    if ($onstat_buf =~ /^Chunks/)   # Entering chunks section
    {
        $in_dbspaces = 0;           # Not in dbspaces section anymore;
        $in_chunks   = 1;           # We're in chunks territory now
        next;                       # but nothing else to do this line
    }
 
    # So I know I'm in one of the two sections.  Which one?
    #
    if ($in_dbspaces)           # So suppose I *am* in the dbspaces section
    {                           # Not every line is useful to me
      next unless ($onstat_buf =~ $hex_pattern);    # Skip anything that is not
                                                    # a dbspace info line
      #D-printf("DBspace: <%s>\n", $onstat_buf);
      my @dbs_info = split /\s+/, $onstat_buf;
      next unless (   ($dbs_info[0] =~ $addr_pattern)
                   && ($dbs_info[1] =~ $dec_pattern ) );  # Skip extra info
      my $dbsnum = $dbs_info[1];        # Get dbspace number as array index
      $high_dbspace = $dbsnum if ($dbsnum > $high_dbspace); # Track dbspace #
      @{$dbspaces->[$dbsnum]}{qw/address fchunk nchunks pgsize name/}
                = @dbs_info[          0,     3,      4,     5,   -1];
                                        # Get available dbspace info
      $dbspaces->[$dbsnum]{dbs_num} = $dbsnum;  # Save the dbspace number also
      $dbspaces->[$dbsnum]{pgsize} /= 1024; # Change from bytes to k-bytes
 # 
      # Now what kind of dbspace is it? Data (vanilla), Blob, Temp, SBspace,
      # or Temp Sbspace? Since that has no clear-cut field number, I need to
      # use a brute-force substring on the data line.
      #
      $dbspaces->[$dbsnum]{dbs_type} = substr($onstat_buf, $blob_flag_pos, 1);
      $dbspaces->[$dbsnum]{mirrored} = substr($onstat_buf, $mirror_flag_pos,1);
  
      # Initialize these tallies - they are the main reason for this utility
      #
      $dbspaces->[$dbsnum]{pages}      = 0;
      $dbspaces->[$dbsnum]{free_pages} = 0;
  
      next;                     # Done with this dbspace line
    }

    if ($in_chunks)               # So suppose I *am* in the chunks section
    {                             # Not every line is useful to me
      next unless ($onstat_buf =~ $hex_pattern);  # Skip anything that is not
                                                  # a chunk info line
      #-printf("\nChunk: <%s>\n", $onstat_buf); #DEBUG
      my @chunk_info = split /\s+/, $onstat_buf;
      next unless (   ($chunk_info[0] =~ $addr_pattern)
                   && ($chunk_info[1] =~ $dec_pattern ) ); # Skip other lines
      my $chk_flags = $chunk_info[-2];  # Flags string is next-to-last on line
      my $pm = substr($chk_flags, 0, 1); # See if chunk is primary or mirror
      my $chknum = $chunk_info[1];  # Catch an array index
      if ($pm eq "P")               # If this is a primary chunk
      {                             # then all the basic info is here
        @{$chunks->[$chknum]}{qw/address dbsnum offset size free symlink/}
                  = @chunk_info[0,2,3,4,5,-1];
        my $dnum = $chunks->[$chknum]{dbsnum};  # Use dbspace number to get
        $chunks->[$chknum]{chunknum} = $chknum; # Store chunk number as well
        @{$chunks->[$chknum]}{qw(  dbsname dbs_type pgsize)}
        = @{$dbspaces->[$dnum]}{qw(name    dbs_type pgsize)};
        $chunks->[$chknum]{is_first}    # Is this chunk first in its DBspace?
          = ($chknum == $dbspaces->[$dnum]{fchunk}) ? 1 : 0;
    
        # Now the {pages} field may not mean exactly that number. If it is a
        # blob-space chunk, it means number of default-size pages. Need some
        # adjustment so that it can be compared with the free-page count, which
        # onstat -d *does* present in terms of blob pages.  Also, for a blob-
        # space chunk, there may be a ~ in front of the free count.
        #
        $chunks->[$chknum]{free} =~ s/\~//;         # Remove ~ from free count
        if ($chunks->[$chknum]{dbs_type} eq 'B')    # Adjust page count for
        {                                           # blobspace chunk
          $chunks->[$chknum]{size}
            = ($def_page_size * $chunks->[$chknum]{size}) # KB in blob chunk
            / $chunks->[$chknum]{pgsize};                 # / KB in a blob page
        }                   # Yield: [Potential] number of blob pages in chunk

        # And now that I have the page count and free page count properly
        # adjusted, I can tally them for the appropriate dbspace:
        #
        $dbspaces->[$dnum]{pages}      += $chunks->[$chknum]{size};
        $dbspaces->[$dnum]{free_pages} += $chunks->[$chknum]{free};
        #-printf("Before-mirror info on chunk[%d]:\n", $chknum);  #DEBUG
        #-print Dumper($chunks->[$chknum]);                       #DEBUG
      }
#
      elsif ($pm eq "M")        # If this is mirror chunk then all I need is
      {                         # the file/device path and the offset
        @{$chunks->[$chknum]}{qw/m_offset m_path/}
                   = @chunk_info[      3,      -1];
        #-printf("With-mirror info on chunk[%d]:\n", $chknum);    #DEBUG
        #-print Dumper($chunks->[$chknum]);                       #DEBUG
      }                         #(All other fields I already have from primary)
      else                      # Hey! It's gotta be one or the other!
      { die "Chunk[$chknum] is neither mirrored nor non-mirrored";}
    }
  }

  # Exit condition: The word "Expanded", which tells me if the "expanded
  # chunks" feature is enabled or not.
  #
  $big_chunks_enabled = (index("disabled", $onstat_buf) < 0) ? 1 : 0; 
                                # Explanation: If I don't find the word     
                                # "disabled" in that last line, then         
                                # expanded chunk capacity is indeed enabled 

  close $onstat;                # For neatness, put away my toys.

  # Finished tallying the page counts of all dbspaces. A bit more
  # adjustment is needed before it's all ready for presentation
  
  for (my $lc = 1; $lc <= $high_dbspace; $lc++) # Loop to calculate the
  {                                             # %-full of each dbspace
    next unless (defined($dbspaces->[$lc]{name}));  #(In case of gap in
                                                    # dbspace numbers)
    my $ref = \%{$dbspaces->[$lc]}; # (Cleaner-looking code with reference)
    $ref->{pct_full} = 100.0
                     * ($ref->{pages} - $ref->{free_pages}) # Occupied pages
                     / $ref->{pages};                       # over total pages
  } 
  @{$spaces}{qw(dbspaces chunks)} = ($dbspaces, $chunks);
  return $spaces;               # Return the references to (otherwise unnamed)
                                # arrays of dbspace and chunk info hashes.
}
#
# order_chunks(): Reorder the chunks within each DBspace so that they
#                 appear in order of when they were created
# Parameters:
# - References to the onstat -d structure
#
# Returns:
#   Well, nothing, really. But it has added a couple of fields to each
#   chunks entry:
#   - {next_chunk}
#   - {chunk_order}
#
sub order_chunks
{
# my ($dbspaces, $chunks) = @_;         # Get both array references
  my $self = shift;
  my ($dbspaces, $chunks) = @{$self}{qw(dbspaces chunks)};
  die "Subroutine order_chunks() requires both array references"
    unless (   (ref($dbspaces) eq "ARRAY")
            && (ref($chunks)   eq "ARRAY"));

  my $oncheck_cmd = "oncheck -pr |";    # Prepare for reserved pages printout
  my $oncheck;                          # File descriptor for that command
  open ($oncheck, $oncheck_cmd)
    or die "Unable to run <$oncheck_cmd>; Error <$!>";
  my $in_chunk_section = 0;     # My scan is not in the chunk section yet

  # The following "while" loop sets up a linked-list of chunk data for each
  # dbspace.  This is within the @$chunks array.
  #
  my $cur_chnum;        # Current chunk num in chunks reserved page. Once set,
                        # keep the value through all info lines for this chunk
  while (my $oncheck_buf = <$oncheck>)
  {
    $oncheck_buf =~ s/\s+$//;       # Trim trailing blanks, if any
    next if ($oncheck_buf eq "");   # Skip empty lines
    if ($oncheck_buf =~ /Validating PAGE_1PCHUNK/)  # Start of chunk section
    {
      $in_chunk_section = 1;        # Hey, we're into it now
      my $dummy = <$oncheck>;       # Read "Using primary" line to discard it
      next;
    }
    next unless ($in_chunk_section);    # Otherwise, not interested
    if ($oncheck_buf =~ /Validating/)   # This indicates the start of output
    {                                   # for the next reserved page
      $in_chunk_section = 0;            # So no longer in Chunks reserved page
      last;                             # Stop processing that output now
    }
#
    # OK, any lines I encounter now are relevant to my scan
    #
    my @chk_fields;                 # Array for splitting chunk info lines
    if ($oncheck_buf =~ /Chunk number/)
    {
      @chk_fields = split(/\s+/, $oncheck_buf);     # Split by white space
      $cur_chnum = $chk_fields[-1]; # Chunk number is last datum on that line

      # Next step is subtle: Initially assume there is no next chunk for this
      # chunk [in thie dbspace]. So set {next_chunk} = -1.  Then, if a "Next
      # chunk" line *does* appear for this chunk, we will change from -1 to
      # that Next chunk number.
      # 
      $chunks->[$cur_chnum]{next_chunk} = -1;
    }
    elsif ($oncheck_buf =~ /Next chunk in DBspace/) # So this chunk *does* have
    {                                               # a Next: Set it in there
                                                    # instead of the -1
      @chk_fields = split(/\s+/, $oncheck_buf);     # Split by white space

                                # Next chunk number is last datum on that line.
      $chunks->[$cur_chnum]{next_chunk} = $chk_fields[-1]; # Overwrite that -1
    }
    # Any other line in the chunks section can be ignored
  }

  close $oncheck;                   # Everything I need is in memory already

  for (my $dlc = 0; $dlc <= $#{$dbspaces}; $dlc++)
  {
    next unless (defined($dbspaces->[$dlc]{fchunk}));   # Skip missing dbspaces

    my $chunk_order = 0;        # The value I will insert into {chunk_order}
    # Now start traversing the linked-list of chunks attached to this dbspace
    #
    for (my $rel_chk_num = $dbspaces->[$dlc]{fchunk};
            $rel_chk_num > 0;       # Have not fallen off end of linked-list
            $rel_chk_num = $chunks->[$rel_chk_num]{next_chunk}) # -> next chunk
    {                                                           # in DBspace
      $chunks->[$rel_chk_num]{chunk_order} = ++$chunk_order;    # Bump position
    }
  }

  return(1);                    # Act successful
}
#
#----------------------------------------------------------------------------
# Related function: large_chunks_enabled():
# No parameters.
# Prerequisite:
# - This function may be called only after calling dbspace_pages(); otherwise
#   the variable it returns is undefined.
# Returns:
# - The value in the variable $big_chunks_enabled
#
sub large_chunks_enabled
{
  if (defined($big_chunks_enabled))
  {     return $big_chunks_enabled;}
  else
  {
    my $fun_name = (caller(0))[3];  # Name of this function
    die "You must call dbspace_pages() before calling $fun_name()";
  }
}
#
# dbspace_totals(): Function to go through the array I just calculated
# above and return one more row - A total of chunk counts, page counts, and
# cumulative %-full of all dbspaces
# Parameter:
# - Reference to array of dbspace info such as was generated in dbspace_pages()
# Returns:
# - Reference to a hash of data that looks like the dbspace hash but has
#   totals counts and percentage
#
sub dbspace_totals
{
  my $dbspaces = shift();       # Get that array reference parameter
  my $totals;                   # Hash reference that I will return
  my $total_pages = 0;          # Keep tallies as I chase up the dbspaces
  my $total_freep = 0;
  my $total_chunks = 0;

  for (my $lc = 1; $lc <= $#{$dbspaces}; $lc++) #(There is no dbspace[0])
  {
    next unless (defined($dbspaces->[$lc]{name}));  # In case of gap in
                                                    # dbspace numbers
    my $ref = \%{$dbspaces->[$lc]}; # (Cleaner-looking code with reference)
    $ref->{pct_full} = 100.0
                     * ($ref->{pages} - $ref->{free_pages}) # Occupied pages
                     / $ref->{pages};                       # over total pages
    $total_chunks += $dbspaces->[$lc]{nchunks};
    $total_pages  += $dbspaces->[$lc]{pages};       # Keep tallies, as promised
    $total_freep  += $dbspaces->[$lc]{free_pages};  # above
  }
  # Calculate total percent-full over all the dbspaces in the server
  #
  my $total_pct_full = 100.0 * ($total_pages - $total_freep) / $total_pages;
  @{$totals}{qw/name dbs_type pgsize nchunks pages free_pages pct_full/}
            = ("Totals:", "-", 0,
               $total_chunks, $total_pages, $total_freep, $total_pct_full);
  return $totals;
}
#
# locate_logs(): Function to locate the dbspaces in which the physical or
# logical logs reside.
# Parameters:
# - Reference to the array of @$chunks information from dbspace_pages()
# Returns:
# - An array of dbspaces names.
#
sub locate_logs
{
  my $chunks = shift();         # Get my own -> chunks array
  my @ignore_list = ();         # List of dbspaces to not care if they're full
  my $ignore_lc = 0;            # Array counter/index for above list

  # For logical logs, each line starts with a hex address followed by spaces
  #
  my $addr_pattern = qr/^[0-9a-f]+\s+/;
  my $chunk_offset_pattern = qr/^\d+:\d+$/;
  my $onstat_cmd = "onstat -l |";
  my $log_section = "";             # Two sections to onstat -l output
  open (my $onstat, $onstat_cmd)
    or die "Error <$!> running command <$onstat_cmd>";
  while (my $onstat_buf = <$onstat>)
  {
    chomp($onstat_buf);             # As always - lose the line separator
    $onstat_buf =~ s/^\s+//;        # Trim off leading spaces
    next unless($onstat_buf);       # Ignore empty lines

    # Now what section am I in? Pysical log, logical log, or neither
    # If neither: Is this a chance to change state?
    #
    if (!$log_section)              # If still (or again) in limbo
    {
      if ($onstat_buf =~ /^phybegin/)
      {
        $log_section = "physical";  # This line introduced the physical section
        next;                       # but the data I want is on next line
      }
      elsif ($onstat_buf =~ /^address/)
      {
        $log_section = "logical";   # This line is just before the lines
        next;                       # describing logical logs.
      }
    }
    next unless($log_section);      # If I have not set $log_section,
                                    # nothing more to do here.
#
# locate_logs() Continued
    # So I am in a section for either type of log.
    #
    my ($chunk, $offset);
    my ($dbs_name, $dbs_num);
    if ($log_section eq "physical") # The data of interest in the pysical
    {                               # section is in this one line:
      my $dummy;                    # Just to catch the rest of a line
      ($chunk, $dummy) = split(":", $onstat_buf);   # Just want chunk number

      # No need to search the chunks array for this chunk number because
      # the chunk number is the index into the array.
      #
      ($dbs_name, $dbs_num) = @{$chunks->[$chunk]}{qw/dbsname dbsnum/};
      $ignore_list[$ignore_lc++] = $dbs_name;   # Not root: Add to ignore list.
                                                # And yes, it may get repeated
      # But for the the physical log, that's the only line; once I'm done
      # with this one, I am done with the physical log section
      #
      $log_section = "";            # Nullify it again - Back to limbo
      next;
    }
    elsif ($log_section eq "logical")   # Line's layout is quite different
    {                                   # for logical log.
      next unless ($onstat_buf =~ $addr_pattern);   # Avoids extraneous line(s)

      # OK, if have a logical log description line. Pull the chunk
      # information out of it, which leads me to the dbspace
      #
      my @log_array = split(/\s+/, $onstat_buf);
      next unless(@log_array == 8);    # This check & next skip human lines
      next unless ($log_array[4] =~ $chunk_offset_pattern);
      ($chunk, $offset) = split(":", $log_array[4]);    # Isolate chunk #
      ($dbs_name, $dbs_num) = @{$chunks->[$chunk]}{qw/dbsname dbsnum/};
      next if ($dbs_num == 1);          # As before, never ignore root dbspace
      $ignore_list[$ignore_lc++] = $dbs_name; # Not root: Add to ignore list.
    }
    # Else - nothing to do - skip to next line
  }
  close ($onstat);

  # Now, the there may be many repeated entries of any dbspace name in the
  # list. I only want one of each unique dbspace name. What to do??
  #
  @ignore_list = uniq(@ignore_list); # Eliminate the duplicate entries

  return @ignore_list;              # Return These are the spaces with logs
}
#
# symlink_chain() - Function to expand a symbolic link into a chain of symlinks
#                 until it reaches a file that is not a symlink i.e. a raw file
# Parameter:
# - A file name
# Returns:
# - A string in the form (path)->(path)->..->(path) Where the last path in
#   the chain is a raw file path, no a symlink.
#
sub symlink_chain
{
  my $fname = shift(@_);            # Get my parameter
  die "symlink_chain() called with null or undefined parameter"
    if ( !defined($fname) || ! $fname);
  my $chain = $fname;
  my $next_link = readlink($fname); # Start with first link target
  while (defined($next_link))       # Readlink will return "undef" if its para-
  {                                 # ter has no further link
    $chain = $chain . "->" . $next_link;    # Append latest-found link to chain
    $next_link = readlink($next_link);      # Chase it another step.
  }
  return $chain;
}
#----------------------------------------------------------------------------
# symlink_path() - Function to just give me the final destination of the
#                  chain of symbolic links.
# Parameter:
# - A file name, presumably a symbolic link
# Returns:
# - The path of the target file of the symbolic link.
#
sub symlink_path
{
  my $sname = shift(@_);            # Get my parameter
  die "symlink_path() called with null or undefined parameter"
    if ( !defined($sname) || ! $sname);
  #my $rpath = abs_path($sname);
  my $rpath = readlink($sname);
  return $rpath;
}
#
# expand_symlinks() - Subroutine to chase down the chunks list and fill two
#                     more fields: {raw_file} and {sym_chain}, using the output
#                     of symlink_path() and symlink_chain(), defined above.
#                     For any chunks that are mirrored, it also adds fields
#                     {mraw_file} and {msym_chain}
# Parameter:
# - Reference to the DBspaces object (of dbspace_pages() fame)
# Returns
# - A reference to the chunks array in the DBspaces object
#
sub expand_symlinks
{
  my $self = shift;                         # Get our object
  my $chunks = $self->{chunks};
  for (my $clc = 1; $clc <= $#{$chunks}; $clc++)    # Chunk array is here for 
  {                                                 # some enhancement:
    if (defined($chunks->[$clc]))           # (Watch for missing elements)
    {
      next unless defined($chunks->[$clc]{symlink});   #(and dummy elements)
      $chunks->[$clc]{raw_file}  = symlink_path($chunks->[$clc]{symlink});
      $chunks->[$clc]{sym_chain} = symlink_chain($chunks->[$clc]{symlink});
      
      # What if chunk is mirrored?
      #
      if (defined($chunks->[$clc]{m_path}))
      {
        $chunks->[$clc]{mraw_file}  = symlink_path($chunks->[$clc]{m_path});
        $chunks->[$clc]{msym_chain} = symlink_chain($chunks->[$clc]{m_path});
      }
    }
  }
  return $chunks;
}
#
# Function validate_file()
# Make sure the file name fits all proper criteria for the "raw" file of an
# IDS chunk
# Parameters:
# - File name
# - -> stats hash for the file.  If not supplied, I'll get it myself.
# Returns:
# 1 for OK file, 0 for bad file.
# Does all necessary carping
#
# Required conventions for our orderly environment:
# - If the file exists, it may be a raw character device file, with few
#   naming conventions within user control.  However, in our environment we we
#   using cooked files only so this situation will not be considered now.
#   o If the file does not exist, the function should not have been called
#     and will generate an error message.
# Assuming it is a cooked file:
# - The base name must be file.nnnn, where nnnn is a 4-digit, 0-padded integer.
#   (Yes, this does pose an oh-so-oppressive limit of 9,999 chunks on the
#   server's host machine.)
# - Its top level directory must be named /ifmxdev or match /ifmxdev* e.g.
#   /ifmxdev_in2
# - Its second-level directory must be name "files"
# - Of course, it may or may not be in use already; that is not the purpose
#   of this subroutine
#
# These conventions make it easy to generate new file names as needed.
#
sub validate_file
{
  my $fname = shift();          # Get the file name to validate
  my $stats = shift();          # and reference to the passed stats hash
  my %stats_h;                  # In case I need to get it myself
  my $rval = 1;                 # Assume all will be OK.

  if (! ( (-e $fname) && (-f $fname) ) )    # File had better exist and
  {                                         # must be a regular file
    carp "<$fname> does not exist as a regular file";
    $rval = 0;                  # All is *not* OK
    goto done_here;
  }

  # We now know it is a regular file. Make sure we have a handle on its
  # file stats.
  #
  if (! defined($stats))        # If caller did not already pass a hash
  {                             # for file stats, get it myself
    @stats_h{qw/dev ino mode nlink uid gid rdev size
                atime mtime ctime blksize blocks/} = stat($fname);
    $stats = \%stats_h;         # So that we work with a hash reference
  }
  $stats->{mode} &= 0777;       # Mask off any higher-order flags; I'm only
                                # interested in the permission flags
#
# validate_file() Continued

  # Preliminary setups out of the way: Check if it fits the naming convention
  # described in the intro comments to this function.
  #
  my $rawfile_pattern = qr{/ifmxdev\w*/files/file\.\d{4}};

# Complain about everything I find wrong with the file or its path.
#
  if (! ($fname =~ m/$rawfile_pattern/))
  {
    carp "Path <$fname> does not fit our naming convention";
    $rval = 0;
  }
  if (! ($stats->{uid} == $UID) && ($stats->{gid} == $GID))
  {
    carp "I am not the complete owner of file <$fname>!";
    $rval = 0;
  }
  if ($stats->{mode} != oct("660") )
  {
    my $operm = sprintf("%o", $stats->{mode});
    carp "Permissions on file <$fname> are <$operm>, not 660!";
    $rval = 0;
  }

done_here:
  return $rval;
}
#
# Function validate_symlink()
# Checks that the symlink name is of the correct format, in the correct
# directory, and applies to the specified dbspace and server.
# This function does not check of the symbolic link is already in use.
# Parameters:
# - The symlink itself
# - The dbspace I want to use the chunk for
# Globals:
# - %ENV hash, mainly for $INFORMIXSERVER
# Returns:
# - 1 for valid, 0 for invalid, an does all necessary carping
#
# Format of symlink name:
# /<directory>/<server>.dbspace.[PM].num
# - Directory: Must be /ifmxdev/sl
# - Server: Match against $ENV{INFORMIXSERVER}
# - Dbspace: The parameter
# - [PM] Primary or Mirror, although at this time only primary is supported
# - Num - This is the relative chunk number with respect to the dbspace.
#
use constant SYMLINK_DIR => "/ifmxdev/sl";

sub validate_symlink
{
  my ($lpath, $dbn) = @_;               # Get my parameters
  my $rval = 1;                         # Anticipate a happy result

  # Before anything, check that:
  # - The directory is indeed /ifmxdev/sl
  # - The file exists and is indeed a symbolic link.
  #
  my $lpath_dir = dirname($lpath);      # Check if this is /ifmxdev/sl
  my $lpath_file = basename($lpath);    # Match the pattern

  if (! $lpath_dir eq SYMLINK_DIR)
  {
    carp "Top level directory $lpath_dir is not in correct location";
    $rval = 0;
  }
  if (! ( (-e $lpath) && (-l $lpath) ) )    # The path and better exist and
  {                                         # must be a symlink
    carp "<$lpath> does not exist as a symbolic link (if it even exists)";
    $rval = 0;
  }
  goto return_point if ($rval == 0);

  # OK, the file listed is indeed a symbolic link in the correct location
  # Now does it look correct in other respects?
  #
  my %sl_parts;                         # For when I split into components
  @sl_parts{qw/server dbspace pm relnum/} = split('\.', $lpath_file);
#
  # Now I can validate each of those components
  #
  my $ifmx_server = $ENV{INFORMIXSERVER};   # Need to match against this
  $ifmx_server =~ s/_shm$//;                # If I happen to be using the
                                            # shared-memory connection, don't
                                            # worry about that suffix.
  if ($sl_parts{server} ne $ifmx_server)
  {
    carp "Server <$sl_parts{server}> is not server <$ifmx_server>";
    $rval = 0;              # Not a happy ending
  }
  goto return_point if ($rval == 0);
  if ($sl_parts{dbspace} ne $dbn)
  {
    carp "You can not use symlink <$lpath_file> as a chunk in dbspace <$dbn>!";
    $rval = 0;              # Not a happy ending
  }
  goto return_point if ($rval == 0);
  #if !($sl_parts{pm} =~ /^[PM]$/)  # If it is neither primary nor mirror
  if ($sl_parts{pm} ne 'P')         # If it is not primary
  {
    #carp "Chunk type <$sl_parts{pm}> is neither Primary nor Mirror";
    carp "Chunk type <$sl_parts{pm}> is not Primary!";
    $rval = 0;
  }
  goto return_point if ($rval == 0);

  # Now validate relative chunk number - Should be the last component of the
  # symlink name.  It must be 3 digits (left-0 padded, if need be), all numeric
  # and between 1 and 999
  #
  if (!($sl_parts{relnum} =~ /\d{3}/))  # This should cover the requirement
  {
    carp "Suffix <$sl_parts{relnum}> is non-numeric or is out of range!";
    $rval = 0;              # Another happy ending bites the dust!
  }

return_point:
  return $rval;
}
#
# raw_file_inuse(): Function to test whether the given "raw" file is already
#                 used by the current server or referenced by any other
#                 server on this host.
# Parameters:
# - Path of the raw file, the target of the chunk-naming symbolic link
# - A reference to the chunks array generated by the dbspace-pages() function.
#   Prerequisite: the caller has already called expand_symlinks()
# Returns:
# - 0 if it is not used or referenced anywhere
# - 1 if it is used by the current server
# - 2 if is referenced by a symlink in /ifmxdev/sl, but not by current server
#
sub raw_file_inuse
{
  my ($rawfile, $chunks) = @_;      # Get my parameters the usual way
  my $rval = 0;                     # Anticipate that file is not in use

  # First check if the {raw_file} member exists already. If not, I can't
  # run this check.
  #
  die "Must call expand_symlinks() before calling raw_file_inuse()"
    unless (defined($chunks->[1]{raw_file}));

  # The following grep seeks out all array entries whose raw_file member
  # matched the given raw file path.  There had better be only one! (or 0)
  #
  $rval = inlist($rawfile, $chunks, "raw_file");
  carp "SYSTEM BUG! Raw file $rawfile has multiple symlinks!"
    if $rval > 1;
  if ($rval == 0)                   # OK, not used in this server; how about
  {                                 # other servers on this host?
    my $ls_command = sprintf("ls -l /ifmxdev/sl | grep -v %s|grep %s",
                             $ENV{INFORMIXSERVER} . "." , $rawfile);
    # That is: Any mention of this raw file that is NOT associated with
    # this server.  Must be associated with another server on this host.
    #
    my @ls_array = `$ls_command`;           # Run that pipeline
    $rval = 2 if (scalar(@ls_array) > 0);   # Found something? Set this status
  }
done_here:
  return $rval;
}
#
# symlink_inuse(): Function to determine if a named symbolic link is already
#                 in use in this server.  It is assumed to have passed muster
#                 for a valid symbolic link path via validate_symlink()
# Parameters:
# - The symbolic link - full path
# - Reference to the chunks array produced by dbspace-pages(). It is not
#   necessary for it to have passed under expand_symlinks()
# Returns:
# - 1 if it is in use
# - 0 if not.
# Note that unlike rawFile_inuse(), I will not check the sl subdirectory
# because the symlink may be associated with only this one server.
#
sub symlink_inuse
{
  my ($symlink, $chunks) = @_;
  my $rval = 0;                 # Assume symlink not in use yet

  $rval = inlist($symlink, $chunks, "symlink");
  return $rval;
}
#--------------------------------------------------------------------------
# dbspace_inuse() Determine if the given dbspace is already in the server.
# Parameters:
# - Name of the DBspace to check on
# - Reference to the DBspaces array created by dbspace-pages()
# Returns:
# - 0 if the named DBspace does not exist in this server
# - The DBspace's number if the named DBspace exists in the server
#
sub dbspace_inuse
{
  my ($dsname, $dblist) = @_;   # Capture my parameters
                                # Scan array for this dbspace name
  my @dups = grep {    defined($dblist->[$_]{name})
                    && $dblist->[$_]{name} eq $dsname}
                  1 .. $#{$dblist};
  my $rval;
  if (@dups == 0) {$rval = 0;}  # If dbspace does not exist, I return 0
  else
  {
    my $position = $dups[0];    # Get array index of the only entry returned
    $rval = $dblist->[$position]{dbs_num};  # The DBspace number
  }
  return $rval;
}
#
# get_fs_info(): Get file system infomation on the any file system(s) that
#                contain chunks in the given dbspace.
# Parameters:
# - The name of the dbspace
# - Reference to $chunks array, as per dbspace_pages()
# - Reference to the hash, keyed by mount-point, to receive FS information
# Returns:
# - Always 1.
#
sub get_fs_info
{
  my ($dbspace, $chunks, $fs_hash) = @_;

  # Get a list of array keys into @$chunks of all chunks in this dbspace
  #
  my @chunk_refs = grep {   (defined($chunks->[$_]{dbsname}))
                         && ($chunks->[$_]{dbsname} eq $dbspace) }
                        0 .. $#{$chunks};
  foreach my $clc (@chunk_refs) # Scan my way up this list to segue my way
  {                             # through selected segment of $chunks list
    my $mount_point;
    my $raw_file = $chunks->[$clc]{raw_file};   # Name of actual file of chunk
   ### $fs_ref = df($raw_file);                 # Just like df -k
    my $fs_ref = my_df($raw_file);              # Almost like df -k
    $mount_point = $fs_ref->{mountpt}; # Get the mount point for this file
    @{$fs_hash->{$mount_point}}{qw(fsystem blocks used bavail per)}
                   = @{$fs_ref}{qw(fsystem blocks used bavail per)}
      unless (defined($fs_hash->{$mount_point})); # No point in overwriting
                                                  # a location with same data
    $fs_hash->{$mount_point}{error} = $fs_ref->{error}
                          if (defined($fs_ref->{error}));
  }
  return(1);
}
#
# my_df() - Substitute for Filesys::Df::df() Because I can't get it to work
#           in Perl 5.8 without completely installing it.
# Parameter:
# - The path of a file or directory
# Returns
# - A reference to a hash, almost identical to that of the true df() but
#   for 2 difference:
#   o The true df function returns separate fields for bavail and bfree. The
#     df -k command does not list bfree; hence, I can't either
#   o The true df function does not return the actual mount point or the
#     path of the filesystem (as created by mkfs). This one does.
#   The returned hash reference contains the following fields:
#   o {fsystem} - Name of the file system as created with mkfs command.
#     It's just there in the output of df -k; I have no use for it here.
#   o {blocks}  - Number of 1-K blocks in the file system
#   x {bfree}   - Number of unused blocks in the FS (Not in df -k output)
#   o {bavail}  - Number of blocks available to create new files
#   o {used}    - Number of blocks used for any purpose`
#   o {per}     - Percent full
#   o {mountpt} - Mount point - the directory by which we access that file
#                 system.
# - If the df command fails, return a bogus file system description with an
#   {error} field.
#
sub my_df
{
  my $fname = $_[0];    # Get the file.directory name

  my $r_ref;            # Return value - Reference to the hash structure
  my $df_cmd = sprintf("df -k %s 2>&1", $fname); # Get info on only this file
  my @df_lines = `$df_cmd`;         # Slurp whole output (yeah, 1 line) to array
  chomp(@df_lines);                 # Clear extraneous <new-line>
  if (scalar(@df_lines) > 1)        #(Actually should be heading + 1 line)
  {
    @{$r_ref}{qw(fsystem blocks used bavail per mountpt)}
           = split(/\s+/, $df_lines[1]);    # Skip the df heading line
    $r_ref->{per} =~ s/%//;           # Lose the % sign in the output
  }
  #else {$r_ref = undef();}          # Got no lines from df command - bad news!
  else                              # Got no lines from df command - bad news!
  {                                 # Prepare a bogus file system entry
    @{$r_ref}{qw(fsystem blocks used bavail per mountpt)}
            =   ("(BAD)",     0,   0,     0, -1, $fname);
    $r_ref->{error} = $df_lines[0]; # Add the error message to the hash
  }

  return $r_ref;
}
#
# next_file_num() - When determining a new raw file, what number shall I use?
#   This function scans all the /ifmxdev*/files/* files and, upon finding the
#   highest number in use, returns one higher.  If there are -NEE- files in
#   there it will ignore them.
# Parameters: None
# Returns:
# - An integer to be the next raw file number to use.
# Note: At the shell level I have been able to get what I want with this
# pipe-lined command:
# $ ls -1 /ifmxdev*/files/* |sort -t'.' +1nr |
#   /usr/xpg4/bin/egrep -e 'file[s]{0,1}.[0-9]{4}$'
# I trust my own checking better, rather than the vaguaries of grep.
# (Mother, please! I'd rather do it myself! :-)
#
our $raw_file_pattern = qr(file\.\d+);       # How a raw file name looks
our $all_raw_pattern  = qr(^($raw_file_pattern)$);   # (Doesn't work <sad> )
#my $all_raw_pattern = qr(^file\.\d+$);  # ONLY raw file pattern, nothing else

# That is: The base name of the file must be the word "file" , followed by a
# period followed by N digits.  (Currently defaulting to 5 digits) You see, we
# want a pattern that looks entirely like the raw file pattern.  So anchor the
# raw pattern to beginning and end of the string.
#
# Next, a NEE file pattern is a raw file pattern, followed by NEE followed
# by a legitimate-looking symlink (base) file name.
#
our $sym_file_pattern = qr(\w+\.\w+\.[Pm].\d+); # How a symlink looks
our $nee_file_pattern = qr(^($raw_file_pattern\.NEE-$sym_file_pattern)$);
#
my $ls_command = "ls -1 /ifmxdev*/file*| sort -t'.' +1 -2 -nr |";

sub next_file_num
{
  my $lsfh;                     # File handle for sort command
  open ($lsfh, $ls_command)
    or die "Error <$!> opening command <$ls_command>";

  my $rnum = -1;                # Return value
  while (my $fpath = <$lsfh>)
  {
    my $fname = basename($fpath);    # I'm fine with dir; just look at file name

    # To get the highest file number, look only at files that are in use or
    # had been used at symlink targets within the server.  This includes NEE
    # files, the remnants of dropped chunks.
    #
    next unless (  ($fname =~ $nee_file_pattern)  # Count NEE files for number
                 ||($fname =~ $all_raw_pattern)); # Ignore non-conforming files
    my @fparts = split('\.', $fname); # Separate base name from numeric suffix
    next unless ($fparts[1] =~ /^[\d]+$/); # File num suffix: Numeric!

    # If I passed all of those tests, I have a winner! A highest number
    #
    $rnum = $fparts[1] + 1;         # Which yields the next number to use
    last;                           # and I can stop scanning
  }
  close($lsfh);                 # Put away my toys
  return $rnum;                 # Give user what he asked for
}
#
# round_down_size(): The size of a chunk must be a multiple of the page
# size.  If it is not, this funcion will round that page size down to a
# multiple of said page size.  This is more appropriate with true raw device
# files where you cannot just make it bigger by seeking out past the end.
# Parameters:
# - Page size in K. Obviously an integer. For example, 8 means an 8K page size
# - Chunk size, also in K, to check and reduce if necessary
# Returns:
# - A chunk size reduced to the nearest lower multiple of page size.  Or
#   unchanged page size if it is already a proper multiple.
#
sub round_down_size
{
  my ($pg_size, $chk_size) = @_;
  my $r_size = 0;               # Return value

  my $rem = int($chk_size) % int($pg_size); # Get the remainder after a divide

  # If remainder is 0, hey! No problem! Use that size.  Otherwise, reduce.
  #
  $r_size = ($rem == 0) ? $chk_size : $chk_size - $rem ;

  return $r_size;
}
#----------------------------------------------------------------------

# round_up_size(): Given a potential size of a chunk, it must me a multiple
#   of the page size.  This function makes sure it is by rounding it up.
#   This is appropriate for cooked files.
# Parameters:
# - Page size in K. Obviously an integer. For example, 8 means an 8K page size
# - Chunk size, also in K, to check and reduce if necessary
# Returns:
# - A chunk size reduced to the nearest higher multiple of page size.  Or
#   unchanged page size if it is already a proper multiple.
#
sub round_up_size
{
  my ($pg_size, $chk_size) = @_;
  my $r_size = 0;               # Return value

  my $rem = int($chk_size) % int($pg_size); # Get the remainder after a divide

  $r_size = ($rem == 0) ? $chk_size
                        : round_down_size($pg_size, $chk_size) + $pg_size;
  # That is:If not a multiple, round up by rounding down and adding-back the
  # page size.
}
#
# Some utility functions I had to write because I am unable to compile
# modules that would provide the needed functionality.
#
# inlist() - Substitute for the "in" function in List::Util, with little
#            extra features I didn't see in the POD for List::Util
# - Accounts for missing elements - gaps - in the array.
# - Array can be an array of hashes, if you provide a hash key parameter
# Parameters:
# - A string to match exactly
# - Reference to an array to be searched.
# - (Optional) If the array elements are hashes, this paramter is the hash-key
#   for the specific field to be searched.
# Returns:
# - Number of matching entries (TRUE) if the pattern exists in the array
# - 0 (FALSE) otherwise
# (Possible future option: If called in array context, perhaps return the
# array of matching items)
#
# Note: This will work for an array of scalars or hashes; it is not set up to
# to search a hash
#
sub inlist
{
  my ($pattern, $list, $hkey);  # My parameters
  my @matches;                  # Dummy array to catch matching entries

  # Get my parameters one at a time, just to keep careful count.
  #
  $pattern = shift(@_);         # String to match
  $list    = shift(@_);         # Array reference
  $hkey = (@_ > 0) ? shift(@_) : undef; # If hash key was specified, get it.

  if (defined($hkey))       # Matching a field within elements of hash array?
  {                         # Equality check is differnt for numbers or strings

    @matches = (looks_like_number($pattern))
         ? grep {defined($list->[$_]{$hkey}) && $list->[$_]{$hkey} == $pattern}
                0 .. $#{$list}
         : grep {defined($list->[$_]{$hkey}) && $list->[$_]{$hkey} eq $pattern}
                0 .. $#{$list}
         ;
  }
  else                      # No, just looking for exact match in simple array
  {                         # Equality check is differnt for numbers or strings
    @matches = (looks_like_number($pattern))
             ? grep {defined($_) && $_ == $pattern} @{$list}
             : grep {defined($_) && $_ eq $pattern} @{$list}
             ;
  }
  my $rval = @matches;                  # How many entries match the pattern?
  return $rval;                         # That's the user's need.
}
#------------------------------------------------------------------------------
# uniq(): Clear an array of duplicate entries.  Copied from the same-named
# function in List::MoreUtils (I can't follow the clever 2-liner here but if
# it works, I don't care.)
#
sub uniq (@) {
    my %seen = ();
    grep { not $seen{$_}++ } @_;
}
1;
#
__END__

=pod

=head1  Module Name

DBspaces.pm

=head2 Author

 Jacob Salomon
 jakesalomon@yahoo.com

=head2 Abstract

This module contains a large number of utility functions relating to the
maintenance and monitoring of DBspaces and Chunks.  These utilities are:

=over 2

=item * new-dbspace: Creates a new DBspace (kinda obvious by name, eh?)

=item * add-chunk: Adds a chunk to an existing DBspace

=item * drop-chunk: Drops the indicated chunk from a DBspace (iff empty)

=item * drop-dbspace: Drops the indicated DBspace

=item * spaces: Displays information about the DBspaces and chunks

=item * dup-spaces: Regenerates the onspaces commands that would rebuild
this server

=item * extents: Displays information on all extents of a table. This
steps out of the DBspace/chunk business but it does use this module.

Note that all these utilities also use UNLreport.pm but that's another
issue.  Also note that each of these utilities has its own perldoc page.

=back

=head2 Preface and Discussion

This module and the first four utilities listed establish a naming
convention and directory placement for the chunk files and the symbolic
links that reference them.  Recall that ideally, all chunk file names in a
server are symbolic links to their "device" files.

The reason I quoted "device" is that it actually creates flat files,
creating symbolic links to those flat files.  The well-known Informix
preference for character device files is somewhat obsolete since release
11.5 or so.  The data pages get flushed to the drive just as quickly as if
they had been based on a raw character device.

Another advantage of using flat file chunks is that they can be set to
automatically extend as needed (if the DBspace is not mirrored). If you
wish or a chunk to autoextend, please see L<this page in the IBM Knowledge
Center|https://www.ibm.com/support/knowledgecenter/SSGU8G_12.1.0/com.ibm.admin.doc/ids_admin_1368.htm/>
or Chapter 9 in the Administrator's Guide, the section titled B<Marking a
chunk as extendable>. (Just search for that string in the PDF of the
Administrator's Guide.)
Note that these utilities do not directly support for chunk auto-extension
but neither do they interfere.

=head2 Default settings

The new-dbspace and add-chunk utilities operate with certain defaults.
THese are for the location and layout of the chunk file names and the
symbolic links that reference the chunk file.  (Remember, the server knows
them only by the symbolic link names.) These can be overridden by a
configuration file but more on that later.  In the Informix server in which
these utilities were tested:

=over 2

=item * All of the symlinks, both for primary and mirror chunks, are in the
same directory, /ifmxdev.

=item * All of the primary chunk "raw" files are in directory /ifmxdevp

=item * All of the mirror chunk "raw" files are in directory /ifmxdevm

=item * The format of a chunk symbolic link name includes a DBspace-relative
chunk number, zero-padded to three places.  Example:
C<js_server.data_dbs.P.003>; that is: S<{server name}.{dbspace}.{P or
m}.{number}>
In this setup, a DBspace can have up to 999 chunks without messing up the
neat scheme.  (Although over 100 chunks to a single DBspace sounds like a
lot, I developed these utilities on a server where one DBspace had over 60.)
Note that I<P> stands for Primary and I<m> for mirror.

=item * The format of a "raw" file (I think I'll stop quoting that now) is
simply file.<number 0-padded to 5 places>.  For example: C<file.00012>.
Thus the complete picture of one chunk file looks like this:
S</ifmxdev/js_server.data_dbs.P.003 -> /ifmxdevp/file.00012> while the
mirror chunk's setup looks like S</ifmxdev/js_server.data_dbs.m.003 ->
/ifmxdevm/file.00012>

=item * The default chunk size is the original (2GB - 2K), the largest chunk
you can have in a 2K-page server without I<large chunks enabled>.

=back

=head2 Discussion about object-oriented-ness of this module.

This module was originally written as a repository for common functions
needed by the utilities listed above.  The notion of making it object
oriented did not occur to the author until it had grown into a 500-pound
gorilla.

Should you peek into the code you will see the tell-tale "bless" command.
There was some effort to retrofit this into the object-oriented model.
This effort has been pretty much abandoned.  As interesting as it would be,
I doubt it would improve functionality enough to be worth the effort of
retrofitting all the dependent utilities.

=head2 Configuration of these defaults

When this module starts up, it will try to read a configuration file to set
those defaults.  If the the file is not found, there are defaults values
already set up in the BEGIN block.  The configuration file can override
some or all of these defaults.  In the environment where these were
developed, the file is /ifmx-work/dbspace-defaults.cfg.  If you prefer, you
can set an environment variable, DBSPACE_DEFAULTS to the path of your
choice.  Here is that file in my environment:

 $ cat /ifmx-work/dbspace-defaults.cfg
 # dbspace_defaults.cfg
 # Defaults for DBspace file location, chunk size and page size.
 #
 primary_path    /ifmxdevp
 #primary_sub_path       # Leave this to hard-coded default
 mirror_path     /ifmxdevm
 #mirror_sub_path
 chunk_path      /ifmxdev
 #chunk_sub_path         # Also leave this to hard-coded default
 chunk_decimals  3
 raw_decimals    5
 chunk_size      2000000
 data_page_size  2       # That is 2K, of course. For -k option
 blob_page_size  2       # For -g option on blob pages



=head2 Finally: Methods and Functions

Note that although this module exports many functions, only those more
likely to be used by someone else have been documented here.  I may expand
the list as time goes on, if this module gets used by others.

=over 2

=item * dbspace_defaults()

Returns a reference to a hash keyed on the parameters described in
dbspace-defaults.cfg, containing the current values for those parameters.

Usage: $def_hash = dbspace_defaults();

=item * dbspace_pages()

This is the heart of this entire package.  It returns a hash whose elements
are a pair of array references.  This is data distilled from the output of the
B<onstat -d> command.

=over 2

=item * {dbspaces} An array reference whose elements are hashes of DBspaces
information, distilled from the DBspaces section of onstat -d.

=item * {chunks}  An array reference whose elements are hashes of chunk
information, distilled from the chunk section of that command.

=back

The arrays are keyed on the DBspace number and chunk number, respectively.
However, since there may be gaps caused by deleted DBspaces and chunks,
there may be a number of dummy entries.

In retrospect, these could have been hashes rather than arrays, with the
DBpsace elements keyed by the name of the DBspace and the chunks keyed on
chunk number but as hashes, not arrays.  Let's consider this a back-burner
wish-list item, if I get the opportunity for such a revision.  But as mentioned
above, it would take too long and too much effort to fix this and it works
quite well as is.

As mentioned above, this module is not quite object oriented.  Hence, the
components of the returned hash are not encapsulated.  The code in the
accompanying utilities calls dbspace_pages(), then assigns regular variables
to reference the arrays, something like this:

 my $dbspace_info = dbspace_pages();         # Get all vital stats
 my ($dbspaces, $chunks) = @{$dbspace_info}{qw(dbspaces chunks)};

It then goes on to reference the arrays using the references $dbspaces and
$chunks.

=item * large_chunks_enabled():

This quickie just returns a flag - 1 or 0 - to tell me if I<expanded chunk
capacity> is enabled.  You must call dbspace_pages() before calling
large_chunks_enabled(). Failure to do so will cause an abort.

=item * order_chunks()

Usage: $dbspace_info->order_chunks();

Returns: Well, actually, nothing.  But it does a couple of things to the
{chunks} array in the dbspace_info structure:

=over 2

=item * The chunks array is now sorted by (DBspace number, DBspace-relative
chunk number)

=item * It adds two fields to each item in the chunks array:

=over 2

=item * {next_chunk} This is the actual chunk number (relative to the server)
of the next chunk on this DBspace.  This value is 0 for the last chunk of a
DBspace.

=item * {order_number} This is the order of the chunk within its DBspace.
This is not a fixed number; if you were to delete chunk[2] of a DBspace, the
former chunk[3] would be displayed as chunk[2] next time you run the spaces
command.

=back

=back

=item * expand_symlinks()

Usage: $chunk_list_ref = $dbspace_info->expand_symlinks();

This function chases down the symbolic link of each chunk file and adds that
in a new field, {raw_file}, to each item in the {chunks} array of the
$dbspace_info structure.  If the chunk as a mirror, is also adds field
{mraw_file} to the chunk's item.

I<Note: It also adds {sym_chain} and {msym_chain}, a complete chase-down of
the chain of symbolic links of each chunk. I am considering deprecating this
feature.>

=back

=cut
