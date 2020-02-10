#!/bin/bash
config_executeable(){
	local -r myRoot="$1"
	# include components required to create this executable
	local mod
	for mod in $( "$myRoot/sourcer/sourcer.sh" "$myRoot"); do
		source "$mod"
	done
}

test_sudo__grace_sudoers_timeout_min(){
	assert_true '[ -z "$(echo | sudo__grace_sudoers_timeout_min)" ]'
	assert_true '[ -z "$(echo "10_" | sudo__grace_sudoers_timeout_min)" ]'
	assert_true '[ 600 == $(echo 10 | sudo__grace_sudoers_timeout_min) ]'
	assert_true '[ -600 == $(echo -10 | sudo__grace_sudoers_timeout_min) ]'
	assert_true '[ 600 == $(echo +10 | sudo__grace_sudoers_timeout_min) ]'
	assert_true '[ -z "$(echo --10 | sudo__grace_sudoers_timeout_min)" ]'
	assert_true '[ 150 == $(echo 2.5 | sudo__grace_sudoers_timeout_min) ]'
	assert_true '[ -60 == $(echo -1 | sudo__grace_sudoers_timeout_min) ]'
	assert_true '[ 1200 == $( test_sudo__grace_sudoers_timeout_min_20 | sudo__grace_sudoers_timeout_min) ]'

}

test_sudo__grace_sudoers_timeout_min_zero(){
	echo -1
	echo 0
}

test_sudo__grace_sudoers_timeout_min_20(){
	echo 0
	echo -1
	echo 20
}

test_grace_period_system_get(){
	assert_true '[ -z "$( sudo__grace_period_system_get "$PWD/file/GracePeriodSystem.Empty")" ]'
  assert_true '[ 600 == $( sudo__grace_period_system_get "$PWD/file/GracePeriodSystem.10min") ]'
  assert_true '[ 635 == $( sudo__grace_period_system_get "$PWD/file/GracePeriodSystem.10.599min") ]'
  assert_true '[ -60 == $( sudo__grace_period_system_get "$PWD/file/GracePeriodSystem.TerminalSession") ]'
}

test_sudo__grace_period_override_get(){
	assert_true '[ -z "$( sudo__grace_period_override_get ./file/sudoers.d.excluded)" ]'
	assert_true '[ -z "$( sudo__grace_period_override_get ./file/sudoers.d.empty)" ]'
	assert_true '[ -60 == $( sudo__grace_period_override_get ./file/sudoers.d.terminal) ]'
}

test_sudo__grace_override_dir_get(){
	assert_true 'sudo__grace_override_dir_get /dev/null'
	assert_true 'sudo__grace_override_dir_get /notexist/notexist/notexist'
	assert_true '[ -z "$(sudo__grace_override_dir_get /dev/null)" ]'
	assert_true '[ "/SudoersDir" == "$(sudo__grace_override_dir_get ./file/sudoers.d.Sudoers/SudoersFile)" ]'
}

test_sudo_grace_period_get()(
	assert_false 'sudo__grace_period_get'
	declare -g sudo__grace_SUDOERS_SETTINGS=./file/etc/sudoers
	local -i gpRtn
	# grace period not specified in any file :: should return the the well known system default
	sudo__grace_period_get 'gpRtn' 2>/dev/null
	assert_true "[ $? ]"
	assert_true '[ $sudo__grace_SUDOERS_GRACE_PERIOD_SYSTEM_DEFAULT_SEC == $gpRtn ]'
	declare -g sudo__grace_SUDOERS_SETTINGS=./file/etc/sudoers.5Min
	sudo__grace_period_get 'gpRtn'
	assert_true "[ $? ]"
	assert_true '[ 300 == $gpRtn ]'
	# Check the system's sudoers settings to verify permission esclation required to 
	# read these files.
	declare -g sudo__grace_SUDOERS_SETTINGS="/etc/sudoers"
	assert_true "sudo__grace_period_get 'gpRtn'"
	declare -g sudo__grace_SUDOERS_SETTINGS="./file/etc/ShouldNotExist"
	assert_false "sudo__grace_period_get 'gpRtn'" 
	assert_return_code_set
)

