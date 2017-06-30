#!/usr/bin/ksh
#
# set-symlinks.sh: Create symbolic links for the .pl scripts in this
# directory that are partd of the DBspaces.pm package.

ln -s new-dbspace.pl  new-dbspace
ln -s add-chunk.pl    add-chunk
ln -s drop-chunk.pl   drop-chunk
ln -s drop-dbspace.pl drop-dbspace
ln -s spaces.pl       spaces
ln -s dup-spaces.pl   dup-spaces

# That's all.
