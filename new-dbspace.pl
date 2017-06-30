#!/usr/bin/perl -w
#+---------------------------------------------------------------------------+
#| Copyright (C) Jacob Salomon - All Rights Reserved                         |
#| Unauthorized use of this file is strictly prohibited                      |
#| Unauthorized copying of this file, via any medium, is strictly prohibited |
#| Proprietary and confidential                                              |
#| Written by Jacob Salomon <jakesalomon@yahoo.com>                          |
#+---------------------------------------------------------------------------+
# new-dbspace.pl - Create a new dbspace in the current IDS server using the
#                  chunk-path naming conventions established for Onyx
# Author:   Jacob Salomon
#           Axiom Technology
# History:
# Release   1.0
#   Date    2014-01-01
#           Initial release
# Release:  1.1
#   Date:   2015-09-08
#         o Closer adaptations for object-oriented DBspaces.pm
#         o Added code to support explicitly naming raw path or symbolic
#           link as the chunk file
#
# Release:  2.0
#   Date:   2017-03-01
#         o Added -m/M options to support mirrored DBspaces.
#         o Dropped a whole bunch of never used option and delete a lotta
#           code to support them.  There were extra complicated when applied
#           to mirroring.
#-----------------------------------------------------------------------------
# Command line options:
# -d    Name of the dbspace - required. Assumes regular dbspace unless one
#       of the following additional options is specified:
#       o -T for temp DBspace
#       o -B for blob space
#       o -S for Smart-blob space
#       o -X (The extspace is not supported at this time)
# -p    Either:
#       o Name of the "raw-file" folder. (Must have a "files" subdirectory)
#       o Complete path name of the "raw file"
#       o A symbolic link already referencing a "raw file"
#       If omitted, we will automatically generate a new file name in
#       directory /ifmxdev/files with a file number 1 + the current highest
#       file number.
# -m    Identical option as for -p but for a mirror chunk.
# -k    Page size. Default: 2 (for 2-k page size). Must be a multiple of 2
#       for the number of K for the page size.
# -g    Page size for Blob pages - Treated differently from vanilla dbspaces.
# -s    Size of the chunk to be created. Default 2,097,150K (sans the commas,
#       of course). Note that an offset of 0 will ALWAYS be used in our
#       conventions
# -X    Generate the shell commands but do not execute them
# -h    Display parameters and exit
#
# This is being coded with assumption that it is being run by user informix.
# If run by anyone else, it will validate some parameters but refuse to
# actually run any onspaces commands.
#
use strict;
use Carp;
use Data::Dumper;
use Pod::Usage;
use Getopt::Std;        # Stick with simple 1-letter options
use Cwd 'abs_path';     # So I can chase a symlink
use File::Basename;
#use File::stat;         # So I can get size in case it is a raw device
                        #(Consider using File::stat only if I'm willing to
                        # change the way I'm calling it.)
use File::Touch;        #(Version on CPAN needs later release of Makemake)
use Scalar::Util qw(looks_like_number);
#use DBI;               #(These turned out not be needed)
#use DBD::Informix;
use DBspaces;           # Access to my standard functions
                        # and specialized functions
use DBspaces qw(dbspace_defaults validate_file validate_symlink order_chunks);

