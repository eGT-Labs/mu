# BEGIN COPYRIGHT BLOCK
# Copyright (C) 2009 Red Hat, Inc.
# All rights reserved.
#
# License: GPL (version 3 or any later version).
# See LICENSE for details. 
# END COPYRIGHT BLOCK
#

###########################
#
# This perl module provides code to update/upgrade directory
# server shared files/config and instance specific files/config
#
##########################

package DSUpdate;
use DSUtil;
use Inf;
use FileConn;
use DSCreate qw(setDefaults createInstanceScripts makeOtherConfigFiles
                makeDSDirs updateSelinuxPolicy updateTmpfilesDotD updateSystemD);

use File::Basename qw(basename dirname);

# load perldap
use Mozilla::LDAP::Conn;
use Mozilla::LDAP::Utils qw(normalizeDN);
use Mozilla::LDAP::API qw(ldap_explode_dn);
use Mozilla::LDAP::LDIF;

use Exporter;
@ISA       = qw(Exporter);
@EXPORT    = qw(updateDS isOffline);
@EXPORT_OK = qw(updateDS isOffline);

use strict;

use SetupLog;

# the default location of the updates - this is a subdir
# of the directory server data dir (e.g. /usr/share/dirsrv)
# the default directory is read-only - if you need to provide
# additional updates, pass in additional update directories
# to updateDS
my $DS_UPDATE_PATH = "/usr/share/dirsrv/updates";

my $PRE_STAGE = "pre";
my $PREINST_STAGE = "preinst";
my $RUNINST_STAGE = "runinst";
my $POSTINST_STAGE = "postinst";
my $POST_STAGE = "post";

my @STAGES = ($PRE_STAGE, $PREINST_STAGE, $RUNINST_STAGE, $POSTINST_STAGE, $POST_STAGE);
my @INSTSTAGES = ($PREINST_STAGE, $RUNINST_STAGE, $POSTINST_STAGE);

# used to create unique package names for loading updates
# from perl scriptlets
my $pkgname = "Package00000000000";

# generate and return a unique package name that is a 
# subpackage of our current package
sub get_pkgname {
        return __PACKAGE__ . "::" . $pkgname++;
}

sub loadUpdates {
    my $errs = shift;
    my $dirs = shift;
    my $mapinfo = shift || {};
    my @updates; # a list of hash refs, sorted in execution order

    for my $dir (@{$dirs}) {
        for my $file (glob("$dir/*")) {
            my $name = basename($file);
            next if $name !~ /^\d\d/; # we only consider files that begin with two digits
#            print "name = $name\n";
            my $href = { path => $file, name => $name };
            if ($file =~ /\.(pl|pm)$/) { # a perl file
                my $fullpkg = get_pkgname(); # get a unique package name for the file
                # this will import the update functions from the given file
                # each file is given its own private namespace via the package
                # directive below
                # we have to use the eval because package takes a "bareword" -
                # you cannot pass a dynamically constructed string to package
                eval "package $fullpkg; require q($file)"; # "import" it
                if ($@) {
                    if ($@ =~ /did not return a true value/) {
                        # this usually means the file did not end with 1; - just use it anyway
                        debug(3, "notice: $file does not return a true value - using anyway\n");
                    } else {
                        # probably a syntax or other compilation error in the file
                        # we can't safely use it, so log it and skip it
                        push @{$errs}, ['error_loading_update', $file, $@];
                        debug(0, "Error: not applying update $file. Error: $@\n");
                        next; # skip this one
                    }
                }
                # grab the hook functions from the update
                for my $fn (@STAGES) {
                    # this is some deep perl magic - see the perl Symbol Table
                    # documentation for the gory details
                    # We're trying to find if the file defined a symbol called
                    # pre, run, post, etc. and if so, if that symbol is code
                    no strict 'refs'; # turn off strict refs to use magic
                    if (*{$fullpkg . "::" . $fn}{CODE}) {
                        debug(5, "$file $fn is defined\n");
                        # store the "function pointer" in the href for this update
                        $href->{$fn} = \&{$fullpkg . "::" . $fn};
                    } else {
                        debug(5, "$file $fn is not defined or not a subroutine\n");
                    }
                }
            } else { # some other type of file
                $href->{file} = 1;
            }
            if ($mapinfo->{$file}) {
                $href->{mapper} = $mapinfo->{$file}->{mapper};
                $href->{infary} = $mapinfo->{$file}->{infary};
            }
            push @updates, $href;
        }
    }

    # we have all the updates now - sort by the name
    @updates = sort { $a->{name} cmp $b->{name} } @updates;

    return @updates;
}

