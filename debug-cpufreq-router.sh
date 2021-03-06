#!/bin/sh
# See http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail

CPUFREQ_POLICY_PATH="/sys/devices/system/cpu/cpufreq/policyCPUINDEX"
CPUFREQ_IPQ8065_DEFAULT_MAX_CLOCK="$(cat ${CPUFREQ_POLICY_PATH/CPUINDEX/0}/cpuinfo_max_freq)"
CPUFREQ_IPQ8065_1_4GHZ_MAX_CLOCK="1400000"
CPUFREQ_IPQ8065_1GHZ_MAX_CLOCK="1000000"

CPUFREQ_DEFAULT_GOVERNOR="ondemand"
CPUFREQ_FORCED_GOVERNOR="performance"

# From 'qcom-ipq8065.dtsi', divided by 1000 for Hz -> KHz (remove 3 zeroes)
# Not sure how to get this at runtime
# If "384000" is disabled by /etc/init.d/cpufreq, it will automatically be skipped
CPUFREQ_OPP_FREQS="384000 600000 800000 1000000 1400000 1725000"
CPUFREQ_OPP_FREQS_COUNT="$(echo $CPUFREQ_OPP_FREQS | wc -w)"

CPU_PRIOR_MAX_CLOCK_0="<unknown>"
CPU_PRIOR_MAX_CLOCK_1="<unknown>"
CPU_TEST_FAILED=false

#Global variables cannot be adjusted inside subshell
#CPU_TEST_FREQS_INDEX_0=0
#CPU_TEST_FREQS_INDEX_1=0
CPU_TEST_FREQS_INDEX_0_FILE=""
CPU_TEST_FREQS_INDEX_1_FILE=""

log_datetime ()
{
	date "+%F %r"
}