# Get information about my environmenr
#
my $logname = $ENV{LOGNAME};    # Name of user running this utility
my $me = basename($0);          # Name of running script w/o directory stuff
my $ifmx_server = $ENV{INFORMIXSERVER};
my $UID = $<;                   # $UID not available in this Perl release
my $GID = $( + 0;               # Neither is $GID. (+0 is Perl bug workaround)
my $run_user = getpwuid($UID);  # Name of user running this. Must be informix

# Default values, to be modified if user specifies the corresponding option
#
my $defaults = dbspace_defaults();

# Base file name and symbolic links to be specified in onspaces command
# as well as their target "raw" files
#
my ($symlink_name, $symlink_path, $msymlink_name, $msymlink_path);
my ($rawfile_name, $rawfile_path,                 $mrawfile_path);

# Prepare the directory of symlinks early in the game
#
$symlink_path = $defaults->{symlink_path};
$symlink_path .= "/$defaults->{symlink_sub_path}"
  if ($defaults->{symlink_sub_path});
$msymlink_path = $symlink_path; # Same directory for all symlinks but this
                                # gives me the flexibility of using a different
                                # directory for the mirror symlinks
# Above two really should not change, even across servers, because all
# symlinks should be in the same directory
#
#my $def_chunk_size   = $defaults->{chunk_size};     # Size of chuk, in KB
#my $def_raw_dir      = $defaults->{primary_path};  # Top dir for raw data files
#my $raw_subdir       = $defaults->{primary_sub_path}; # and its subdirectory
#my $def_mir_dir      = $defaults->{mirror_path};    # Top dir for raw mir files
#my $def_mir_subdir   = $defaults->{mirror_sub_path}; # and its subdir
#my $def_page_size    = $defaults->{data_page_size}; # Default page size: 2K
#my $def_blob_pg_size = $defaults->{blob_page_size};# Default blob page multiple

my $command = "";               # Create command lines in here

my $exec_flag    = 0;           # Assume we will not actually execute commands
#
# Ready to parse command line
#
my $option_list = "Xhd:p:s:Mm:k:tBg:SE";     # Option with *w/o parameters
my %opts;                       # Hash for chosen options & values
getopts($option_list, \%opts);  # Parse the options list

if (defined($opts{h}))          # Just wanted to see how to use this
{
  display_help();               # Show options
  exit 0;                       # and get out
}

# Still here: Something to parse
#
if (! defined($opts{X})) {$exec_flag = 1;}  # No -X: Run commands for real
my $ahem = ($exec_flag == 1) ? "" : " (ahem)";  # Indicate I was only kidding

die "You must specify a dbspace!"
  unless (defined($opts{d}));   # Can't create a DBspace with no name

my $vanilla = 1;                # Assume nothing out of the ordinary
my $dbspace = $opts{d};         # Still here: User specified a DBspace name

# Setup for symlink directory was completed above (Early in the game).
# do some validation on the given path (if given, of course)
#
$rawfile_path = defined($opts{p}) ? $opts{p}
                                  : $defaults->{primary_path} ;
$rawfile_path .= "/$defaults->{primary_sub_path}"   # In either case, may ap-
  if ($defaults->{primary_sub_path});               # pend a subdirectory

# Now the mirror chunk top directory poses a problem: There is no
# requirement to define a mirror with the DBspace, so the user (the DBA)
# could simply omit that option. But if the DBA wants the mirror but wants
# to use the default directory without specifying it, he can't specify -m
# without a parameter; getopts simply will not allow that!  (OK, I really
# ought to switch to Getopts::Long.  Another day..)
#
# Solution: -m requires a parameter and -M specifies mirroring to the default
# directory.  Just make sure a confused user does not specify both options
#
die "You cannot specify -M and -m options together"
  if (defined($opts{M}) && defined($opts{m}));

if    (defined($opts{M})) {$mrawfile_path = $defaults->{mirror_path};}
elsif (defined($opts{m})) {$mrawfile_path = $opts{m};}
my $mflag = defined($opts{M}) || defined($opts{m})
          ? 1 : 0;      # This will make conditional code SO much cleaner!
#
# Finally! Done with determining the directory paths for raw files
# Now for chunk sizes:
#
my $chunk_size   = defined($opts{s}) ? $opts{s} : $defaults->{chunk_size};

# Chunk type: Vanilla, Blob spae, Smart blob space, Temp space (which may
# also be a smart blob space.  Headache!)
#
my $temp_flag    = defined($opts{t}) ? "-t" : "";   # Temp DBspace? Or..
my $blob_flag    = defined($opts{B}) ? "-b" : "";   # Option for blob space
my $sbspace_flag = defined($opts{S}) ? "-s" : "";   # Option for SB Space
$vanilla = 0 if (defined($opts{B}) || defined($opts{S}));   # Not ordinary

my $blob_pg_size = 0;       # This matters only if user asked for blobspace
if ($blob_flag)
{
  $blob_pg_size = defined($opts{g}) ? $opts{g}
                                    : $defaults->{blob_page_size};
}   # Else, $blob_pg_size remains 0

die "Option -t and -B are mutually exclusive"
  if (defined($opts{t}) && defined($opts{B}));
die "Option -B and -S are mutually exclusive"
  if (defined($opts{B}) && defined($opts{S}));
die "You cannot specify a page size for an SBspace"
  if (defined($opts{k}) && defined($opts{S}));
die "-k: Wrong page size parameter for blob space. Use -g"
  if (defined($opts{k}) && defined($opts{B}));

# Validate and use page size, if specified (and valid, of course!)
#
my $page_size;
if (defined($opts{k}))          # If user specified a page size
{                               # validate it before using it
  $page_size = $opts{k};        #(Code easier to read w/o braces)
  my $def_pg_size = $defaults->{data_page_size};  #(Just for neater code)
  die "Page size must be a multiple of $def_pg_size in [$def_pg_size,16]"
    if ( (($page_size % $def_pg_size) != 0) || ($page_size > 16));
  $page_size = $opts{k};        # OK, we can use the data-page size specified
}
else {$page_size = $defaults->{data_page_size};}

# Now validate chunk size.  That is, did user request a large chunk with large
# chunks disabled?  Ah, but getting that tidbit requires getting the full
# DBspace and Chunk information for the server.  We'll need all that soon
# anyway so let's go for that now.
#
my $dbspace_info = dbspace_pages();     # Get all vital stats
my ($all_dbspaces, $all_chunks) = @{$dbspace_info}{qw(dbspaces chunks)};
# My apologies: I have not completely implemented DBspaces.pm and this utility
# in the proper object-oriented model.  -- JS

$all_chunks = $dbspace_info->expand_symlinks();     # And symlink targets
$dbspace_info->order_chunks();						# Sort, while I'm at it
my $large_chunk_ok = large_chunks_enabled();        # and get that tidbit

# Now I can check if the indicated chunk size is permitted and stop the
# show if user tried to violate it
#
die "Expanded chunks feature is disabled; you cannot specify $chunk_size"
  if (!$large_chunk_ok &&  $chunk_size > $defaults->{chunk_size});

# But wait! There's more!  Make sure the page size divides neatly into the
# chunk size.  If not, yank down the chunk size properly.  The item to
# check for is slightly different for a blob space than for a data space.
#
if (defined($opts{B}))      # For a blob space, -g page size refers to how many
{                           # data pages fit in a blob page. Get that in KB
  my $bpage_size = $blob_pg_size * $defaults->{data_page_size};
  my $remainder = $chunk_size % $bpage_size;    # NOW check for remainder
  $chunk_size -= $remainder;                    # Yank it down to a multiple

}
else
{
  my $remainder = $chunk_size % $page_size; # Did it divide nicely?
  $chunk_size -= $remainder;                # Yank it down to be a multiple
}
#
# Still here - the requested chunk size is OK.
# Now about validating that dbspace:
# 1. Is it OK syntax for a DBspace name? That is:
#    a. Start with lower-case alpha
#    b. Optionally followed by mixed alphanumeric (lower case only) and
#       underscore
# 2. Is there already a dbspaces by that name in the server?
#
{ # Check syntax for the name of the new DBspace
  #
  my $alpha_pat = qr([a-z]);      # Lower-case alpha
  my $alphan_pat = qr([a-z0-9_]); # lc + numbers + underscore
  my $dbspace_pat = qr(^($alpha_pat)($alphan_pat)*$);   # DBspace regex
  die "<$dbspace> is not valid as a DBspace name"
    unless ($dbspace =~ $dbspace_pat);  # If name is bad, stop now!
}

die "DBspace <$dbspace> already exists in this server"
  if (dbspace_inuse($dbspace, $all_dbspaces));

# Next validation: The path parameter in variable $rawfile_path. First let's
# set up the complete directory for this raw path by appending any default
# sub-directory thereto
#
$rawfile_path .= "/$defaults->{primary_sub_path}"
  if ($defaults->{primary_sub_path});

if ($mflag)
{
  $mrawfile_path .= "/$defaults->{mirror_sub_path}"
    if ($defaults->{mirror_sub_path});
}
# Note:
# I've decided not to do any validation of the complete directory paths at this
# point. When I try to create the raw chunk file(s) I'll just get an error then
#
#
#X-There is a default directory for
#X-# this in the %defaults hash but that can be overridden by the -p parameter.
#X-# And if there is a default sub-path specified it will be appended to the
#X-# path directory.
#X-#
#X-# Oh, one more item: The chunk_path may be a directory or a symlinkk to one.
#X-# I need to make sure it is a directory at the bottom line
#X-#
#X-my $real_path = (-l $rawfile_path) ? abs_path($rawfile_path) | $rawfile_path;
#X-die "-p <$rawfile_path>: Specify an existing directory or symlink to it"
#X-  unless (-d $real_path);       # If you gave me a path, it must be a dir
#X-
#X-# So the specified directory is legit
#X-#
#X-my (%path_stats, %mpath_stats); # Hashes for vital stats about the file/path
#X-@path_stats{qw/dev ino mode nlink uid gid rdev size
#X-               atime mtime ctime blksize blocks/}
#X-         = stat($real_path);    # Get those vital stats. Mainly want {mode}
#X-die "Unable to stat($rawfile_path)" unless (defined($path_stats{mode}));
#X-$path_stats{perms} = $path_stats{mode}; # Add my own field to mangle it a bit
#X-$path_stats{perms} &= oct("0777");      # Mask off anything left of these bits
#X-
#X-# If if a mirror chunk was defined, put it through the same tests
#X-#
#X-if (defined($mrawfile_path))
#X-{
#X-  my $mreal_path = (-l $mrawfile_path) 
#X-                 ? abs_path($mrawfile_path) | $mrawfile_path;
#X-  die "-p <$mrawfile_path>: Specify an existing directory or symlink to it"
#X-    unless (-d $mreal_path);      # If you gave me a path, it must be a dir
#X-
#X-  # So the specified directory is legit
#X-  #
#X-  @mpath_stats{qw/dev ino mode nlink uid gid rdev size
#X-                  atime mtime ctime blksize blocks/}
#X-           = stat($mreal_path);   # Get those vital stats. Mainly want {mode}
#X-  die "Unable to stat($mrawfile_path)" unless (defined($mpath_stats{mode}));
#X-  $mpath_stats{perms} = $mpath_stats{mode};# Add my own field to mangle it a bit
#X-  $mpath_stats{perms} &= oct("0777");     # Mask off anything left of these bits
#X-}
#X-                            # Now, even though we passed the stats...
#X-my $dir_ok     = 0;         # Don't assume directory is completely valid
#X-my $file_ok    = 0;         # Similarly, don't assume file path is valid
#X-my $symlink_ok = 0;         # or even a symlink
#X-#
#X-# Validation of the given path name.  The goal of the if/else sequence is
#X-# to make sure $rawfile_path and a corresponding $symlink_path are usable for
#X-# the new chunk.
#X-# I may need to check against existing symlinks and their targets so...
#X-#
#X-#Xmy %step_flags = (create_symlink => 0,  # Indicators of what I must do
#X-#X                  create_rawfile => 0); # Assume I create nothing
#X-
#X-$chunk_path .= "/$defaults->{primary_sub_path}" # Append subdirectory
#X-  if ($defaults->{primary_sub_path});           # if it is defined
#X-
#X-# If a mirror was specified then do the same validations I did for the primary
#X-#
#X-if ($mirror_path)               # If user wants this DBspace to be mirrored
#X-{                               # then we have a top directory in $mirror_path
#X-  $real_path = (-l $mirror_path) ? abs_path($mirror_path) | $mirror_path;
#X-  die "-m <$mirror_path>: Specify an existing directory or symlink to it"
#X-    unless (-d $real_path);     # If you gave me a path, it must exist
#X-                                # (Shoulda just omitted the -p in that case)
#X-  # So the specified directory (or symlink) is legit so far.  Use the same
#X-  # stat call as before to see if I can access it.
#X-  #
#X-  @mpath_stats{qw/dev ino mode nlink uid gid rdev size
#X-                  atime mtime ctime blksize blocks/}
#X-         = stat($real_path);    # Get those vital stats. Mainly want {mode}
#X-  die "Unable to stat($mirror_path)" unless (defined($mpath_stats{mode}));
#X-  $mpath_stats{perms} = $path_stats{mode}; # Add my own field to mangle it a bit
#X-  $mpath_stats{perms} &= oct("0777");      # Mask off anything left of perms
#X-  $mirror_path .= "/$defaults->{mirror_sub_path}"   # Append subdirectory if
#X-    if ($defaults->{mirror_sub_path});              # that is defined
#X-}
#
# OK, we have the target directories for the raw files for the primary and
# (maybe) mirror chunks.  Next: Generate the raw file name(s) and path(s)
#
my $use_file_num = next_file_num();     # Generate a number for next raw file
$rawfile_name = sprintf("file.%0*d",    # Format the file name
                           $defaults->{raw_decimals}, $use_file_num);
$rawfile_path .= "/$rawfile_name";  # Append new file name to raw file path

$mrawfile_path .= "/$rawfile_name"  # Append new file name to mirror-raw
  if ($mflag);                      # file path, if applicable

# Also generate the complete path name for symlink(s) to -> raw file(s)
# (The location of all symlinks was set up very early in this program.)
#
$symlink_name = sprintf("%s.%s.P.%0*d",                     # Generate file
                        $ENV{INFORMIXSERVER}, $dbspace,     # name for the
                        $defaults->{chunk_decimals}, 1);    # symlink
$symlink_path .= "/$symlink_name";  # Append symlink name to symlink directory

if ($mflag)                         # If DBspace is to be mirrored
{                                   # create a mirror symlink name
  $msymlink_name = sprintf("%s.%s.m.%0*d",                  # Almost identical
                           $ENV{INFORMIXSERVER}, $dbspace,  # to primary
                           $defaults->{chunk_decimals}, 1); # symlink name
  $msymlink_path .= "/$msymlink_name";  # And append that to the directory
}
else {$msymlink_path = "";}     # Sure signal not to use it in onspaces command

# Now, the likelihood of this is really low and would indicate a bug in the
# process.  But let's just make sure these 2 or 4 files do not exist yet:
#
die "Designated raw primary file $rawfile_path already exists"
    if (-e $rawfile_path);
die "Primary symbolic link/file $symlink_path already exists"
    if (-e $symlink_path);
if ($mflag)                     # No need to check this if I had not intended
{                               # to mirror this new DBspace
  die "Designated raw mirror file  $mrawfile_path already exists"
      if (-e $mrawfile_path);
  die "Mirror symbolic link/file $msymlink_path already exists"
      if (-e $msymlink_path);
}
# My action steps at this point:
# 1a. Create the raw file, the targer of the primay symlink
# 1b. (Maybe) Create the mirror raw file

# Note: With the current Perl installation, we cannot compile File::Touch and
# hence, the touch() call cannot work.  Using brute force system() # instead
#
my $touch_command  = sprintf("touch %s", $rawfile_path);
printf("%s\n", $touch_command); # Display the command I would run
my $mtouch_command = "";        #(Not sure if I'm should run this)
if ($mflag)
{
  $mtouch_command = sprintf("touch %s", $mrawfile_path);
  printf("%s\n", $mtouch_command);  # Display the command I would run
}

if ($exec_flag)                   # Still here: I can safely create the file
{
  my $touch_success = system($touch_command);
  die "Error <$!> trying to create $rawfile_path"
    unless ($touch_success == 0);

  if ($mflag)
  {
    $touch_success = system($mtouch_command);
    die "Error <$!> trying to create $mrawfile_path"
      unless ($touch_success == 0);
  }
}

# Steps 2a 2b: Set permissions on the raw files
#
printf("chmod 660 %s\n", $rawfile_path);
printf("chmod 660 %s\n", $mrawfile_path) if ($mflag);

if ($exec_flag)
{
  die "Error <$!> setting permissions on $rawfile_path"
    unless (chmod 0660, $rawfile_path);
  if ($mflag)
  {
    die "Error <$!> setting permissions on $mrawfile_path"
      unless (chmod 0660, $mrawfile_path);
  }
}
# OK, so the raw files, both primary and mirror (as appropriate) both exist
# and have correct permissions.
# (Assumption: Ownership is already informix:informix
#
# Steps 3a, 3b: Connect the symlink file names to their targets
# As before, announce our intentions
#
printf("ln -s %s %s\n", $rawfile_path,  $symlink_path);
printf("ln -s %s %s\n", $mrawfile_path, $msymlink_path) if ($mflag);
if ($exec_flag)                     # Still here: I can safely create symlink
{                                   #(Or die trying)
  my $symlink_success = symlink($rawfile_path, $symlink_path);
  die "Error <$!> creating symbolic link $symlink_path->$rawfile_path!"
    unless ($symlink_success);      # can't create symlink - stop there!
  if ($mflag)
  {
    $symlink_success = symlink($mrawfile_path, $msymlink_path);
    die "Error <$!> creating symbolic link $msymlink_path->$mrawfile_path!"
      unless ($symlink_success);    # can't create symlink - stop there!
  }
}

# Steps 4a and 4b: Generating the onspaces commands.  
# Whew! Passed all that gauntlet!  At this point I know that:
# - The raw file and the symbolic link referencing it are both in place.
# - The dbspace does not exist yet and we can get down to the
#   business of actually creating the dbspace.
# - The chunk size is a guaranateed  multiple of the page size
#
my $remainder_pages;                # Used in calculating rounded-up size
my $onspaces_cmd = "";              # Build complete command in here
if ($vanilla)                       # Regular or temp dbspace:
{                                   # Build here:
  $onspaces_cmd = sprintf("onspaces -c -d %s -k %d %s",
                            $dbspace, $page_size, $temp_flag);
}

elsif ($sbspace_flag)               # Normal or temp SBspace:
{
  $onspaces_cmd = sprintf("onspaces -c -S %s %s",
                          $dbspace, $temp_flag);
}
elsif ($blob_flag)                  # Blob space:
{
  $onspaces_cmd = sprintf("onspaces -c -b %s -g %s",
                           $dbspace, $blob_pg_size);
}
else {die "BUG: Space not of type -d, -b, -S, or -t";}

# Now ready to set up the remaining options of onspaces command
#
$onspaces_cmd = sprintf("%s -p %s -o 0 -s %d",
                        $onspaces_cmd, $symlink_path, $chunk_size);
if ($mflag)                     # If space it to be mirrored
{                               # append the mirror chunks information
  $onspaces_cmd = sprintf("%s -m %s 0",
                          $onspaces_cmd, $msymlink_path);
}
printf("%s\n", $onspaces_cmd);
#
# Now for my raison d'être: Run the onspaces command
#
if ($exec_flag)
{
  my $onspaces_exit_code = system($onspaces_cmd);       # MOMENT OF TRUTH!
  die "onspaces command failed with code $? <$!>!"
    unless ($onspaces_exit_code == 0);    # Uh-oh! onspaces failed
  print "onspaces command completed successfully\n";    # Hey, I did not die!

  #***************************************************
  # * INSERT BOOKKEEPING CODE (maintain_chunks) HERE *
  #***************************************************
}
printf("Successfully created %s new dbspace: %s\n", $ahem, $dbspace);

exit 0;                                 # Make a successful exit
#
sub display_help
{
  print <<EOH
This program adds creates a new DBspace

Usage:
$me -h     # Display this help text

In the samples below, the -X is a debugging mode: It generates the commands
that you copy into a script but does not run them.

Ordinary dbspace:
$me [-X] -d dbspace [-p <path>] [-s size (in kb)]

The dbspace name must be provided and must not exist; this program creates them

-p path: This should be a top-level directory.  The default is
   $defaults->{primary_path}.  If a default sub-path (like "files") is defined,
   $me will append that sub-path to this, for example:
   $defaults->{primary_path}/files.  This is where the raw file will be
   created.  And, of course, if that sub-path is not defined, the raw files
   will be created under this path.

-m path:
   Specify mirroring on this new DB spaces in the directory that I specify
   The options for mirror path are identical to those for -p but refer to
   file for the mirror chunk

-M Specify mirroring but in the default mirror chunk directory. This will
   be $defaults->{mirror_path} on this server.

   If you specifiy neither M nor m, the DBspace will not be mirrored.

-s Size of the chunk in kb.  If omitted, the default is 2097150, 1 page shy
   of 2gB.

-X Output the shell commands but do not execute them.


Additional command line options:
o -k    Page size. Default: 2 (for 2-k page size). Must be a multiple of 2
        for the number of K for the page size.
o -t    for temp DBspace
o -B    for blob space (Cannot specify with -t of course)
o -g    Page size for Blob pages - Treated differently from vanilla dbspaces.
        It refers to the blob page as a multiple the default data-page
        size. For example, if the default data page is 2K then -g 3 means
        the blob page in this dbspace is 6K, 3 times the defaule size of a
        data page
o -S    for Smart-Blob (SB) space.  May be used together with -t.  But you
        cannot specify a page size (-g) as with a regular blob space
o -E    Create an EXTspace.  Syntax is accepted but ignored. At this time this
        utility does not support EXTspaces
EOH
}
__END__

=pod

=head1 Program Name

new-dbspaces.pl (or just "new-dbspace" if you have set up the symlink for it)

=head2 Author

 Jacob Salomon
 jakesalomon@yahoo.com

=head2 Abstract

Creates a new DBspace in the current Informix server, subject to the
options provided and default options.

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

=head2 Synopsis of basic options

new-dbspace [-X] -d <dbspace> [-p <path>] [-s <size in kb>] [{-M}, {-m
<path>}]

Note that the only required parameter is the name of the new DBspace

=over 4

=item * -X  Display equivalent shell commands for each step in the creation
of the new DBspace but do not execute them.  This is for debugging your
command line; it's awkward to back out the creation of a new space.  The
default is to display the shell commands and execute Perl equivalents of
those commands.

=item * -d <dbspace>    Specify the name of the new DBspace.  If the
DBspace exists already, we carp about it and exit.

=item * -p <path>       Specify the location - the file system - in which
to create the first primary chunk of the new DBspace.  This defaults to
/ifmxdevp and, unless that file system is already full, there is no real
reason to override this default.

=item * -s <size in kb> Specify the size of the chunk, in KB.  Defaults to
2GB minus the default size of a page for this machine/release.  Check your
local notes file ($INFORMIXDIR/SERVER/doc/ids_machine_notes_<release>.txt)
for that information.

=item * -m <path>       Specify the location - the file system of the mirror
chunk, if desired.  This also has a default: /ifmxdevm.  So if you want the
mirror in the default location, you can use:

=item * -M              Just create the mirror chunk in the default mirror
file system.

=back

=head2 Additional options

=over 4

=item * -k <page size>  Specify the page size (in KB) for this DBspace.  Default
is usually 2 but for some hardware it may be 4.  Check your local machine_notes
file. (See the -s option)

=item * -B  Flag that this is a Blob space. It it strongly advised that you
also suppy a page size parameter for the Blob space, in the form of:

=item * -g <page-multiple>  The size of a blob page in this blob space.
This is not in K; it is data pages.  For example, if yout default page dize
is 4K and you specify -g 3 then every blob page in this blob space will be
12K; 3 X the size of a data page.

=item * -t  Specifies that this is a temp space.

=item * -S  Specifies that this a SmartBlobSpace (SBspace). It may be used
with the -t option.  But you cannot specify a blob page size for an SBspace.

=item * -E  Specifies that this is an EXTspace.  We accept the syntax but
really, this utility does not [yet] support EXTspaces.  We will create a
regular DBspace instead.

=back

=head2 Example

$ new-dbspace -d fred_space -d /ifmxdevp -s 1000000 -M

The output of this command will look like:

 touch /ifmxdevp/file.00014
 touch /ifmxdevm/file.00014
 chmod 660 /ifmxdevp/file.00014
 chmod 660 /ifmxdevm/file.00014
 ln -s /ifmxdevp/file.00014 /ifmxdev/js_server.fred_space.P.001
 ln -s /ifmxdevm/file.00014 /ifmxdev/js_server.fred_space.m.001
 onspaces -c -d fred_space -k 2  -p /ifmxdev/js_server.fred_space.P.001 -o 0 -s 1000000 -m /ifmxdev/js_server.fred_space.m.001 0
 Successfully created  new dbspace: fred_space

Notice the left-0 padding on the file number and the chunk number.  Notice
also the symlink name of the chunk file. The format is:
/ifmxdev/<server>.<dbspace>.{P|m}.nnn

=head3  Additional notes

The default directories for chunks symlinks, as well as the location of the
"raw" files of the primary and mirror chunks, can all be monkeyed with using
the file /ifmx-work/dbspace-defaults.cfg.  So can the left-padding of zeroes
on the chunk and file numbers. This will be better explained in the perldoc for
the package DBspace.pm

=cut