sub applyLDIFUpdate {
    my ($upd, $conn, $inf) = @_;
    my @errs;
    my $path = ref($upd) ? $upd->{path} : $upd;

    my $mapper;
    my @infary;
    # caller can set mapper to use and additional inf to use
    if (ref($upd)) {
        if ($upd->{mapper}) {
            $mapper = new Inf($upd->{mapper});
        }
        if ($upd->{infary}) {
            @infary = @{$upd->{infary}};
        }
    }
    if (!$mapper) {
        $mapper = new Inf("$inf->{General}->{prefix}/usr/share/dirsrv/inf/dsupdate.map");
    }
    my $dsinf = new Inf("$inf->{General}->{prefix}/usr/share/dirsrv/inf/slapd.inf");

    $mapper = process_maptbl($mapper, \@errs, $inf, $dsinf, @infary);
    if (!$mapper or @errs) {
        return @errs;
    }

    getMappedEntries($mapper, [$path], \@errs, \&check_and_add_entry,
                     [$conn]);

    return @errs;
}

# process an update from an ldif file or executable
# LDIF files only apply to instance updates, so ignore
# LDIF files when not processing updates for instances
sub processUpdate {
    my ($upd, $inf, $configdir, $stage, $inst, $dseldif, $conn) = @_;
    my @errs;
    # $upd is either a hashref or a simple path name
    my $path = ref($upd) ? $upd->{path} : $upd;
    if ($path =~ /\.ldif$/) {
        # ldif files are only processed during the runinst stage
        if ($stage eq $RUNINST_STAGE) {
            @errs = applyLDIFUpdate($upd, $conn, $inf);
        }
    } elsif (-x $path) {
        # setup environment
        $ENV{DS_UPDATE_STAGE} = $stage;
        $ENV{DS_UPDATE_DIR} = $configdir;
        $ENV{DS_UPDATE_INST} = $inst; # empty if not instance specific
        $ENV{DS_UPDATE_DSELDIF} = $dseldif; # empty if not instance specific
        $? = 0; # clear error condition
        my $output = `$path 2>&1`;
        if ($?) {
            @errs = ('error_executing_update', $path, $?, $output);
        }
        debug(1, $output);
    } else {
        @errs = ('error_unknown_update', $path);
    }

    return @errs;
}