microsleep ()
{
	local EXPECTED_ARGS=1
	if [ $# -ne $EXPECTED_ARGS ]; then
		echo "Usage: `basename $0` [microsleep] {time in seconds, fractional time allowed}" >&2
		return 1
	fi

	local SLEEP_TIME="$1"

	# OpenWRT BusyBox doesn't come with "usleep" by default
	# To avoid requiring a custom firmware build, hack it together with Lua
	#
	# See https://stackoverflow.com/questions/1034334/easiest-way-to-make-lua-script-wait-pause-sleep-block-for-a-few-seconds
	lua -e "clock = os.clock
function sleep(n)  -- seconds
   local t0 = clock()
   while clock() - t0 <= n do
   end
end
sleep($SLEEP_TIME)"
}

get_rand_number ()
{
	local EXPECTED_ARGS=1
	if [ $# -ne $EXPECTED_ARGS ]; then
		echo "Usage: `basename $0` [get_rand_number] {upper bound of random numbers}" >&2
		return 1
	fi

	# Add one to get inclusive
	local UPPER_BOUND="$(( $1 + 1))"

	# See https://stackoverflow.com/questions/4678836/how-to-generate-random-numbers-under-openwrt
	echo $(( $(hexdump -n 4 -e '"%u"' </dev/urandom) % $UPPER_BOUND ))
}

cpu_set_governor ()
{
	local EXPECTED_ARGS=2
	if [ $# -ne $EXPECTED_ARGS ]; then
		echo "Usage: `basename $0` [cpu_set_governor] {CPU index, or 'all'} {valid CPU governor mode}" >&2
		return 1
	fi

	local CPU_INDEX="$1"
	local CPU_GOVERNOR="$2"

	if [[ "$CPU_INDEX" == "all" ]]; then
		# Set governor of all CPUs
		echo "$CPU_GOVERNOR" > "${CPUFREQ_POLICY_PATH/CPUINDEX/0}/scaling_governor" || return $?
		echo "$CPU_GOVERNOR" > "${CPUFREQ_POLICY_PATH/CPUINDEX/1}/scaling_governor" || return $?
	else
		# Set governor of indicated CPU
		echo "$CPU_GOVERNOR" > "${CPUFREQ_POLICY_PATH/CPUINDEX/$CPU_INDEX}/scaling_governor" || return $?
	fi
}

cpu_set_max_clock ()
{
	local EXPECTED_ARGS=2
	if [ $# -ne $EXPECTED_ARGS ]; then
		echo "Usage: `basename $0` [cpu_set_max_clock] {CPU index, or 'all'} {maximum clock speed in KHz}" >&2
		return 1
	fi

	local CPU_INDEX="$1"
	local CPU_MAX_CLOCK="$2"

	if [[ "$CPU_INDEX" == "all" ]]; then
		# Set max clock of all CPUs
		echo "$CPU_MAX_CLOCK" > "${CPUFREQ_POLICY_PATH/CPUINDEX/0}/scaling_max_freq" || return $?
		echo "$CPU_MAX_CLOCK" > "${CPUFREQ_POLICY_PATH/CPUINDEX/1}/scaling_max_freq" || return $?
	else
		# Set max clock of indicated CPU
		echo "$CPU_MAX_CLOCK" > "${CPUFREQ_POLICY_PATH/CPUINDEX/$CPU_INDEX}/scaling_max_freq" || return $?
	fi
}

cpu_get_max_allowed_clock ()
{
	local EXPECTED_ARGS=2
	if [ $# -ne $EXPECTED_ARGS ]; then
		echo "Usage: `basename $0` [cpu_get_max_allowed_clock] {CPU index} {mode: current, prior}" >&2
		return 1
	fi

	local CPU_INDEX="$1"
	local FREQ_MODE="$2"

	if [[ "$CPU_INDEX" == "all" ]]; then
		# Get max clock of all CPUs
		local CPU_MAX_CLOCK_0="$(cpu_get_max_allowed_clock 0 $FREQ_MODE)" || return $?
		local CPU_MAX_CLOCK_1="$(cpu_get_max_allowed_clock 1 $FREQ_MODE)" || return $?
		# Make sure they're consistent
		if [[ "$CPU_MAX_CLOCK_0" == "$CPU_MAX_CLOCK_1" ]]; then
			echo "$CPU_MAX_CLOCK_0"
		else
			echo "`basename $0` [cpu_get_max_allowed_clock] Could not get max allowed clock speed for CPUs, mismatch (CPU 0=\"$CPU_MAX_CLOCK_0\", CPU 1=\"$CPU_MAX_CLOCK_1\")" >&2
			return 1
		fi
	else
		# Get max allowed clock of indicated CPU
		case "$FREQ_MODE" in
			"prior" )
				case "$CPU_INDEX" in
					"0" )
						echo "$CPU_PRIOR_MAX_CLOCK_0"
						;;
					"1" )
						echo "$CPU_PRIOR_MAX_CLOCK_1"
						;;
					* )
						echo "`basename $0` [cpu_get_max_allowed_clock] Unknown CPU index '$CPU_INDEX'" >&2
						return 1
						;;
				esac
				;;
			"current" )
				cat "${CPUFREQ_POLICY_PATH/CPUINDEX/$CPU_INDEX}/scaling_max_freq" || return $?
				;;
			* )
				echo "Usage: `basename $0` [cpu_get_max_allowed_clock] {CPU index} {mode: current, prior}" >&2
				return 1
				;;
		esac
	fi
}

