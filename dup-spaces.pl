#!/usr/bin/perl -w
#+---------------------------------------------------------------------------+
#| Copyright (C) Jacob Salomon - All Rights Reserved                         |
#| Unauthorized use of this file is strictly prohibited                      |
#| Unauthorized copying of this file, via any medium, is strictly prohibited |
#| Proprietary and confidential                                              |
#| Written by Jacob Salomon <jakesalomon@yahoo.com>                          |
#+---------------------------------------------------------------------------+
# dup-spaces.pl - Produce a script that reproduces the dbspaces
# of the current system.
#
# Author:   Jacob Salomon
#           jakesalomon@yahoo.com
# Date:     2004-12-28
#
# Based on copy-spaces.sh
#    by Peter Stiglich, DBA at ProMark One Marketing Services
#       stiglich@promarkone.com
#  Web: http://www.promarkone.com
#
# The shell version of this was a complete revision of copy-spaces.sh. While
# copy-spaces.sh, dup-spces.sh and dup-spaces.pl all have the same purpose,
# this Perl version uses an internal array rather than temp files.
#
# My primary motivation for shell rewrite was my need for BLOBspace support.
# My motivation for the much later Perl rewrite was a slow move to Perl
# away from shell for these utility scripts
#
# Revision History:
# 2017-05-09: o This has been working will in a non-mirrored environment
#               with no blob spaces. When used in a mirrored environment
#               with a blog space some bugs were exposed.  Today's fix
#               corrects those lacks.
#---------------------------------------------------------------------------
# Preliminaries:
#
use strict;
use Carp;
use Pod::Usage;         # In case I decide to provide decent Perl-type help
use Data::Dumper;
use DBspaces;
use DBspaces qw(order_chunks);  #(This function is a special order)

my $white = qr/\s+/;    # white-space pattern for splitting strings into arrays

# To separate heading lines from lines with the data we want:
#
my $hex_digit_pattern = qr([0-9a-f]);
my $hex_addr_pattern  =  qr/^[0-9a-f]+\s+/; # To recognize a line beginning
                                            # with a hex address

my $root_pgsize = 2;    # That is, the default page size (in K) of the server.
                        # This may be incorrect; we fill confirm later

my $max_chunk_num = 0;  # For eventual use as loop limit
#
# Begin main work:
#
#$| = 1;                 # Turn off stdio buffering  #Debug (but can stay)
my $dbspace_info = dbspace_pages();
my ($dbs_h, $chunk_h) = @{$dbspace_info}{qw(dbspaces chunks)};
#order_chunks($dbs_h, $chunk_h);
$dbspace_info->order_chunks();          # Sort chunks by dbspace/chunk numbers
$chunk_h = $dbspace_info->expand_symlinks();