test_graceperiod_verify(){

	local -i gpRtn
	sudo__grace_period_get 'gpRtn'
	assert_true "[ $? ]"
	# can't verify grace period if its infinite - also potential security risk
	# abort to warn user
	assert_true '[ $gpRtn -gt -1 ]'
	assert_true 'sudo_elevate'
	# grace period disabled, so elongate should fail
	[ $gpRtn == 0 ] && assert_false 'sudo__elongate'
	# grace period enabled, pause test so elongate should fail
	# add 1 second to ensure resolution
	[ $gpRtn -gt 0 ] && test_pause $((gpRtn + 1)) && assert_false 'sudo__elongate'
}

test_graceperiod_reset(){
	
	local -i  gpRtn
	sudo__grace_period_get 'gpRtn'
	assert_true "[ $? ]"
	#  grace period is longer than potential timer resolution concerns
	local -ri gpTestTrigSec=$sudo__GRACE_TRIGGER_HEARTBEAT_SEC
	assert_true '[ $gpTestTrigSec -gt 1 ]'
	# grace period has to be a little more than twice the test trigger gap so
	# second grace period test occcurs after exhaustion of firt grace period
	# in order to verify that the sudo_elevate command and sudo__elongate commands
	# actually reset the sudo timestamp.
	assert_true '[ $((2*gpRtn + 2)) -gt $gpTestTrigSec ]'
	assert_true 'sudo_elevate'
	# sudo grace period already ticking hopefully its resolution is in seconds or better.
	# if so, this elevate will validate resetting grace period $gpTestTrigSec seconds before
	# the current grace period ends.  Relies on execution of sleep and sudo_elevate
	# add no more than $gpTestTrigSec-1 seconds to the timed grace period.
  test_pause $((gpRtn-gpTestTrigSec))
	assert_true 'sudo__elongate'
	# since grace period is specified in minutes and fractions of minutes 
	# therefore its resolution should be at least to the second.  Ensure sleep
	# executes at least after initial sudo_elevate has expired
  # and before immediately previous sudo_elongate's grace period has expired.
  test_pause $((gpRtn-gpTestTrigSec))
	assert_true 'sudo__elongate'
}

test_sudo_elevate_periodic_timer(){
	sudo_elevate_periodic_timer
	assert_true "[ $? == 0 ]"
	local -i gpSec
	sudo__grace_period_get 'gpSec'
	assert_true "[ $? ]"
	local -r gpSec
	assert_true '[ $gpSec -gt 0 ]'
	local -ri expiredGracePeriod=gpSec+2
  test_pause $expiredGracePeriod
	assert_true 'sudo__elongate'
  test_pause $expiredGracePeriod
	assert_true 'sudo__elongate'
  test_pause $expiredGracePeriod
	assert_true 'sudo__elongate'
}

test_pause(){
	local -ri pauseIntervalSec=$1

	local -ri duration=$(date +%s)+pauseIntervalSec
	local -r pauseEnd=$(date '+%T %d.%b.%Y' --date="@$duration")
	cat <<TEST_PAUSE_MESSAGE
Info: Testing grace period duration. Function: '${FUNCNAME[1]}' Line: ${BASH_LINENO[0]}.
  +   Process asleep for: $pauseIntervalSec seconds. Will restart at ~: $pauseEnd.
TEST_PAUSE_MESSAGE

	sleep ${pauseIntervalSec}s
	return 0
}

main(){
	config_executeable "$(dirname "${BASH_SOURCE[0]}")"
	assert_bool_detailed
	test_sudo__grace_sudoers_timeout_min
	test_grace_period_system_get
	test_sudo__grace_period_override_get
	test_sudo__grace_override_dir_get
	assert_return_code_child_failure_relay test_sudo_grace_period_get
#	test_graceperiod_verify
#	test_graceperiod_reset
	test_sudo_elevate_periodic_timer
	assert_return_code_set
}
main

