#!/usr/bin/perl -w
#+---------------------------------------------------------------------------+
#| Copyright (C) Jacob Salomon - All Rights Reserved                         |
#| Unauthorized use of this file is strictly prohibited                      |
#| Unauthorized copying of this file, via any medium, is strictly prohibited |
#| Proprietary and confidential                                              |
#| Written by Jacob Salomon <jakesalomon@yahoo.com>                          |
#+---------------------------------------------------------------------------+
# add-chunk.pl - Add a chunk to an existing dbspaces in the current IDS server
#                using the chunk-path naming conventions established for Onyx
# Author:   Jacob Salomon
#           Axiom Technology
#
# Command line options:
# -X    Generate the shell commands but do not execute them
# -d    Name of the dbspace - required
# -c    Count Chunks: How many chunks to create in this dbspace.
# -p    Path: The name of the "raw-file" top-level directory.
#       If omitted, we will automatically generate a new file name in
#       directory /ifmxdevp with a file number 1 + the current highest
#       file number of all chunk files.
# -m    Also a path: The top level directory of the locationof the mirror
#       chunk.
# -s    Size of the chunk to be created. Default 2,097,150K (sans the commas,
#       of course). Note that an offset of 0 will ALWAYS be used in our
#       conventions
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
#use File::Touch;       #(Version on CPAN needs later release of Makemake)
use Scalar::Util qw(looks_like_number);
#use DBI;
#use DBD::Informix;
use DBspaces;
use DBspaces qw(dbspace_defaults validate_file validate_symlink);

my $me = basename($0);          # Name of running script w/o directory stuff
#
# Default values, to be modified if user specifies the corresponding option
#
my $defaults = dbspace_defaults();
my ($def_raw_dir, $p_sub_path,
    $def_mir_dir, $m_sub_path,
    $symlink_dir, $s_sub_path,
    $def_chunk_size, $def_page_size, $def_blob_page_size)
  = @{$defaults}{qw(primary_path primary_sub_path
                    mirror_path mirror_sub_path
                    symlink_path symlink_sub_path
                    chunk_size data_page_size blob_page_size)};
my ($raw_places, $sym_places) = @{$defaults}{qw(raw_decimals chunk_decimals)};
my $ifmx_server = $ENV{INFORMIXSERVER};

