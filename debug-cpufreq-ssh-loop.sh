#!/bin/bash
# See http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail

_LOCAL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Get directory of this file

print_usage ()
{
	echo "Usage:" >&2
	echo "  `basename $0` {CPU max frequency: default, stable, unchanged}" >&2
	echo "  {test mode: random, case1} {router hostname}" >&2
	echo "  {optional: router SSH port, default=22} {optional: KDE Connect device name for notifications, default=disabled}" >&2
	echo >&2
	echo "Recommended settings:" >&2
	echo "  Set frequency to 'default' or 'stable', set test mode to 'case1'" >&2
	echo >&2
	echo "NOTE:" >&2
	echo "  It may take up to 8 hours or more for the crash to occur!" >&2
	echo "  Sadly, this is a non-deterministic test." >&2
	echo >&2
	echo "Example:" >&2
	echo "  ./`basename $0` \"default\" \"case1\" \"openwrt\"" >&2
}

EXPECTED_ARGS=3
EXPECTED_ARGS_SSH_PORT=4
EXPECTED_ARGS_KDECONNECT=5
if [ $# -lt $EXPECTED_ARGS ] || [ $# -gt $EXPECTED_ARGS_KDECONNECT ]; then
	echo -e "Not enough arguments given\n" >&2
	print_usage
	exit 1
fi

# Testing configuration
START_FREQ_MODE="$1"
TEST_MODE="$2"

# SSH connection details
ROUTER_HOST="$3"
if [ $# -ge $EXPECTED_ARGS_SSH_PORT ]; then
	ROUTER_PORT="$4"
else
	ROUTER_PORT="22"
fi

# KDE Connect setup
if [ $# -ge $EXPECTED_ARGS_KDECONNECT ]; then
	USE_KDE_CONNECT=true
	KDE_CONNECT_NAME="$5"
else
	USE_KDE_CONNECT=false
	KDE_CONNECT_NAME=""
fi

# Validate settings
case "$START_FREQ_MODE" in
	"default" | "stable" | "unchanged" )
		: # All good!
		;;
	* )
		echo -e "Invalid frequency start option\n" >&2
		print_usage
		exit 1
		;;
esac

case "$TEST_MODE" in
	"random" | "case1" )
		: # All good!
		;;
	* )
		echo -e "Invalid test mode\n" >&2
		print_usage
		exit 1
		;;
esac

if ! [ -n "$ROUTER_HOST" ]; then
	echo -e "Invalid router hostname\n" >&2
	print_usage
	exit 1
fi

# ssh -p "$ROUTER_PORT" "root@$ROUTER_HOST"
#
# Extra options:
#   -t
#     Force a TTY (only needed to send SIGINT/Ctrl-C)
#   -o "ServerAliveInterval 3"
#     Time out after 3 missed pings (default 15 seconds)

