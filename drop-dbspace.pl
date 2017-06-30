#!/usr/bin/perl -w
#+---------------------------------------------------------------------------+
#| Copyright (C) Jacob Salomon - All Rights Reserved                         |
#| Unauthorized use of this file is strictly prohibited                      |
#| Unauthorized copying of this file, via any medium, is strictly prohibited |
#| Proprietary and confidential                                              |
#| Written by Jacob Salomon <jakesalomon@yahoo.com>                          |
#+---------------------------------------------------------------------------+
# drop-dbspace.pl - Drop a dbspace. No greate validations because
#                   if the onspaces drop-chunk (or drop-dbspaces) command fails,
#                   no harm done
#
# Parameters:
# -h Help Text
# -X Generate commands but do not execute
# -d Name of the dbspace - Required parameter
#
# This utility generates the onspaces -d command without checking the
# validity of the parameters (except the name of the dbspace, of course).
# If the chunk is not empty or anything else is wrong, the generated onspaces
# command will fail anyway.
#
# Author:           Jacob Salomon
#                   jakesalomon@yahoo.com
# First release:    2014-06-14
#
# Modification History:
# 2016-09-04:   Found that the error messages for failure to drop a chunk and
#               drop a dbspace were reversed. Corrected this.
#
# 2017-05-19:   Added support for mirrored DBspaces.
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
my $option_list = "hd:X";
my %opts;                       # For chosen options
my $execute_flag = 1;           # Assume the caller means business unless
my $execute_option = "";        # and I won't use -X with drop-chunk command
                                # otherwise indicated (by the -X option)
getopts($option_list, \%opts);  # Parse command line
if (defined($opts{h}))
{
  display_help();
  exit 0;
}
#
# If specified -X, set two variables; one to be passed to drop-chunk utility
#
($execute_flag, $execute_option) = (0, "-X") if (defined($opts{X}));

# Enforce dbspace parameter:
#
die "You must supply a dbspace name"
  unless (defined($opts{d}) );

# Still here: dbspace name was given as required
#
my ($dbspace) = $opts{d};       # Get it into a variable

my $ifmx_server = $ENV{INFORMIXSERVER};
my $dbspace_info = dbspace_pages();     # Get all vital stats
my ($dbspaces, $chunks) = @{$dbspace_info}{qw(dbspaces chunks)};
$dbspace_info->order_chunks();          # Sort the chunks by dbspace/chunk
$chunks = $dbspace_info->expand_symlinks(); # chunk information I need

# A validation and a fail-safe (i.e. assert)
#
my $dbspace_exists;
die "No such dbspace <$dbspace> in server $ifmx_server"
  unless ($dbspace_exists = inlist($dbspace, $dbspaces, "name"));
die "BUG: Found $dbspace_exists entries for dbspace $dbspace"
  if ($dbspace_exists > 1);

# Pare down the list of chunks; I need an array of chunks only for this dbspace
# (Will settle for the list of keys.)
#
my @chunk_keys = grep {   defined($chunks->[$_]{symlink})
                       && $chunks->[$_]{dbsname} eq $dbspace}
                      0 .. $#{$chunks};
# Now sort them in chunk order
#
@chunk_keys = sort {$chunks->[$a]{chunk_order} <=> $chunks->[$b]{chunk_order}}
                   @chunk_keys;