cpu_get_min_allowed_clock ()
{
	local EXPECTED_ARGS=1
	if [ $# -ne $EXPECTED_ARGS ]; then
		echo "Usage: `basename $0` [cpu_get_min_allowed_clock] {CPU index}" >&2
		return 1
	fi

	local CPU_INDEX="$1"

	if [[ "$CPU_INDEX" == "all" ]]; then
		# Get min clock of all CPUs
		local CPU_MIN_CLOCK_0="$(cpu_get_min_allowed_clock 0)" || return $?
		local CPU_MIN_CLOCK_1="$(cpu_get_min_allowed_clock 1)" || return $?
		# Make sure they're consistent
		if [[ "$CPU_MIN_CLOCK_0" == "$CPU_MIN_CLOCK_1" ]]; then
			echo "$CPU_MIN_CLOCK_0"
		else
			echo "`basename $0` [cpu_get_min_allowed_clock] Could not get min allowed clock speed for CPUs, mismatch (CPU 0=\"$CPU_MIN_CLOCK_0\", CPU 1=\"$CPU_MIN_CLOCK_1\")" >&2
			return 1
		fi
	else
		# Get min allowed clock of indicated CPU
		cat "${CPUFREQ_POLICY_PATH/CPUINDEX/$CPU_INDEX}/scaling_min_freq" || return $?
	fi
}

cpu_test_freqs_set_index ()
{
	local EXPECTED_ARGS=2
	if [ $# -ne $EXPECTED_ARGS ]; then
		echo "Usage: `basename $0` [cpu_test_freqs_set_index] {CPU index, or 'all'} {frequency index}" >&2
		return 1
	fi

	if [ ! -f "$CPU_TEST_FREQS_INDEX_0_FILE" ] || [ ! -f "$CPU_TEST_FREQS_INDEX_1_FILE" ]; then
		echo "[cpu_test_freqs_set_index] Global variables CPU_TEST_FREQS_INDEX_0_FILE or CPU_TEST_FREQS_INDEX_1_FILE were not created!" >&2
		return 1
	fi

	local CPU_INDEX="$1"
	local CPU_FREQ_INDEX="$2"

	# Set index of indicated CPU
	case "$CPU_INDEX" in
		"all" )
			#CPU_TEST_FREQS_INDEX_0="$CPU_FREQ_INDEX"
			#CPU_TEST_FREQS_INDEX_1="$CPU_FREQ_INDEX"
			echo "$CPU_FREQ_INDEX" > "$CPU_TEST_FREQS_INDEX_0_FILE"
			echo "$CPU_FREQ_INDEX" > "$CPU_TEST_FREQS_INDEX_1_FILE"
			;;
		"0" )
			#CPU_TEST_FREQS_INDEX_0="$CPU_FREQ_INDEX"
			echo "$CPU_FREQ_INDEX" > "$CPU_TEST_FREQS_INDEX_0_FILE"
			;;
		"1" )
			#CPU_TEST_FREQS_INDEX_1="$CPU_FREQ_INDEX"
			echo "$CPU_FREQ_INDEX" > "$CPU_TEST_FREQS_INDEX_1_FILE"
			;;
		* )
			echo "`basename $0` [cpu_test_freqs_set_index] Unknown CPU index '$CPU_INDEX'" >&2
			return 1
			;;
	esac
}

cpu_test_freqs_get_index ()
{
	local EXPECTED_ARGS=1
	if [ $# -ne $EXPECTED_ARGS ]; then
		echo "Usage: `basename $0` [cpu_test_freqs_get_index] {CPU index}" >&2
		return 1
	fi

	if [ ! -f "$CPU_TEST_FREQS_INDEX_0_FILE" ] || [ ! -f "$CPU_TEST_FREQS_INDEX_1_FILE" ]; then
		echo "[cpu_test_freqs_set_index] Global variables CPU_TEST_FREQS_INDEX_0_FILE or CPU_TEST_FREQS_INDEX_1_FILE were not created!" >&2
		return 1
	fi

	local CPU_INDEX="$1"

	# Get index of indicated CPU
	case "$CPU_INDEX" in
		"all" )
			# Make sure they're consistent
			if [[ "$CPU_TEST_FREQS_INDEX_0" == "$CPU_TEST_FREQS_INDEX_1" ]]; then
				#echo "$CPU_TEST_FREQS_INDEX_0"
				cat "$CPU_TEST_FREQS_INDEX_0_FILE"
			else
				echo "`basename $0` [cpu_test_freqs_get_index] Could not get CPU test index for CPUs, mismatch (CPU 0=\"$CPU_TEST_FREQS_INDEX_0\", CPU 1=\"$CPU_TEST_FREQS_INDEX_1\")" >&2
				return 1
			fi
			;;
		"0" )
			#echo "$CPU_TEST_FREQS_INDEX_0"
			cat "$CPU_TEST_FREQS_INDEX_0_FILE"
			;;
		"1" )
			#echo "$CPU_TEST_FREQS_INDEX_1"
			cat "$CPU_TEST_FREQS_INDEX_1_FILE"
			;;
		* )
			echo "`basename $0` [cpu_test_freqs_get_index] Unknown CPU index '$CPU_INDEX'" >&2
			return 1
			;;
	esac
}

