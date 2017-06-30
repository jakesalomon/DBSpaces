#!/usr/bin/perl -w
#+---------------------------------------------------------------------------+
#| Copyright (C) Jacob Salomon - All Rights Reserved                         |
#| Unauthorized use of this file is strictly prohibited                      |
#| Unauthorized copying of this file, via any medium, is strictly prohibited |
#| Proprietary and confidential                                              |
#| Written by Jacob Salomon <jakesalomon@yahoo.com>                          |
#+---------------------------------------------------------------------------+
# drop-chunk.pl - Drop a chunk from a dbspace. No greate validations because
#                 if the onspaces drop-chunk command fails, no harm done
# Release history:
# 2015-01-02: Initial release in an environment with no mirrors.
# 2017-05-19: Finally motivated to support dropping a chunk with its mirror
#
# Parameters:
# -h Help Text
# -X Generate commands but do not execute
# -d Name of the dbspace - Required parameter
# -n Chunk number relative to the dbspace - Required
# Implicit parameter:
# - The server name - taken from $ENV{INFORMIXSERVER}
#
# This utility generates the onspaces -d command without checking the
# validity of the parameters. If the chunk is not empty or anything else is
# wrong, the onspaces command will fail anyway and none of the succeeding
# steps will occur.
#
use strict;
use Carp;
use Data::Dumper;
use Getopt::Std;        # Stick with simple 1-letter options
use Cwd 'abs_path';     # So I can chase a symlink
use File::Basename;
use DBspaces;
use DBspaces qw(order_chunks);

my $me = basename($0);          # Name of running script w/o directory stuff
my $option_list = "hd:n:X";
my %opts;                       # For chosen options
my $execute_flag = 1;           # Assume the caller means business unless
                                # otherwise indicated (by the -X option)
getopts($option_list, \%opts);  # Parse command line
if (defined($opts{h}))
{
  display_help();
  exit 0;
}
$execute_flag = 0 if (defined($opts{X}));   # Note if user just wants to
                                            # generate shell-worthy commands
# Enforce both parameters:
#
die "You must supply both a dbspace name and chunk number"
  unless (defined($opts{d}) && defined($opts{n}));

# Still here: Both parameters were given as required
#
my ($dbspace, $rel_chunk_num) = @opts{qw/d n/}; # Get them into variables

die "Use drop-dbspace to drop the first chunk of DBspace $dbspace"
  if ($rel_chunk_num == 1);
die "Chunks are ordered starting 1 with a DBspace; 0 is an invalid chunk number"
  if ($rel_chunk_num == 0);
my $ifmx_server = $ENV{INFORMIXSERVER};
my $dbspace_info = dbspace_pages();     # Get all vital stats
my ($dbspaces, $chunks) = @{$dbspace_info}{qw(dbspaces chunks)};
$dbspace_info->order_chunks();              # Get their historical order
$chunks = $dbspace_info->expand_symlinks();  # Will later chase down raw file

#
# order_chunks() has given us the DBspace-relative chunk numbers of each chunk
# in the server.  Identify the actual entry by {dbsnum} and {chunk_order}
#
my @dummy_list = grep {   defined($chunks->[$_]{dbsname})
                       && $chunks->[$_]{dbsname} eq $dbspace
                       && $chunks->[$_]{chunk_order} == $rel_chunk_num}
                      0 .. $#{$chunks};
# There can be no more than one, of course.  But there might be none - if
# user supplied a bad  chunk position with -n
#
my $dummy_count = @dummy_list;              # So how many chunks did respond?
die "No such DBspace or Chunk: $dbspace/Chunk[$rel_chunk_num]"
  if ($dummy_count < 1);
die "Program bug: Found $dummy_count chunks for $dbspace/Chunk[$rel_chunk_num]"
  if ($dummy_count > 1);

# Good! Exactly 1 chunk matches
#
my $target_chunk = $dummy_list[0];  # Index into @$chunks of the target chunk
my $chunk_path  = $chunks->[$target_chunk]{symlink};
my $mchunk_path = defined($chunks->[$target_chunk]{m_path})
                ? $chunks->[$target_chunk]{m_path} : undef;
                       
# A couple (or 4) of fail-safes: Make sure the entity requested really
# exists and an assert-like program check, on both the dbspaces and the
# chunk
#
my $dbspace_exists = inlist($dbspace, $dbspaces, "name");   # Is space listed?
die "No dbspace <$dbspace> in this server"
  if ($dbspace_exists == 0);
die "Bug: Found <$dbspace_exists> instances of <$dbspace> in dbspaces list"
  if ($dbspace_exists > 1);