kde_connect_msg ()
{
	EXPECTED_ARGS=1
	if [ $# -ne $EXPECTED_ARGS ]; then
		echo "Usage: `basename $0` [kde_connect_msg] {message}" >&2
		return 1
	fi

	local MESSAGE="$1"

	if [[ "$USE_KDE_CONNECT" == "false" ]]; then
		# Don't send if not using KDE Connect
		return 0
	fi

	kdeconnect-cli --name "$KDE_CONNECT_NAME" --ping-msg "$MESSAGE"
	return $?
}

COUNT_SUCCESS=0
COUNT_FAILURE=0
COUNT_TOTAL=0
DESCRIPTION="cpufreq test"
LOG_DIR="$_LOCAL_DIR/test-logs"
RUN_SCRIPT="debug-cpufreq-router.sh"
RUN_SCRIPT_PATH="$_LOCAL_DIR/$RUN_SCRIPT"

if [ ! -f "$RUN_SCRIPT_PATH" ]; then
	echo "[!] Testing script '$RUN_SCRIPT' not found, check if missing?" >&2
	echo "Expected path: $RUN_SCRIPT_PATH" >&2
fi

# Ensure execute permissions
chmod u+x "$RUN_SCRIPT_PATH"

mkdir --parents "$LOG_DIR"
RUN_LOG="$LOG_DIR/debug-cpufreq - clock $START_FREQ_MODE test $TEST_MODE - $(date "+%F %H-%M-%S").log"
STOP_REASON="unknown reason"

# If "true", successful test runs will be treated as a stop
STOP_ON_SUCCESS=true

# Some tools aren't happy with Unicode color emoji
# Store as escape sequences just in case
# Also makes it easier to edit out if you don't want emoji :(
EMJ_CHECK=$'\xe2\x9c\x85'
EMJ_X=$'\xe2\x9d\x8c'
EMJ_FLAG=$'\xf0\x9f\x8f\x81'
EMJ_STOP=$'\xf0\x9f\x9b\x91'

# ---- Test begin ----

echo "Testing router at '$ROUTER_HOST:$ROUTER_PORT', CPU max frequency '$START_FREQ_MODE', test mode '$TEST_MODE'." | tee --append "$RUN_LOG"
if [[ "$USE_KDE_CONNECT" == "true" ]]; then
	echo "Messages will be forwarded to KDE Connect device '$KDE_CONNECT_NAME' if available." | tee --append "$RUN_LOG"
fi


# Copy testing script
echo "$(date -R): Copying '$RUN_SCRIPT' to router to perform testing..." | tee --append "$RUN_LOG"
if ! scp -P "$ROUTER_PORT" "$RUN_SCRIPT_PATH" "root@$ROUTER_HOST:/tmp/$RUN_SCRIPT"; then
	echo "$(date -R): Unable to copy testing script '$RUN_SCRIPT' to router, stopping test" >&2
	exit 1
fi

setup_test_freqs ()
{
	case "$START_FREQ_MODE" in
		"default" | "stable")
			# Set system to known state
			echo "$(date -R): Setting CPU max frequency..." | tee --append "$RUN_LOG"
			ssh -p "$ROUTER_PORT" "root@$ROUTER_HOST" "/tmp/$RUN_SCRIPT" "$START_FREQ_MODE" 2>&1 | tee --append "$RUN_LOG"
			;;
		"unchanged" )
			# Don't change the frequencies at all
			:
			;;
		* )
			echo "Unexpected START_FREQ_MODE '$START_FREQ_MODE'" >&2
			exit 1
			;;
	esac
}
# Set system to known state if enabled
setup_test_freqs

