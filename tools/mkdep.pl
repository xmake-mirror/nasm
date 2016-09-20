#!/usr/bin/perl
## --------------------------------------------------------------------------
##   
##   Copyright 1996-2016 The NASM Authors - All Rights Reserved
##   See the file AUTHORS included with the NASM distribution for
##   the specific copyright holders.
##
##   Redistribution and use in source and binary forms, with or without
##   modification, are permitted provided that the following
##   conditions are met:
##
##   * Redistributions of source code must retain the above copyright
##     notice, this list of conditions and the following disclaimer.
##   * Redistributions in binary form must reproduce the above
##     copyright notice, this list of conditions and the following
##     disclaimer in the documentation and/or other materials provided
##     with the distribution.
##     
##     THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
##     CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
##     INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
##     MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
##     DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
##     CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
##     SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
##     NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
##     LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
##     HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
##     CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
##     OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
##     EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
##
## --------------------------------------------------------------------------

#
# Script to create Makefile-style dependencies.
#
# Usage: perl mkdep.pl [-s path-separator] [-o obj-ext] dir... > deps
#

use File::Spec;
use File::Basename;
use Fcntl;

$barrier = "#-- Everything below is generated by mkdep.pl - do not edit --#\n";

# This converts from filenames to full pathnames for our dependencies
%dep_path = {};

#
# Scan files for dependencies
#
sub scandeps($) {
    my($file) = @_;
    my $line;
    my @xdeps = ();
    my @mdeps = ();

    open(my $fh, '<', $file)
	or return;		# If not openable, assume generated

    while ( defined($line = <$fh>) ) {
	chomp $line;
	$line =~ s:/\*.*\*/::g;
	$line =~ s://.*$::;
	if ( $line =~ /^\s*\#\s*include\s+\"(.*)\"\s*$/ ) {
	    my $nf = $1;
	    if (!defined($dep_path{$nf})) {
		die "$0: cannot determine path for dependency: $file -> $nf\n";
	    }
	    $nf = $dep_path{$nf};
	    push(@mdeps, $nf);
	    push(@xdeps, $nf) unless ( defined($deps{$nf}) );
	}
    }
    close($fh);
    $deps{$file} = [@mdeps];

    foreach my $xf ( @xdeps ) {
	scandeps($xf);
    }
}

# %deps contains direct dependencies.  This subroutine resolves
# indirect dependencies that result.
sub alldeps($$) {
    my($file, $level) = @_;
    my %adeps;

    foreach my $dep ( @{$deps{$file}} ) {
	$adeps{$dep} = 1;
	foreach my $idep ( alldeps($dep, $level+1) ) {
	    $adeps{$idep} = 1;
	}
    }
    return sort(keys(%adeps));
}

# This converts a filename from host syntax to target syntax
# This almost certainly works only on relative filenames...
sub convert_file($$) {
    my($file,$sep) = @_;
    my @fspec = (basename($file));
    while ( ($file = dirname($file)) ne File::Spec->curdir() &&
	    $file ne File::Spec->rootdir() ) {
	unshift(@fspec, basename($file));
    }

    if ( $sep eq '' ) {
	# This means kill path completely.  Used with Makes who do
	# path searches, but doesn't handle output files in subdirectories,
	# like OpenWatcom WMAKE.
	return $fspec[scalar(@fspec)-1];
    } else {
	return join($sep, @fspec);
    }
}

