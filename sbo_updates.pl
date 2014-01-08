#!/usr/bin/perl -w

# Copyright (c) 2013-2014 LEVAI Daniel
# All rights reserved.
#
# * Redistribution and use in source and binary forms, with or without
#   modification, are permitted provided that the following conditions
#   are met:
# * Redistributions of source code must retain the above copyright notice
#   this list of conditions and the following disclaimer.
# * Redistributions in binary form must reproduce the above copyright
#   notice, this list of conditions and the following disclaimer in the
#   documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED ''AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
# COPYRIGHT HOLDER BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
# OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
# OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
# ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


use strict;
use warnings;
use feature "say";

use version qw(is_lax);
use Getopt::Std;
use File::Find;


sub show_progress;
sub quirks;
sub VERSION_MESSAGE;
sub HELP_MESSAGE;


$Getopt::Std::STANDARD_HELP_VERSION = 1;
my %opts;

my $gen_list = 1;
my $verbose = 0;
my $show_downgrades = 0;
my $show_revisions = 0;
my $show_progress = 1;
my $progress_spin_id = 1;
my @PROGRESS_SPINNER = ( '-', '\\', '|', '/' );

my $conf_file = '/etc/sbo_updates.conf';

Getopt::Std::getopts('c:lv:drqhR:P:', \%opts)  or  HELP_MESSAGE;

(defined($opts{l}))  and  $gen_list = 0;
if (defined($opts{v})) {
	if ($opts{v} =~ /^[0-9]$/) {
		$verbose = $opts{v};
		$show_progress = 0;
	} else {
		HELP_MESSAGE;
	}
}
(defined($opts{d}))  and  $show_downgrades = 1;
(defined($opts{r}))  and  $show_revisions = 1;
if (defined($opts{q})) {
	$show_progress = 0;
	$verbose = -1;
}
if (defined($opts{h})) {
	VERSION_MESSAGE;
	HELP_MESSAGE;
}
if (defined($opts{c})) {
	$conf_file = $opts{c};

	# If the specified configuration file is not present, that is an error.
	if (!stat($conf_file)) {
		die "Couldn't find the specified configuration file (${conf_file}): $!\n";
	}
}


my $PACKAGE_INFORMATION = '/var/log/packages';
my $REPO_TAG = '_SBo';
my $REPOSITORY = '/usr/slackbuilds/git';
my @IGNORE_PACKAGES;
my %QUIRKS;
# If the default configuration file is not present, that is not an error,
# because we provide sane defaults for every parameter that would be read
# from the configuration file.
if (stat($conf_file)) {
	open(CONF, "<", $conf_file)  or  die "Couldn't open configuration file (${conf_file}): $!\n";
	while (<CONF>) {
		next  if m/^#/;

		chomp;

		if (m/^PACKAGE_INFORMATION=/) {
			( undef, $PACKAGE_INFORMATION ) = split /=/;
			$PACKAGE_INFORMATION =~ s,/$,,g;
		} elsif (m/^REPOSITORY=/) {
			( undef, $REPOSITORY ) = split /=/;
			$REPOSITORY =~ s,/$,,g;
		} elsif (m/^REPO_TAG=/) {
			( undef, $REPO_TAG ) = split /=/;
		} elsif (m/^IGNORE_PACKAGES=/) {
			s/^.*=//;
			foreach (split / /) {
				push @IGNORE_PACKAGES, $_;
			}
		} elsif (m/^QUIRKS=/) {
			s/^.*=//;
			foreach (split / /) {
				( my $qpkg, my $qsubs ) = split /,/;
				$QUIRKS{$qpkg} = $qsubs;
			}
		}
	}
	close(CONF);
}

# Override the configuration file variables with the command arguments
if (defined($opts{R})) {
	$REPOSITORY = $opts{R};
}
if (defined($opts{P})) {
	$PACKAGE_INFORMATION = $opts{P};
}

# strip trailing slashes, because perl can not open the directories if they are present.
$REPOSITORY =~ s,/$,,;
$PACKAGE_INFORMATION =~ s,/$,,;


