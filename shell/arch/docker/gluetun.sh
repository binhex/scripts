#!/bin/bash

# Script to get the incoming port from gluetun and configure a predefined list of applications. This script will block.
#
# In order for the script to work you need the following configured for gluetun
# 1. Ensure VPN provider supports incoming port assignment and that its turned on via xxxxx env var.
# 2. Ensure the applicaiton is using the gluetun container as its network.

# script name and path
readonly ourScriptName="$(basename -- "$0")"
readonly ourScriptversion="1.0.0"

# default values
readonly defaultDebug="no"
readonly defaultControlServerPort="8000"
readonly defaultPollDelay="10"

debug="${defaultDebug}"
control_server_port="${defaultControlServerPort}"
poll_delay="${defaultPollDelay}"

# Read all command line arguments
SCRIPT_ARGS=("$@")

# Initialize array for remaining arguments
remaining_args=()

function incoming_port_watchdog {
	local control_server_url="http://127.0.0.1:${control_server_port}/v1"
	local vpn_current_incoming_port
	local vpn_previous_incoming_port
	local vpn_public_ip
	local vpn_country_ip
	local vpn_city_ip

	while true; do
		# Get the current forwarded port
		vpn_current_incoming_port=$(curl -s "${control_server_url}/openvpn/portforwarded" | jq -r '.port')
		vpn_public_ip=$(curl -s "${control_server_url}/publicip/ip" | jq -r '.public_ip')
		vpn_country_ip=$(curl -s "${control_server_url}/publicip/ip" | jq -r '.country')
		vpn_city_ip=$(curl -s "${control_server_url}/publicip/ip" | jq -r '.city')

		if [[ "${debug}" == "yes" ]] || [[ "${debug}" == "yes" ]]; then
			echo "[DEBUG] Current incoming port for VPN tunnel is '${vpn_current_incoming_port}'"
			echo "[DEBUG] Public IP for VPN tunnel is '${vpn_public_ip}'"
			echo "[DEBUG] Country for VPN tunnel is '${vpn_country_ip}'"
			echo "[DEBUG] City for VPN tunnel is '${vpn_city_ip}'"
		fi

		if [[ "${vpn_current_incoming_port}" != "${vpn_previous_incoming_port}" ]]; then
			if [[ -z "${vpn_previous_incoming_port}" ]]; then
				echo "[INFO] No previous VPN port forward found, assuming first run, configuring application..."
			else
				echo "[INFO] Previous VPN port forward '${vpn_previous_incoming_port}' and current VPN port forward '${vpn_current_incoming_port}' are different, configuring application..."
			fi

			# Kill existing application process if it exists
			if [[ -n "${APPLICATION_PID}" ]] && kill -0 "${APPLICATION_PID}" 2>/dev/null; then
				echo "[INFO] Killing existing application process with PID: ${APPLICATION_PID}"
				kill "${APPLICATION_PID}"
				wait "${APPLICATION_PID}" 2>/dev/null
			fi

			# Start new application process with new port
			configure_incoming_port_for_application "nicotineplus" "${vpn_current_incoming_port}"
			vpn_previous_incoming_port="${vpn_current_incoming_port}"
		else
				if [[ "${debug}" == "yes" ]]; then
					echo "[DEBUG] Previous VPN port forward '${vpn_previous_incoming_port}' and current VPN port forward '${vpn_current_incoming_port}' are the same, nothing to do."
				fi
		fi

		# Sleep for a bit before checking again
		if [[ "${debug}" == "yes" ]]; then
			echo "[DEBUG] sleeping for '${poll_delay}' seconds before next invocation..."
		fi
		sleep "${poll_delay}"
	done
}

function configure_incoming_port_for_application {
	local application_name="$1"
	shift
	local incoming_port="$1"
	shift

	if [[ "${application_name,,}" == 'nicotineplus' ]]; then
		echo "[INFO] Configuring Nicotine+ with VPN incoming port: $incoming_port"
		"${SCRIPT_ARGS[@]}" --port "${incoming_port}" &
	elif [[ "${application_name,,}" == 'qbittorrent' ]]; then
		echo "[INFO] Configuring ${application_name} with VPN incoming port: $incoming_port"
		"${SCRIPT_ARGS[@]}" --port "${incoming_port}" &
	else
		echo "[ERROR] Unknown application name '${application_name}'"
		return 1
	fi
	APPLICATION_PID=$!
	echo "[INFO] Started ${application_name} with PID '${APPLICATION_PID}'"
	echo "${APPLICATION_PID}"
}

function show_help() {
  cat <<ENDHELP
Description:
  This script can either monitor VPN port changes and restart applications, or simply pass through commands.
	${ourScriptName} ${ourScriptversion} - Created by binhex.
Syntax:
  ${0} [options] [command and arguments]
Where:
  -h or --help
  Displays this text.

  -an or --application-name <nicotineplus|qbittorrent>
  Define the application name to configure with the VPN incoming port.
  No default.

  -csp or --control-server-port <port>
  Define the gluetun control server port.
  Defaults to '${control_server_port}'.

  -pd or --poll-delay <seconds>
  Define the polling delay in seconds between port checks.
  Defaults to '${poll_delay}'.

  --debug
  Define whether debug mode is enabled.
  If not set, debug mode is disabled.

Environment Variables:
  CONFIGURE_INCOMING_PORT
  Set to 'yes' to enable VPN port monitoring and application configuration.
  Set to 'no' or leave unset to simply execute the provided command.

Examples:
  Monitor VPN port and configure Nicotine+:
  CONFIGURE_INCOMING_PORT=yes ${0} --application-name nicotineplus /usr/bin/nicotine

  Monitor VPN port with custom settings:
  CONFIGURE_INCOMING_PORT=yes ${0} --control-server-port 9000 --poll-delay 5 /usr/bin/qbittorrent

  Simply execute a command without VPN monitoring:
  ${0} /usr/bin/some-application --some-flag

Notes:
  - When CONFIGURE_INCOMING_PORT=yes, the script monitors gluetun for port changes and restarts the application
  - When CONFIGURE_INCOMING_PORT is not 'yes', the script simply executes the provided command
  - The application must support a --port argument to configure the listening port
ENDHELP
}

while [ "$#" != "0" ]
do
  case "$1"
  in
  -an|--application-name)
    application_name="${2,,}"
    shift
    ;;
  -csp|--control-server-port)
		control_server_port="${2}"
    shift
    ;;
  -pd|--poll-delay)
		poll_delay="${2}"
		shift
		;;
  --debug)
    debug="yes"
    ;;
  -h|--help)
    show_help
    exit 0
    ;;
  *)
    # Save unrecognized arguments for passthrough
    remaining_args+=("$1")
    ;;
  esac
  shift
done

if [[ "${CONFIGURE_INCOMING_PORT,,}" == 'yes' ]]; then
	echo "[INFO] Configuration of VPN incoming port is enabled, starting incoming port watchdog..."
	# Pass remaining arguments to the function
	SCRIPT_ARGS=("${remaining_args[@]}")
	incoming_port_watchdog
else
	echo "[INFO] Configuration of VPN incoming port is disabled, executing provided command..."
	if [[ ${#remaining_args[@]} -gt 0 ]]; then
		echo "[INFO] Executing: ${remaining_args[*]}"
		exec "${remaining_args[@]}"
	else
		echo "[INFO] No command provided to execute"
		exit 0
	fi
fi
