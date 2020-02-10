#!/bin/bash
###############################################################################
#
#	Purpose:
#		Provide consistent interface for sudo privilege elevation.  Selective
#		privilege elevation can, but not necessarily, improve a script's security by
#		only elevating the hopefully small subset of commands requiring more
#		permissive privileges.
#
#		As mentioned security isn't necessarily improved, as once an account's (user's)
#		privileges have been elevated, one must "trust" that the code written doesn't
#		exploit this elevated status.  For example, a malicious command could "hide"
#		an elevation request somewhere in its code waiting for execution by an
#		account that currently permits privilege elevation, enabling this command to
#		elevate its process permissions.  To address this gaping hole, elevation must
#		be coupled with another least privileged strategy to minimize this risk.
# 
#		As a suggestion, perhaps this package should be extended to include a
#		sudo_demote that executs a command with a least privileged account.
#		
#	Notes:
#		Important conventions when modifying this file:
#		https://github.com/WhisperingChaos/SOLID_Bash/blob/master/README.md#source-file-conventions
#
###############################################################################

###############################################################################
#
#	Purpose:
#		- Elevate privileges of command, if specified.
#		- Elongate sudo grace period by resetting its timer.
#
#	Notes:
#		- https://gratisoft.us/sudo/sudoers.man.html
#		- Recommend not using this function.  Instead use 'sudo_elevate_periodic_timer'.
#		  The 'sudo_elevate_periodic_timer' can be seamlessly added to an existing
#		  script that employs granular 'sudo' commands in its implementation.  This 
#		  strategy permits the developer to continue directly using sudo allowing
#		  simple reversion without having to change code if this implementation
#		  is found problematic.
#
#	In:
#		- If account not currently in sudo grace period, expect command line prompt
#		  for account password.
#		- nothing - Just elongate sudo grace period.
#   - $1-$N   - Run command & elongate sudo grace period.
#
#	Out:
#		- When successful & command - mirrors output of command
#		- When successful & no comand - no output
#		- When unsuccessful potentially message on STDERR  
#
###############################################################################
sudo_elevate(){
	local -r command="$1"

	if ! sudo__elongate >/dev/null && ! sudo__elongate_prompt; then
		return 1
  fi

  if [ -z "$command" ]; then
    return
  fi

	sudo__execute $@
}
# used to trigger periodic elongation of sudo grace period. Due to resolution
# concerns, would not reduce this value below 2 seconds.  Use SOLID principles
# to override value.
declare -gi sudo__GRACE_TRIGGER_HEARTBEAT_SEC=2
###############################################################################
#
#	Purpose:
#		Reduce/eliminate the need for the current process calling this function
#		to display a password prompt as long as this process runs.  This function
#		periodically elongates grace period in child background process spawned
#		from the process (parent) calling this function.
#
#	Assumes:
#		- Linux OS will enfore timing to a precision such that a process scheduled
#		  nearly before a second one will always, under at least most conditions,
#		  execute before the second one.
#		- Precision/resolution to a second.
#		- Execution time between calculating a timer duration and starting the
#		  timer ticking is no more than 1 second.
#
#	Notes:
#		- Periodic timer isn't created at all when:
#		  - sudo requires a privilege (password) prompt for every elevation request. 
#		  - sudo configured to infinitely extend grace period.
#		- Recommend using this function instead of 'sudo_elevate', as it can be 
#		  seamlessly added to an existing script that employs granular 'sudo'
#		  commands in its implementation.  This strategy permits a developer to
#		  continue directly encoding sudo commands allowing simple removal of
#		  this function without having to change code if its implementation is
#		  found problematic.
# 
#	In
#		- If account not currently in sudo grace period, expect sudo to produce
#		  command line prompt for account password.
#		- sudo__GRACE_TRIGGER_HEARTBEAT_SEC specifies the interval before the
#		  expiration of the grace period when the grace period will be reset
#		  to elongate the elevated session.
#		- $1 (optional) - overrides the system/user specified grace period.
#        Specify this value when the default grace period is not exactly
#		     known, but is within this value or there is a desire to agressively
#			   reset the grace interval.  Measured in minutes and fractional 
#			   minutes specified in decimal notation (same as timestamp_timeout).
#        Ex. grace period of 5min and 30sec: timestamp_timeout=5.5
#
#	Out
#		- When successful, unnecessary, or not applicable - no output.
#
###############################################################################
sudo_elevate_periodic_timer(){
	local gracePeriodInMin="$1"

	local -i gracePeriodSec
	if [ -n "$gracePeriodInMin" ] && ! sudo__grace_period_timeout_to_sec "$gracePeriodInMin" 'gracePeriodSec'; then
		return 1
	fi

	if ! sudo_elevate; then
		return 1
	fi

	if [ -z "$gracePeriodInMin" ] && ! sudo__grace_period_get 'gracePeriodSec'; then
		sudo__grace_periodic_fail
		return 1
  fi
	local -r gracePeriodSec

  if [ $gracePeriodSec -lt 0 ]; then
		# grace interval has been configured to last duration of current terminal
    # session :: it never needs to be renewed.
		return
  fi

  if [ $gracePeriodSec == 0 ]; then
		# grace interval is disabled - only lasts for a single command.  Periodic
		# timer not applicable.
		return
  fi
	# subtract 1sec from grace period to ensure that when coupled to sleep's
	# 1ms resolution and time required to execute commands to establish heartbeat,
	# reset will almost always occur before grace period expires. 
	local -ri graceHeartbeatSec=gracePeriodSec-1-sudo__GRACE_TRIGGER_HEARTBEAT_SEC
	if [ $graceHeartbeatSec -lt $sudo__GRACE_TRIGGER_HEARTBEAT_SEC ]; then
		sudo__timer_resolution_unstable $sudo__GRACE_TRIGGER_HEARTBEAT_SEC
		return 1
	fi  
  # run sudo_elevate to help background process start before grace period expires
	# due to executing code since last grace period reset.
	if ! sudo_elevate; then
		return 1
	fi
	sudo__elevate_heartbeat $$ $graceHeartbeatSec >/dev/null &
}
###############################################################################
# Private functions and constants below - do not call directly.  However, use
# bash's function override mechanism to, when desired, change implementation.
# Same applies to environment variables.
###############################################################################