# 
sub updateDS {
    # get base configdir, instances from setup
    my $setup = shift;
    # get other info from inf
    my $inf = $setup->{inf};
    # directories containing updates to apply
    my $dirs = shift || [];
    my $mapinfo = shift;
    # the default directory server update path
    if ($inf->{slapd}->{updatedir}) {
        push @{$dirs}, $inf->{General}->{prefix} . $inf->{slapd}->{updatedir};
    } else {
        push @{$dirs}, $inf->{General}->{prefix} . $DS_UPDATE_PATH;
    }
    my @errs;
    my $force = $setup->{force};

    my @updates = loadUpdates(\@errs, $dirs, $mapinfo);

    if (@errs and !$force) {
        return @errs;
    }

    if (!@updates) {
        # nothing to do?
        debug(0, "No updates to apply in @{$dirs}\n");
        return @errs;
    }

    # run pre-update hooks
    for my $upd (@updates) {
        my @localerrs;
        if ($upd->{$PRE_STAGE}) {
            debug(1, "Running updateDS stage $PRE_STAGE update ", $upd->{path}, "\n");
            @localerrs = &{$upd->{$PRE_STAGE}}($inf, $setup->{configdir});
        } elsif ($upd->{file}) {
            debug(1, "Running updateDS stage $PRE_STAGE update ", $upd->{path}, "\n");
            @localerrs = processUpdate($upd, $inf, $setup->{configdir}, $PRE_STAGE);
        }
        if (@localerrs) {
            push @errs, @localerrs;
            if (!$force) {
                return @errs;
            }
        }
    }

    # update each instance
    my @instances = $setup->getDirServers();
    my $inst_count = @instances;
    my @failed_instances = ();
    my $failed_count = 0;
    for my $inst (@instances) {
        debug(0, "Updating instance ($inst)...\n");
        my @localerrs = updateDSInstance($inst, $inf, $setup->{configdir}, \@updates, $force);
        if (@localerrs) {
            # push array here because localerrs will likely be an array of
            # array refs already
            $failed_count++;
            if (!$force || $inst_count == 1) {
                push @errs, @localerrs;
                return @errs;
            }
            push @failed_instances, $inst;
            debug(0, "Failed to update instance ($inst):\n---> @localerrs\n");
        } else {
            debug(0, "Successfully updated instance ($inst).\n");
        }
    }
    if($failed_count && $failed_count == $inst_count){
        push @errs, ('error_update_all');
        return @errs;
    }
    if (@failed_instances){
        # list all the instances that were not updated
        debug(0, "The following instances were not updated: (@failed_instances).  "); 
        debug(0, "After fixing the problems you will need to rerun the setup script\n");
    }

    # run post-update hooks
    for my $upd (@updates) {
        my @localerrs;
        if ($upd->{$POST_STAGE}) {
            debug(1, "Running updateDS stage $POST_STAGE update ", $upd->{path}, "\n");
            @localerrs = &{$upd->{$POST_STAGE}}($inf, $setup->{configdir});
        } elsif ($upd->{file}) {
            debug(1, "Running updateDS stage $POST_STAGE update ", $upd->{path}, "\n");
            @localerrs = processUpdate($upd, $inf, $setup->{configdir}, $POST_STAGE);
        }
        if (@localerrs) {
            push @errs, @localerrs;
            if (!$force) {
                return @errs;
            }
        }
    }

    return @errs;
}