# Now, what is the default page size for this server? Need to know because
# it may affect my interpretation of blob page information.
#
$root_pgsize  = $dbs_h->[0]{pgsize};    # Page size of root dbspace (needed?)
my $top_chunk = $chunk_h->[$#{$chunk_h}]{chunknum}; # Last chunk number

# Now I step through the chunks list and add some details from each chunk's
# dbspace into the chunk structure. (Unless it turns out that dbspace-pages()
# already did that.)
#
for (my $clc = 0; $clc <= $#{$chunk_h}; $clc++)
{
  next unless (defined($chunk_h->[$clc]));  # May be gaps in the chunk array
  my $dbn = $chunk_h->[$clc]{dbsnum};       # Get dbspace num
  @{$chunk_h->[$clc]}{qw(name pgsize)} = @{$dbs_h->[$dbn]}{qw(name pgsize)};
}

# OK, at this point, both the dbspace array and the chunk arrays have
# been built.  Sort them by:
# - Dbspace number
# - First-chunk yes/no (yes first)
# - Chunk number: If not the first chunk of the DBspace, sort by chunk number
#
# Before I can do any sorting I need to lose all the undefined entires in
# the chunks_h array.  Scheme: WOrk backwards to splice out all undefined
# entries.
#
for (my $clc = $#{$chunk_h}; $clc >= 0; $clc--)
{
  next if (defined($chunk_h->[$clc]));  # Skip healthy entry
  splice(@$chunk_h, $clc, 1);
  1 == 1;           # (For debugging breakpoint)
}

# @ordered_chunks is just another array of integers, indexing into $chun_h
#
my @ordered_chunks
           = sort {   $chunk_h->[$a]->{dbsnum}   <=> $chunk_h->[$b]->{dbsnum}
                   || $chunk_h->[$b]->{is_first} <=> $chunk_h->[$a]->{is_first}
                   || $chunk_h->[$a]->{chunknum} <=> $chunk_h->[$b]->{chunknum}
                  } 0 .. $#{$chunk_h};
#
# Now translate all that data into onspaces commands
#
my @commands = ();      # Array to store commands
my $cmlc = 0;           # Index into above array
my $max_len = 0;        # Track the longest command line.
for (my $clc = 0; $clc <= $#ordered_chunks; $clc++)
{                       # Generate and print 1 onspaces command/chunk
  my $cnum = $ordered_chunks[$clc];         # Get array index into $chunk_h
  next unless (defined($chunk_h->[$cnum])); # Ignore deleted chunks
  my $command_string
   = onspaces_command($chunk_h->[$cnum]);   # Generate onspaces command
  $max_len = length($command_string) if (length($command_string) > $max_len);
  $commands[$cmlc]{command} = $command_string;
  $commands[$cmlc]{raw_file} = $chunk_h->[$cnum]->{raw_file};
  $cmlc++;              # After handling the entry, bump the index
}

# Now display the onspaces commands, with the target raw files.
#
for (my $clc = 0; $clc <= $#commands; $clc++)
{
  my $command_string = sprintf("%-*s #%s", $max_len,
                               $commands[$clc]{command},
                               $commands[$clc]{raw_file});
  printf("%s\n", $command_string);
}

# ** End of main program.
#
# onspaces_command() - Generate one onspaces command string for one
#                      chunk number
# Parameters:
# - Reference to a chunk structure
# - Implicit: The arrays @$dbs_h and @$chunk_h
#
sub onspaces_command
{
  #my $cn = $_[0];          # Passed parameter: The chunk number
  my $chunk = $_[0];        # Passed parameter: Ref -> chunk structure
  my $command = "";         # Declare these local string variables
  my $primary_part = "";    # from which I will piece together the
  my $pchunk_part = "";     # onspaces commands.
  my $mchunk_part = "";

  # Some assumptions (with initial values) about this chunk:
  #
  my $d_s_type = "-d";      # 1. First assume dbspace, not blob space
  my $pg_size  = "";        #    with default page size
  my $d_t_type = "";        # 2. Assume permanent dbspace, not temp
  my $bp_size = "";         # If not a blob space, assume no page size param
                            # Above assumptions are flexible..
  my $dbnum = $chunk->{dbsnum}; # Hold for dbspace number

  $command = "onspaces";    # Start building the command line
  if ($chunk->{chunknum} == 1)      # If this is chunk 1, comment it out
  { $command = "#-" . $command; }   # (but will still display it)

  # primary_part: Naming the dbspace with create or add-chunk option
  #               Also determine if regular, temp, or blob space
  # Note that the primary part is much simpler when adding a chunk
  # than when creating the dbspace.
  #
  if ($chunk->{is_first})       # Is the first chunk in its dbspace?
  {                             # Create operation for dbspace/blobspace
    if ($dbs_h->[$dbnum]{dbs_type} eq "T")  # 1st chunk in temp space?
    {                           # Modify assumption (1) above
      $d_t_type = "-t";         # Add the -t (for temp) parameter
    }
    elsif ($dbs_h->[$dbnum]{dbs_type} eq "B") # 1st chunk in blobspace?
    {                           # Modify assumption (2) and set up
      $d_s_type = "-b";         # parameter to indicate blob space flag
                                # and generate blob page-size parameter
      #-printf("Dump of blobspace structure:\n"); #DEBUG
      #-print Dumper($dbs_h->[$dbnum]);           #DEBUG
      $bp_size = sprintf("-g %d", $dbs_h->[$dbnum]{pgsize});
    }
    elsif ($dbs_h->[$dbnum]{dbs_type} eq "S")   # 1st chunk in an SBspace
    {
      $d_s_type = "-S";
    }
    # At this time, no allowance for replicating a temporary SBspace (type U)
    # or temporary DBspace on primary server (Type W). Also no provision
    # for recognizing an EXTspace (type -x) to set that type in the onspaces
    # command
#
    # Now, does the non-blobspace have a non-default page size?
    #
    if (   ($d_s_type eq "-d")
        || ($d_t_type eq "-t") )    # If vanilla or temp dbspace
    {
      $pg_size = sprintf("-k %d", $dbs_h->[$dbnum]{pgsize} );
    }
    
    # Results for a first primary (ie non-miror) chunk in a dbspace:
    # For vanilla dbspace: d_s_type = "-d",
    #                      d_t_type & bp_size are both empty strings
    #                      pg_size = null or "-k <page-size>"
    # For Temp dpspace:    d_s_type = "-d", d_t_type = "-t"
    #                      pg_size = null or "-k <page-size>"
    # For BLOB space:      d_t_type is empty string
    #                      d_s_type = "-b", bp_size = "-g <size>"
    # Now put them all together for the primary part of the command
    #
    $primary_part = sprintf("-c %s %s %s %s %s",
                            $d_s_type, $chunk->{dbsname},
                            $d_t_type, $pg_size, $bp_size);
  } # End: if ($is_first[$cn])
  else                      # ie. This is NOT first chunk of dbspace
  {                         # Requires only naming the dbspace
    $primary_part = sprintf("-a %s", $dbs_h->[$dbnum]{name});
  }
  # Next part of the command: Location of the primary chunk, (as
  # opposed to the mirror chunk to be handled later.) This includes:
  # - Path name of device/file
  # - Offset within the file to start of chunk
  # - Size, in KB, of the chunk.
  #
  $pchunk_part = sprintf("-p %s -o %d -s %d",
                         $chunk->{symlink}, $chunk->{offset}, $chunk->{size});

  # That was easy enough. Now for mirror part, if it exists:
  # If mirrored, all I need supply is the path and offset - the size
  # is implicit inthe size of the primary chunk of this pair.
  #
  $mchunk_part = "";        # Clear this from possible previous value
  if ($dbs_h->[$dbnum]{mirrored} eq "M")    # If dbspace is mirrored
  {                                   # then generate its parameters
    #-printf("\nDBspace[%d], <%s> claims to be mirrored\n",   #DEBUG
    #-       $dbnum, $dbs_h->[$dbnum]{name});                 #DEBUG
    $mchunk_part = sprintf("-m %s %d",
                           $chunk->{m_path}, $chunk->{m_offset});
  }
  # Ok, I have all 4 parts of the onspaces command put together:
  # The command, the dbspace part, the primary chunk part and the
  # mirror chunk part.  Put them all together:
  #
  my $command_string = sprintf("%s %s %s %s",
                               $command, $primary_part,
                               $pchunk_part, $mchunk_part);
  return $command_string;
}
#
__END__

=pod

=head1  Program Name

dup-spaces (dup-spaces.pl if you have not set up the appropriate symbolic
link)

=head2 Abstract

This program produces a set of commands that could be used to recreate the

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

=back

=head2 Usage:

This program has no options.  Just run it against a live server and it
produces the output.  of course, you need a terminal window wider that the
usual 80 columns if you don't like line-wrapped output.

=head2 Example

 $ dup-spaces
 #-onspaces -c -d rootdbs  -k 2  -p /ifmxdev/js_server.rootdbs.P.001 -o 0 -s 500000 -m /ifmxdev/js_server.rootdbs.m.001 0    #/ifmxdevp/file.00001
 onspaces -c -d plog_dbs  -k 2  -p /ifmxdev/js_server.plog_dbs.P.001 -o 0 -s 400000                                          #/ifmxdevp/file.00002
 onspaces -c -d llog_dbs  -k 2  -p /ifmxdev/js_server.llog_dbs.P.001 -o 0 -s 250100                                          #/ifmxdevp/file.00003
 onspaces -c -d tmpdbs01 -t -k 8  -p /ifmxdev/js_server.tmpdbs01.P.001 -o 0 -s 25000                                         #/ifmxdevp/file.00004
 onspaces -c -d tmpdbs02 -t -k 8  -p /ifmxdev/js_server.tmpdbs02.P.001 -o 0 -s 25000                                         #/ifmxdevp/file.00005
 onspaces -c -d data_dbs  -k 16  -p /ifmxdev/js_server.data_dbs.P.001 -o 0 -s 25000 -m /ifmxdev/js_server.data_dbs.m.001 0   #/ifmxdevp/file.00006
 onspaces -a data_dbs -p /ifmxdev/js_server.data_dbs.P.002 -o 0 -s 6250 -m /ifmxdev/js_server.data_dbs.m.002 0               #/ifmxdevp/file.00011
 onspaces -a data_dbs -p /ifmxdev/js_server.data_dbs.P.003 -o 0 -s 6250 -m /ifmxdev/js_server.data_dbs.m.003 0               #/ifmxdevp/file.00012
 onspaces -a data_dbs -p /ifmxdev/js_server.data_dbs.P.004 -o 0 -s 6250 -m /ifmxdev/js_server.data_dbs.m.004 0               #/ifmxdevp/file.00013
 onspaces -c -d index_dbs  -k 8  -p /ifmxdev/js_server.index_dbs.P.001 -o 0 -s 50000 -m /ifmxdev/js_server.index_dbs.m.001 0 #/ifmxdevp/file.00007
 onspaces -c -b blobs_dbs   -g 6 -p /ifmxdev/js_server.blobs_dbs.P.001 -o 0 -s 50000                                         #/ifmxdevp/file.00008
 onspaces -c -S sbdbs01    -p /ifmxdev/js_server.sbdbs01.P.001 -o 0 -s 12500                                                 #/ifmxdevp/file.00009
 onspaces -c -S syssbdbs01    -p /ifmxdev/js_server.syssbdbs01.P.001 -o 0 -s 12500                                           #/ifmxdevp/file.00010

(The above output looks better in the PDF version. :-)

=cut