#
# Insert dependencies into a Makefile
#
sub insert_deps($) {
    my($file) = @_;
    $nexttemp++;		# Unique serial number for each temp file
    my $tmp = File::Spec->catfile(dirname($file), 'tmp.'.$nexttemp);

    open(my $in, '<', $file)
	or die "$0: Cannot open input: $file\n";
    open(my $out, '>', $tmp)
	or die "$0: Cannot open output: $tmp\n";

    my($line,$parm,$val);
    my($obj) = '.o';		# Defaults
    my($sep) = '/';
    my($cont) = "\\";
    my($maxline) = 78;		# Seems like a reasonable default
    my @exclude = ();		# Don't exclude anything
    my @genhdrs = ();

    while ( defined($line = <$in>) ) {
	if ( $line =~ /^([^\s\#\$\:]+\.h):/ ) {
	    # Note: we trust the first Makefile given best
	    my $fpath = $1;
	    my $fbase = basename($fpath);
	    if (!defined($dep_path{$fbase})) {
		$dep_path{$fbase} = $fpath;
		print STDERR "Makefile: $fbase -> $fpath\n";
	    }
	} elsif ( $line =~ /^\s*\#\s*@([a-z0-9-]+):\s*\"([^\"]*)\"/ ) {
	    $parm = $1;  $val = $2;
	    if ( $parm eq 'object-ending' ) {
		$obj = $val;
	    } elsif ( $parm eq 'path-separator' ) {
		$sep = $val;
	    } elsif ( $parm eq 'line-width' ) {
		$maxline = $val+0;
	    } elsif ( $parm eq 'continuation' ) {
		$cont = $val;
	    } elsif ( $parm eq 'exclude' ) {
		@exclude = split(/\,/, $val);
	    }
	} elsif ( $line eq $barrier ) {
	    last;		# Stop reading input at barrier line
	}
	print $out $line;
    }
    close($in);

    my $e;
    my %do_exclude = ();
    foreach $e (@exclude) {
	$do_exclude{$e} = 1;
    }

    my $dfile, $ofile, $str, $sl, $len;
    my @deps, $dep;

    print $out $barrier;

    foreach $dfile ( sort(keys(%deps)) ) {
	if ( $dfile =~ /^(.*)\.[Cc]$/ ) {
	    $ofile = $1;
	    $str = convert_file($ofile, $sep).$obj.':';
	    $len = length($str);
	    print $out $str;
	    foreach $dep ($dfile, alldeps($dfile,1)) {
		unless ($do_exclude{$dep}) {
		    $str = convert_file($dep, $sep);
		    $sl = length($str)+1;
		    if ( $len+$sl > $maxline-2 ) {
			print $out ' ', $cont, "\n ", $str;
			$len = $sl;
		    } else {
			print $out ' ', $str;
			$len += $sl;
		    }
		}
	    }
	    print $out "\n";
	}
    }
    close($out);

    (unlink($file) && rename($tmp, $file))
	or die "$0: Failed to change $tmp -> $file\n";
}

#
# Main program
#

my %deps = ();
my @files = ();
my @mkfiles = ();
my $mkmode = 0;

while ( defined(my $arg = shift(@ARGV)) ) {
    if ( $arg eq '-m' ) {
	$arg = shift(@ARGV);
	push(@mkfiles, $arg);
    } elsif ( $arg eq '-M' ) {
	$mkmode = 1;		# Futher filenames are output Makefile names
    } elsif ( $arg eq '--' && $mkmode ) {
	$mkmode = 0;
    } elsif ( $arg =~ /^-/ ) {
	die "Unknown option: $arg\n";
    } else {
	if ( $mkmode ) {
	    push(@mkfiles, $arg);
	} else {
	    push(@files, $arg);
	}
    }
}

my @cfiles = ();

foreach my $dir ( @files ) {
    opendir(DIR, $dir) or die "$0: Cannot open directory: $dir";

    while ( my $file = readdir(DIR) ) {
	$path = ($dir eq File::Spec->curdir())
	    ? $file : File::Spec->catfile($dir,$file);
	if ( $file =~ /\.[Cc]$/ ) {
	    push(@cfiles, $path);
	} elsif ( $file =~ /\.[Hh]$/ ) {
	    print STDERR "Filesystem: $file -> $path\n";
	    $dep_path{$file} = $path;
	}
    }
    closedir(DIR);
}

foreach my $cfile ( @cfiles ) {
    scandeps($cfile);
}

foreach my $mkfile ( @mkfiles ) {
    insert_deps($mkfile);
}