sudo__elongate(){

	sudo -vn
}

sudo__elongate_prompt(){

	sudo -v
}	

sudo__execute(){

	sudo $@
}

sudo__grace_periodic_get_fail(){
  cat >&2 <<SUDO__GRACE_PERIOD_PERIODIC_FAIL

Error: Unable to determine grace period.
SUDO__GRACE_PERIOD_PERIODIC_FAIL
}

sudo__timer_resolution_unstable(){
local -ri minHeartbeatResSec=$1

  cat >&2 <<SUDO__TIMER_RESOLUTION_UNSTABLE

Error: Timer resolution to trigger heartbeat renewal (validation) unstable.
  + sudo grace period is less than $minHeartbeatResSec seconds.
SUDO__TIMER_RESOLUTION_UNSTABLE
}

sudo__elevate_heartbeat(){
	local -ri heartBeatPID=$!
	local -ri parentPID=$1
	local -ri graceIntervalSec="$2"

	sudo_elevate_heartbeat_parent_poll $parentPID >/dev/null &
	local -ri parentPollPID=$!
	local -i gracePollPID
	while true; do
		sudo__elongate >/dev/null
		sleep ${graceIntervalSec}s >/dev/null &
		gracePollPID=$!
		wait -n $parentPollPID $gracePollID >/dev/null
		if ! kill -0 $parentPID >/dev/null 2>/dev/null; then
			break
		fi
	done
	kill $gracePollPID >/dev/null
	kill $heartBeatPID >/dev/null
}

sudo_elevate_heartbeat_parent_poll(){

	while true; do
		if ! kill -0 $parentPID >/dev/null 2>/dev/null; then
			return
		fi	
		sleep 1s
	done
}