sub updateDSInstance {
    my ($inst, $inf, $configdir, $updates, $force) = @_;
    my @errs;

    my $dseldif = "$configdir/$inst/dse.ldif";

    # get the information we need from the instance
    delete $inf->{slapd}; # delete old data, if any
    if (@errs = initInfFromInst($inf, $dseldif, $configdir, $inst)) {
        return @errs;
    }

    # create dirs if missing e.g. cross platform upgrade
    if (@errs = makeDSDirs($inf)) {
        return @errs;
    }

    # upgrade instance scripts
    if (@errs = createInstanceScripts($inf, 0)) {
        return @errs;
    }

    # add new or missing config files
    if (@errs = makeOtherConfigFiles($inf, 1)) {
        return @errs;
    }

    my $conn;
    if ($inf->{General}->{UpdateMode} eq 'online') {
        # open a connection to the directory server to upgrade
        my $host = $inf->{General}->{FullMachineName};
        my $port = $inf->{slapd}->{ServerPort};
        # this says RootDN and password, but it can be any administrative DN
        # such as the one used by the console
        my $binddn = $inf->{$inst}->{RootDN} || $inf->{slapd}->{RootDN};
        my $bindpw = $inf->{$inst}->{RootDNPwd};
        my $certdir = $inf->{$inst}->{cert_dir} || $inf->{$inst}->{config_dir} || $inf->{slapd}->{cert_dir};

        $conn = new Mozilla::LDAP::Conn({ host => $host, port => $port, bind => $binddn,
                                          pswd => $bindpw, cert => $certdir, starttls => 1 });
        if (!$conn) {
            debug(1, "Could not open TLS connection to $host:$port - trying regular connection\n");
            $conn = new Mozilla::LDAP::Conn({ host => $host, port => $port, bind => $binddn,
                                              pswd => $bindpw });
        }

        if (!$conn) {
            debug(0, "Could not open a connection to $host:$port\n");
            return ('error_online_update', $host, $port, $binddn);
        }
    } else {
        $conn = new FileConn($dseldif);
        if (!$conn) {
            debug(0, "Could not open a connection to $dseldif: $!\n");
            return ('error_offline_update', $dseldif, $!);
        }
    }

    # run pre-instance hooks first, then runinst hooks, then postinst hooks
    # the DS_UPDATE_STAGE 
    for my $stage (@INSTSTAGES) {
        # always process these first in the runinst stage - we don't really have any
        # other good way to process conditional features during update
        if ($stage eq $RUNINST_STAGE) {
            my @ldiffiles;
            if ("1") {
                push @ldiffiles, $inf->{General}->{prefix} . $DS_UPDATE_PATH . "/dnaplugindepends.ldif";
            }
            push @ldiffiles, $inf->{General}->{prefix} . $DS_UPDATE_PATH . "/50updateconfig.ldif";

            for my $ldiffile (@ldiffiles) {
                my @localerrs = processUpdate($ldiffile, $inf, $configdir, $stage,
                                              $inst, $dseldif, $conn);
                if (@localerrs) {
                    push @errs, @localerrs;
                    if (!$force) {
                        $conn->close();
                        return @errs;
                    }
                }
            }
        }
        for my $upd (@{$updates}) {
            my @localerrs;
            if ($upd->{$stage}) {
                debug(1, "Running updateDSInstance stage $stage update ", $upd->{path}, "\n");
                @localerrs = &{$upd->{$stage}}($inf, $inst, $dseldif, $conn);
            } elsif ($upd->{file}) {
                debug(1, "Running updateDSInstance stage $stage update ", $upd->{path}, "\n");
                @localerrs = processUpdate($upd, $inf, $configdir, $stage,
                                           $inst, $dseldif, $conn);
            }
            if (@localerrs) {
                push @errs, @localerrs;
                if (!$force) {
                    $conn->close();
                    return @errs;
                }
            }
        }
    }

    $conn->close();

    updateSelinuxPolicy($inf);

    push @errs, updateTmpfilesDotD($inf);

    push @errs, updateSystemD(1, $inf);

    return @errs;
}