my @installed_pkgs;

my $pos = 0;
opendir(my $dh, $PACKAGE_INFORMATION)  or  die "Couldn't open ${PACKAGE_INFORMATION}: $!\n";
while(readdir $dh) {
	if ( -f "${PACKAGE_INFORMATION}/$_"  &&  m/${REPO_TAG}$/ ) {
		show_progress('Getting list of installed packages with repoitory tag...', $pos++, 0, 5)
			if ($verbose >= 0);
		push @installed_pkgs, $_;
	}
}
closedir $dh;
say "\rGetting list of installed packages with repoitory tag - done(${pos})."  if ($verbose >= 0);


my %repo_pkgs;

my $depth_pre = $REPOSITORY =~ tr,/,,;
$pos = 0;
find(	{	wanted => sub {
				my $depth = tr,/,,;

				die "Couldn't open ${REPOSITORY}: $!\n"  if (! -d "$_"  &&  $depth == $depth_pre);

				return if (! -d "$_"  ||  m/\/*\.git(\/.*)*$/);

				# The magic number 2 here is the difference in
				# depth, between the pkg. repo's root path, and
				# the path where the actual packages'
				# directories are.
				# i.e.: this specifies how many slashes are
				#  between a package's directory and the
				#  specified repo. root.
				#
				# The difference between a package's directory
				# and the repo. root is the category directory.
				#
				# XXX Maybe this could have been specified in
				# the configuration file, but not sure if there
				# are any setups where 2 is not valid.
				return if (($depth - $depth_pre) != 2);

				show_progress('Getting repository package list...', $pos++, 0, 100)
					if ($verbose >= 0);

				s,^.*/([^/]+)/([^/]+)$,$1/$2,;
				(my $category, my $name) = split(/\//);

				if (defined($repo_pkgs{$name})) {
					say STDERR "Duplicate package in repository: '${name}'!";
				}
				$repo_pkgs{$name} = { category => $category, version => undef, revision => undef };
			},
		no_chdir => 1,
		follow => 1,
	},
	$REPOSITORY
);
say "\rGetting repository package list - done(${pos})."  if ($verbose >= 0);


my $progress_pkg = 0;
my $package_signature_regex = qr/^(.*)-([^-]+)-[^-]+-([0-9])+${REPO_TAG}$/;
my %installed_pkg;
my @pkg_list;	# list of differing packages

foreach (@installed_pkgs) {
	$progress_pkg++;

	$installed_pkg{name} = $_; $installed_pkg{name} =~ s,$package_signature_regex,$1,;
	$installed_pkg{version} = $_; $installed_pkg{version} =~ s,$package_signature_regex,$2,;
	$installed_pkg{revision} = $_; $installed_pkg{revision} =~ s,$package_signature_regex,$3,;

	say "Searching for $installed_pkg{name} in the repository..."  if ($verbose >= 1);

	next  if (quirks(\%installed_pkg) < 0);

	my $repo_pkg = $installed_pkg{name};
	if (defined($repo_pkgs{$repo_pkg})) {
		say "\tfound!"  if ( $verbose >= 2 );
	} else {
		say "\tnot found in repository!"  if ($verbose >= 2);
		next;
	}


	my @info = glob qq("${REPOSITORY}/$repo_pkgs{$repo_pkg}{category}/$installed_pkg{name}/*.info");
	if ( !defined($info[0])  or  ! -f $info[0] ) {
		say STDERR "No info file found for " . $installed_pkg{name} . "!";
		next;
	}


	my @slackbuild = glob qq("${REPOSITORY}/$repo_pkgs{$repo_pkg}{category}/$installed_pkg{name}/*.SlackBuild");
	if ( !defined($slackbuild[0])  or  ! -f $slackbuild[0] ) {
		say STDERR "No slackbuild file found for " . $installed_pkg{name} . "!";
		next;
	}


	open(INFO_FILE, "<", $info[0])  or  say STDERR "Couldn't open info file (" . $info[0] . "): $!";
	( $repo_pkgs{$repo_pkg}{version} ) = grep(/^VERSION/, <INFO_FILE>);
	chomp($repo_pkgs{$repo_pkg}{version});
	( undef, $repo_pkgs{$repo_pkg}{version} ) = split(/=/, $repo_pkgs{$repo_pkg}{version});
	$repo_pkgs{$repo_pkg}{version} =~ s,",,g;
	close(INFO_FILE);


	open(SLACKBUILD_FILE, "<", $slackbuild[0])  or  say STDERR "Couldn't open slackbuild file (" . $slackbuild[0] . "): $!";
	( $repo_pkgs{$repo_pkg}{revision} ) = grep(/^BUILD/, <SLACKBUILD_FILE>);
	chomp($repo_pkgs{$repo_pkg}{revision});
	( undef, $repo_pkgs{$repo_pkg}{revision} ) = split(/=/, $repo_pkgs{$repo_pkg}{revision});
	$repo_pkgs{$repo_pkg}{revision} =~ s,^\${BUILD:-([0-9])}$,$1,;
	close(SLACKBUILD_FILE);


	# Try to handle the version string manually if the 'version' module can not.
	if (!is_lax($installed_pkg{version})) {
		say "\tnon lax format:" . $installed_pkg{version}  if ($verbose >= 2);

		$installed_pkg{version} =~ s/[^0-9_\.]//g;
		$installed_pkg{version} =~ tr/_//s;

		# If 'version' still can not parse it, be more radical
		if (!is_lax($installed_pkg{version})) {
			$installed_pkg{version} =~ tr/_/./;
			$installed_pkg{version} =~ s/[^0-9\.]//g;
		}

		say "\tnew version number :" . $installed_pkg{version}  if ($verbose >= 2);

		if (!is_lax($installed_pkg{version})) {
			say STDERR "Couldn't parse version string for " . $installed_pkg{name} . "(" . $installed_pkg{version} . ")" . "!";
			next;
		}
	}
	if (!is_lax($repo_pkgs{$repo_pkg}{version})) {
		say "\tnon lax format:" . $repo_pkgs{$repo_pkg}{version}  if ($verbose >= 2);

		$repo_pkgs{$repo_pkg}{version} =~ s/[^0-9_\.]//g;
		$repo_pkgs{$repo_pkg}{version} =~ tr/_//s;

		# If 'version' still can not parse it, be more radical
		if (!is_lax($repo_pkgs{$repo_pkg}{version})) {
			$repo_pkgs{$repo_pkg}{version} =~ tr/_/./;
			$repo_pkgs{$repo_pkg}{version} =~ s/[^0-9\.]//g;
		}

		say "\tnew version number :" . $repo_pkgs{$repo_pkg}{version}  if ($verbose >= 2);

		if (!is_lax($repo_pkgs{$repo_pkg}{version})) {
			say STDERR "Couldn't parse version string for " . $installed_pkg{name} . "(" . $repo_pkgs{$repo_pkg}{version} . ")" . "!";
			next;
		}
	}


	$installed_pkg{version_obj} = version->declare(version->parse($installed_pkg{version}));
	$repo_pkgs{$repo_pkg}{version_obj} = version->declare(version->parse($repo_pkgs{$repo_pkg}{version}));

	if ($verbose >= 2) {
		say $installed_pkg{version} . " => " . $installed_pkg{version_obj}->normal;
		say $repo_pkgs{$repo_pkg}{version} . " => " . $repo_pkgs{$repo_pkg}{version_obj}->normal;
	}

	my %pkg_to_list;

	if ($installed_pkg{version_obj} == $repo_pkgs{$repo_pkg}{version_obj}) {
		if (	$show_revisions  and
			$installed_pkg{revision} != $repo_pkgs{$repo_pkg}{revision}
		) {
			$pkg_to_list{name} = $installed_pkg{name};
			$pkg_to_list{status} = $repo_pkgs{$repo_pkg}{revision} <=> $installed_pkg{revision};
			$pkg_to_list{installed_version} = $installed_pkg{version} . "-" . $installed_pkg{revision};
			$pkg_to_list{repo_version} = $repo_pkgs{$repo_pkg}{version} . "-" . $repo_pkgs{$repo_pkg}{revision};

			push @pkg_list, \%pkg_to_list  if ($gen_list);
		}
	} else {
		$pkg_to_list{name} = $installed_pkg{name};
		$pkg_to_list{status} = $repo_pkgs{$repo_pkg}{version_obj} <=> $installed_pkg{version_obj};
		$pkg_to_list{installed_version} = $installed_pkg{version} . "-" . $installed_pkg{revision};
		$pkg_to_list{repo_version} = $repo_pkgs{$repo_pkg}{version} . "-" . $repo_pkgs{$repo_pkg}{revision};

		push @pkg_list, \%pkg_to_list  if ($gen_list);
	}

	show_progress('Checking packages:', $progress_pkg, $#installed_pkgs + 1, 5)
		if ($show_progress);
}
say "\rChecking packages(" . ($#installed_pkgs + 1) . ") - done.  "  if ($show_progress);
print "\n";


if (@pkg_list) {
	if ($verbose >= 0) {
		my @upgrades;
		my @downgrades;

		foreach (@pkg_list) {
			if ($_->{status} == -1) {
				if ($show_downgrades) {
					if ($verbose >= 0) {
						say "Downgrade: " . $_->{name} . " " .
							$_->{installed_version} . " -> " . $_->{repo_version};
					}
					push @downgrades, $_->{name};
				}
			} elsif ($_->{status} == 1) {
				if ($verbose >= 0) {
					say "Upgrade: " . $_->{name} . " " .
						$_->{installed_version} . " -> " . $_->{repo_version};
				}
				push @upgrades, $_->{name};
			}
		}
		if (@upgrades) {
			say "\nUpgrades:";
			foreach (@upgrades) {
				print $_ . " ";
			}
			print "\n";
		}
		if ($show_downgrades  and  @downgrades) {
			say "\nDowngrades:";
			foreach (@downgrades) {
				print $_ . " ";
			}
			print "\n";
		}
	} else {
		exit(2);
	}
}

exit(0);


sub show_progress
{
	my	$descr = shift;
	my	$pos = shift;
	my	$max = shift;
	my	$advance = shift;

	local	$| = 1;


	# only update the progress bar with every $advance step
	if ($pos % $advance eq 0) {
		print "${descr}";
		print " ${pos}/${max}"  if ($max > 0);
		print " " . int($pos * 100 / $max) . "%"  if ($max > 0);
		print " " . $PROGRESS_SPINNER[$progress_spin_id];
		print "\r";

		if ($progress_spin_id >= 3) {
			$progress_spin_id = 0;
		} else {
			$progress_spin_id++;
		}
	}
}


sub quirks
{
	if (grep(/$_[0]->{name}/, @IGNORE_PACKAGES)) {
		say "\tignored package"  if ($verbose >= 1);
		return(-1);
	}

	if (defined($QUIRKS{$_[0]->{name}})) {
		say "\tusing quirk for package version"  if ($verbose >= 1);
		say "\tquirk: " . $QUIRKS{$_[0]->{name}}  if ($verbose >= 2);
		foreach ($_[0]->{version}) {
			eval($QUIRKS{$_[0]->{name}});
		}
		say "\tquirked version: " . $_[0]->{version}  if ($verbose >= 2);
	}

	return(0);
}


sub VERSION_MESSAGE
{
	say "sbo_updates.pl 1.2";
}


sub HELP_MESSAGE
{
	say "Usage:";
	say "$0 [-c] [-l] [-d] [-r] [-v] [-p] [-q]";
	say "\t-c : Configuration file. The default is $conf_file";
	say "\t-l : Don't show one-line package list at the end.";
	say "\t-d : Show downgrades too.";
	say "\t-r : Compare revisions too.";
	say "\t-v number : Verbose list - Print more information about what is being done. 'number' can be 1 or 2 depending on how much verbosity is needed.";
	say "\t-p : Show percentage in progress bar.";
	say "\t-q : Don't print anything, just return 2 if there would have been output.";

	exit(1);
}