declare -g  sudo__grace_SUDOERS_SETTINGS="/etc/sudoers"
declare -gi sudo__grace_SUDOERS_GRACE_PERIOD_SYSTEM_DEFAULT_SEC=5*60

###############################################################################
#	Purpose:
#		Obtain sudo command grace period, in seconds, for currently executing host.
#
# Assumes:
#		- Grace period's resolution is at least a second.
#
#	Notes:
#		- https://gratisoft.us/sudo/sudoers.man.html describes, in detail, sudo
#		  file format and grace period values.
#		- sudo can implement grace period policies on a per application
#		  granularity that's beyond the ability of this script to support.
#		- Since "timestamp_timeout" permits specifying a fractions of a minute
#		  using decimal notation, the grace period will be calculated to a
#		  truncated second.  Additionaly, given this understanding, the code
#		  assumes the grace period's resolution to be at least a second. If
#		  resolution is better than a second then this routine will always
#		  return a grace period value that's less than the actual one due to
#		  truncation.
#		
# In:
#		- $1 - The name of a variable to return the value of the grace period.
#   - sudo__grace_SUDOERS_SETTINGS - a file that may explicitly define the value
#		  of timestamp_timeout or provide a directory of files to search for this value.
#		  It's not a parameter to the function as this variable is intimate to the 
#		  implementation of "sudo" therefore, it should not be exposed to the caller
#		  that acts on a more abstract level.
#
# Out:
#		- $1 grace period environment variable value:
# 		- <0 - sudo grace period is life of current terminal session.
#     - =0 - sudo grace period is one command invocation.
#			- >0 - sudo grace period is some positive integer of seconds.  If
#			       none specified use default: sudo__grace_SUDOERS_GRACE_PERIOD_SYSTEM_DEFAULT_SEC
#
###############################################################################
sudo__grace_period_get() {
	local -r gpOut="$1"

	if [ -z "$gpOut" ]; then 
		return 1
	fi
	# see if override settings specified
	if ! sudo_elevate test -f "$sudo__grace_SUDOERS_SETTINGS" >/dev/null; then
		sudo__sudoers_settings_file_fail "$sudo__grace_SUDOERS_SETTINGS"
		return 1
	fi

	local -r sudoersOverrideSettingsDir=$(sudo__grace_override_dir_get "$sudo__grace_SUDOERS_SETTINGS")
	local graceOveride
  if [ -n "$sudoersOverrideSettingsDir" ]; then
		graceOveride=$(sudo__grace_period_override_get "$sudoersOverrideSettingsDir")
  fi
	local -r graceOveride
  if [ -n "$graceOveride" ]; then
		# override sudo grace period was specified
		eval $gpOut\=\$graceOveride
    return
  fi
	# see if system level settings include override of default
	local graceSystem=$(sudo__grace_period_system_get "$sudo__grace_SUDOERS_SETTINGS")
  if [ -n "$graceSystem" ]; then
		eval $gpOut\=\$graceSystem
		return
	fi
  # nothing specified in settings, return known default
	eval $gpOut\=sudo__grace_SUDOERS_GRACE_PERIOD_SYSTEM_DEFAULT_SEC
}

sudo__sudoers_settings_file_fail(){
	local -r sudoersSettings="$1"

	cat >&2 <<SUDO__SUDOERS_SETTINGS_FILE_FAIL

Error: Unable to locate or lack permissions to view sudoers settings file: '$sudoersSettings'.
SUDO__SUDOERS_SETTINGS_FILE_FAIL
}

declare -g sudo__grace_EXTENSION_PREMBLE_REGEX='^[[:space:]]*#includedir[[:space:]]+'
# [^#]+ - any characters after #includedir except characters after comment. Unfortunately
# this simple regex may incorrectly include directories whose names include a #.
# Since most developers avoid special characters in directory names, then a #
# is most likely the start of a comment.
declare -g sudo__grace_EXTENSION_REGEX="$sudo__grace_EXTENSION_PREMBLE_REGEX"'([^#]+)'