# populate the fields in the inf we need to perform upgrade
# tasks from the information in the instance dse.ldif and
# other config
sub initInfFromInst {
    my ($inf, $dseldif, $configdir, $inst) = @_;
    my $conn = new FileConn($dseldif, 1);
    if (!$conn) {
        debug(1, "Error: Could not open config file $dseldif: Error $!\n");
        return ('error_opening_dseldif', $dseldif, $!);
    }

    my $dn = "cn=config";
    my $entry = $conn->search($dn, "base", "(cn=*)", 0);
    if (!$entry) {
        $conn->close();
        debug(1, "Error: Search $dn in $dseldif failed: ".$conn->getErrorString()."\n");
        return ('error_finding_config_entry', $dn, $dseldif, $conn->getErrorString());
    }

    my $servid = $inst;
    $servid =~ s/slapd-//;

    if (!$inf->{General}->{FullMachineName}) {
        $inf->{General}->{FullMachineName} = $entry->getValue("nsslapd-localhost");
    }
    $inf->{General}->{SuiteSpotUserID} = $entry->getValue("nsslapd-localuser");
    $inf->{slapd}->{ServerPort} = $entry->getValue("nsslapd-port");
    $inf->{slapd}->{ldapifilepath} = $entry->getValue("nsslapd-ldapifilepath");
    if (!$inf->{$inst}->{RootDN}) {
        $inf->{$inst}->{RootDN} || $entry->getValue('nsslapd-rootdn');
    }
    # we don't use this password - we either use {$inst} password or
    # none at all
    $inf->{slapd}->{RootDNPwd} = '{SSHA}dummy';
    if (!$inf->{$inst}->{cert_dir}) {
        $inf->{$inst}->{cert_dir} = $entry->getValue('nsslapd-certdir');
    }
    $inf->{slapd}->{cert_dir} = $inf->{$inst}->{cert_dir};
    if (!$inf->{slapd}->{ldif_dir}) {
        $inf->{slapd}->{ldif_dir} = $entry->getValue('nsslapd-ldifdir');
    }
    if (!$inf->{slapd}->{ServerIdentifier}) {
        $inf->{slapd}->{ServerIdentifier} = $servid;
    }
    if (!$inf->{slapd}->{bak_dir}) {
        $inf->{slapd}->{bak_dir} = $entry->getValue('nsslapd-bakdir');
    }
    if (!$inf->{slapd}->{config_dir}) {
        $inf->{slapd}->{config_dir} = $configdir."/".$inst;
    }
    if (!$inf->{slapd}->{inst_dir}) {
        $inf->{slapd}->{inst_dir} = $entry->getValue('nsslapd-instancedir');
    }
    if (!$inf->{slapd}->{run_dir}) {
        $inf->{slapd}->{run_dir} = $entry->getValue('nsslapd-rundir');
    }
    if (!$inf->{slapd}->{schema_dir}) {
        $inf->{slapd}->{schema_dir} = $entry->getValue('nsslapd-schemadir');
    }
    if (!$inf->{slapd}->{lock_dir}) {
        $inf->{slapd}->{lock_dir} = $entry->getValue('nsslapd-lockdir');
    }
    if (!$inf->{slapd}->{log_dir}) {
        # use the errorlog dir
        my $logfile = $entry->getValue('nsslapd-errorlog');
        if ($logfile) {
            $inf->{slapd}->{log_dir} = dirname($logfile);
        }
    }
    if (!$inf->{slapd}->{sasl_path}) {
        $inf->{slapd}->{sasl_path} = $entry->getValue('nsslapd-saslpath');
    }


    # dn: cn=config,cn=ldbm database,cn=plugins,cn=config
    $dn = "cn=config,cn=ldbm database,cn=plugins,cn=config";
    $entry = $conn->search($dn, "base", "(cn=*)", 0);
    if (!$entry) {
        $conn->close();
        debug(1, "Error: Search $dn in $dseldif failed: ".$conn->getErrorString()."\n");
        return ('error_finding_config_entry', $dn, $dseldif, $conn->getErrorString());
    }

    if (!$inf->{slapd}->{db_dir}) {
        $inf->{slapd}->{db_dir} = $entry->getValue('nsslapd-directory');
    }

    $conn->close(); # don't need this anymore

    # set defaults for things we don't know how to find, after setting the values
    # we do know how to find
    return setDefaults($inf);
}

# check to see if the user has chosen offline mode and the server is really offline
sub isOffline {
    my ($inf, $inst, $conn) = @_;

    if ($inf->{General}->{UpdateMode} !~ /offline/i) {
        debug(3, "UpdateMode " . $inf->{General}->{UpdateMode} . " is not offline\n");
        return 0;
    }

    # mode is offline - see if server is really offline
    my $config = $conn->search("cn=config", "base", "(objectclass=*)");
    if (!$config) {
        return 0, ['error_finding_config_entry', 'cn=config',
                   $conn->getErrorString()];
    }
    my $rundir = $config->getValues('nsslapd-rundir');

    if (serverIsRunning($rundir, $inst)) {
        return 0, ['error_update_not_offline', $inst];
    }

    return 1; # server is offline
}

1;

# emacs settings
# Local Variables:
# mode:perl
# indent-tabs-mode: nil
# tab-width: 4
# End:
