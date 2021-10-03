#!/bin/sh
# See http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail

SERVICE_NAME="cpu_crash_workaround"
SERVICE_START_PRIORITY="98"
SERVICE_STOP_PRIORITY="10"

cpu_crash_workaround_install ()
{
	# See https://openwrt.org/docs/guide-user/services/network_monitoring/vnstat
	echo " * Installing CPU crash workaround service"
	local INIT_SERVICE="/etc/init.d/$SERVICE_NAME"
	local INIT_SERVICE_ENABLED_STOP_LINK="/etc/rc.d/K${SERVICE_STOP_PRIORITY}${SERVICE_NAME}"
	local INIT_SERVICE_ENABLED_START_LINK="/etc/rc.d/S${SERVICE_START_PRIORITY}${SERVICE_NAME}"
	cat << "EOF_cat" > "$INIT_SERVICE"
#!/bin/sh /etc/rc.common

START=SED_SERVICE_START_PRIORITY
STOP=SED_SERVICE_STOP_PRIORITY

LOGGER_TAG="SED_SERVICE_NAME"

CPUFREQ_POLICY_PATH="/sys/devices/system/cpu/cpufreq/policyCPUINDEX"
CPUFREQ_IPQ8065_DEFAULT_MAX_CLOCK="$(cat ${CPUFREQ_POLICY_PATH/CPUINDEX/0}/cpuinfo_max_freq)"
CPUFREQ_IPQ8065_1_4GHZ_MAX_CLOCK="1400000"
CPUFREQ_IPQ8065_1GHZ_MAX_CLOCK="1000000"

is_governor_ondemand() {
	GOVERNOR=$(cat "${CPUFREQ_POLICY_PATH/CPUINDEX/0}/scaling_governor")
	if [ "$GOVERNOR" = "ondemand" ]; then
		return 0
	else
		return 1
	fi
}

start() {
	if ! is_governor_ondemand; then
		logger -t $LOGGER_TAG -p warn "Not adjusting CPU max clock, governor is not set to 'ondemand'"
		exit 0
	fi
	logger -t $LOGGER_TAG -p info "Limiting CPU max clock to 1.0 GHz to workaround CPU crash"
	echo "$CPUFREQ_IPQ8065_1GHZ_MAX_CLOCK" > "${CPUFREQ_POLICY_PATH/CPUINDEX/0}/scaling_max_freq" || return $?
	echo "$CPUFREQ_IPQ8065_1GHZ_MAX_CLOCK" > "${CPUFREQ_POLICY_PATH/CPUINDEX/1}/scaling_max_freq" || return $?
}

stop() {
	if ! is_governor_ondemand; then
		logger -t $LOGGER_TAG -p warn "Not adjusting CPU max clock, governor is not set to 'ondemand'"
		exit 0
	fi
	logger -t $LOGGER_TAG -p info "Undoing workaround for CPU crash by restoring CPU max clock to default"
	echo "$CPUFREQ_IPQ8065_DEFAULT_MAX_CLOCK" > "${CPUFREQ_POLICY_PATH/CPUINDEX/0}/scaling_max_freq" || return $?
	echo "$CPUFREQ_IPQ8065_DEFAULT_MAX_CLOCK" > "${CPUFREQ_POLICY_PATH/CPUINDEX/1}/scaling_max_freq" || return $?
}
EOF_cat
	# Update variables
	sed -i -e "s@SED_SERVICE_NAME@$SERVICE_NAME@" "$INIT_SERVICE"
	sed -i -e "s@SED_SERVICE_START_PRIORITY@$SERVICE_START_PRIORITY@" "$INIT_SERVICE"
	sed -i -e "s@SED_SERVICE_STOP_PRIORITY@$SERVICE_STOP_PRIORITY@" "$INIT_SERVICE"
	echo "   > Enabling service"
	chmod +x "$INIT_SERVICE"
	"$INIT_SERVICE" enable
	echo "   > Starting service"
	"$INIT_SERVICE" start

	local SYSUPGRADE_CONF="/etc/sysupgrade.conf"
	if ! grep -q "$INIT_SERVICE" "$SYSUPGRADE_CONF" ; then
		echo " * Including CPU crash workaround service in backups"
		echo "# cpu-crash-workaround.sh: CPU crash workaround service" >> "$SYSUPGRADE_CONF"
		echo "$INIT_SERVICE" >> "$SYSUPGRADE_CONF"
		echo "$INIT_SERVICE_ENABLED_STOP_LINK" >> "$SYSUPGRADE_CONF"
		echo "$INIT_SERVICE_ENABLED_START_LINK" >> "$SYSUPGRADE_CONF"
	else
		echo " * CPU crash workaround service already in backups"
	fi
}

cpu_crash_workaround_remove ()
{
	# See https://openwrt.org/docs/guide-user/services/network_monitoring/vnstat
	local INIT_SERVICE="/etc/init.d/$SERVICE_NAME"
	local INIT_SERVICE_ENABLED_STOP_LINK="/etc/rc.d/K${SERVICE_STOP_PRIORITY}${SERVICE_NAME}"
	local INIT_SERVICE_ENABLED_START_LINK="/etc/rc.d/S${SERVICE_START_PRIORITY}${SERVICE_NAME}"
	if [ -f "$INIT_SERVICE" ]; then
		echo " * Removing CPU crash workaround service"
		"$INIT_SERVICE" stop
		"$INIT_SERVICE" disable
		rm "$INIT_SERVICE"
	else
		echo " * CPU crash workaround service already removed"
	fi

	local SYSUPGRADE_CONF="/etc/sysupgrade.conf"
	if grep -q "$INIT_SERVICE" "$SYSUPGRADE_CONF" ; then
		echo " * Removing CPU crash workaround service from backups"
		sed -i -e "\\@# cpu-crash-workaround.sh: CPU crash workaround service@d" "$SYSUPGRADE_CONF"
		sed -i -e "\\@$INIT_SERVICE@d" "$SYSUPGRADE_CONF"
		sed -i -e "\\@$INIT_SERVICE_ENABLED_STOP_LINK@d" "$SYSUPGRADE_CONF"
		sed -i -e "\\@$INIT_SERVICE_ENABLED_START_LINK@d" "$SYSUPGRADE_CONF"
	else
		echo " * CPU crash workaround service already removed from backups"
	fi
}

print_usage ()
{
	echo "Usage: `basename $0` {install, remove}" >&2
}

EXPECTED_ARGS=1
if [ $# -lt $EXPECTED_ARGS ]; then
	print_usage
	exit 1
fi

case "$1" in
	"install" )
		cpu_crash_workaround_install || return $?
		;;
	"remove" )
		cpu_crash_workaround_remove || return $?
		;;
	* )
		print_usage
		exit 1
esac
