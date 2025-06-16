#!/bin/bash

# Script to get the incoming port from gluetun and configure a predefined list of applications. This script will block.
#
# In order for the script to work you need the following configured for gluetun:
# 1. Ensure VPN provider supports incoming port assignment and that its enabled in the gluetun container configuration.
# 2. Ensure the application is using the gluetun container as its network.

# script name and path
readonly ourScriptName="$(basename -- "$0")"
readonly ourScriptversion="1.0.0"

# default values
readonly defaultQbittorrentConfigFilepath="/config/qBittorrent/config/qBittorrent.conf"
readonly defaultQbittorrentWebuiPort="8080"
readonly defaultQbittorrentBindAdapter="yes"
readonly defaultGluetunControlServerPort="8000"
readonly defaultConfigureIncomingPort="yes"
readonly defaultPollDelay="10"
readonly defaultDebug="no"

# read env var values if not empty, else use defaults
QBITTORRENT_CONFIG_FILEPATH="${QBITTORRENT_CONFIG_FILEPATH:-${defaultQbittorrentConfigFilepath}}"
QBITTORRENT_WEBUI_PORT="${QBITTORRENT_WEBUI_PORT:-${defaultQbittorrentWebuiPort}}"
QBITTORRENT_BIND_ADAPTER="${QBITTORRENT_BIND_ADAPTER:-${defaultQbittorrentBindAdapter}}"
GLUETUN_CONTROL_SERVER_PORT="${GLUETUN_CONTROL_SERVER_PORT:-${defaultGluetunControlServerPort}}"
CONFIGURE_INCOMING_PORT="${CONFIGURE_INCOMING_PORT:-${defaultConfigureIncomingPort}}"
POLL_DELAY="${POLL_DELAY:-${defaultPollDelay}}"
DEBUG="${DEBUG:-${defaultDebug}}"

# Read all command line arguments
SCRIPT_ARGS=("$@")

# Initialize array for remaining arguments
REMAINING_ARGS=()

function start_process() {
	local arguments="${1}"
	shift

	echo "[INFO] Starting '${APPLICATION_NAME}' with incoming port '${INCOMING_PORT}'"
	# shellcheck disable=SC2086
	"${SCRIPT_ARGS[@]}" ${arguments}
	APPLICATION_PID=$!
	echo "[INFO] Started '${APPLICATION_NAME}' with PID '${APPLICATION_PID}'"
}

function kill_process() {
	# Kill existing application process if it exists
	if [[ -n "${APPLICATION_PID}" ]] && kill -0 "${APPLICATION_PID}" 2>/dev/null; then
		echo "[INFO] Killing existing application process with PID '${APPLICATION_PID}'"
		kill "${APPLICATION_PID}"
		wait "${APPLICATION_PID}" 2>/dev/null
		echo "[INFO] Application process with PID '${APPLICATION_PID}' has been killed"
	fi
}

function get_vpn_adapter_name() {

	if [[ -n "${VPN_INTERFACE}" ]]; then
		VPN_ADAPTER_NAME="${VPN_INTERFACE}"
		if [[ "${DEBUG}" == "yes" ]]; then
			echo "[DEBUG] Using VPN interface from environment variable: '${VPN_ADAPTER_NAME}'"
		fi
	else
		if [[ "${DEBUG}" == "yes" ]]; then
			echo "[DEBUG] No VPN interface specified in environment variable, attempting to determine automatically..."
		fi
	fi
	VPN_ADAPTER_NAME="$(ifconfig | grep 'mtu' | grep -P 'tun.*|tap.*|wg.*' | cut -d ':' -f1)"
	if [[ -z "${VPN_ADAPTER_NAME}" ]]; then
		echo "[ERROR] Unable to determine VPN adapter name, please check your gluetun configuration and ensure the VPN is connected."
		exit 1
	elif [[ "${DEBUG}" == "yes" ]]; then
		echo "[DEBUG] Detected VPN adapter name is '${VPN_ADAPTER_NAME}'"
	fi
}