my $chunk_exists = inlist($chunk_path, $chunks, "symlink"); # Is chunk listed?
die "No symlink <$chunk_path> for dbspace <$dbspace>/chunk <$rel_chunk_num>"
  if ($chunk_exists == 0);
die "BUG: Found <$chunk_exists> instances of <$chunk_path> in chunks list"
  if ($chunk_exists > 1);

# All in order: I can generate the onspaces command
#
my $onspaces_format = "onspaces -d %s -p %s -o 0 -y";   # Again, no mir support
my $onspaces_command = sprintf("$onspaces_format", $dbspace, $chunk_path);
printf ("\n%s\n", $onspaces_command);               # Display generated command
if ($execute_flag)                                  # Unless otherwise indicated
{
  my $onspaces_status = system($onspaces_command);  # Run it
  die "Chunk <$chunk_path> not dropped!"            # Go away with noise if the
    unless ($onspaces_status == 0);                 # command has failed.
}
#
# Still here: Chunk has been dropped. (Or command generated)
# Now get rid of the symlink and its target file. But let's not destroy it
# outright; rather rename it so that we can get back the name of the original
# symlink.  This is in case we need to recover that dropped chunk with a
# restore.  Otherwise, there is really no point in preserving the target file,
# as by renaming it.  If we were to try to reuse it, it would be reinialized
# again anyway.
#
my ($unlink_status, $unlink_status_m);
printf("rm %s;\n", $chunk_path);
printf("rm %s;\n", $mchunk_path) if (defined($mchunk_path));    # Mirrored?
if ($execute_flag)
{
  $unlink_status = unlink $chunk_path;
  die "Failed to unlink symlink <$chunk_path>; Error <$!>"
    unless ($unlink_status);
  $unlink_status_m = unlink $mchunk_path;
  die "Failed to unlink symlink <$mchunk_path>; Error <$!>"
    unless ($unlink_status_m);
}

# DO NOT JUST DELETE THE TARGET RAW FILES!
# Rather, name them to something we may later want to recover
#
# Locate the number in the array where this chunk was described
#
my ($chunk_key) = grep {   defined($chunks->[$_]{symlink})
                        && $chunks->[$_]{symlink} eq $chunk_path}
                       0 .. $#{$chunks};
my $target_path = $chunks->[$chunk_key]{raw_file};
my $chunk_base  = basename($chunk_path);
my $target_dir  = dirname($target_path);
my $renamed_target  = sprintf("%s.NEE-%s", $target_path,  $chunk_base);
printf("mv %s %s\n", $target_path, $renamed_target);
if ($execute_flag)
{
  die "Error <$!> renaming target file!"
    unless (rename($target_path, $renamed_target));
}

if (defined($mchunk_path))      # If this is a mirrored chunk then whatever I
{                               # did on the primary, replicate on the mirror
  my $mtarget_path = $chunks->[$chunk_key]{mraw_file};
  my $mchunk_base = basename($mchunk_path);
  my $mtarget_dir = dirname($mtarget_path);
  my $renamed_mtarget = sprintf("%s.NEE-%s", $mtarget_path, $mchunk_base);
  printf("mv %s %s\n", $mtarget_path, $renamed_mtarget);
  if ($execute_flag)
  {
    die "Error <$!> renaming target file!"
      unless (rename($mtarget_path, $renamed_mtarget));
  }
}
#
#********************************
# (Insert bookkeeping code here)
#********************************

my $ahem = ($execute_flag) ? "" : "(ahem)";
printf("Successfully %s dropped chunk %s[%d] from server %s\n",
       $ahem, $dbspace, $rel_chunk_num, $ifmx_server);

sub display_help
{
  print <<EOH
This utility generates the onspaces -d command without checking the
validity of the parameters. If the chunk is not empty or anything else is
wrong, the onspaces command will fail anyway.

Usage:
$me -h    # Display this help text
$me -d <dbspace> -n <relative chunk number> [-X]
Where:
  -d dbspace    Specify name of the dbspace with a chunk to be dropped
  -n number     The relative chunk number of the chunk I want to drop,
                relative to the dbspace.
  Both above are required

  -X            Reassurance - Generate the shell commands to accomplish the
                same thing bit do NOT execute them
Question: How do I know which chunk is in which position relative to each
DBspace? Answer: Run:
\$ spaces --chunks

This will not only order them by creation time but explicitly tel you the
position number of each chunk relative to its dbspace.
EOH
}
#
__END__

=pod

=head1  Program name

drop-chunk (or drop-chunk.pl if you have not created appropriate symlink)

=head2  Abstract

Drops the indicated chunk from a DBspace.

=head2 Author

 Jacob Salomon
 jakesalomon@yahoo.com

=head2 Dependencies

=over 2

=item * DBI.pm: The general DataBase Interface used by all Perl programs
that must access a commercial database. This is usually installed with the
Perl core

=item * DBD::Informix: Jonathan Leffler's Informix-specific package for Perl.
Available at L<DBD::Informix
|https://metacpan.org/pod/DBD::Informix>

=item * DBspaces.pm: The Perl module with the functions and methods used by
all of the utilities in this package.  Of course, it comes with this
package.  At this time available only on IIUG, not on CPAN.

=item * UNLreport.pm: The Perl module that formats test output into neat
columns for reports.  This is available from CPAN at L<Data::UNLreport.pm
|https://metacpan.org/pod/Data::UNLreport>

=back

=head2 Synopsis of operations

drop-chunk [-X] -d <dbspace> -n <relative chunk number>

Note that the -d and -n options are both required

=over 4

=item * -X  (Optional) flag to tell me not to actually execute anything but
to display equivalent shell commands to accomplish the the operation.

=item * -d <DBspace> Specify the name of the DBspace to lose a chunk

=item * -n <Relative chunk number> Specify which chunk of the DBspace to
drop.  Note that this number is not fixed.  For example, if I drop chunk[3]
for a 4 chunk DBspace, the former chunk[4] will become chunk[3].

=back

=head2 Explanation and Examples

Question: So how do I see which chunk is in which position?

Answer: By first running:

 $ spaces -ch <dbspace>

=head3 Example:

 $ spaces --chunks data_dbs
 DBspace  Type DNum Ord State  CNum PgSize NumPages FreePges %-Full ofs Chunk-File                        Raw-File
 data_dbs ---M    6   1 PN----    6  16384    25000    22360  10.56   0 /ifmxdev/js_server.data_dbs.P.001 /ifmxdevp/file.00006
 data_dbs ---M    6   1 MN----    6  16384    25000    22360  10.56   0 /ifmxdev/js_server.data_dbs.m.001 /ifmxdevm/file.00006
 data_dbs ---M    6   2 PN----   11  16384     6250     6247   0.05   0 /ifmxdev/js_server.data_dbs.P.002 /ifmxdevp/file.00011
 data_dbs ---M    6   2 MN----   11  16384     6250     6247   0.05   0 /ifmxdev/js_server.data_dbs.m.002 /ifmxdevm/file.00011
 data_dbs ---M    6   3 PN----   12  16384     6250     6247   0.05   0 /ifmxdev/js_server.data_dbs.P.003 /ifmxdevp/file.00012
 data_dbs ---M    6   3 MN----   12  16384     6250     6247   0.05   0 /ifmxdev/js_server.data_dbs.m.003 /ifmxdevm/file.00012
 data_dbs ---M    6   4 PN----   13  16384     6250     6247   0.05   0 /ifmxdev/js_server.data_dbs.P.004 /ifmxdevp/file.00013
 data_dbs ---M    6   4 MN----   13  16384     6250     6247   0.05   0 /ifmxdev/js_server.data_dbs.m.004 /ifmxdevm/file.00013

Note the column heading "Ord" - the chunk order number.  Now suppose we wish to
drop chunk[3].  For this example we will use the -X option because we want to
see what actions will be taken.

 $ drop-chunk -X -d data_dbs -n 3
  
 onspaces -d data_dbs -p /ifmxdev/js_server.data_dbs.P.003 -o 0 -y
 rm /ifmxdev/js_server.data_dbs.P.003;
 rm /ifmxdev/js_server.data_dbs.m.003;
 mv /ifmxdevp/file.00012 /ifmxdevp/file.00012.NEE-js_server.data_dbs.P.003
 mv /ifmxdevm/file.00012 /ifmxdevm/file.00012.NEE-js_server.data_dbs.m.003
 Successfully (ahem) dropped chunk data_dbs[3] from server js_server

Notice also the (ahem) in the success message, a reassurance that nothing has
been dropped or changed.

As you can see, while the chunk has been dropped, we remove the symbolic link
for that chunk but keep the raw file around, renaming it for the chunk that had
previously referenced it.  This way, if you realize you should not have done so,
you can easily recreate the symlink and recover from a backup from before that
drop.

=head2 One more note

You cannot use this utility to drop the first chunk of a DBspace; for that
you must use the drop-dbspace utility.  For information on that one, type

 $ perldoc drop-dbspace

=cut