# Test forever!  Or at least a very long time...
while true; do
	if ! ssh -o "ServerAliveInterval 3" -p "$ROUTER_PORT" "root@$ROUTER_HOST" echo "success" >/dev/null; then
		echo "$(date -R): Unable to connect to router, stopping test" 2>&1 | tee --append "$RUN_LOG"
		STOP_REASON="disconnect"
		break
	fi

	echo "$(date -R): Running $DESCRIPTION..." 2>&1 | tee --append "$RUN_LOG"
	# Don't exit on failure
	set +e
	case "$TEST_MODE" in
		"random" )
			# Use tty (-t) to allow sending signals
			# Results in a successful exit on Ctrl-C
			ssh -o "ServerAliveInterval 3" -t -p "$ROUTER_PORT" "root@$ROUTER_HOST" "/tmp/$RUN_SCRIPT" test_cycle_freqs random $TEST_MODE 2>&1 | tee --append "$RUN_LOG"
			;;
		"case1" )
			# Use tty (-t) to allow sending signals
			# Results in a successful exit on Ctrl-C
			ssh -o "ServerAliveInterval 3" -t -p "$ROUTER_PORT" "root@$ROUTER_HOST" "/tmp/$RUN_SCRIPT" test_cycle_freqs random $TEST_MODE 2>&1 | tee --append "$RUN_LOG"
			;;
		* )
			echo "Unexpected TEST_MODE '$TEST_MODE'" >&2
			exit 1
			;;
	esac
	EXIT_STATUS=$?
	# Resume exit on failure
	set -e

	# Determine exit result
	if [ "$EXIT_STATUS" -eq 0 ]; then
		COUNT_SUCCESS="$((COUNT_SUCCESS + 1))"
	elif [ "$EXIT_STATUS" -eq 255 ]; then
		echo "$(date -R): SSH reported failure" 2>&1 | tee --append "$RUN_LOG"
		COUNT_FAILURE="$((COUNT_FAILURE + 1))"
	elif [ "$EXIT_STATUS" -gt 128 ]; then
		echo "$(date -R): Received signal, stopping test" 2>&1 | tee --append "$RUN_LOG"
		STOP_REASON="interrupt"
		break
	else
		COUNT_FAILURE="$((COUNT_FAILURE + 1))"
	fi
	COUNT_TOTAL="$((COUNT_SUCCESS + COUNT_FAILURE))"

	# Show new status
	if [ "$EXIT_STATUS" -eq 0 ]; then
		if [[ "$STOP_ON_SUCCESS" == "true" ]]; then
			STOP_REASON="successful test"
			break
		else
			echo "$EMJ_CHECK $DESCRIPTION succeeded!"$'\n'"[$COUNT_SUCCESS $EMJ_CHECK / $COUNT_FAILURE $EMJ_X of $COUNT_TOTAL $EMJ_FLAG]" 2>&1 | tee --append "$RUN_LOG"
			kde_connect_msg "$EMJ_CHECK $DESCRIPTION succeeded!"$'\n'"[$COUNT_SUCCESS $EMJ_CHECK / $COUNT_FAILURE $EMJ_X of $COUNT_TOTAL $EMJ_FLAG]" || true # Don't exit on failure
		fi
	else
		echo "$EMJ_X $DESCRIPTION failed.  Status: $EXIT_STATUS"$'\n'"[$COUNT_SUCCESS $EMJ_CHECK / $COUNT_FAILURE $EMJ_X of $COUNT_TOTAL $EMJ_FLAG]" 2>&1 | tee --append "$RUN_LOG"
		kde_connect_msg "$EMJ_X $DESCRIPTION failed.  Status: $EXIT_STATUS"$'\n'"[$COUNT_SUCCESS $EMJ_CHECK / $COUNT_FAILURE $EMJ_X of $COUNT_TOTAL $EMJ_FLAG]" || true # Don't exit on failure
	fi

	# Ping local console
	echo -n -e '\a'
done

echo "$EMJ_STOP Stopped $DESCRIPTION due to $STOP_REASON."$'\n'"[$COUNT_SUCCESS $EMJ_CHECK / $COUNT_FAILURE $EMJ_X of $COUNT_TOTAL $EMJ_FLAG]" 2>&1 | tee --append "$RUN_LOG"
kde_connect_msg "$EMJ_STOP Stopped $DESCRIPTION due to $STOP_REASON."$'\n'"[$COUNT_SUCCESS $EMJ_CHECK / $COUNT_FAILURE $EMJ_X of $COUNT_TOTAL $EMJ_FLAG]" || true # Don't exit on failure


# KDE Connect unfortunately does not provide reliable detection of device absence
# Usually it finds out after long enough delay that the message doesn't get sent
#
#if [[ "$USE_KDE_CONNECT" == "true" ]]; then
#	kde_connect_msg "$EMJ_STOP Stopped $DESCRIPTION due to $STOP_REASON."$'\n'"[$COUNT_SUCCESS $EMJ_CHECK / $COUNT_FAILURE $EMJ_X of $COUNT_TOTAL $EMJ_FLAG]" || true # Don't exit on failure
#
#	MESSAGE_FINISHED="$EMJ_STOP Stopped $DESCRIPTION due to $STOP_REASON."$'\n'"[$COUNT_SUCCESS $EMJ_CHECK / $COUNT_FAILURE $EMJ_X of $COUNT_TOTAL $EMJ_FLAG]"
#	if ! kde_connect_msg "$MESSAGE_FINISHED"; then
#		# Retry in case network had gone down
#		echo -n "Retrying sending message via KDE Connect"
#		for ATTEMPT in {1..120}; do
#			echo -n "."
#			if kde_connect_msg "$MESSAGE_FINISHED" 2>/dev/null; then
#				echo
#				echo " sent!"
#				break
#			fi
#			sleep 30
#		done
#	fi
#fi
