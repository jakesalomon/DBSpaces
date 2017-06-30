#!/usr/bin/perl -w
#+---------------------------------------------------------------------------+
#| Copyright (C) Jacob Salomon - All Rights Reserved                         |
#| Unauthorized use of this file is strictly prohibited                      |
#| Unauthorized copying of this file, via any medium, is strictly prohibited |
#| Proprietary and confidential                                              |
#| Written by Jacob Salomon <jakesalomon@yahoo.com>                          |
#+---------------------------------------------------------------------------+
# spaces.pl - Another incarnation of dbspace-pages, this time working
# completely from SQL on the sysmaster database
#
# History:
# 2015-01-02: Initial release, without mirroring support
# 2017-02-20: - Support for mirrored DBspace chunks
#             - Added --AbsolutePath option, a modifier for --Chunks. WHen
#               specified, we will chase down the chain of sybolic links to
#               the final path.
# 2017-03-27: - Fixed a bug in the formating of absolute path
#-----------------------------------------------------------------------------
use strict;
use Carp;
use Pod::Usage;
use File::Basename;
use Data::Dumper;
use Cwd 'abs_path';
use Getopt::Long;
use DBI;
use DBD::Informix;
use DBspaces qw(dbspace_defaults);
use FragmentList qw(ifmx_data_source);
use Data::UNLreport;

my $me = basename($0);
# Variables for use with GetOptions():
#
my $defaults = dbspace_defaults();  # Get some semi-constants in here
my $def_page_size = 1024 * $defaults->{data_page_size};
my ($want_help, $want_dbspaces, $want_chunks, $want_abs_path);
GetOptions('help'         => \$want_help,
           'DBspaces'     => \$want_dbspaces,
           'chunks'       => \$want_chunks,
           'absolutepath' => \$want_abs_path)
  or die "Syntax error in command options";

# User *must* specify a desired action
#
die "You can request --help, --Dbspaces or --chunks. Something!"
  unless (   defined($want_help)
          || defined($want_dbspaces)
          || defined($want_chunks));

# OK, so what did user ask for?
#
if ($want_help)        { display_help(); exit(0); }

my @dbspace_list = @ARGV;   # Copy what's left of the command line into an
                            # intelligibly named array
#
# Main execution starts here.
#
my ($spaces, $chunks, $combo);

# Get lots of info on the specified dbspaces/chunks.  Or all of them.
#
($spaces, $chunks) = dbspace_pages_sql(@dbspace_list);

if ($want_dbspaces)  {display_dbspaces($spaces);}
elsif ($want_chunks) {display_chunks($spaces, $chunks, $want_abs_path);}
else {die "You can request --help, --Dbspaces or --chunks. Something!";}

