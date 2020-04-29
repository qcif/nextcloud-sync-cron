#!/bin/bash
#
# Nextcloud sync cron script.
#
# This script is a wrapper around nextcloudcmd, designed to be run
# periodically as a cron job, to keep a local directory synchronised
# with a Nextcloud repository.
#
# Usage: nextcloud-sync-cron.sh configfile
#
# The config file must contain "username", "password", "local"
# directory and "remote" URL to a Nextcloud service. Equal sign
# between name and value.
#
# See the README file at <https://github.com/qcif/nextcloud-sync-cron>
# for more details.
#
# Copyright 2017, 2019, 2020, QCIF Pty Ltd.
#----------------------------------------------------------------

#----------------------------------------------------------------
# Constants: these should not be changed

NAME="Nextcloud sync cron"
VERSION=1.3.0

#----------------------------------------------------------------

PROG=`basename "$0"`
PROGDIR=$(cd "$(dirname "$0")" && pwd)

#----------------------------------------------------------------
# Exit status

STATUS_OK=0
STATUS_ERROR=1
STATUS_USAGE_ERROR=2
STATUS_UNEXPECTED_ERROR=3
STATUS_ALREADY_RUNNING=4
STATUS_SKIPPING=5
STATUS_CONFIG_ERROR=6
STATUS_CONFIG_FILE_NOT_FIXED=7

#----------------------------------------------------------------
# Bash strict mode: http://redsymbol.net/articles/unofficial-bash-strict-mode/

set -e # exit if any command has non-zero exit status (works in sh too)
set -u # fail on attempts to expand undefined enviroment variables
set -o pipefail # prevents errors in a pipeline from being masked

# Better error message than "set -e" produces (but only bash supports ERR)
trap "echo $PROG: aborted; exit $STATUS_UNEXPECTED_ERROR" ERR

# Can't figure out which command failed? Run using "bash -x" or uncomment:
# set -x # write each command to stderr before it is exceuted

IFS=$'\n\t'

#----------------------------------------------------------------
# Process command line arguments

LOG_DIR=
VERBOSE=
CONF_FILE=

## Define options: trailing colon means has an argument

SHORT_OPTS=l:Vvh
LONG_OPTS=logdir:,verbose,version,help

SHORT_HELP="Usage: $PROG [options] configFile
Options:
  -l dir          directory for log files
  -v              always print out error messages to stderr on error
  -h              show this help message"

LONG_HELP="Usage: $PROG [options] configFile
Options:
  -l | --logdir dir   directory for log files
  -v | --verbose      always print out error messages to stderr on error
  -h | --help         show this help message
  --version           show version information"

# Detect if GNU Enhanced getopt is available

HAS_GNU_ENHANCED_GETOPT=
if getopt -T >/dev/null; then :
else
  if [ $? -eq 4 ]; then
    HAS_GNU_ENHANCED_GETOPT=yes
  fi
fi

# Run getopt (runs getopt first in `if` so `trap ERR` does not interfere)

if [ -n "$HAS_GNU_ENHANCED_GETOPT" ]; then
  # Use GNU enhanced getopt
  if ! getopt --name "$PROG" --long $LONG_OPTS --options $SHORT_OPTS -- "$@" \
    >/dev/null; then
    echo "$PROG: usage error (use -h or --help for help)" >&2
    exit 2
  fi
  ARGS=`getopt --name "$PROG" --long $LONG_OPTS --options $SHORT_OPTS -- "$@"`
else
  # Use original getopt (no long option names, no whitespace, no sorting)
  if ! getopt $SHORT_OPTS "$@" >/dev/null; then
    echo "$PROG: usage error (use -h for help)" >&2
    exit 2
  fi
  ARGS=`getopt $SHORT_OPTS "$@"`
fi
eval set -- $ARGS

## Process parsed options

while [ $# -gt 0 ]; do
    case "$1" in
        -l | --logdir)   LOG_DIR="$2"; shift;;
        -v | --verbose)  VERBOSE=yes;;
        -h | --help)     if [ -n "$HAS_GNU_ENHANCED_GETOPT" ]
                         then echo "$LONG_HELP";
                         else echo "$SHORT_HELP";
                         fi;  exit 0;;
        -V | --version)  echo "$NAME $VERSION"; exit 0;;
        --)              shift; break;; # end of options
    esac
    shift
done

## Process remaining arguments