function incoming_port_watchdog {
	local control_server_url="http://127.0.0.1:${GLUETUN_CONTROL_SERVER_PORT}/v1"
	local vpn_previous_incoming_port
	local vpn_public_ip
	local vpn_country_ip
	local vpn_city_ip

	if [[ "${CONFIGURE_INCOMING_PORT}" != 'yes' ]]; then
		echo "[INFO] Configuration of VPN incoming port is disabled."
		if [[ ${#REMAINING_ARGS[@]} -gt 0 ]]; then
			echo "[INFO] Executing: ${REMAINING_ARGS[*]}"
			exec "${REMAINING_ARGS[@]}"
		else
			echo "[INFO] No command provided to execute, exiting script..."
			exit 0
		fi
	fi

	if ! curl -s "${control_server_url}" >/dev/null 2>&1; then
		echo "[ERROR] Unable to connect to gluetun Control Server at '${control_server_url}', are you running this container in the gluetun containers network?, exiting..."
		exit 1
	fi

	if [[ "${DEBUG}" == "yes" ]]; then
		echo "[DEBUG] Successfully connected to gluetun Control Server at '${control_server_url}'"
	fi

	# run any initial setup of the application prior to port configuration
	application_initial_setup

	while true; do

		INCOMING_PORT=$(curl -s "${control_server_url}/openvpn/portforwarded" | jq -r '.port')
		vpn_public_ip=$(curl -s "${control_server_url}/publicip/ip" | jq -r '.public_ip')
		vpn_country_ip=$(curl -s "${control_server_url}/publicip/ip" | jq -r '.country')
		vpn_city_ip=$(curl -s "${control_server_url}/publicip/ip" | jq -r '.city')

		if [[ "${DEBUG}" == "yes" ]]; then
			echo "[DEBUG] Current incoming port for VPN tunnel is '${INCOMING_PORT}'"
			echo "[DEBUG] Public IP for VPN tunnel is '${vpn_public_ip}'"
			echo "[DEBUG] Country for VPN tunnel is '${vpn_country_ip}'"
			echo "[DEBUG] City for VPN tunnel is '${vpn_city_ip}'"
		fi

		if [[ "${INCOMING_PORT}" != "${vpn_previous_incoming_port}" ]]; then
			if [[ -z "${vpn_previous_incoming_port}" ]]; then
				echo "[INFO] No previous VPN port forward found, assuming first run, configuring application..."
			else
				echo "[INFO] Previous VPN port forward '${vpn_previous_incoming_port}' and current VPN port forward '${INCOMING_PORT}' are different, configuring application..."
			fi

			application_configure_incoming_port
			vpn_previous_incoming_port="${INCOMING_PORT}"
		else
				if [[ "${DEBUG}" == "yes" ]]; then
					echo "[DEBUG] Previous VPN port forward '${vpn_previous_incoming_port}' and current VPN port forward '${INCOMING_PORT}' are the same, nothing to do."
				fi
		fi

		# Sleep for a bit before checking again
		if [[ "${DEBUG}" == "yes" ]]; then
			echo "[DEBUG] sleeping for '${POLL_DELAY}' seconds before next invocation..."
		fi
		sleep "${POLL_DELAY}"
	done
}

function nicotineplus_configure_incoming_port() {
	kill_process
	echo "[INFO] Configuring '${APPLICATION_NAME}' with VPN incoming port: ${INCOMING_PORT}"
	start_process "--port ${INCOMING_PORT} &"
}

function qbittorrent_configure_bind_adapter() {

	if [[ "${QBITTORRENT_BIND_ADAPTER,,}" == 'yes' ]]; then
		echo "[INFO] Binding '${APPLICATION_NAME}' to gluetun network interface"

			# get vpn adapter name (wg0/tun0/tap0)
			get_vpn_adapter_name

			# set network interface binding to vpn virtual adapter (wg0/tun0/tap0) for qbittorrent on startup
			sed -i -e "s~^Connection\\\\Interface\=.*~Connection\\\\Interface\=${VPN_ADAPTER_NAME}~g" "${QBITTORRENT_CONFIG_FILEPATH}"
			sed -i -e "s~^Connection\\\\InterfaceName\=.*~Connection\\\\InterfaceName\=${VPN_ADAPTER_NAME}~g" "${QBITTORRENT_CONFIG_FILEPATH}"
			sed -i -e "s~^Session\\\\Interface\=.*~Session\\\\Interface\=${VPN_ADAPTER_NAME}~g" "${QBITTORRENT_CONFIG_FILEPATH}"
			sed -i -e "s~^Session\\\\InterfaceName\=.*~Session\\\\InterfaceName\=${VPN_ADAPTER_NAME}~g" "${QBITTORRENT_CONFIG_FILEPATH}"

			# forcibly set allow anonymous access from localhost to api (used to change incoming port)
			sed -i -e 's~^WebUI\\LocalHostAuth=.*~WebUI\\LocalHostAuth=false~g' "${QBITTORRENT_CONFIG_FILEPATH}"
	else
		echo "[INFO] Not binding '${APPLICATION_NAME}' to gluetun network interface"
	fi
}

function qbittorrent_configure_incoming_port() {

	local web_protocol

	echo "[INFO] Configuring '${APPLICATION_NAME}' with VPN incoming port '${INCOMING_PORT}'"

		# identify protocol, used by curl to connect to api
		if grep -q 'WebUI\\HTTPS\\Enabled=true' "${QBITTORRENT_CONFIG_FILEPATH}"; then
			web_protocol="https"
		else
			web_protocol="http"
		fi

		# note -k flag required to support insecure connection (self signed certs) when https used
		curl -k -i -X POST -d "json={\"random_port\": false}" "${web_protocol}://localhost:${QBITTORRENT_WEBUI_PORT}/api/v2/app/setPreferences" &> /dev/null
		curl -k -i -X POST -d "json={\"listen_port\": ${INCOMING_PORT}}" "${web_protocol}://localhost:${QBITTORRENT_WEBUI_PORT}/api/v2/app/setPreferences" &> /dev/null

}

function qbittorrent_start() {
	echo "[info] Removing session lock file (if it exists)..."
	rm -f /config/qBittorrent/data/BT_backup/session.lock
	start_process
}

function application_initial_setup() {

	if [[ "${APPLICATION_NAME,,}" == 'qbittorrent' ]]; then
		qbittorrent_configure_bind_adapter
		qbittorrent_start
	else
		echo "[ERROR] Unknown application name '${APPLICATION_NAME}', exiting script..."
		exit 1
	fi
}

function application_configure_incoming_port() {

	if [[ "${APPLICATION_NAME,,}" == 'nicotineplus' ]]; then
		nicotineplus_configure_incoming_port
	elif [[ "${APPLICATION_NAME,,}" == 'qbittorrent' ]]; then
		qbittorrent_configure_incoming_port
	else
		echo "[ERROR] Unknown application name '${APPLICATION_NAME}', exiting script..."
		exit 1
	fi
}

function show_help() {
  cat <<ENDHELP
Description:
  A simple bash script to monitor the VPN incoming port from gluetun and configure a predefined list of applications.
	${ourScriptName} ${ourScriptversion} - Created by binhex.

Syntax:
  ./${ourScriptName} [options] [command and arguments]

Where:
  -an or --application-name <name>
		Define the name of the application to configure for incoming port.
		No default.

  -qcf or --qbittorrent-config-filepath <path>
		Define the file path to the qBittorrent configuration file.
		Defaults to '${QBITTORRENT_CONFIG_FILEPATH}'.

  -qwp or --qbittorrent-webui-port <port>
		Define the web UI port for qBittorrent.
		Defaults to '${QBITTORRENT_WEBUI_PORT}'.

  -qba or --qbittorrent-bind-adapter <yes|no>
		Define whether to bind qBittorrent to the gluetun network interface.
		Defaults to '${QBITTORRENT_BIND_ADAPTER}'.

  -gcsp or --gluetun-control-server-port <port>
		Define the Gluetun Control Server port.
		Defaults to '${GLUETUN_CONTROL_SERVER_PORT}'.

  -cip or --configure-incoming-port <yes|no>
		Define whether to enable VPN port monitoring and application configuration.
		Defaults to '${CONFIGURE_INCOMING_PORT}'.

  -pd or --poll-delay <seconds>
		Define the polling delay in seconds between incoming port checks.
		Defaults to '${POLL_DELAY}'.

  --debug
		Define whether debug mode is enabled.
		Defautlts to not set.

  -h or --help
		Displays this text.
Notes:
  - Any additional arguments provided after the options will be passed to the specified application.

Environment Variables:
	APPLICATION_NAME
		Set the name of the application to configure with the VPN incoming port.
  QBITTORRENT_CONFIG_FILEPATH
		Set the file path to the qBittorrent configuration file.
  QBITTORRENT_WEBUI_PORT
		Set the web UI port for qBittorrent.
	QBITTORRENT_BIND_ADAPTER
		Set to the name of the application to configure with the VPN incoming port.
	GLUETUN_CONTROL_SERVER_PORT
		Set the port for the Gluetun Control Server.
	CONFIGURE_INCOMING_PORT
		Set to 'yes' to enable VPN port monitoring and application configuration.
	POLL_DELAY
		Set the polling delay in seconds between incoming port checks.
	DEBUG
		Set to 'yes' to enable debug mode.
Notes:
  - Command line arguments take precedence over environment variables.

Examples:
  Monitor VPN port and configure Nicotine+:
  ./${ourScriptName} /usr/bin/nicotine

  Monitor VPN port with custom settings:
  ./${ourScriptName} --gluetun-control-server-port 9000 --poll-delay 5 /usr/bin/qbittorrent

  Simply execute a command without VPN monitoring:
  ./${ourScriptName} /usr/bin/some-application --some-flag

	Manually executing the script for debug:
	CONFIGURE_INCOMING_PORT=yes APPLICATION_NAME=nicotineplus ./${ourScriptName} --debug /usr/bin/nicotine

ENDHELP
}

while [ "$#" != "0" ]
do
  case "$1"
  in
	-an|--application-name)
		APPLICATION_NAME="${2}"
    shift
    ;;
  -qcf|--qbittorrent-config-filepath)
		QBITTORRENT_CONFIG_FILEPATH="${2}"
    shift
    ;;
  -qwp|--qbittorrent-webui-port)
		QBITTORRENT_WEBUI_PORT="${2}"
    shift
    ;;
  -qba|--qbittorrent-bind-adapter)
		QBITTORRENT_BIND_ADAPTER="${2}"
    shift
    ;;
  -gcsp|--gluetun-control-server-port)
		GLUETUN_CONTROL_SERVER_PORT="${2}"
    shift
    ;;
  -cipd|--configure-incoming-port)
		CONFIGURE_INCOMING_PORT="${2}"
		shift
		;;
  -pd|--poll-delay)
		POLL_DELAY="${2}"
		shift
		;;
  --debug)
    DEBUG="yes"
    ;;
  -h|--help)
    show_help
    exit 0
    ;;
  *)
    # Save unrecognized arguments for passthrough
    REMAINING_ARGS+=("$1")
    ;;
  esac
  shift
done

if [[ -z "${APPLICATION_NAME}" ]]; then
	echo "[INFO] No application name specified via argument '-an|--application-name' or environment variable 'APPLICATION_NAME', showing help..."
	show_help
fi

echo "[INFO] Configuration of VPN incoming port is enabled, starting incoming port watchdog..."
# Pass remaining arguments to the function
SCRIPT_ARGS=("${REMAINING_ARGS[@]}")
incoming_port_watchdog