my $UID = $<;                   # $UID not available in this Perl release
my $GID = $( + 0;               # Neither is $GID. (+0 is Perl bug workaround)
my $run_user = getpwuid($UID);  # Name of user running this. Must be informix
my $command = "";               # Create command lines in here

my $symlink_path = undef;       # The symbolic link to use for chunk path
my $rawfile_path = undef;       # Target file for above symlink
my ($symlinks, $rawpaths,       # Arrays of symlink path names and
    $msymlinks, $mrawpaths);    # their corresponding target files plus
                                # similar array refs for mirror paths
my $top_dir      = "/ifmxdev";  # Default target directory
my $exec_flag    = 0;           # Assume we will not actually execute commands

# Ready to parse command line
#
my $option_list = "hXd:c:p:m:s:"; # All options (but help) require a parameter
my %opts;                       # Hash for chosen options & values
die "Unknown option specified on command line"
 unless (getopts($option_list, \%opts));    # Parse the options list

if (defined($opts{h}))          # Just wanted to see how to use this
{
  display_help();               # Show options
  exit 0;                       # and get out
}

# Still here: Something to parse
# All parameters are subject to validation
#
$exec_flag = 1 unless (defined($opts{X}));  # Testing or really want new chunk?
my $ahem = ($exec_flag == 1) ? "" : " (ahem)";  # Indicate I was only kidding

die "You must specify a dbspace!"           # Did user specify a dbspace?
  unless (defined($opts{d}));               # Can't add chunk to no dbspace.
my $dbspace = $opts{d};         # Still here: User specified it

# Did the user specify a chunk count, size or location?
#
my $chunk_count = defined($opts{c}) ? $opts{c} : 1; # Default: 1 chunk
my $chunk_size  = defined($opts{s}) ? $opts{s} : $def_chunk_size;   # Size?
my $chunk_path  = defined($opts{p}) ? $opts{p} : $def_raw_dir;      # Location?
my $mirror_path;                # Don't define it here; wait to determine
                                # if the indicated DBspace is even mirrored.
#
# Some validations require I know what dbspaces and chunks are already out
# there.  Get that information now.
#
my $dbspace_info = dbspace_pages();         # Get all vital stats
my ($dbspaces, $chunks) = @{$dbspace_info}{qw(dbspaces chunks)};
# My apologies: I have not completely implemented DBspaces.pm and this
# utility in the proper object-oriented model.  -- JS

$chunks = $dbspace_info->expand_symlinks();  # Get more complete chunk info

# First off: Adding chunk to an existing DBspace.  Let's make sure that
# DBspace actully exists in our server:
#
my $dbspace_num = dbspace_inuse($dbspace, $dbspaces);
die "DBspace $dbspace does not exist in server $ifmx_server"
  if ($dbspace_num == 0);

# Now that I have the proper DBspace number, I can check if it is mirrored
# and then look at the -m option
#
if ($dbspaces->[$dbspace_num]{mirrored} eq "M") # If this DBspace is mirrored
{                                               # I can think about -m option
  $mirror_path = defined($opts{m}) ? $opts{m} : $def_mir_dir ;
}                                           # Otherwise, ignore -m option

# Next validation: The path parameter.  This has a few possible formats:
# - The path of a directory in which to create the target "raw" file
# - The full path name of a file, which had better not be associated with
#   any existing chunk in any server.  (Although the convention here has
#   been one server per host, I cannot assume that will always be the case.)
#
die "<-p $chunk_path>: You must specify an existing file or directory!"
  unless (-e $chunk_path);      # If you gave me a path, it must exist
                                # (If symlink, its target must also exist)

# So the specied directory or file exists.
#
my %path_stats;                 # Hash for vital stats about the file/path
@path_stats{qw/dev ino mode nlink uid gid rdev size
               atime mtime ctime blksize blocks/}
         = stat($chunk_path);   # Get those vital stats. Mainly want {mode}
die "Unable to stat($chunk_path)" unless (defined($path_stats{mode}));
$path_stats{perms} = $path_stats{mode}  # Add my own field to mangle it a bit
                   & oct("0777");       # Mask off anything @left of these bits

                            # Now, even though we passed the stats...
my $dir_ok     = 0;         # Don't assume directory is valid
my $file_ok    = 0;         # Similarly, don't assume file path is valid
my $symlink_ok = 0;         # or even a symlink

# I may need to check against existing symlinks and their targets so...
#
my %step_flags = (create_symlink => 0,  # Indicators of what I must create
                  create_rawfile => 0); # Pretend I need create nothing
#
# Validate chunk size.  It may exceed 2GB if "Expanded chunk capacity mode"
# is enabled.  Otherwise, barf.
#
my $large_chunk_ok = large_chunks_enabled();    # Chunk > 2GB permitted?
die "Expanded chunk is disabled; you cannot specify $chunk_size"
  if (!$large_chunk_ok &&  $chunk_size > $def_chunk_size);

# Now how about the chunk size?  The requested chunk size is probably OK
# but it must be a multiple of the page size of the DBspace. Scheme:
# - First locate the space's entry in the $dpspaces array AKA dbspace number
# - Use the {pgsize} field to round up chunk_size to next multiple of page size
#
$chunk_size = round_down_size($dbspaces->[$dbspace_num]{pgsize}, $chunk_size);

# Now about validating the given path name.  I may need to check against
# existing symlinks and their targets so...
#
if (-d $chunk_path)         # Given path is a directory
{ # Since the raw file will go into a "files" subdirectory of this one,
  # let's make sure that subdirectory is valid and accessible.  
  # The top level path, if a directory, is most likely, the mount point of
  # a file system.  Validations:
  # 1. The directory (or FS) must have a "files" subdirectory
  # 2. That subdir must be owned by informix
  # 3. User informix must have rwx privilege on that subdirectory
  # Pass all that and I will generate at least one (symlink, raw-file) pair.
  # If user specified -c greater than one, I will create as many such pairs
  # as requested.
  #
  @step_flags{qw(create_symlink create_rawfile)}    # Flag: Create both, raw
   = (1, 1);                            # file and the symlinkg to reference it

  my $files_path = ($defaults->{primary_sub_path} eq "")
                 ? $chunk_path
                 : sprintf("%s/%s", $chunk_path, $defaults->{primary_sub_path});

  # mirror_path was already set a bit past the program start, to either the
  # default mirror path or the specified mirror directory.  Now see about
  # appending the subdirectory to that, if such was set up in our defaults.
  #
  if ($dbspaces->[$dbspace_num]{mirrored} eq "M")
  {
    $mirror_path = sprintf("%s/%s", $mirror_path, $defaults->{mirror_sub_path})
      unless ($defaults->{mirror_sub_path} eq "");
  }

  # Said subdir must exist and, furthermore, I, Informix, must own that dir
  #
  die "User $run_user does not have proper access on <$files_path>!"
    unless (   (-e $files_path) && (-o $files_path)
            && (-r $files_path) && (-w $files_path) && (-x $files_path));
  if (length($mirror_path))     # If I have set up a string for the directory
  {                             # of the mirror chunk(s) do that same check.
    die "User $run_user does not have proper access on <$mirror_path>!"
      unless (   (-e $mirror_path) && (-o $mirror_path)
              && (-r $mirror_path) && (-w $mirror_path) && (-x $mirror_path));
  }
  $dir_ok = 1;              # It passes muster as a directory
#
  # I need to generate names for the raw file path and symlink path (or
  # multiples thereof, if -c was specified.)  Create those items soon
  #
  ($symlinks, $rawpaths) = gen_fnames($chunks, $ifmx_server, $dbspace,
                                      $chunk_path, $chunk_count);
  if (length($mirror_path))     # If I need to deal with mirror chunk
  {
    @$msymlinks = @$symlinks;   # Start with identical symlink paths
    @$mrawpaths = @$rawpaths;   # and identical raw file path names but..
    map { s/\.P\./.m./ ; $_}       @$msymlinks; # But change P to m in symlink
    map {s/$chunk_path/$mirror_path/; $_} @$mrawpaths; # and to mirror top dir
  }
  else                          # If no mirroring is involved, set some
  {                             # indicator to add_1chunk() to not bother
    $msymlinks->[0] = $mrawpaths->[0] = ""; # with mirror chunks.
  }
}
#
else                        # Given path is none of the above
{ die "Path <$chunk_path> is not an acceptable file type!" }

# Still here? The dbspace exists and we can get down to the business of
# actually creating the chunk.  The twin arrays @$symlinks and @$rawpaths
# already hold the path names of the entities that will comprise the new
# chunks(s)
#
# WOW! All the parameters I need for a new chunk are in place!
# - $dbspace:       The name of the dbspace
# - @$symlinks:     The path name(s) of the symbolic link(s)
# - @$rawpaths:     The path name(s) of the raw file(s)
# - $chunk_size:    The size (in KB) of the desired chunk. (Well, that is
#                   still subject to adjustment.)
# - $exec_flag:     Whether I really want to do this or just generate commands
#
# Now create all those new chunks in the for-loop below.
#
my $chunks_added = 0;                   # Haven't added any yet
my $add_success = 0;

# Create a hash for those 4 arrays in order to pass fewer parameters to
# add_1chunk();
#
my %path_list = (symlinks  => $symlinks,
                 rawpaths  => $rawpaths,
                 msymlinks => $msymlinks,
                 mrawpaths => $mrawpaths);

if ( $step_flags{create_symlink} && $step_flags{create_rawfile})
{ # That is: If I am to create both symlink[s] and raw file[s], use this loop
  #
  for (my $clc = 0; $clc < $chunk_count; $clc++)
  {
    $add_success
    = add_1chunk($exec_flag, $dbspace, $chunk_size, \%path_list, $clc);
    last if ($add_success != 1);        # Failed once - stop right there!
    $chunks_added += $add_success;      # Tally up successful adds
  }
}

printf("\nAdded %d%s of %d chunks to dbspace %s\n",
       $chunks_added, $ahem, $chunk_count, $dbspace);

exit 0;                                 # Make a successful exit
#
# Subroutine: add_1chunk() - Assumes all parameters are valid and applies
# them to the addition of the new chunk to the indicated dbspace. It may
# have to create the raw file and the symbolic link before invoking the
# onspaces command.
# Parameters:
# - The execute-flag: 1 for "I mean it", 0 for "Just kidding"
# - Name of the dbspace:
# - The size, in K of the chunk to be added
# - A reference to a hash with following members:
#   o symlinks  => $symlinks,
#   o rawpaths  => $rawpaths,
#   o msymlinks => $msymlinks
#   o mrawpaths => $mrawpaths
# - The index number within the array to fetch all the path-related parameters
# Returns:
# - +1 for success, 0 for failure
#
sub add_1chunk
{
  # Easy start: Just get my parameters
  #
  my ($exec_flag, $dbspace, $chunk_size, $path_hash, $entry)
    = @_; 
  my $rval = 1;                 # Assume I will be successful

  my $rawfile_path  = $path_hash->{rawpaths}[$entry];
  my $symlink_path  = $path_hash->{symlinks}[$entry];
  my ($mrawfile_path, $msymlink_path)   # Will I put values in here?
    = (length($path_hash->{mrawpaths}[0]) > 0)
    ? ($path_hash->{mrawpaths}[$entry], $path_hash->{msymlinks}[$entry])
    : ("", "");

  #(Gulp! OK above means: If mirorring is set for this dbspace (as
  # indicated by a genuine entry in the mirror-paths array) the set my
  # internal variables to the indicated values.  Otherwise, set 'em to
  # empty strings.
  #

  # 1a. Create the target raw file, if it does not exist yet
  #
  #X-Note: With the Perl release 5.8, we cannot compile File::Touch and hence,
  #X-the touch() call cannot work.  Using brute force system() instead
  #X-
  #X-if ($exec_flag)
  #X-{ touch($rawfile_path)             # Create the file from scratch
  #X-    unless (-e $rawfile_path);}    # if it does not exist yet
  #X
  my $touch_command = sprintf("touch %s", $rawfile_path);

  if (! ((-e $rawfile_path) && (-f $rawfile_path))) # If target file does not
  {                                 # exist yet, just gotta do it myself
    printf("\n%s\n", $touch_command);
    if ($exec_flag)
    {
      my $touch_success = system($touch_command) if ($exec_flag);
      if ($touch_success != 0)      # (Exit code is 0 if success)
      {
        carp "Error number $touch_success on touch $rawfile_path";
        $rval = 0;                  # Not successful
      }
    }
  } # Otherwise, it existed already and has passed its own validations
  goto return_point if ($rval == 0);    # Exit if no  point in continuing

  # 1b. Create the mirror raw file, if relevant
  if (length($mrawfile_path))
  {
    my $touch_command = sprintf("touch %s", $mrawfile_path);

    if (! ((-e $mrawfile_path) && (-f $mrawfile_path))) # If target file does
    {                               # not exist yet, just gotta do it myself
      printf("%s\n", $touch_command);
      if ($exec_flag)
      {
        my $touch_success = system($touch_command) if ($exec_flag);
        if ($touch_success != 0)        # (Exit code is 0 if success)
        {
          carp "Error number $touch_success on touch $mrawfile_path";
          $rval = 0;                    # Not successful
        }
      }
    }   # Otherwise, it existed already and has passed its own validations
    goto return_point if ($rval == 0);  # Exit if no  point in continuing
  }
#
  # 2a. Set permissions on the file so that Informix likes it
  #
  printf("chmod 660 %s\n", $rawfile_path);
  if ($exec_flag)
  {
    my $chmod_success = chmod 0660, $rawfile_path;
    if ($chmod_success < 1)
    {
      carp "Error <$!> setting permissions on $rawfile_path";
      $rval = 0;                    # This will not fly
    }
  }
  goto return_point if ($rval == 0);    # This did not fly

  # 2b. Same step for mirror chunk, if relevant.
  #
  if (length($mrawfile_path))
  {
    printf("chmod 660 %s\n", $mrawfile_path);
    if ($exec_flag)
    {
      my $chmod_success = chmod 0660, $mrawfile_path;
      if ($chmod_success < 1)
      {
       carp "Error <$!> setting permissions on $mrawfile_path";
       $rval = 0;                   # This will not fly
      }
    }
    goto return_point if ($rval == 0);  # This did not fly
  }

  # 3a. Create the symbolic link: chunk-path -> raw file path, if the symlink
  #     does not already exist
  #
  if (! ((-e $symlink_path) && (-l $symlink_path)) )    # If the symlink does
  {                                                     # not exist yet
    printf("ln -s %s %s\n", $rawfile_path, $symlink_path);  # Say what I will do
    if ($exec_flag)                         # and if user means it, do it!
    {
      my $symlink_success = symlink($rawfile_path, $symlink_path);
      if (! $symlink_success)       # Can't create symlink - stop there!
      {
        carp "Error <$!> creating symbolic link $symlink_path->$rawfile_path!";
        $rval = 0;                  # No reason to continue
      }
    }
  }
  goto return_point if ($rval == 0);    # This did not fly

  # 3b. Perform same service for the symbolic link, if relevant
  #
  if (length($mrawfile_path))
  {
   if (! ((-e $msymlink_path) && (-l $msymlink_path)) )  # If the symlink does
   {                                                     # not exist yet
    printf("ln -s %s %s\n", $mrawfile_path, $msymlink_path); # Say what I plan
    if ($exec_flag)                         # and if user means it, do it!
    {
      my $msymlink_success = symlink($mrawfile_path, $msymlink_path);
      if (! $msymlink_success)      # Can't create symlink - stop there!
      {
       carp "Error <$!> creating symbolic link $msymlink_path->$mrawfile_path!";
       $rval = 0;                   # No reason to continue
      }
    }
   }
   goto return_point if ($rval == 0);    # This did not fly
  }

  # Otherwise, the symlink already exists and has passed it own validations
  goto return_point if ($rval == 0);    # Exit if no  point in continuing

  # 4. Build the onspaces command
  #
  my $onspaces = sprintf("onspaces -a %s -p %s -o 0 -s %d",
                         $dbspace, $symlink_path, $chunk_size);
  if (length($mrawfile_path))   # If DBspace is mirrored, the chunk symlink
  {                             # is ready to be included in onspaces command
    my $mirror_clause = sprintf("-m %s 0", $msymlink_path); # Build the clause
    $onspaces = sprintf("%s %s", $onspaces, $mirror_clause); # Append clause
  }

  # 5. Now for my raison d'être: Run the onspaces command
  #
  printf("%s\n", $onspaces);                # Say what I intend to do
  if ($exec_flag)                           # Do it only if user means it
  {
    my $onspaces_exit_code = system($onspaces);         # MOMENT OF TRUTH!
    if ($onspaces_exit_code == 0)           # Successful program execution
    {
      print "onspaces command completed successfully\n";    # Hey, it worked!
    }
    else                                    # It didn't fly after all! :-(
    {
      carp die "onspaces command failed with code $? <$!>!";
      $rval = 0;                            # Make sure caller knows that.
    }

    #***************************************************
    # * INSERT BOOKKEEPING CODE (maintain_chunks) HERE *
    #***************************************************
  }

return_point:
  return $rval;
}
#
# Function: next_symlink()
# Generates a new symlink path name for the indicated dbspace
# Parameters:
# - Reference to the $chunks array from dbspace_pages()
# - Name of the dbspace
# Returns
# - A new symlink path name, to be attached to a raw file (but not here)
#
sub next_symlink
{
  my ($chunks, $dbspace) = @_;  # Name my parameters. (Use familiar names)
  my $rsymlink;                 # Symlink to return to caller

  # Array of indexes into @$chunks, but only those entries for this dbspace
  #
  my @dchunks = grep {   (defined($chunks->[$_]{dbsname}))
                       && ($chunks->[$_]{dbsname} eq $dbspace) }
                     0 .. $#{$chunks} ;
  my $highest = $dchunks[-1];   # Chunks are sorted to last one is highest
  my $high_symlink = $chunks->[$highest]{symlink};  # Get that symlink
  my @parsed_sym = split('\.', $high_symlink);      # parse it, if only to
  my $high_chunk_num = $parsed_sym[-1];             # get at rel chunk number
  my $use_chunk_num = $high_chunk_num + 1;          # and bump up over that

  # Piece together the symlink path to use. This is identical to the
  # previous one, except for the suffix, the chunk number 
  #
  $rsymlink = sprintf("%s.%s.%s.%03d",
                      $parsed_sym[0],   # Same path name (ifmxef/sl)
                      $parsed_sym[1],   # Same dbspace
                      $parsed_sym[2],   # Same Primary/Mirror status (P only)
                      $use_chunk_num);  # New chunk number
  return $rsymlink;
}
#
# Function: gen_fnames()
# Generates 2 lists of file names:
# - A list of "raw" file paths like
#   (/ifmxdev/files/file.0123, /ifmxdev/files/file.0124...)
# - A list of symlink path names, likeL
#   (/ifmxdev/sl/myserver.rcdbs.P.005, /ifmxdev/sl/myserver.rcdbs.P.006 ..)
#
# Parameters:
# - Reference to the Chunks list, as per dbspace_pages()
# - Name of the server
# - Name of a dbspace to which these should be applied
# - Path of top-level directory, likely the file-system's mount-point, for
#   the raw files e.g. /ifmxdev or /ifmxdev_gold. It must have a
#   subdirectory named "files" e.g. /ifmxdev_gold/files
# - Number of items to generate in the lists.
# Returns:
# - Reference to list of raw files path names
# - Reference to list symbolic link path names
#
sub gen_fnames
{
  my ($chunks, $server, $dbspace, $raw_dir, $nchunks) = @_; # Name my parameters
  my ($symlink_list, $rawfile_list);    # Array references to be returned
  my @dbspace_chunks;                   # Array of indexes into @$chunks array
  my $top_dir = $symlink_dir;           # Top-level directory for symlinks
  $top_dir = sprintf("%/%", $top_dir, $s_sub_path)  # If a subdir is called for
               if (length($s_sub_path));            # then append that
  @dbspace_chunks = grep {    (defined($chunks->[$_]))
                           && ($chunks->[$_]{dbsname} eq $dbspace) }
                         0..$#{$chunks};
  # Must be at least one: The dbspaces is listed in the @$dbspaces array or
  # we would have died a ways back.  Scan the array to get the highest relative 
  # chunk number in this dbspace
  #
  my $current_top_chunkn = 0;
  for (my $lc = 0; $lc <= $#dbspace_chunks; $lc++)
  {                                 # Step through the subset array
    my $clc = $dbspace_chunks[$lc]; # to reference an element in chunks array
    my @symlink_parts = split('\.', $chunks->[$clc]{symlink});
    my $rel_chunk_num = $symlink_parts[-1]; # Last part is chunk nmumber
    $current_top_chunkn = $rel_chunk_num    # New candidate for new chunk num
      if ($rel_chunk_num > $current_top_chunkn);# if this is highest so far
  }
  # Coming out of above loop, $current_top_chunkn has the dbspace-relative
  # highest chunk number. Plan is to generate symlink paths that reflect a
  # set of new symlink with chunk numbers over that current top.  That code
  # is in the following for-loop
  #
  my ($first_new_chunkn,       $last_new_chunkn)
   = ($current_top_chunkn + 1, $current_top_chunkn + $nchunks);
  my $s_ix = 0;                     # Index into @$symlink_list array
  for (my $sym_lc = $first_new_chunkn; $sym_lc <= $last_new_chunkn; $sym_lc++)
  {
    $symlink_list->[$s_ix++] = sprintf("%s/%s.%s.%s.%0*d",
                                    $top_dir, $server, $dbspace, "P",
                                    $sym_places, $sym_lc);
  }
#
  # Now compile a list of raw target files, the targets of the symlinks in
  # the above list.
  #
  # Start by getting the starting number for raw files
  #
  my $first_file_num = next_file_num(); # Obtain the next available raw-file
  my $last_file_num = $first_file_num   # numeric suffix and derive the
                    + $nchunks -1;      # last suffix I will need for this task
  my $f_ix = 0;                     # Array index into @$rawfile_list
  for (my $f_lc = $first_file_num; $f_lc <= $last_file_num; $f_lc++)
  {                                 # Piece together a raw file path
    $raw_dir = sprintf("%s/%s", $raw_dir, $p_sub_path)
      if (length($p_sub_path));     # Append subdirectory if specified
    $rawfile_list->[$f_ix++] = sprintf("%s/file.%0*d", $raw_dir,$raw_places , $f_lc);
  }
  # I got my arrays put together. Return them to caller
  #
  return($symlink_list, $rawfile_list);
}
#
sub display_help
{
  print <<EOH
This program adds a chunk to an existing dbspace

Usage:
$me -h     # Display this message

$me -d dbspace [-p <path>] [-s size (in kb)] [-X]

The dbspace must be provided and must exist - this program does not create
new dbspaces.

-X Outout the shell commands but do not execute them.
-p path: This may be:
  o A top-level directory for cooked files most likely a mounted file
    system, like /ifmxdevp or /imfxdevp-gold.  Based on the config file
    /ifmx-work/dbspace-defaults.cfg, there may be a reqired subdirectory
    under that top-level. e.g. "files". $me will create a new file named
    file.nnnnn, where nnnnn is 1 + the current highest file number used in
    all of the target file numbers.  It will also create an appropriately named
    symbolic link in /ifmxdev/sl.
XXo A complete file path, which must follow the naming convention -
    file.nnnn (4 digits, left-0 padded). add_chunk will create a new
    symbolic link to reference this file (provided it passes validation)
XXo An existing symbolic link that already references a "raw file"
  In each case, the file or directory will need to pass validations.
  Default: add_chunk will create a file in /ifmxdev/files and a symbolic
  link to it in /ifmxdev/sl.

-m The top level directory for mirror chunk, if the DBspace is mirrored.
   Default is /ifmxdevm, in accordance with the defaults confiruration file
-c Count of chunks - How many chunks to add to this dbspaces. Default is 1
   of course.  

-s Size of the chunk in kb.  If omitted, the default is 2097150, 1 page shy
   of 2gB.

EOH
}
#
__END__

=pod

=head1 Program Name

add-chunk.pl (or just "add-chunk" if if you have set up the symlink for it)

=head2 Abstract

Adds a chunk to an existing DBspace in the current informix instance (as
determined by the INFORMIXSERVER environment variable)

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
|http://metacpan.org/pod/DBD::Informix>

=item * DBspaces.pm: The Perl module with the functions and methods used by
all of the utilities in this package.  Of course, it comes with this
package.  At this time available only on IIUG, not on CPAN.

=item * UNLreport.pm: The Perl module that formats test output into neat
columns for reports.  This is available from CPAN at L<Data::UNLreport.pm
|http://metacpan.org/pod/Data::UNLreport>

=back

=head2 Synopsys of operations

add-chunk [-X] -d <dbspace> [-p <path>] [-s <size>] [-m <path>] [-c <count>]

The DBspace parameter is required and it must exist.

=over 4

=item * -X  			Displays shell commands equivalent to the steps that
this program will perform.  Used for debugging or just making sure of what will
go where.

=item * -d <dbspace>	Names the DBspace to which we wish to add a chunk.
Obviously, this is a required parameter; how can we know which DBspace you
wish to agument?

=item * -p <path>		(Optional) This is the top level directory or file
system of where to create the chunk "raw" file for the primary chunk (as
opposed to the mirror chunk; see the -m option). The default is determined in
the file $IFMX_WORK/defaults; if that file does not exist it will be /ifmxdevp.
Note that the defaults file may specify a subdirectory as well.  This is
discussed in the perldoc output on DBspaces.pm

=item * -s <size>		(Optional but strongly recommended) This is the size of
the new chunk in KB.  If not provided it will be 2GB - the root page size of
the server. So for a 2K root page size, the default will be 2097150 and for a
4K root page size (seldom used) this will be 2097148.

=item * -m <path>		(As optional as -p) This is the top level directory for
the "raw file" of the mirror chunk. The default is /ifmxdevm, and is subject
the the same subdirectory issues as is the primary chunk.

=item * -c <count>		(Optional) If you omit this, we will add one chunk (and
its mirror) to the DBspace.  But you can add any number of chunks in a single
command using the -c option.  apply to the mirror chunk as to the promary chunk.

=back

=head2 Example

informix:/home/informix:$ add-chunk -d index_dbs -c 4

 touch /ifmxdevp/file.00014
 touch /ifmxdevm/file.00014
 chmod 660 /ifmxdevp/file.00014
 chmod 660 /ifmxdevm/file.00014
 ln -s /ifmxdevp/file.00014 /ifmxdev/js_server.index_dbs.P.002
 ln -s /ifmxdevm/file.00014 /ifmxdev/js_server.index_dbs.m.002
 onspaces -a index_dbs -p /ifmxdev/js_server.index_dbs.P.002 -o 0 -s 2097144 -m /ifmxdev/js_server.index_dbs.m.002 0

 touch /ifmxdevp/file.00015
 touch /ifmxdevm/file.00015
 chmod 660 /ifmxdevp/file.00015
 chmod 660 /ifmxdevm/file.00015
 ln -s /ifmxdevp/file.00015 /ifmxdev/js_server.index_dbs.P.003
 ln -s /ifmxdevm/file.00015 /ifmxdev/js_server.index_dbs.m.003
 onspaces -a index_dbs -p /ifmxdev/js_server.index_dbs.P.003 -o 0 -s 2097144 -m /ifmxdev/js_server.index_dbs.m.003 0

 touch /ifmxdevp/file.00016
 touch /ifmxdevm/file.00016
 chmod 660 /ifmxdevp/file.00016
 chmod 660 /ifmxdevm/file.00016
 ln -s /ifmxdevp/file.00016 /ifmxdev/js_server.index_dbs.P.004
 ln -s /ifmxdevm/file.00016 /ifmxdev/js_server.index_dbs.m.004
 onspaces -a index_dbs -p /ifmxdev/js_server.index_dbs.P.004 -o 0 -s 2097144 -m /ifmxdev/js_server.index_dbs.m.004 0

 touch /ifmxdevp/file.00017
 touch /ifmxdevm/file.00017
 chmod 660 /ifmxdevp/file.00017
 chmod 660 /ifmxdevm/file.00017
 ln -s /ifmxdevp/file.00017 /ifmxdev/js_server.index_dbs.P.005
 ln -s /ifmxdevm/file.00017 /ifmxdev/js_server.index_dbs.m.005
 onspaces -a index_dbs -p /ifmxdev/js_server.index_dbs.P.005 -o 0 -s 2097144 -m /ifmxdev/js_server.index_dbs.m.005 0

 Added 4 of 4 chunks to dbspace index_dbs

=cut