# Scheme: Use existing utility - drop-chunk - to get rid of all chunks of
# the dbspace but the first. That one requires a different onspaces command.
# And if any chunk cannot be removed, the process stops there.  Any chunks
# removed before that happens stay gone, but that's OK because they were
# obviously empty anyway.
#
my @chunk_info;
my ($symlink_path, $msymlink_path);
my ($rawfile_path, $mrawfile_path);
my $both_paths;
my $drop_status;
#
my ($lc, $ch_key);              # Loop counter: Start with highest chunk key
for ($lc = scalar(@chunk_keys); $lc > 0; $lc--) #(Note: $lc is NOT chunk key;
{                                               # it references a chunk key)
  next unless (defined($chunk_keys[$lc]));  #(I took liberties with the indexes)
  $ch_key = $chunk_keys[$lc];               # *This* is the key into @$chunks

  my $drop_chunk_cmd = sprintf("drop-chunk %s -d %s -n %d",
                               $execute_option, $dbspace,
                               $chunks->[$ch_key]{chunk_order});
  my $drop_chunk_comment = sprintf("# Free up %s -> %s\n",
                                   $chunks->[$ch_key]{symlink},
                                   $chunks->[$ch_key]{raw_file});
  printf("\n%s %s\n", $drop_chunk_cmd, $drop_chunk_comment); # Display my plan
  if ($execute_flag)
  {
    $drop_status = system($drop_chunk_cmd);
    die "Drop chunk command failed with exit <$drop_status>"
      unless ($drop_status == 0);
  }
}

# Still here: All that's left of the original dbspace is its root chunk.
# (And lc == 0 so I can use the more clear literal 0)

$ch_key = $chunk_keys[0];               # Key -> root chunk of this dbspace
my $onspaces_cmd = sprintf("onspaces -d %s -y", $dbspace);
my $onspaces_comment = sprintf("# Finally: Free up %s -> %s\n",
                               $chunks->[$ch_key]{symlink},
                               $chunks->[$ch_key]{raw_file});
printf("\n%s %s\n", $onspaces_cmd, $onspaces_comment);  # Display command
if ($execute_flag)
{
  $drop_status = system($onspaces_cmd);
  die "Drop dbspace command failed with <$!>"
    unless ($drop_status == 0);
}
# I didn't die anyplace above. Now, whatever drop-chunk did for each
# chunk's files (symlink->rawfile) I need to do now for the root chunk.
# 
($symlink_path, $rawfile_path)   = @{$chunks->[$ch_key]}{qw(symlink raw_file)};

my ($unlink_status, $unlink_status_m);
printf("rm %s;\n", $symlink_path);      # Display plan to unlink the symlink
if ($execute_flag)                      # and if that's the plan
{                                       # do it!
  $unlink_status = unlink $symlink_path;    # (Or die trying)
  die "Failed to unlink symlink <$symlink_path>; Error <$!>"
    unless ($unlink_status);
}
#
# Rather than delete the raw file, rename it to something we may later want to
# recover
#
my $symlink_base = basename($symlink_path);
my $renamed_target = sprintf("%s.NEE-%s", $rawfile_path, $symlink_base);
printf("mv %s %s\n", $rawfile_path, $renamed_target);
if ($execute_flag)
{
  die "Error <$!> renaming target file!"
    unless (rename($rawfile_path, $renamed_target));
}

if (defined($chunks->[$ch_key]{m_path})) # If a mirror is defined on this first
{                               # chunk we need to unlink and rename raw file
  ($msymlink_path, $mrawfile_path)
    = @{$chunks->[$ch_key]}{qw(m_path mraw_file)};
  printf("rm %s;\n", $msymlink_path);   # Display plan to remove mirror symlink
  if ($execute_flag)                    # and if that's the plan
  {                                     # do it!
    $unlink_status_m = unlink $msymlink_path;     # (Or die trying)
    die "Failed to unlink symlink <$msymlink_path>; Error <$!>"
      unless ($unlink_status_m);
  }

  # Rather than delete the raw file, rename it to something we may later want
  # to recover it
  #
  my $msymlink_base = basename($msymlink_path);
  my $mrenamed_target = sprintf("%s.NEE-%s", $mrawfile_path, $msymlink_base);
  printf("mv %s %s\n", $mrawfile_path, $mrenamed_target);
  if ($execute_flag)
  {
    die "Error <$!> renaming target file!"
      unless (rename($mrawfile_path, $mrenamed_target));
  }

}
# Well, go out gracefully now.
#
my $ahem = $execute_flag ? "" : "(ahem)" ;
print "DBspace $dbspace has been successfully $ahem dropped.\n";
exit(0);
#
sub display_help
{
  print <<EOH
This utility generates the onspaces -d command without checking the
validity of the parameters. If the chunk is not empty or anything else is
wrong, the onspaces command will fail anyway.

Usage:
$me -h    # Display this help text
$me -d <dbspace> [-X]
Where:
  -d dbspace    (Required) Specify name of the dbspace to be dropped

  -X            Reassurance - Generate the shell commands to accomplish the
                same thing bit do NOT execute them
EOH
}
#
__END__