cpu_get_valid_freq ()
{
	local EXPECTED_ARGS=2
	if [ $# -ne $EXPECTED_ARGS ]; then
		echo "Usage: `basename $0` [cpu_get_valid_freq] {CPU index, or 'all'} {frequency mode: random, case1, case2, ramp1}" >&2
		return 1
	fi

	local CPU_INDEX="$1"
	local FREQ_MODE="$2"

	case "$FREQ_MODE" in
		"random" )
			# Pick random frequency from list, discarding picks that are too high/too low
			local MIN_FREQ="$(cpu_get_min_allowed_clock $CPU_INDEX)" || return $?
			local MAX_FREQ="$(cpu_get_max_allowed_clock $CPU_INDEX prior)" || return $?
			local CURRENT_FREQ="$(cpu_get_max_allowed_clock $CPU_INDEX current)" || return $?
			# Set initial non-random value to out of range
			local RAND_FREQ="$((MAX_FREQ + 1))"
			while [ $RAND_FREQ -gt $MAX_FREQ ] \
				|| [ $RAND_FREQ -lt $MIN_FREQ ] \
				|| [ $RAND_FREQ -eq $CURRENT_FREQ ]; do
				local RAND_NUM="$(get_rand_number $CPUFREQ_OPP_FREQS_COUNT)"
				RAND_FREQ="$(echo $CPUFREQ_OPP_FREQS | cut -d ' ' -f $RAND_NUM)"
			done
			echo "$RAND_FREQ"
			;;
		"case1" )
			# Emulate first observed crash with toggling to/from a low-ish and maximum frequency
			# See log files
			#   * "2021-08-19 02-14-09-openwrt-21.02-cpufreq-dtsivolt-cache-dynamic-debug-on.tar.xz"
			#   * "2021-08-21 01-59-40-openwrt-master-fix-ipq8065-dts-opp-order-dynamic-debug-on.tar.xz"
			local CURRENT_FREQ="$(cpu_get_max_allowed_clock $CPU_INDEX current)" || return $?
			if [[ "$CURRENT_FREQ" == "800000" ]]; then
				# Print out prior (before test) maximum allowed clock
				cpu_get_max_allowed_clock $CPU_INDEX prior || return $?
			else
				echo "800000"
			fi
			;;
		"case2" )
			# Toggle between lowest allowed (600 MHz, see /etc/init.d/cpufreq) and highest
			# This offers the maximum possible jump, especially when disabling 1.4 GHz and 1.75 GHz
			local CURRENT_FREQ="$(cpu_get_max_allowed_clock $CPU_INDEX current)" || return $?
			if [[ "$CURRENT_FREQ" == "600000" ]]; then
				# Print out prior (before test) maximum allowed clock
				cpu_get_max_allowed_clock $CPU_INDEX prior || return $?
			else
				echo "600000"
			fi
			;;
		"ramp1" )
			# Ramp up/down from minimum to maximum, stopping at intermediate frequencies
			# This ensures CPU jumps the least through the problematic range (1.4 & 1.75 GHz)
			local FREQ_INDEX_NEXT="$(cpu_test_freqs_get_index $CPU_INDEX)" || return $?

			# Double frequency count to use the same index for decreasing, too
			local FREQ_INDEX_BOUNDS=$CPUFREQ_OPP_FREQS_COUNT
			FREQ_INDEX_BOUNDS=$(((FREQ_INDEX_BOUNDS - 1)*2))

			# Pick transition frequency from list, discarding too high/too low/repeat
			local MIN_FREQ="$(cpu_get_min_allowed_clock $CPU_INDEX)" || return $?
			local MAX_FREQ="$(cpu_get_max_allowed_clock $CPU_INDEX prior)" || return $?
			local CURRENT_FREQ="$(cpu_get_max_allowed_clock $CPU_INDEX current)" || return $?
			# Set initial value to out of range
			local TRANS_FREQ="$((MAX_FREQ + 1))"
			while [ $TRANS_FREQ -gt $MAX_FREQ ] \
				|| [ $TRANS_FREQ -lt $MIN_FREQ ] \
				|| [ $TRANS_FREQ -eq $CURRENT_FREQ ]; do
				if [ $FREQ_INDEX_NEXT -ge $FREQ_INDEX_BOUNDS ]; then
					# Wrap around to start
					FREQ_INDEX_NEXT=0
				fi

				local REAL_INDEX=$FREQ_INDEX_NEXT
				if [ $FREQ_INDEX_NEXT -ge $CPUFREQ_OPP_FREQS_COUNT ]; then
					# > Decreasing
					REAL_INDEX=$((FREQ_INDEX_BOUNDS-FREQ_INDEX_NEXT))
				fi
				# else - increasing, use value directly

				# Shift from 0-index to 1-index
				REAL_INDEX=$((REAL_INDEX+1))
				TRANS_FREQ="$(echo $CPUFREQ_OPP_FREQS | cut -d ' ' -f $REAL_INDEX)"
				#echo "FREQ_INDEX_NEXT = $FREQ_INDEX_NEXT, REAL_INDEX = $REAL_INDEX, TRANS_FREQ = $TRANS_FREQ" >&2

				# Increment
				FREQ_INDEX_NEXT=$((FREQ_INDEX_NEXT+1))
			done

			# Save index for next time
			cpu_test_freqs_set_index "$CPU_INDEX" "$FREQ_INDEX_NEXT" || return $?

			echo "$TRANS_FREQ"
			;;
		* )
			echo "Usage: `basename $0` [cpu_get_valid_freq] {CPU index, or 'all'} {frequency mode: random, case1, case2, ramp1}" >&2
			return 1
			;;
	esac
}

