# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007 Vyatta, Inc.
# All Rights Reserved.
#
# **** End License ****

package Vyatta::Login::User;
use strict;
use warnings;
use lib "/opt/vyatta/share/perl5";
use Vyatta::Config;
use Vyatta::Misc;

# Exit codes form useradd.8 man page
my %reasons = (
    0  => 'success',
    1  => 'can´t update password file',
    2  => 'invalid command syntax',
    3  => 'invalid argument to option',
    4  => 'UID already in use (and no -o)',
    6  => 'specified group doesn´t exist',
    9  => 'username already in use',
    10 => 'can´t update group file',
    12 => 'can´t create home directory',
    13 => 'can´t create mail spool',
);

my $levelFile = "/opt/vyatta/etc/level";

# Convert level to additional groups
sub _level_groups {
    my $level = shift;
    my @groups;

    open( my $f, '<', $levelFile )
      or return;

    while (<$f>) {
        chomp;
	# Ignore blank lines and comments
        next unless $_;
	next if /^#/;

        my ( $l, $g ) = split /:/;
        if ( $l eq $level ) {
            @groups = split( /,/, $g );
            last;
        }
    }
    close $f;
    return @groups;
}

sub _authorized_keys {
    my $user   = shift;
    my $config = new Vyatta::Config;
    $config->setLevel("system login user $user authentication public-keys");

    # ($name,$passwd,$uid,$gid,$quota,$comment,$gcos,$dir,$shell,$expire)
    #   = getpw*
    my ( undef, undef, $uid, $gid, undef, undef, undef, $home ) =
      getpwnam($user);
    return unless $home;
    return unless -d $home;

    my $sshdir = "$home/.ssh";
    unless ( -d $sshdir ) {
        mkdir $sshdir;
        chown( $uid, $gid, $sshdir );
        chmod( 0750, $sshdir );
    }

    my $keyfile = "$sshdir/authorized_keys";
    open( my $auth, '>', $keyfile)
	or die "open $keyfile failed: $!";

    print {$auth} "# Automatically generated by Vyatta configuration\n";
    print {$auth} "# Do not edit, all changes will be lost\n";

    foreach my $name ($config->listNodes()) {
	my $options = $config->returnValue("$name options");
        my $type = $config->returnValue("$name type");
        my $key  = $config->returnValue("$name key");

	print {$auth} "$options " if $options;
        print {$auth} "$type $key $name\n";
    }

    close $auth;
    chmod( 0640, $keyfile );
    chown( $uid, $gid, $keyfile)
}

sub _delete_user {
    my $user = shift;

    my $login = getlogin();
    if ( $user eq 'root' ) {
	warn "Disabling root account, instead of deleting\n";
	system('usermod -p ! root') == 0
	    or die "usermod of root failed: $?\n";
    } elsif ( defined($login) && $login eq $user ) {
	die "Attempting to delete current user: $user\n";
    } elsif ( getpwnam($user) ) {
	if (`who | grep "^$user"` ne '') {
	    warn "$user is logged in, forcing logout\n";
	    system("pkill -HUP -u $user");
	}
	system("pkill -9 -u $user");

	system("userdel $user") == 0
	    or die "userdel of $user failed: $?\n";
    }
}

sub _update_user {
    my $user = shift;
    my $cfg = new Vyatta::Config;
    my $pwd = "";
        
    $cfg->setLevel("system login user $user");
    if ($cfg->exists('authentication encrypted-password')) {
        $pwd = $cfg->returnValue('authentication encrypted-password');
    } else {
        $pwd = "!";
    }
    my $level = $cfg->returnValue('level');
    my $fname = $cfg->returnValue('full-name');
    my $home  = $cfg->returnValue('home-directory');

    unless ($pwd) {
	warn "Encrypted password not in configuration for $user";
	return;
    }

    unless ($level) {
	warn "Level not defined for $user";
        return;
    }

    # map level to group membership
    my @groups = _level_groups($level);

    # add any additional groups from configuration
    push( @groups, $cfg->returnValues('group') );

    # Read existing settings
    my $uid = getpwnam($user);

    my $shell;
    if ($level eq "operator") {
        $shell = "/opt/vyatta/bin/restricted-shell";
    }
    else {
        $shell = "/bin/vbash";
    } 

    # not found in existing passwd, must be new
    my $cmd;
    unless ( defined($uid) ) {
	# make new user using vyatta shell
	#  and make home directory (-m)
	#  and with default group of 100 (users)
	$cmd = "useradd -s $shell -m -N";
    } else {
	# update existing account
	$cmd = "usermod";
    }

    $cmd .= " -p '$pwd'";
    $cmd .= " -s $shell";
    $cmd .= " -c \"$fname\"" if ( defined $fname );
    $cmd .= " -d \"$home\"" if ( defined $home );
    $cmd .= ' -G ' . join( ',', @groups );
    system("$cmd $user");

    unless ( $? == 0 ) {
	my $reason = $reasons{ ( $? >> 8 ) };
	die "Attempt to change user $user failed: $reason\n";
    }
}

# returns list of dynamically allocated users (see Debian Policy Manual)
sub _local_users {
    my @users;

    setpwent();
    while ( my ($name, undef, $uid, undef, undef, undef,
                undef, undef, $shell) = getpwent() ) {
	next unless ($uid >= 1000 && $uid <= 29999);
	next unless $shell eq '/bin/vbash';

        push @users, $name;
    }
    endpwent();

    return @users;
}

sub update {
    my $uconfig    = new Vyatta::Config;
    $uconfig->setLevel("system login user");
    my %users = $uconfig->listNodeStatus();

    die "All users deleted!\n" unless %users;

    foreach my $user ( keys %users ) {
        my $state = $users{$user};
        if ( $state eq 'deleted' ) {
	    _delete_user($user);
            next;
        }

        next unless ( $state eq 'added' || $state eq 'changed' );

	_update_user($user);
        _authorized_keys($user);
    }

    # Remove any normal users that do not exist in current configuration
    # This can happen if user added but configuration not saved
    # and system is rebooted
    foreach my $user ( _local_users() ) {
	# did we see this user in configuration?
        next if defined $users{$user};

        warn "removing $user not listed in current configuration\n";
	# Remove user account but leave home directory to be safe
        system("userdel $user") == 0
          or die "Attempt to delete user $user failed: $!";
    }
}

1;