exit(0);
#
sub display_chunks
{
  my ($spaces, $chunks, $abs_flag) = @_;    #(Pardon my re-use of these names)
  my $combo = combine_dbspace_chunks($spaces, $chunks); # Consolidate 1 array

  # Now display what I have learned.  First sort the [indexes of the] combined
  # array by dbspace, chunk order within each dbspace.  Ah, but let's skirt the
  # gaps in the array to avoid "undefined" errors in the sort by creating dummy
  # values in the sort fields of non-defined chunk entries.
  #
  my $chunk_rpt = new Data::UNLreport;
  $chunk_rpt->in_delim('b');    # Set both input and output delimiters to blank
  $chunk_rpt->out_delim('b');

  map {$combo->[$_]{dbs_num} = $combo->[$_]{chunk_order} = 0
       unless (defined($combo->[$_]{dbs_num})) }
       0 .. $#{$combo};
  my @ordered = sort {   $combo->[$a]{dbs_num}    <=> $combo->[$b]{dbs_num}
                      || $combo->[$a]{chunk_order}<=> $combo->[$b]{chunk_order}}
                      0 .. $#{$combo};
  my $chunk_header = "DBspace Type DNum Ord State CNum PgSize NumPages "
                   . "FreePges %-Full ofs Chunk-File Raw-File";
  my $combo_format = "%s %s %d %d %s %d %d %d %d %5.2f %d %s %s";
  if ($abs_flag)                    # Shall Ichase down to last symlink
  {                                 # in chain of symlinks?
    $chunk_header .= " --> AbsolutePath";    # Add an item to the heading
   #$combo_format .= " --> %s";              # and a format for absolute path
  }
  my $ch_count = $chunk_rpt + $chunk_header; # Send column header to formatter
  for (my $oc = 0; $oc < @ordered; $oc++) # Walk up array of sorted chunk nums
  {
    my $cn = $ordered[$oc];       # Use cn to access chunk's entry in combo
    next unless (defined($combo->[$cn]{dbs_num}));
    next unless ($combo->[$cn]{dbs_num} > 0); # Skip the dummy entries
  # printf("\ncombo[%d] =\n", $cn); print Dumper($combo->[$cn]);
    $combo->[$cn]{pm_chunk_state}
      = "P" . $combo->[$cn]{chunk_state};   # Prepend P for Primary Chunk
    my $outbuf = sprintf($combo_format,
                         @{$combo->[$cn]}{qw(name dbs_type dbs_num chunk_order
                                             pm_chunk_state chunknum pgsize
                                             size free pct_full
                                             offset symlink raw_file)});

    # Now, if the direct link target of primary is not the same path name as
    # absolute link target and the user wants to see that as well, include the
    # absolute target as well
    #
    $outbuf .= " --> " . $combo->[$cn]->{p_abs_path} if ($abs_flag);
    #printf("%s\n", $outbuf);
    $ch_count = $chunk_rpt + $outbuf;   # Send the line for columns-formatting
#
    if (defined($combo->[$cn]{m_path})) # Did this chunk come with a
    {                                   # mirror chunk? Display that too
      $combo->[$cn]{pm_chunk_state}
        = "M" . $combo->[$cn]{chunk_state}; # Prepend M for Mirror Chunk
      $outbuf = sprintf($combo_format,
                        @{$combo->[$cn]}{qw(name dbs_type dbs_num chunk_order
                                            pm_chunk_state chunknum pgsize
                                            size free pct_full
                                            m_offset m_path m_raw_file)});
      # Now, if the direct link target of mirror is not the same path name as
      # absolute link target, include the absolute target as well, if the
      # user wants to see that..
      #
      $outbuf .= " --> " . $combo->[$cn]->{m_abs_path} if ($abs_flag);
      $ch_count = $chunk_rpt + $outbuf; # Send mirror line for column-formatting
    }
  }     #(End of loop to generate output)
  $chunk_rpt->print();              # And finish the job
  undef $chunk_rpt;                 # Put my toys away when finished
}
#
sub display_dbspaces
{
  my ($spaces) = @_;

  my $space_report = new Data::UNLreport;
  $space_report->in_delim('b'); # Set both input and output delimiters to blank
  $space_report->out_delim('b');
  
  my $space_header = "DBspace DNum Type PSz Chunks NumPages FreePgs %-Full";
  my $sp_count = $space_report + $space_header; # Send header to column format
  my $space_format = "%s %d %s %d %d %d %d %6.2f";
  for (my $dlc = 1; $dlc <= $#{$spaces}; $dlc++)
  {
    next unless (defined($spaces->[$dlc]{name}));
  # printf("spaces->[%d]:\n", $dlc); print Dumper($spaces->[$dlc]);
    my $outbuf = sprintf($space_format,
                         @{$spaces->[$dlc]}{qw(name dbs_num dbs_type pgsize
                                               nchunks pages free_pages
                                                pct_full)});
    $sp_count = $space_report + $outbuf;    # Send to column formatter
  }

  $space_report->print();       # Output the report
  undef $space_report;          # Putting away my toys when done
}
#
# dbspace_pages_sql():
# This function is morally identical to dbspace_pages but with the difference
# that it gets everything from SQL on the local sysmaster database, rather then
# from onstat and oncheck commands.
#
# Parameters: A list of dbspaces to operate on
# Returns:
# - $spaces->[]: A reference to an array of hashes with vital dbspace
#                information
# - $chunks->[]: A reference to an array of hashes with vital chunk
#                 information
# The relevant fields of the $spaces hash are:
# - dbs_num     The DBspace identifying number that joins to the chunk
#               structures; a primary key for the list of dbspaces
# - name        Name of the DBspace
# - fchunk      Chunk number of the first chunk
# - nchunks     Number of chunks in this DBspace
# - pgsiz       In bytes, size of a page in this DBspace
# - dbs_type    Concatenation of the flags temp, blobspace, sbspace, mirrored
#               These flags are, if true, T, B, S, and M.  If not true they
#               are dashes... Except for not-mirrored; the negative of
#               Mirrored is N.
# - pages       Sum of the page counts of all the chunks in the DBspace
# - free_pages  Sum of the free-page counts of all the chunks in the DBspace
# - pct_full    Calculated percent-full pages in the DBspace
# Leftover fields are:
# - temp        Flag that this is a temp space
# - blobspace   Flag that this is a blob space
# - sbspace     Flag that this is a smart-blob space, used as an aid in
#               enterprise replication
# - mirrored    Flag that this spaces is mirrored
#
# Relevant fields of the $chunks hash are:
# - dbs_name    Name of the DBspace to which this chunk belongs.
# - type        Just a copy of the dbs_type from the parent dbspaces hash
# - chunk_state Concatenation of states:
#               o off_line (N = OnLine, F = OffLine)
#               o inconsistent (S or -)
#               o recovering (R or -)
#               o Is a blob chunk (B or -)
#               o Is a smart-blob chunk (S or -)
# - chunknum    The primary key for the list of chunks
# - dbsnum      DBspace number to which this chunk belongs.  A foreign key
# - chunk_order A calculated sequence number - the DBspace-relative sequence
#               number of this chunk.  Starts over with 1 for each DBspace
# - nxchknum    In a linked list, the primary key of the next chunk in this
#               DBspace
# - size        Number of pages in this chunk
# - free        Number of free pages in this chunk
# - pct_full    Calculated value (albeit from SQL) of how full the chunk is
# - symlink     Name of the "file" of the chunk, which SHOULD be a symbolic link
# - raw_file    Name of the actual file that the symlink references. It may be
#               at the end of a chain of symbolic links but it is the last in
#               the line.
# - offset      Offset into the file for the start of this chunk.  In a well
#               set-up environment, this should be 0
#
# - m_path      If the chunk has a mirror, the symlink of the mirror chunk file
# - m_raw_file  File that is the final target of symbolic links starting
#               from m_path
# - m_offset    Offset, in pages, of the mirror chunk into its file.
#               Should be 0
# (Whew! A full-page introduction!)
#
sub dbspace_pages_sql
{
  my $where_clause = "";            # Where name in ("dbspace", "dbspace"..)
  if (scalar(@dbspace_list) > 0)    # If user supplied dbspace names
  {
    $where_clause = "where name in (XX)";   # Aha! There is a WHERE clause
    map {$_ = sprintf("\"%s\"", $_)} @dbspace_list; # Put quotes on each item
    my $d_list = join(", ", @dbspace_list);         # Separate with commas
    $where_clause =~ s/XX/$d_list/;         # Complete the WHERE clause
  }
  my $dbspaces_sql
    = "select d.dbsnum, trim(d.name), d.fchunk, d.nchunks, d.pagesize,"
     . " (case when d.is_temp      = 1 then 'T' else '-' end) temp,"
     . " (case when d.is_blobspace = 1 then 'B' else '-' end) blobspace,"
     . " (case when d.is_sbspace   = 1 then 'S' else '-' end) sbspace,"
     . " (case when d.is_mirrored  = 1 then 'M' else 'N' end) mirrored"
     . " from sysdbspaces d"
     . " $where_clause"
     . " order by d.dbsnum";
  
  my $chunks_sql
    = "select c.chknum, c.dbsnum, c.nxchknum, c.pagesize, c.chksize, c.nfree,"
     . " trim(c.fname), c.offset,"
     . " (case when c.is_offline      = 1 then 'F' else 'N' end) off_line,"
     . " (case when c.is_inconsistent = 1 then 'I' else '-' end) inconsistent,"
     . " (case when c.is_recovering   = 1 then 'R' else '-' end) recovering,"
     . " (case when c.is_blobchunk    = 1 then 'B' else '-' end) blobchunk,"
     . " (case when c.is_sbchunk     = 1 then 'S' else '-' end) smartblobchunk,"
     . " trim(c.mfname), c.moffset"
     . " from syschunks c "
     . "where chknum = ?";
  
  # Now connect to database sysmaster in current server - $INFORMIXSERVER
  #
  my $db_connector;
  $db_connector = ifmx_data_source("sysmaster", $ENV{INFORMIXSERVER})
    or die "Error: <DBI::errstr> trying to connect to $db_connector";
  my $dbh = DBI->connect($db_connector)
    or die "Error: <DBI::errstr> trying to connect to $db_connector";
  
  # Prepare the queries: First for the dbspaces, then for the chunks.
  #
  my $dbspaces_p = $dbh->prepare($dbspaces_sql)
    or die "Error <$DBI::errstr> preparing query:\n<$dbspaces_sql>";
  my $chunks_p = $dbh->prepare($chunks_sql)
    or die "Error <$DBI::errstr> preparing query:\n<$chunks_sql>";
#
  my ($spaces, $chunks);            # Arrays of hashes
  my ($snum, $cnum);                # Array indexes
  my (@s_list, @c_list);            # Arrays for I/O buffering
  $dbspaces_p->execute();           # Open cursor for dbspace query.
                                    # dbspaces and chunks
  while (@s_list = $dbspaces_p->fetchrow_array())
  {
    $snum = $s_list[0];             # Get dbspace number
    @{$spaces->[$snum]}{qw(dbs_num name fchunk nchunks pgsize
                           temp blobspace sbspace mirrored)} = @s_list;
  
    $spaces->[$snum]{dbs_type} = $spaces->[$snum]{temp} # Combine all possible
                             . $spaces->[$snum]{blobspace} # dbspace attributes
                             . $spaces->[$snum]{sbspace}   # into one string
                             . $spaces->[$snum]{mirrored};
    $spaces->[$snum]{qw(pages free_pages)} = (0, 0);    # Haven't counted yet

    # Discovery: Column syschunks.chksize gives the chunk-size in 2K pages.
    # This is not too useful if the dbspace is 16K. Solution: A bit of
    # arithmetic.  This boils down to 1 for standard 2K page size but goes
    # higher for larger page size.  i.e. for 16-k page, this is 4
    #
    my $chsize_multiplier = $spaces->[$snum]{pgsize} / $def_page_size;
  
    # Now that I have dbspace info, I can reference its first chunk number.
    # Start traversing the chunks linked list
    #
    my $chunk_order = 0;            # To show where chunk sits historically
    for ($cnum = $spaces->[$snum]{fchunk}; $cnum > 0;
         $cnum = $chunks->[$cnum]{nxchknum})
    {
      $chunks_p->execute($cnum);    # [Re]Open chunks cursor with chunk number
      @c_list = $chunks_p->fetchrow_array();    # Get the chunk data
      @{$chunks->[$cnum]}{qw(chunknum dbsnum nxchknum pagesize size free
                             symlink offset off_line inconsistent
                             recovering blobchunk smartblobchunk
                             m_path m_offset)
                         }
                        = @c_list;

      $chunks->[$cnum]{chunk_state} = $chunks->[$cnum]{off_line}
                                    . $chunks->[$cnum]{inconsistent}
                                    . $chunks->[$cnum]{recovering}
                                    . $chunks->[$cnum]{blobchunk}
                                    . $chunks->[$cnum]{smartblobchunk};
      $chunks->[$cnum]{chunk_order} = ++$chunk_order;   # DBspace-relative order
  
      $chunks->[$cnum]{dbsname} = $spaces->[$snum]{name}; # Copy dbspace name
#
      # Now we need to make sure that {symlink} link exists. Because if
      # it's gone, we can't let the output look normal.  Also flag it it is
      # not a symbolic link.
      #
      if (-e $chunks->[$cnum]{symlink})     # Is the symlink file even there?
      {                                     #(Or lost in an outage)?
        if (-l $chunks->[$cnum]{symlink})   # OK, it's here. Is it a symlink
        {                                   # or is it a naked device/file name?
          $chunks->[$cnum]{raw_file}        # Symlink: Get the path of the 
           = readlink($chunks->[$cnum]{symlink});   # target of our symlink
          $chunks->[$cnum]{p_abs_path}              # In case symlink target
            = abs_path($chunks->[$cnum]{symlink});  # != the first link target
        }
        else
        { $chunks->[$cnum]{raw_file} = "-Not-a-Symlink-";}
      }
      else                                  # The symlink is lost
      { $chunks->[$cnum]{raw_file} = "-Missing-Symlink-"; }

      # Now let's validate the target of the symlink, assuming it had a target
      #
      if ($chunks->[$cnum]{raw_file} =~ qr(^/)) # If target raw file looks like
      {                                         # a legit full path name
        if (! -e $chunks->[$cnum]{raw_file})    # But if it ain't there
        { $chunks->[$cnum]{raw_file} .= "<MISSING>"; }  # shout about it.
      }

      # If chunk has a mirror, do the same cheking and serivicing as we did
      # for the primary chunk: Get its target "raw" file path.  Or not..
      #
     #$chunks->[$cnum]{m_raw_file} = (defined($chunks->[$cnum]{m_path}))
     #                             ? abs_path($chunks->[$cnum]{m_path}) : undef;
      if (defined($chunks->[$cnum]{m_path}))
      {
        if (-e $chunks->[$cnum]{m_path})    # Is the mirror "file" even there?
        {                                   #(Or lost in an outage)?
          if (-l $chunks->[$cnum]{m_path})  # OK, it's here. Is it a symlink
          {                                 # or is it a naked device/file name?
            $chunks->[$cnum]{m_raw_file}    # Symlink: Get the path of the 
             = readlink($chunks->[$cnum]{m_path});  # target of our symlink
            $chunks->[$cnum]{m_abs_path}            # In case symlink target
              = abs_path($chunks->[$cnum]{m_path}); # != first link target
          }
          else
          { $chunks->[$cnum]{m_raw_file} = "-Not-a-Symlink-";}
        }
      }
#
      # Now to translate the messed up chunk size into the number of
      # dbspace-sized pages
      #
      $chunks->[$cnum]{size} /= $chsize_multiplier;
      $chunks->[$cnum]{free} /= $chsize_multiplier
        unless ($chunks->[$cnum]{blobchunk} eq "B");

      # Note: In a blob space, as in a data dbspace, the chunk size is
      # returned in terms of data pages (2K or 4K), not the number of possible
      # blob pages.  However, the number of free pages *is* given in terms of
      # blob pages.  Hence, the pct_full is quite off. for this reason, I
      # skipped the chsize_multiplier for a blobspace chunk
      #
      $chunks->[$cnum]{pct_full} = 100
                                 * (  $chunks->[$cnum]{size} 
                                    - $chunks->[$cnum]{free})
                                 / $chunks->[$cnum]{size} ;
  
      # Now, is this the leading chunk of the current dbspace?
      #
      $chunks->[$cnum]{is_first}
       = $spaces->[$snum]{fchunk} == $chunks->[$cnum]{chunknum} ? 1 : 0;
  
      $spaces->[$snum]{pages} += $chunks->[$cnum]{size}; # Tally dbspace pages
      $spaces->[$snum]{free_pages} += $chunks->[$cnum]{free}; # and free pages
  
      1 == 1;
    }

    # Now that I have the full tally of the number of pages and free pages of
    # this dbspace, let's get the percent-full:
    #
    $spaces->[$snum]{pct_full} = 100.0
                               * ( (  $spaces->[$snum]{pages}
                                    - $spaces->[$snum]{free_pages})
                                  / $spaces->[$snum]{pages});
    1 == 1;
  }

  return $spaces, $chunks;
}
#
# combine_dbspace_chunks()
# Function to consolitdate the data from the $spaces and $chunks arrays.
# Essentially creating an augmented $chunks array to include all dbspace
# information.
# Parameters:
# - Reference to the $spaces array
# - Reference to the $chunks array
# Returns
# - Reference to a the augmented array with the same number of entries as
#   the $chunks array
#
sub combine_dbspace_chunks
{
  my ($spaces, $chunks) = @_;   # Get my parameters
  
  my $combo;                        # ->Array of hashes with info form both
  my $clc = 0;                      # Index into $chunks and $combo arrays
  my $snum;                         # DBspace number
  for ($clc = 0; $clc <= $#{$chunks}; $clc++)
  {
    next unless (defined($chunks->[$clc]{chunknum}));   # Skip gaps in chunks

    # First pull in information from corresponding DBspace hash, then get
    # the rest from the current chunk hash.  (Really makes no difference
    # which I copy first
    #
    $snum = $chunks->[$clc]{dbsnum};                    # -> dbspace info
    @{$combo->[$clc]}{qw(name dbs_num dbs_type pgsize)}
       = @{$spaces->[$snum]}{qw(name dbs_num dbs_type pgsize)};
    @{$combo->[$clc]}{qw(chunknum chunk_state size free pct_full
                         symlink raw_file p_abs_path offset chunk_order
                         m_path m_offset m_raw_file m_abs_path)}
     = @{$chunks->[$clc]}{qw(chunknum chunk_state size free pct_full
                             symlink raw_file p_abs_path offset chunk_order
                             m_path m_offset m_raw_file m_abs_path)};
  }
  return $combo;
}
#
# display_help() - Kinda self-explanatory..
#
sub display_help
{
  print <<EOH
Usage:
  $me --help
  $me --DBspaces [dbspace dbspace ...]
  $me --chunks   [--absolutepath] [dbspace dbspace ...]

--help
 -h
  Display this help text and exit

--DBspaces (Not case sensitive)
 -d
  Displays summary information about the dbspaces listed on the command line.
  If no list is given, display the same about all dbspaces in the server

--chunks
 -c
  Displays fairly detailed information about the chunks in the specified
  dbspaces.  If no list, display this information about all chunks in the
  server

--absolutepath
 -a
 Modifier to the --chunks option. By default, $me displays only the
 immediate target of the symbolic link.  If you specify --absolutepath (-a
 is enough, really) it will display the final file in the chain of symbolic
 links.  (If there is a longer chain of symlinks, sorry, I haven't coded
 for that many levels of indirection.)
 Note: This option is ignored without comment if you include it with the
 --dbspaces option

Note the "Type" and "State" columns; These refer to flags on the DBspace
and chunk, respectively.

Type[1]: T if it is a temp dbspace; - otherwise
Type[2]: B for a BLOBspace, - otherwise
Type[3]: S for Smart BLOBspace, - otherwise
Type[4]: M if the DBspaces is mirrored, N otherwise

State[1]: F if the chunk is off-line, N if it is on-line
State[2]: I if the chunk is inconsistent, as in after an unsuccessful onbar
          resore
State[3]: R If the chunk is being recovered, an unlikely state if the
          DBspace is not mirrored
State[4]: B if this is a BLOBspace chunk
State[5]: S if this is a chunk in a Smart BLOBspace
EOH
}
__END__

=pod

=head1 PROGRAM NAME

spaces.pl (or just "spaces" if you have set up the symlink for it)

=head2 ABSTRACT

Displays quick summary of vital statistics about DBspaces and Chunks in the
current Informix instance (as determined by environment variable INFORMIXSERVER)

=head2 Author

 Jacob Salomon
 jakesalomon@yahoo.com

=head2 Dependencies

=over 2

=item * DBI.pm: The general DataBase Interface used by all Perl programs
that must access a commercial database. This is usually installed with the
Perl core

=item * DBD::Informix: Jonathan Leffler's Informix-specific package for Perl.
Available at L<DBD::Informix|https://metacpan.org/pod/DBD::Informix>

=item * DBspaces.pm: The Perl module with the functions and methods used by
all of the utilities in this package.  Of course, it comes with this
package.  At this time available only on IIUG, not on CPAN.

=item * UNLreport.pm: The Perl module that formats test output into neat
columns for reports.  This is available from CPAN at L<Data::UNLreport.pm
|https://metacpan.org/pod/Data::UNLreport>

=back

=head2 SYNOPSIS

spaces {--DBspaces | --Chunks [--AbsolutePath]} [dbspace [dbspace ..] ]

The command has the following options:

=over 4

=item * --DBspaces (or --db) Display only basic information on the indicated
DBspace(s). If not specified, display the basic information on all DBspaces
in the server. This includes the DBspace name, DBspace number, some flags
(more on those later), the page size, number of chunks, total number of
pages, total number of free pages and, finally, the biggest reason to have
such a utility, the percent full.

=item * --Chunks (or jst --ch) Display detailed chunk information on the
indicated DBspaces(s).  This includes some of the same information as the
--DBspaces option but includes the absolut chunk number, the position of
this chunk within the DBspace, the path of the chunk file, which should be
a symbolic link, and finally, the target path of that symbolic link.

=item * --AbsolutePath (or just --abs) A modifier for the chunks display.
Appends one item to the chunk information lines: The absolute path of the
chunk file.  This is useful if the target path of the symlink is itself a
symlink or any component directory is a symlink.  An example is given
below:

=back

=head2 Examples

=head3 Displaying DBspaces:

 $ spaces --db rootdbs data_dbs index_dbs blobs_dbs
 DBspace   DNum Type PSz   Chunks NumPages FreePgs %-Full
 rootdbs      1 ---M  2048      1   500000  487703   2.46
 data_dbs     6 ---M 16384      4    43750   41101   6.05
 index_dbs    7 ---M  8192      1    50000   49947   0.11
 blobs_dbs    8 -B-N  6144      1    50000   49933   0.13

=head3 Displaying chunks:

Due to the width of the chunk output lines, it is impractical to try to
display a complete example.  Instead, we will display partial lines.

For the same DBspaces, for the first part of the lines: 

 $ spaces --ch --abs rootdbs data_dbs index_dbs blobs_dbs
 DBspace   Type DNum Ord State  CNum PgSize NumPages FreePges %-Full ofs
 rootdbs   ---M    1   1 PN----    1   2048   500000   487703   2.46   0
 rootdbs   ---M    1   1 MN----    1   2048   500000   487703   2.46   0
 data_dbs  ---M    6   1 PN----    6  16384    25000    22360  10.56   0
 data_dbs  ---M    6   1 MN----    6  16384    25000    22360  10.56   0
 data_dbs  ---M    6   2 PN----   11  16384     6250     6247   0.05   0
 data_dbs  ---M    6   2 MN----   11  16384     6250     6247   0.05   0
 data_dbs  ---M    6   3 PN----   12  16384     6250     6247   0.05   0
 data_dbs  ---M    6   3 MN----   12  16384     6250     6247   0.05   0
 data_dbs  ---M    6   4 PN----   13  16384     6250     6247   0.05   0
 data_dbs  ---M    6   4 MN----   13  16384     6250     6247   0.05   0
 index_dbs ---M    7   1 PN----    7   8192    50000    49947   0.11   0
 index_dbs ---M    7   1 MN----    7   8192    50000    49947   0.11   0
 blobs_dbs -B-N    8   1 PN--B-    8   6144    50000    49933   0.13   0

 Now the latter part of the same lines:
 Chunk-File                     Raw-File             --> AbsolutePath
 /ifmxdev/jserv.rootdbs.P.001   /ifmxdevp/file.00001 --> /db/p/files/file.00001
 /ifmxdev/jserv.rootdbs.m.001   /ifmxdevm/file.00001 --> /db/m/files/file.00001
 /ifmxdev/jserv.data_dbs.P.001  /ifmxdevp/file.00006 --> /db/p/files/file.00006
 /ifmxdev/jserv.data_dbs.m.001  /ifmxdevm/file.00006 --> /db/m/files/file.00006
 /ifmxdev/jserv.data_dbs.P.002  /ifmxdevp/file.00011 --> /db/p/files/file.00011
 /ifmxdev/jserv.data_dbs.m.002  /ifmxdevm/file.00011 --> /db/m/files/file.00011
 /ifmxdev/jserv.data_dbs.P.003  /ifmxdevp/file.00012 --> /db/p/files/file.00012
 /ifmxdev/jserv.data_dbs.m.003  /ifmxdevm/file.00012 --> /db/m/files/file.00012
 /ifmxdev/jserv.data_dbs.P.004  /ifmxdevp/file.00013 --> /db/p/files/file.00013
 /ifmxdev/jserv.data_dbs.m.004  /ifmxdevm/file.00013 --> /db/m/files/file.00013
 /ifmxdev/jserv.index_dbs.P.001 /ifmxdevp/file.00007 --> /db/p/files/file.00007
 /ifmxdev/jserv.index_dbs.m.001 /ifmxdevm/file.00007 --> /db/m/files/file.00007
 /ifmxdev/jserv.blobs_dbs.P.001 /ifmxdevp/file.00008 --> /db/p/files/file.00008

Of course, the AbsolutePath column in included only because we had specified the
--abs option.  If your server is not configured with such a chain of symbolic
links, we do recommend you never use that option.

=head2 Dependencies

In order to function, this utility requires the following modules to
accessible, either in one of the Perl official directories or in another
directory already included in the environment variable PERL5LIB:

=over 4

=item * DBI, the general Perl interface to database engines, by Tim Bunce.
It should have been included with the Perl installation but if you don't have
it, you can get it at L<https://metacpan.org/pod/DBI>.

=item * DBD::Informix, the Informix-specific database module for Perl, by
Jonathan Leffler.  It is available at L<https://metacpan.org/pod/DBD::Informix>.

=item * Data::UNLreport, available at
L<https://metacpan.org/pod/Data::UNLreport>  This the tool used to format
the nice columns in the output.

=item * DBspaces.pm, which is part of this package.  This has the functions
called by this utility

=back

=cut
