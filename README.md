# nextcloud-sync-cron

Script to run the Linux/Unix Nextcloud command line client in a cron job.

# Synopsis

    nextcloud-sync-cron.sh [--logdir dir] [--verbose] [--help] [--version] configfile
    
# Description

For running the [Nextcloud command line
client](https://docs.nextcloud.com/desktop/2.5/advancedusage.html#nextcloud-command-line-client)
program, `nextcloudcmd`, in a _cron_ job.

The standard Nextcloud command line client performs one sync run and
exits. Therefore, to keep a local directory synchronised with a
Nextcloud repository, it needs to be run everytime files have changed
or regularly to scan for any changes. Running it directly from a
_cron_ job is possible, but can lead to problems. This script
addresses those problems.

Features are:

- Prevents multiple copies of the script from running at the same
  time.  This is needed to prevent _cron_ starting another run before
  a previous run has finished.

- Blocking and/or delaying retries when errors are encountered. This
  prevents excessive retries before problems are fixed. For example,
  retrying with the wrong password can blacklist the user account and
  make the problem harder to fix.

- Account details are stored in a separate configuration file instead
  of embedded inside the crontab.

## Command line options

- `--logdir` _dir_ directory for log files.

- `--verbose` show error messages on stderr.

- `--version` shows version information.

- `--help` shows a brief help message.

- _configfile_ file containing the configuration information.

## Configuration file

### Recommended method using .netrc

A configuration file is a text file that must contain:

- `local` directory on the local machine where the files will be stored.
- `remote` URL to the Nextcloud service.

For example:

```
# Config file for Nextcloud sync cron

local: /home/fbar/mydata
remote: https://nextcloud.example.com
```

And the `~/.netrc` file contains the user credentials:

```
default
login foobar
password p@ssw0rd
```

Note: the _.netrc_ file must reside in the home directory. It is
not possible for a different file to be used.

### Alternative not using .netrc

If the username and password is included in the configuration file,
they will be used instead of the _.netrc_ file.

This method is not recommended, because the password will be passed to
_nextcloudcmd_ via command line parameters which exposes it to others
on the system.

```
# Config file for Nextcloud sync cron

local: /home/fbar/mydata
remote: https://nextcloud.example.com
username: foobar
password: p@ssw0rd
```

### Unsynced folders

Optionally the configuration file can also contain:

- `unsyncedfolders` file with names of folders on remote machine that shall not be synced.

The file is passed to _nextcloudcmd_ as the `--unsyncedfolders` option.

```
# Config file for Nextcloud sync cron

local: /home/fbar/mydata
remote: https://nextcloud.example.com
unsyncedfolders: /home/fbar/nosync.lst
```

## Logging and errors

The default log directory is called "`._sync_nextcloud`" inside the local
directory, or it can be specified via command line arguments.

The log directory contains these files:

- `sync.log` contains a line for each run of the Nextcloud command
  line client. The line contains a timestamp and whether the run was
  "ok" or "fail". If ok, the duration it took to run is included.

- `nextcloudcmd.txt` contains the output from the previous run of the
  Nextcloud command line client (regardless of whether it was
  successful or not). This file is useful for debugging why the sync
  client failed.

- `sync.pid` contains the process identifier (PID) number of the
  script currently running for that local directory. The PID file
  should not be present when there is none runnning.

- `failures.txt` contains information about previous failures, if the
  most recent run was not successful. The information in it determines
  the delay before the client is allowed to run again.  If the most
  recent run was successful this file is deleted, because it breaks
  the previous sequence of failures.

The log directory is created if it does not already exist.

# Example

[Install](https://nextcloud.com/install/#install-clients) the
Nextcloud command line client.  For example, on CentOS 7, this can be
done by running:

    sudo yum install epel-release
    sudo yum install nextcloud-client

Create a configuration file.

If the local directory does not exist, create it.  The user running
the _cron_ job needs permissions to read/write/access the local
directory, as well as reading the configuration file.

Optionally, test the configuration file.  Manually run the script to
check the configuration is correct.  Note: this can take a long time
to run, since it will perform the initial sync.

    nextcloud-sync-cron.sh --verbose /home/username/myncs.conf

Configure _cron_ by editing the crontab file:

    crontab -e

For example, this job runs the script once every minute:

     * * * * * /home/username/nextcloud-sync-cron.sh /home/username/myncs.conf

# Details

## Retries after failure

### Retries and configuration errors

If the client fails because of a problem with the values in the
configuration file, subsequent runs are prevented until the config
file is fixed. For example, the password was wrong.  The script
compares the modified timestamp on the config file with the
_failures.txt_ file.

If the problem is fixed without needing to update the configuration
file, the script can be allowed to run either by: changing the
modified timestamp of the config file; or simply deleting the
_failures.txt_ file.

### Retries and other errors

Other failures results in subsequent retries being skipped until a
delay is reached. This delay increases with subsequent failures.

The delay starts at 1 minute, and doubles with subsequent failures,
with the maximum delay of 24 hours. That is the delays are: 1 minute
on the first failure, then 2, 4, 8 minutes etc.


# Exit status

**0: ok**

Success.

**2: usage error**

Command line arguments were incorrect.

**3: unexpected error**

A command in the script failed.

**4: already running**

Another instance of the script is already running for the local
directory.

Solution: wait until the other script finishes running.

**5: Skipping**

A previous run of the script failed and the time delay before another
sync can be attempted has not been reached. Try again later.

Solution: try again later, or delete the _failures.txt_ file to clear
the failures causing it to delay synching.

**6: bad value in configuration file**

The configuration file contains incorrect values. The script will not
run.

Solution: edit the config file to provide the correct values.

**7: values in configuration file incorrect**

The configuration file contains incorrect values. The script used them
in a previous sync, but they were rejected. For example, the username
and password are incorrect.

The script will not attempt another sync until the configuration file
has been modified.

Solution: edit the config file to provide the correct values. But if
the values are correct (i.e. the problem was fixed elsewhere), update
the timestamp of the configuration file or delete the _failures.txt_
file.


# Known limitations

## Security issues

If the `.netrc` file is not used, the password is passed to the
Nextcloud command line client via command line arguments. This is a
limitation of the Nextcloud command line client.

## Some errors will produce output

Certain types of errors will cause the script to print out an error
message on stdout. Cron, by default, emails the user if the job
produces output.  Therefore, the user could receive many emails before
the problem is fixed (especially if the cron job runs frequently).

Normally, error messages will be written to the log file and no output
is produced (unless the verbose option is provided). Until the script
is ready to write to the log file, error messages appear on
stderr. Usually, these are all problems that will be raised the first
time the script is run.  For example:

- the configuration file cannot be read;
- the configuration file contain incorrect values; or
- the local directory does not exist or has the wrong permissions.

Therefore, it is advised to wait until the cron job runs, at least
once, before leaving it unattended. However, these errors can also
arise if incorrect changes are made to the configuration file or local
system.

## Performance

Every time the script is run, it needs to scan the entire local
directory for changes.

The _nextcloudcmd_ program is not designed to be a sync client. There
is a long-standing
[issue](https://github.com/owncloud/client/issues/2002) for a proper
non-GUI sync client to be built.