=pod

=head1  Program Name

drop-dbspace (or drop-dbspace.pl if you have not created the symlink)

=head2  Abstract

Drops the indicated DBspace, provided it is empty.

=head2 Author

 Jacob Salomon
 jakesalomon@yahoo.com

=head2 Dependencies

=over 2

=item * DBI.pm: The general DataBase Interface used by all Perl programs
that must access a commercial database. This is usually installed with the
Perl core

=item * DBD::Informix: Jonathan Leffler's Informix-specific package for Perl.
Available at L<DBD::Informix |https://metacpan.org/pod/DBD::Informix>

=item * DBspaces.pm: The Perl module with the functions and methods used by
all of the utilities in this package.  Of course, it comes with this
package.  At this time available only on IIUG, not on CPAN.

=item * UNLreport.pm: The Perl module that formats test output into neat
columns for reports.  This is available from CPAN at L<Data::UNLreport.pm
|https://metacpan.org/pod/Data::UNLreport>

=back

=head2 Synopsis

drop-dbspace [-X] -d <dbspace>

Note that the -d option is required; otherwise how am I supposed to know
which DBspace to drop?

=head2 Options

=over 4

=item * -X  (Optional) flag to tell me not to actually execute anything but
to display equivalent shell commands to accomplish the the same operations.

=item * -d <dbspace> Tell me which DBspace you wish to drop

=back

=head2 How it works

If the DBspace has multiple chunks, we will drop them form highest order to
lowest using the drop-chunk utility.  Only then do we operate on the first
chunk of the dbspace directly. The program displays all shell-level
commands that could be used to accomplish the same results.

The operations on each chunk are:

=over 4

=item * Run the onspaces command to drop the chunk or the DBspace

=item * Remove the symbolic link of the chunk, the file name by which the
engine addresses the chunk

=item * Rename the "raw file" that had been referenced by that symlink. See
perldoc drop-chunk to observe the renaming convention.  But the bottom line
is that if you wish you had not dropped a chunk or the DBspace, you can use
the new name of the raw file to recreate the symlink and recover it from a
backup taken before the drop.

=back

It is not possible to lose data in these operations; the engine will not
allow me to drop a chunk or DBspace containing data.

=head2 Example

This example will use the -X option - I don't really want to drop this
DBspace nor could I, since it contains data.  The DBspace in the example
has four chunks and is mirrored.

 $ drop-dbspace.pl -X -d data_dbs
 drop-chunk -X -d data_dbs -n 4 # Free up /ifmxdev/js_server.data_dbs.P.004 -> /ifmxdevp/file.00013
 
 
 drop-chunk -X -d data_dbs -n 3 # Free up /ifmxdev/js_server.data_dbs.P.003 -> /ifmxdevp/file.00012
 
 
 drop-chunk -X -d data_dbs -n 2 # Free up /ifmxdev/js_server.data_dbs.P.002 -> /ifmxdevp/file.00011
 
 
 onspaces -d data_dbs -y # Finally: Free up /ifmxdev/js_server.data_dbs.P.001 -> /ifmxdevp/file.00006
 
 rm /ifmxdev/js_server.data_dbs.P.001;
 mv /ifmxdevp/file.00006 /ifmxdevp/file.00006.NEE-js_server.data_dbs.P.001
 rm /ifmxdev/js_server.data_dbs.m.001;
 mv /ifmxdevm/file.00006 /ifmxdevm/file.00006.NEE-js_server.data_dbs.m.001
 DBspace data_dbs has been successfully (ahem) dropped.

If you wish to see how each drop operation operates, simply copy one of the
above drop-chunk commands BUT DON'T FORGET -X!

=cut