if [ $# -eq 0 ]; then
    echo "$PROG: usage error: missing configuration file ('-h' for help)" >&2
    exit $STATUS_USAGE_ERROR
elif [ $# -eq 1 ]; then
    CONF_FILE="$1"
else
    echo "$PROG: too many arguments ('-h' for help)" >&2
    exit $STATUS_USAGE_ERROR
fi

#----------------------------------------------------------------
# Check nextcloud client program is available

NEXTCLOUDCMD=nextcloudcmd

if ! which "$NEXTCLOUDCMD" >/dev/null 2>&1; then
    echo "$PROG: error: command not found: $NEXTCLOUDCMD" 2>&1
    exit 1
fi

#----------------------------------------------------------------
# Load configuration

function getconfig () {
    # Usage: getconfig [--optional] param_name config_file
    if [ $# -eq 3 -a "$1" = '--optional' ]; then
	OPTIONAL=yes
	PARAM="$2"
	FILE="$3"
    elif [ $# -eq 2 ]; then
	OPTIONAL=
	PARAM="$1"
	FILE="$2"
    else
	echo "$PROG: internal error: invoking getconfig" >&2
	exit $STATUS_CONFIG_ERROR
    fi
    VALUE=
    FOUND=
    IFS=": "
    while read -r K V; do
	if [ "$K" = "$PARAM" ]; then
	    if [ -n "$FOUND" ]; then
		echo "$PROG: config: multiple value for \"$PARAM\": $FILE" >&2
		exit $STATUS_CONFIG_ERROR
	    fi
	    VALUE="$V"
	    FOUND=yes
	fi
    done < "$FILE"
    if [ -z "$OPTIONAL" ]; then
	# Parameter was mandatory
	if [ -z "$FOUND" ]; then
	    echo "$PROG: config: missing value for \"$PARAM\": $FILE" >&2
	    exit $STATUS_CONFIG_ERROR
	fi
	if [ -z "$VALUE" ]; then
	    echo "$PROG: config: \"$PARAM\" cannot be blank: $FILE" >&2
	    exit $STATUS_CONFIG_ERROR
	fi
    fi
    echo "$VALUE"
}

if [ ! -e "$CONF_FILE" ]; then
    echo "$PROG: error: config file missing: $CONF_FILE" >&2
    exit $STATUS_ERROR
fi
if [ ! -f "$CONF_FILE" ]; then
    echo "$PROG: error: config file is not a file: $CONF_FILE" >&2
    exit $STATUS_ERROR
fi
if [ ! -r "$CONF_FILE" ]; then
    echo "$PROG: error: cannot read config file: $CONF_FILE" >&2
    exit $STATUS_ERROR
fi

USERNAME=`getconfig --optional username "$CONF_FILE"`
PASSWORD=`getconfig --optional password "$CONF_FILE"`

UNSYNCEDFOLDERS=`getconfig --optional unsyncedfolders "$CONF_FILE"`
DAVPATH=`getconfig --optional davpath "$CONF_FILE"`
EXCLUDE=`getconfig --optional exclude "$CONF_FILE"`

LOCAL_DIR=`getconfig local "$CONF_FILE"`
REMOTE_URI=`getconfig remote "$CONF_FILE"`

#----------------------------------------------------------------
# Setup internal file names

if [ -z "$LOG_DIR" ]; then
    # No log directory from command line: use default inside local directory
    LOG_DIR="$LOCAL_DIR/._sync_nextcloud"
fi

LOG_FILE="$LOG_DIR/sync.log"
PID_FILE="$LOG_DIR/sync.pid"
OUT_FILE="$LOG_DIR/nextcloudcmd.txt"
BAD_FILE="$LOG_DIR/failures.txt"

#----------------------------------------------------------------
# Check configuration is correct

if [ ! -e "$LOCAL_DIR" ]; then
    echo "$PROG: error: local directory missing: $LOCAL_DIR" >&2
    exit $STATUS_ERROR
fi
if [ ! -d "$LOCAL_DIR" ]; then
    echo "$PROG: error: local directory is not a directory: $LOCAL_DIR" >&2
    exit $STATUS_ERROR
fi
if [ ! -r "$LOCAL_DIR" ]; then
    echo "$PROG: error: cannot read local directory: $LOCAL_DIR" >&2
    exit $STATUS_ERROR
fi
if [ ! -w "$LOCAL_DIR" ]; then
    echo "$PROG: error: cannot write to local directory: $LOCAL_DIR" >&2
    exit $STATUS_ERROR
fi
if [ ! -x "$LOCAL_DIR" ]; then
    echo "$PROG: error: cannot access local directory: $LOCAL_DIR" >&2
    exit $STATUS_ERROR
fi

if [ ! -d "$LOG_DIR" ]; then
    if ! mkdir "$LOG_DIR" 2>&1; then
	echo "$PROG: error: cannot create log directory: $LOG_DIR" >&2
	exit $STATUS_ERROR
    fi
fi
if [ ! -w "$LOG_DIR" ]; then
    echo "$PROG: error: cannot write to log directory: $LOG_DIR" >&2
    exit $STATUS_ERROR
fi
if [ ! -x "$LOG_DIR" ]; then
    echo "$PROG: error: cannot access log directory: $LOG_DIR" >&2
    exit $STATUS_ERROR
fi

#----------------------------------------------------------------
# Start log file

if [ ! -f "$LOG_FILE" ]; then
    # Log does not exist: create it
    if ! touch "$LOG_FILE"; then
	echo "$PROG: error: could not create log file: $LOG_FILE" >&2
	exit $STATUS_ERROR
    fi
fi 

# NOTE: After this point this script does not produce any output to
# stdout or stderr, unless in verbose mode. This is so cron won't
# email the user anything.  See the log file for any error messages.

#----------------------------------------------------------------
# Check credentials (might) exist
# Might because it doesn't look inside any ~/.netrc file for correctness.

ERROR=
if [ -n "$USERNAME" -a -z "$PASSWORD" ]; then
    ERROR="config file has username without password"
elif [ -z "$USERNAME" -a -n "$PASSWORD" ]; then
    ERROR="config file has password without username"
elif [ -z "$USERNAME" -a -z "$PASSWORD" ]; then
    if [ ! -r "$HOME/.netrc" ]; then
	ERROR="cannot read file: $HOME/.netrc"
    fi
    if [ ! -e "$HOME/.netrc" ]; then
	ERROR="file missing: $HOME/.netrc"
    fi
fi

if [ -n "$UNSYNCEDFOLDERS" ]; then
  if [ ! -r "$UNSYNCEDFOLDERS" ]; then
    ERROR="cannot read unsyncedfolders file: $UNSYNCEDFOLDERS"
  fi
fi

if [ -n "$EXCLUDE" ]; then
  if [ ! -r "$EXCLUDE" ]; then
    ERROR="cannot read excludelist file: $EXCLUDE"
  fi
fi

if [ -n "$ERROR" ]; then
    TS=`date '+%F %T'`
    echo "$TS: fail: $ERROR" >> "$LOG_FILE"
    if [ -n "$VERBOSE" ]; then
	echo "$PROG: error: $ERROR" >&2
    fi
    exit $STATUS_CONFIG_ERROR
fi

#----------------------------------------------------------------
# Check for previous failures

PARAM_NAME_NUM_FAILURES=number_of_failures
PARAM_NAME_TIMESTAMP=last_runtime
PARAM_NAME_REASON=reason

REASON_CONFIG='configuration error'

if [ -e "$BAD_FILE" ]; then
    # Previous run failed

    NUM_FAILURES=`getconfig $PARAM_NAME_NUM_FAILURES "$BAD_FILE"`
    PREV_FAIL_SECS=`getconfig $PARAM_NAME_TIMESTAMP "$BAD_FILE"`
    PREV_REASON=`getconfig $PARAM_NAME_REASON "$BAD_FILE"`

    if ! echo "$NUM_FAILURES" | grep -E '^[0-9]+$' >/dev/null; then
	if [ -n "$VERBOSE" ]; then
	    echo "$PROG: error: corrupt file: $BAD_FILE" >&2
	fi
	exit $STATUS_ERROR
    fi
    if [ $NUM_FAILURES -le 0 ]; then
	if [ -n "$VERBOSE" ]; then
	    echo "$PROG: error: corrupt file: $BAD_FILE" >&2
	fi
	exit $STATUS_ERROR
    fi

    if ! echo "$PREV_FAIL_SECS" | grep -E '^[0-9]+$' >/dev/null; then
	if [ -n "$VERBOSE" ]; then
	    echo "$PROG: error: corrupt file: $BAD_FILE" >&2
	fi
	exit $STATUS_ERROR
    fi

    # Determine delay before retrying
    # Current algorithm: 1, 2, 4 minute ... 4, 8, 16, 24, 24, 24 hours ...

    MAX_DELAY=$((60 * 60 * 24))  # 1 day

    DELAY=$(( 2 ** (($NUM_FAILURES - 1)) * 60 ))
    if [ $DELAY -gt $MAX_DELAY ]; then
	DELAY=$MAX_DELAY
    fi

    # Abort if reason was configuration error and it has not been fixed

    if echo "$PREV_REASON" | grep "^$REASON_CONFIG" >/dev/null; then
	# Configuration error

	if [ "$CONF_FILE" -nt "$BAD_FILE" ]; then
	    # Config file has been modified since last run
	    :
	elif [ \( -z "$USERNAME" \) -a \
	       \( "$HOME/.netrc" -nt "$BAD_FILE" \) ];then
	    # Using ~/.netrc and it has been modified since last run
	    :
	else
	    # Problem probably has not been fixed
	    if [ -n "$USERNAME" ]; then
		ERROR="fix \"$CONF_FILE\" or delete \"$BAD_FILE\""
	    else
		ERROR="fix \"$CONF_FILE\" and/or \"$HOME/.netrc\", or delete \"$BAD_FILE\""
	    fi
	    TS=`date '+%F %T'`
	    echo "$TS: fail: $ERROR" >> "$LOG_FILE"

	    if [ -n "$VERBOSE" ]; then
		echo "$PROG: $PREV_REASON" >&2
		echo "$PROG: $ERROR before running again" >&2
	    fi
	    exit $STATUS_CONFIG_FILE_NOT_FIXED
	fi
	
	# Note: normal delay does not apply.
    else
	# Not a config file error: retry or wait?

	NOW_SECS=`date +%s`
	ELAPSED=$(($NOW_SECS - $PREV_FAIL_SECS))

	if [ $ELAPSED -lt $DELAY ]; then
	    if [ -n "$VERBOSE" ]; then
		echo "$PROG: skipping (can sync in $(($DELAY-$ELAPSED))s)" >&2
	    fi
	    exit $STATUS_SKIPPING
	fi
    fi

else
    # Previous run was ok
    NUM_FAILURES=0
fi

#----------------------------------------------------------------
# Prevent multiple instances of this script from running

# Check PID file exists and its process is still running

if [ -f "$PID_FILE" ]; then
    OLD_PID=`cat "$PID_FILE"`
    if echo "$OLD_PID" | grep -E '^[0-9]+$' >/dev/null; then
	# PID file contained a number
	if ps -p "$OLD_PID" >/dev/null; then
	    # Process still running
	    if [ -n "$VERBOSE" ]; then
		echo "$PROG: another process is already running" >&2
	    fi
	    exit $STATUS_ALREADY_RUNNING
	else
	    # Process not running: stale PID file
	    rm "$PID_FILE"
	fi
    else
	# PID file contained unexpected data
	TS=`date '+%F %T'`
	echo "$TS: fail: bad PID file: $PID_FILE" >> "$LOG_FILE"
	exit $STATUS_ERROR
    fi
fi

# Create PID file

PID=$$
echo $PID > "$PID_FILE"

SAVED_PID=`cat "$PID_FILE"`
if [ "$SAVED_PID" != "$PID" ]; then
    # Race condition: someone else created the PID file before us?
    if [ -n "$VERBOSE" ]; then
	echo "$PROG: another process is already running" >&2
    fi
    exit $STATUS_ALREADY_RUNNING
fi

#----------------------------------------------------------------
# Run sync command, saving any error messages if this is a last chance run

# Write the settings used into the start of the file to aid debugging

TS=`date '+%F %T'`
START_SECS=`date +%s`

UNSYNCEDFOLDERS_SETTING=
if [ -n "$UNSYNCEDFOLDERS" ]; then
  UNSYNCEDFOLDERS_SETTING="unsyncedfolders: $UNSYNCEDFOLDERS"
fi

DAVPATH_SETTING=
if [ -n "$DAVPATH" ]; then
  DAVPATH_SETTING="davpath: $DAVPATH"
fi

EXCLUDE_SETTING=
if [ -n "$EXCLUDE" ]; then
  EXCLUDE_SETTING="exclude: $EXCLUDE"
fi

cat >"$OUT_FILE" <<EOF
# $NAME: nextcloudcmd output

# script: $PROGDIR/$PROG
# config: $CONF_FILE
# runtime: $TS

remote: $REMOTE_URI
local: $LOCAL_DIR

$UNSYNCEDFOLDERS_SETTING
$DAVPATH_SETTING
$EXCLUDE_SETTING
EOF

# Warning: do not run nextcloudcmd with -h, since that will sync the
# hidden directory used for logging. If hidden files are needed,
# change where the log directory is.

# Stdin is taken from /dev/null so when it attempts to use ~/.netrc
# and suitable credentials aren't in it, it is not going to hang
# waiting for the user to enter the password. The --non-interactive
# option is not used because it causes nextcloudcmd v2.3.2 to return a
# misleading zero exit status if it fails to authenticate.

UNSYNCEDFOLDERS_OPTION=
if [ -n "$UNSYNCEDFOLDERS" ]; then
  UNSYNCEDFOLDERS_OPTION="--unsyncfolders \"$UNSYNCEDFOLDERS\""
fi

DAVPATH_OPTION=
if [ -n "$DAVPATH" ]; then
  DAVPATH_OPTION="--davpath \"$DAVPATH\""
fi

EXCLUDE_OPTION=
if [ -n "$EXCLUDE" ]; then
  EXCLUDE_OPTION="--exclude \"$EXCLUDE\""
fi

# Run command

NCC_SUCCEEDED=
if [ -n "$USERNAME" ]; then
  # Credentials on command line
  if eval "$NEXTCLOUDCMD" --user "$USERNAME" --password "$PASSWORD" \
          $UNSYNCEDFOLDERS_OPTION \
	  $DAVPATH_OPTION \
	  $EXCLUDE_OPTION \
	  "$LOCAL_DIR" "$REMOTE_URI" </dev/null >>"$OUT_FILE" 2>&1; then
    NCC_SUCCEEDED=yes
  fi
else
  # Credentials from ~/.netrc (the "-n" means to use netrc for login)
  if eval "$NEXTCLOUDCMD" -n \
	  $UNSYNCEDFOLDERS_OPTION \
	  $DAVPATH_OPTION \
	  $EXCLUDE_OPTION \
	  "$LOCAL_DIR" "$REMOTE_URI" </dev/null >>"$OUT_FILE" 2>&1; then
    NCC_SUCCEEDED=yes
  fi
fi

TE=`date '+%F %T'`
FINISH_SECS=`date +%s`

DELAY=$(($FINISH_SECS - $START_SECS))

# Write statistics into the end of the file

cat >>"$OUT_FILE" <<EOF

# time taken: $DELAY seconds
# finished: $TE
EOF

if [ -n "$NCC_SUCCEEDED" ]; then
    # Succeeded

    # Reset failures
    if [ $NUM_FAILURES -gt 0 ]; then
	rm "$BAD_FILE"
    fi

    # Log
    echo "$TS: OK (${DELAY} s)" >> "$LOG_FILE"

    EXIT_STATUS=$STATUS_OK

else
    # Failed

    # Attempt to interpret output for obvious errors.

    REASON=
    if grep 'Network error:  "ocs/v1.php/cloud/capabilities" "Host .* not found" QVariant(Invalid)' "$OUT_FILE" >/dev/null; then
	REASON="$REASON_CONFIG: bad host in \"remote\" URL"
    elif grep 'Network error:  "ocs/v1.php/cloud/capabilities" "Error transferring .* - server replied: Not Found" QVariant(int, 404)' "$OUT_FILE" >/dev/null; then
	REASON="$REASON_CONFIG: bad path in \"remote\" URL"
    elif grep 'Network error:  "ocs/v1.php/cloud/capabilities" "Host requires authentication" QVariant(int, 401)' "$OUT_FILE" >/dev/null; then
	REASON="$REASON_CONFIG: incorrect username/password"
    else
	REASON="see nextcloudcmd output: $OUT_FILE"
    fi

    # Record failures

    NUM_FAILURES=$((NUM_FAILURES + 1))

    cat > "$BAD_FILE" <<EOF
# $NAME: recent failures

# script: $PROGDIR/$PROG
# config: $CONF_FILE
# last_runtime: $TS

$PARAM_NAME_NUM_FAILURES: $NUM_FAILURES
$PARAM_NAME_TIMESTAMP: $START_SECS
$PARAM_NAME_REASON: $REASON
EOF

    # Log
    echo "$TS: fail" >> "$LOG_FILE"

    if [ -n "$VERBOSE" ]; then
	echo "$PROG: error: $REASON" >&2
    fi
    EXIT_STATUS=$STATUS_ERROR
fi

#----------------------------------------------------------------
# Remove PID file

rm "$PID_FILE"

exit $EXIT_STATUS

#EOF