print_usage_test_cycle_freqs ()
{
	echo "Usage: `basename $0` test_cycle_freqs {CPU index, cycling one while keeping other at max, or 'random', 'all'} {frequency mode: random, case1, case2, ramp1}" >&2
}

cpu_test_cycle_freqs ()
{
	local EXPECTED_ARGS=2
	if [ $# -ne $EXPECTED_ARGS ]; then
		print_usage_test_cycle_freqs
		echo "(from `basename $0` [cpu_test_cycle_freqs])" >&2
		return 1
	fi

	local CPU_INDEX="$1"
	local FREQ_MODE="$2"

	# Validate max allowed clock frequency if adjusting all CPUs
	if [[ "$CPU_INDEX" == "all" ]]; then
		if ! cpu_get_max_allowed_clock "all" "prior" >/dev/null; then
			echo "[!] Please set both CPUs 'scaling_max_freq' to the same value." >&2
			echo >&2
			echo "    For example, reset to default via" >&2
			echo "    ./`basename $0` default" >&2
			echo >&2
			echo "    Alternatively, specify CPU '0', '1', or 'random' instead of 'all'" >&2
			return 1
		fi
	fi

	local CPU_MAX_CLOCK_0="$(cpu_get_max_allowed_clock 0 prior)" || return $?
	local CPU_MAX_CLOCK_1="$(cpu_get_max_allowed_clock 1 prior)" || return $?

	# Ensure defaults are reset if interrupted
	trap cleanup_test SIGINT SIGTERM

	# Create global variables
	# Workaround for Bash subshell not propagating to parent shell
	# See https://stackoverflow.com/questions/21632126/how-to-store-the-output-of-command-in-a-variable-without-creating-a-subshell-ba
	CPU_TEST_FREQS_INDEX_0_FILE="$(mktemp)"
	CPU_TEST_FREQS_INDEX_1_FILE="$(mktemp)"
	# Initialize
	cpu_test_freqs_set_index "all" 0

	# Record start time
	local TEST_START_SECS="$(date '+%s')"
	# Record last statistic time
	local TEST_LAST_PRINTED_SECS=0

	# Set all CPUs to manual control
	echo "$(log_datetime) Setting CPU governor to '$CPUFREQ_FORCED_GOVERNOR'..."
	cpu_set_governor "all" "$CPUFREQ_FORCED_GOVERNOR" || return $?
	# Set all CPUs to maximum allowed speed
	echo "$(log_datetime) Setting CPU #0 to $CPU_MAX_CLOCK_0 KHz..."
	cpu_set_max_clock 0 "$CPU_MAX_CLOCK_0" || return $?
	echo "$(log_datetime) Setting CPU #1 to $CPU_MAX_CLOCK_1 KHz..."
	cpu_set_max_clock 1 "$CPU_MAX_CLOCK_1" || return $?

	local CURRENT_CPU_INDEX="$CPU_INDEX"

	while true; do
		local TEST_DURATION="$(( $(date '+%s') - $TEST_START_SECS ))"
		if [ "$TEST_DURATION" -lt 0 ]; then
			echo "`basename $0` [cpu_test_cycle_freqs] Time should not travel backwards!" >&2
			echo "Start time in seconds since epoch: $TEST_START_SECS" >&2
			echo "Calculated duration of test: $TEST_DURATION" >&2
			echo "'date' program probably segfaulted?" >&2
			break
		fi
		if [[ "$CPU_INDEX" == "random" ]]; then
			CURRENT_CPU_INDEX="$(get_rand_number 1)"
		fi
		local NEXT_FREQ="$(cpu_get_valid_freq $CURRENT_CPU_INDEX $FREQ_MODE)" || break

		#if [ "$TEST_LAST_PRINTED_SECS" -lt "$TEST_DURATION" ]; then
		#	TEST_LAST_PRINTED_SECS="$TEST_DURATION"
		#	echo
		#	echo "$(log_datetime) [${TEST_DURATION}s]"
		#fi
		if [[ "$CURRENT_CPU_INDEX" == "all" ]]; then
			# Verbose:
			echo "$(log_datetime) [${TEST_DURATION}s] Setting all CPUs to $NEXT_FREQ KHz..."
			## Brief:
			#echo -n "#A={$NEXT_FREQ}KHz "
		else
			# Verbose:
			echo "$(log_datetime) [${TEST_DURATION}s] Setting CPU #$CURRENT_CPU_INDEX to $NEXT_FREQ KHz..."
			## Brief:
			#echo -n "#$CURRENT_CPU_INDEX={$NEXT_FREQ}KHz "
		fi
		cpu_set_max_clock "$CURRENT_CPU_INDEX" "$NEXT_FREQ" || break

		# Turns out the sleep isn't needed
		#microsleep 0.1
	done

	echo "[!] Something went wrong during the test, cleaning up..." >&2
	CPU_TEST_FAILED=true

	# Only reached if error occurs, normal cleanup is handled via signal "trap" above
	cleanup_test

	return 1
}

cpu_test_fake_load ()
{
	# Ensure defaults are reset if interrupted
	trap cleanup_test SIGINT SIGTERM

	# Record start time
	local TEST_START_SECS="$(date '+%s')"
	# Record last statistic time
	local TEST_LAST_PRINTED_SECS=0

	while true; do
		local TEST_DURATION="$(( $(date '+%s') - $TEST_START_SECS ))"
		if [ "$TEST_DURATION" -lt 0 ]; then
			echo "`basename $0` [cpu_test_fake_load] Time should not travel backwards!" >&2
			echo "Start time in seconds since epoch: $TEST_START_SECS" >&2
			echo "Calculated duration of test: $TEST_DURATION" >&2
			echo "'date' program probably segfaulted?" >&2
			break
		fi

		local LOAD_ACTIVE_DURATION="$(get_rand_number 1).$(get_rand_number 9)"
		local LOAD_IDLE_DURATION="$(get_rand_number 1).$(get_rand_number 9)"

		#if [ "$TEST_LAST_PRINTED_SECS" -lt "$TEST_DURATION" ]; then
		#	TEST_LAST_PRINTED_SECS="$TEST_DURATION"
		#	echo
		#	echo "$(log_datetime) [${TEST_DURATION}s]"
		#fi
		# Verbose:
		echo "$(log_datetime) [${TEST_DURATION}s] Running ${LOAD_ACTIVE_DURATION}s active, ${LOAD_IDLE_DURATION}s idle..."
		## Brief:
		#echo -n "#A={$NEXT_FREQ}KHz "

		# Fake load
		yes >/dev/null &
		PID=$!
		microsleep "$LOAD_ACTIVE_DURATION"
		kill "$PID"
		microsleep "$LOAD_IDLE_DURATION"
	done

	echo "[!] Something went wrong during the test, cleaning up..." >&2
	CPU_TEST_FAILED=true

	# Only reached if error occurs, normal cleanup is handled via signal "trap" above
	cleanup_test

	return 1
}

cleanup_test ()
{
	# Set all CPUs to default control
	echo
	echo "$(log_datetime) Setting CPU governor to '$CPUFREQ_DEFAULT_GOVERNOR'..."
	cpu_set_governor "all" "$CPUFREQ_DEFAULT_GOVERNOR"

	# Reset all CPUs maximum allowed speed to before test
	local CPU_MAX_CLOCK_0="$(cpu_get_max_allowed_clock 0 prior)"
	local CPU_MAX_CLOCK_1="$(cpu_get_max_allowed_clock 1 prior)"
	echo "$(log_datetime) Resetting CPUs to prior max allowed clock (CPU 0 = $CPU_MAX_CLOCK_0 KHz, CPU 1 = $CPU_MAX_CLOCK_1 KHz)..."
	cpu_set_max_clock 0 "$CPU_MAX_CLOCK_0"
	cpu_set_max_clock 1 "$CPU_MAX_CLOCK_1"

	# Remove global variable files
	if [ -n "$CPU_TEST_FREQS_INDEX_0_FILE" ] && [ -f "$CPU_TEST_FREQS_INDEX_0_FILE" ]; then
		rm "$CPU_TEST_FREQS_INDEX_0_FILE"
	fi
	if [ -n "$CPU_TEST_FREQS_INDEX_1_FILE" ] && [ -f "$CPU_TEST_FREQS_INDEX_1_FILE" ]; then
		rm "$CPU_TEST_FREQS_INDEX_1_FILE"
	fi

	echo "$(log_datetime) Cleaned up!"

	# Defaults reset, remove handler
	trap - SIGINT SIGTERM

	# Exit
	if [[ "$CPU_TEST_FAILED" == "true" ]]; then
		exit 1
	else
		exit 0
	fi
}

reapply_openwrt_cpufreq_service ()
{
	# Restore OpenWRT startup customization
	if [ -x "/etc/init.d/cpufreq" ] && /etc/init.d/cpufreq enabled; then
		echo "$(log_datetime) Re-applying OpenWRT CPU customization..."
		/etc/init.d/cpufreq restart || return $?
	fi
}

print_usage ()
{
	echo "Usage: `basename $0` {reset, default, 1.4ghz, 1ghz, pin_default, test_cycle_freqs, test_fake_load}" >&2
	echo "Recommended settings - first set to 'default' or '1.4ghz' frequency, then run 'test_cycle_freqs random case1'" >&2
	echo "Alternatively, first set to '1ghz' frequency, then run 'test_cycle_freqs random case2'" >&2
}

EXPECTED_ARGS=1
if [ $# -lt $EXPECTED_ARGS ]; then
	print_usage
	exit 1
fi

# Store for later cleanup
CPU_PRIOR_MAX_CLOCK_0="$(cpu_get_max_allowed_clock 0 current)" || exit $?
CPU_PRIOR_MAX_CLOCK_1="$(cpu_get_max_allowed_clock 1 current)" || exit $?

# Option
case "$1" in
	"reset" )
		# Re-apply default CPU settings with OpenWRT service
		"$0" "default"
		# Restore CPU crash workaround if applied
		if [ -x "/etc/init.d/cpu_crash_workaround" ] && /etc/init.d/cpu_crash_workaround enabled; then
			echo "$(log_datetime) Re-applying CPU crash workaround..."
			/etc/init.d/cpu_crash_workaround restart || return $?
		fi
		echo "$(log_datetime) Default CPU frequency policy restored!"
		;;
	"default" )
		echo "$(log_datetime) Setting CPU governor to '$CPUFREQ_DEFAULT_GOVERNOR', all CPUs max allowed clock to $CPUFREQ_IPQ8065_DEFAULT_MAX_CLOCK KHz"
		cpu_set_governor "all" "$CPUFREQ_DEFAULT_GOVERNOR" || return $?
		cpu_set_max_clock "all" "$CPUFREQ_IPQ8065_DEFAULT_MAX_CLOCK" || return $?
		reapply_openwrt_cpufreq_service
		;;
	"1.4ghz" )
		echo "$(log_datetime) Setting CPU governor to '$CPUFREQ_DEFAULT_GOVERNOR', all CPUs max allowed clock to $CPUFREQ_IPQ8065_1_4GHZ_MAX_CLOCK KHz"
		cpu_set_governor "all" "$CPUFREQ_DEFAULT_GOVERNOR" || return $?
		cpu_set_max_clock "all" "$CPUFREQ_IPQ8065_1_4GHZ_MAX_CLOCK" || return $?
		reapply_openwrt_cpufreq_service
		;;
	"1ghz" )
		echo "$(log_datetime) Setting CPU governor to '$CPUFREQ_DEFAULT_GOVERNOR', all CPUs max allowed clock to $CPUFREQ_IPQ8065_1GHZ_MAX_CLOCK KHz"
		cpu_set_governor "all" "$CPUFREQ_DEFAULT_GOVERNOR" || return $?
		cpu_set_max_clock "all" "$CPUFREQ_IPQ8065_1GHZ_MAX_CLOCK" || return $?
		reapply_openwrt_cpufreq_service
		;;
	"pin_default" )
		echo "$(log_datetime) Setting CPU governor to '$CPUFREQ_FORCED_GOVERNOR', forcing all CPUs clock to $CPUFREQ_IPQ8065_DEFAULT_MAX_CLOCK KHz"
		cpu_set_governor "all" "$CPUFREQ_FORCED_GOVERNOR" || return $?
		cpu_set_max_clock "all" "$CPUFREQ_IPQ8065_DEFAULT_MAX_CLOCK" || return $?
		;;
	"test_cycle_freqs" )
		EXPECTED_ARGS=3
		if [ $# -ne $EXPECTED_ARGS ]; then
			print_usage_test_cycle_freqs
			exit 1
		fi
		CPU_INDEX="$2"
		FREQ_MODE="$3"
		cpu_test_cycle_freqs "$CPU_INDEX" "$FREQ_MODE" || return $?
		;;
	"test_fake_load" )
		cpu_test_fake_load || return $?
		;;
	* )
		print_usage
		exit 1
esac