sudo__grace_override_dir_get(){
	local -r sudoersFile="$1"

	local -r sudoersDir=$( sudo_elevate cat $sudoersFile | grep -E "$sudo__grace_EXTENSION_PREMBLE_REGEX")
	if [[ "$sudoersDir" =~ $sudo__grace_EXTENSION_REGEX ]]; then
		echo "${BASH_REMATCH[1]}" | xargs # remove trailing whitespace
	fi
}



sudo__grace_period_override_get(){
	local -r directory="$1"

	sudo_elevate ls -p "$1"          		                 \
	| grep -v '/'                                        \
 	| grep -v '.*\..*'                                   \
	| grep -v '.*~'                                      \
  | sudo__grace_sudoers_timeout_extract "$directory"   \
	| sudo__grace_period_extract_from_stream
}

sudo__grace_sudoers_timeout_extract(){
	local -r directory="$1"

	local fileName
	while read -r fileName; do
		if [ -z "$fileName" ]; then
			continue
		fi
		sudo_elevate cat "$directory/$fileName"
	done
}

sudo__grace_sudoers_timeout_min(){

  local	   gracePeriod
	local -i timeoutSec
	local -i timeoutLeastSec
	local timeoutSpecified=false
  while read -r gracePeriod; do
		if ! sudo__grace_period_timeout_to_sec "$gracePeriod" 'timeoutSec'; then
			continue
		fi
		if ! $timeoutSpecified; then
			timeoutLeastSec=$timeoutSec
			timeoutSpecified=true
			continue
		fi
		# time out value < 0 means no timeout - normalized as the greatest time out 
		if [ $timeoutLeastSec -gt -1 ] && [ $timeoutSec -gt $timeoutLeastSec ]; then
			continue
		fi
		timeoutLeastSec=$timeoutSec
	done

	if $timeoutSpecified; then
		echo $timeoutLeastSec
	fi
}

declare -g sudo__grace_TIMESTAMP_TIMEOUT_REGEX='([-+]?[0-9]+)(\.([0-9]+))?'
declare -g sudo__grace_SED_REGEX='s/^[[:space:]]*Defaults.+timestamp_timeout=('"$sudo__grace_TIMESTAMP_TIMEOUT_REGEX"')/\1/'

sudo__grace_period_timeout_to_sec(){
	local    gracePeriod="$1"
	local -r timeOutRtn="$2"

	local -r posNegIntPat='^'"$sudo__grace_TIMESTAMP_TIMEOUT_REGEX"'$'
	if ! [[ $gracePeriod =~ $posNegIntPat ]]; then
		sudo__grace_period_format_fail "$gracePeriodInMin" "$posNegIntPat"
		return 1
	fi
	local -ri timeoutInt=${BASH_REMATCH[1]}
	local -ri timeoutDec=${BASH_REMATCH[3]}
	local -i decimalPlaces=${#timeoutDec}
	if [ $timeoutDec -lt 1 ]; then
		decimalPlaces=1
	fi
	eval $timeOutRtn=\$\(\(timeoutInt\*60\+timeoutDec\*60\/\(10\*\*decimalPlaces\)\)\)
	return 0
}

sudo__grace_period_format_fail(){
	local -r gracePeriod="$1"
	local -r timeoutRegex="$2"
  cat >&2 <<SUDO__GRACE_PERIOD_FORMAT_FAIL

Error: Specified grace period: '$gracePeriod' doesn't conform to sudo 'timestamp_timeout'
  +    format.  Must be in minutes and adhere to regex: '$timeoutRegex'.
SUDO__GRACE_PERIOD_FORMAT_FAIL
}

sudo__grace_period_system_get(){
	local sudoersSystem="$1"

	sudo_elevate cat "$sudoersSystem" | sudo__grace_period_extract_from_stream
}

declare -g sudo__grace_GREP_REGEX='^[[:space:]]*Defaults.+timestamp_timeout='

sudo__grace_period_extract_from_stream(){
	grep -E "$sudo__grace_GREP_REGEX"                \
	| sed -E --expression "$sudo__grace_SED_REGEX"   \
	| sudo__grace_sudoers_timeout_min
}
