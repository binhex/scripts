#!/bin/bash

# Script to get the incoming port from gluetun and configure a predefined list of applications. This script will block.
#
# In order for the script to work you need the following configured for gluetun:
# 1. Ensure VPN provider supports incoming port assignment and that its enabled in the gluetun container configuration.
# 2. Ensure the application running this script is sharing the gluetun container's network.

# script name and path
readonly ourScriptName="$(basename -- "$0")"
readonly ourScriptVersion="v1.0.0"

# default values
readonly defaultImageBuildFilepath="/etc/image-build-info"
readonly defaultDelugeWebConfigFilepath="/config/web.conf"
readonly defaultQbittorrentConfigFilepath="/config/qBittorrent/config/qBittorrent.conf"
readonly defaultNicotineplusConfigFilepath="/home/nobody/.config/nicotine/config"
readonly defaultGluetunControlServerPort="8000"
readonly defaultGluetunIncomingPort="no"
readonly defaultPollDelay="60"
readonly defaultDebug="no"

# read env var values if not empty, else use defaults
DELUGE_WEB_CONFIG_FILEPATH="${DELUGE_WEB_CONFIG_FILEPATH:-${defaultDelugeWebConfigFilepath}}"
QBITTORRENT_CONFIG_FILEPATH="${QBITTORRENT_CONFIG_FILEPATH:-${defaultQbittorrentConfigFilepath}}"
NICOTINEPLUS_CONFIG_FILEPATH="${NICOTINEPLUS_CONFIG_FILEPATH:-${defaultNicotineplusConfigFilepath}}"
GLUETUN_CONTROL_SERVER_PORT="${GLUETUN_CONTROL_SERVER_PORT:-${defaultGluetunControlServerPort}}"
GLUETUN_INCOMING_PORT="${GLUETUN_INCOMING_PORT:-${defaultGluetunIncomingPort}}"
POLL_DELAY="${POLL_DELAY:-${defaultPollDelay}}"
DEBUG="${DEBUG:-${defaultDebug}}"

# source in image build info, includes tag name and app name
if [[ -f "${defaultImageBuildFilepath}" ]]; then
  echo "[INFO] Sourcing image build info from '${defaultImageBuildFilepath}'"
  source "${defaultImageBuildFilepath}"
  # note that this will set env var APPNAME from source file, but we want APP_NAME for readability in this script
  APP_NAME="${APPNAME}"
else
  echo "[WARN] Unable to find '${defaultImageBuildFilepath}', no default 'APP_NAME' will be set"
fi

# utility functions
####

function start_process_background() {

  echo "[INFO] Starting single process: ${APP_PARAMETERS[*]}"
  nohup "${APP_PARAMETERS[@]}" &
  APPLICATION_PID=$!

  if [[ "${DEBUG}" == "yes" ]]; then
    echo "[DEBUG] Started '${APP_NAME}' with main PID '${APPLICATION_PID}' (all processes running in background)"
  fi

}

function check_process() {

  if [[ -z "${APPLICATION_PID}" ]]; then
    echo "[WARN] No APPLICATION_PID set, cannot verify if application is running"
    return 1
  fi

  if kill -0 "${APPLICATION_PID}" 2>/dev/null; then
    if [[ "${DEBUG}" == "yes" ]]; then
      echo "[DEBUG] Application with PID '${APPLICATION_PID}' is running"
    fi
    return 0
  else
    echo "[WARN] Application with PID '${APPLICATION_PID}' is not running"
    return 1
  fi

}

function kill_process() {

  if [[ -n "${APPLICATION_PID}" ]] && kill -0 "${APPLICATION_PID}" 2>/dev/null; then
    echo "[INFO] Killing ${APP_NAME} process with PID '${APPLICATION_PID}'"
    kill "${APPLICATION_PID}"
    wait "${APPLICATION_PID}" 2>/dev/null
    echo "[INFO] ${APP_NAME} process with PID '${APPLICATION_PID}' has been killed"
  else
    echo "[INFO] No PID found for ${APP_NAME}, ignoring kill"
  fi

}

function wait_for_port_to_be_listening() {

  local port="${1}"
  shift
  local timeout="${1:-30}"  # Default timeout of 30 seconds
  shift

  local elapsed=0
  local sleep_interval=1

  echo "[INFO] Waiting for port ${port} to be listening..."

  while ! nc -z localhost "${port}" && [[ ${elapsed} -lt ${timeout} ]]; do
    echo "[DEBUG] Port ${port} not yet listening, waiting..."
    sleep "${sleep_interval}"
    elapsed=$((elapsed + sleep_interval))
  done

  if nc -z localhost "${port}"; then
    echo "[INFO] Port ${port} is now listening"
    return 0
  else
    echo "[ERROR] Timeout reached after ${timeout} seconds, port ${port} is still not listening"
    return 1
  fi

}

function get_incoming_port() {

  local control_server_url="http://127.0.0.1:${GLUETUN_CONTROL_SERVER_PORT}/v1"
  local vpn_public_ip
  local vpn_country_ip
  local vpn_city_ip

  local auth
  if [[ -n "${GLUETUN_CONTROL_SERVER_USERNAME}" ]]; then
    auth="-u ${GLUETUN_CONTROL_SERVER_USERNAME}:${GLUETUN_CONTROL_SERVER_PASSWORD}"
  else
    auth=""
  fi

  # Get port forward information from gluetun Control Server
  portforward_response=$(curl_with_retry "${control_server_url}/portforward" 10 1 -s ${auth})

  if [[ "${portforward_response}" == "Unauthorized" || -z "${portforward_response}" ]]; then
    portforward_response=$(curl_with_retry "${control_server_url}/openvpn/portforwarded" 10 1 -s ${auth})
  fi

  if [[ -z "${portforward_response}" ]]; then
    echo "[WARN] Unable to retrieve port forwarded information from gluetun Control Server"
    INCOMING_PORT=""
  else
    # parse results
    INCOMING_PORT="$(echo "${portforward_response}" | jq -r '.port')"
    if [[ "${DEBUG}" == "yes" ]]; then
      echo "[DEBUG] Current incoming port for VPN tunnel is '${INCOMING_PORT}'"
    fi
  fi

  # Get public ip and location information from gluetun Control Server
  public_ip=$(curl_with_retry "${control_server_url}/publicip/ip" 10 1 -s ${auth})

  if [[ -z "${public_ip}" ]]; then
    echo "[WARN] Unable to retrieve public IP information from gluetun Control Server"
  else
    vpn_public_ip="$(echo "${public_ip}" | jq -r '.public_ip')"
    vpn_country_ip="$(echo "${public_ip}" | jq -r '.country')"
    vpn_city_ip="$(echo "${public_ip}" | jq -r '.city')"
    if [[ "${DEBUG}" == "yes" ]]; then
      echo "[DEBUG] Public IP for VPN tunnel is '${vpn_public_ip}'"
      echo "[DEBUG] Country for VPN tunnel is '${vpn_country_ip}'"
      echo "[DEBUG] City for VPN tunnel is '${vpn_city_ip}'"
    fi
  fi

}

function external_verify_incoming_port() {

  local result

  if [[ -z "${INCOMING_PORT}" ]]; then
    return 1
  fi

  result="$(curl_with_retry "https://ifconfig.co/port/${INCOMING_PORT}" 10 1 -s | jq -r '.reachable')"

  if [[ "${result}" == "true" ]]; then
    echo "[INFO] External verification: Incoming port '${INCOMING_PORT}' is reachable."
    return 0
  else
    echo "[WARN] External verification: Incoming port '${INCOMING_PORT}' is NOT reachable."
    return 1
  fi

}

function main {

  echo "[INFO] Running ${ourScriptName} ${ourScriptVersion} - created by binhex."

	# source in curl_with_retry function
	source utils.sh

  # calling functions to generate required globals
  get_incoming_port

  # run any initial pre-start configuration of the application and then start the application
  application_start

  while true; do

    # calling functions to generate required globals
    get_incoming_port

    if [[ "${INCOMING_PORT}" != "${PREVIOUS_INCOMING_PORT}" ]] || ! application_verify_incoming_port || ! external_verify_incoming_port; then

      if [[ -z "${INCOMING_PORT}" ]]; then
        echo "[WARN] Incoming port is not set, this may be due to the VPN not being connected or the gluetun Control Server not being available, checking again in ${POLL_DELAY} seconds..."
        sleep "${POLL_DELAY}"
        continue
      fi

      if [[ "${DEBUG}" == 'yes' ]]; then
        if [[ -z "${PREVIOUS_INCOMING_PORT}" ]]; then
          echo "[DEBUG] No previous VPN port forward found, assuming first run, configuring application..."
        else
          echo "[DEBUG] Previous VPN port forward '${PREVIOUS_INCOMING_PORT}' and current VPN port forward '${INCOMING_PORT}' are different, configuring application..."
        fi
      fi

      # ensure process with PID is running
      if ! check_process; then
        continue
      fi

      # configure applications incoming port
      application_configure_incoming_port

      # set previous incoming port to current
      PREVIOUS_INCOMING_PORT="${INCOMING_PORT}"
    else
      echo "[INFO] Previous VPN port forward '${PREVIOUS_INCOMING_PORT}' and current VPN port forward '${INCOMING_PORT}' are the same"
    fi

    echo "[INFO] Sleeping for ${POLL_DELAY} seconds before re-checking port assignment..."
    sleep "${POLL_DELAY}"
  done

}

function application_start() {

  if [[ "${APP_NAME}" == 'qbittorrent' ]]; then
    qbittorrent_edit_config
    qbittorrent_start
    wait_for_port_to_be_listening "${WEBUI_PORT}"
  elif [[ "${APP_NAME}" == 'deluge' ]]; then
    deluge_start
    wait_for_port_to_be_listening "${WEBUI_PORT}"
  elif [[ "${APP_NAME}" == 'nicotineplus' ]]; then
    nicotine_edit_parameters
    nicotine_start
  elif [[ "${APP_NAME}" == 'slskd' ]]; then
    slskd_edit_parameters
    slskd_start
  else
    echo "[WARN] Application name '${APP_NAME}' unknown, executing remaining arguments '${APP_PARAMETERS[*]}'..."
    exec "${APP_PARAMETERS[@]}"
  fi

}

function application_configure_incoming_port() {

  if [[ "${APP_NAME}" == 'qbittorrent' ]]; then
    wait_for_port_to_be_listening "${WEBUI_PORT}"
    qbittorrent_api_config
  elif [[ "${APP_NAME}" == 'deluge' ]]; then
    wait_for_port_to_be_listening "${WEBUI_PORT}"
    deluge_api_config
  elif [[ "${APP_NAME}" == 'nicotineplus' ]]; then
    nicotine_gluetun_incoming_port
  elif [[ "${APP_NAME}" == 'slskd' ]]; then
    slskd_gluetun_incoming_port
  fi

}

function application_verify_incoming_port() {

  if [[ "${APP_NAME}" == 'qbittorrent' ]]; then
    if ! qbittorrent_verify_incoming_port; then
      return 1
    fi
  elif [[ "${APP_NAME}" == 'nicotineplus' ]]; then
    if ! nicotine_verify_incoming_port; then
      return 1
    fi
  elif [[ "${APP_NAME}" == 'deluge' ]]; then
    if ! deluge_verify_incoming_port; then
      return 1
    fi
  elif [[ "${APP_NAME}" == 'slskd' ]]; then
    if ! slskd_verify_incoming_port; then
      return 1
    fi
  fi
  return 0

}

# shared functions
####

function edit_app_parameters() {

  local parameter_name="${1}"

  echo "[INFO] Configuring '${APP_NAME}' app parameters with VPN incoming port '${INCOMING_PORT}'"

  if [[ -z "${INCOMING_PORT}" ]]; then
    return 1
  fi

  # Create a new array to hold modified parameters
  local new_parameters=()
  local i=0
  local port_found=false

  # Loop through APP_PARAMETERS array
  while [[ $i -lt ${#APP_PARAMETERS[@]} ]]; do
    if [[ "${APP_PARAMETERS[$i]}" == "${parameter_name}" ]]; then
      # Found the port parameter, replace the next value with INCOMING_PORT
      new_parameters+=("${parameter_name}")
      new_parameters+=("${INCOMING_PORT}")
      port_found=true
      # Skip the old port value
      i=$((i + 2))
    else
      # Copy parameter as-is
      new_parameters+=("${APP_PARAMETERS[$i]}")
      i=$((i + 1))
    fi
  done

  # If parameter wasn't found, add it
  if [[ "${port_found}" == "false" ]]; then
    echo "[INFO] ${parameter_name} not found in parameters, adding it with port '${INCOMING_PORT}'"
    new_parameters+=("${parameter_name}" "${INCOMING_PORT}")
  fi

  # Replace the original array
  APP_PARAMETERS=("${new_parameters[@]}")

  if [[ "${DEBUG}" == "yes" ]]; then
    echo "[DEBUG] Modified APP_PARAMETERS: ${APP_PARAMETERS[*]}"
  fi

}

function verify_app_parameters() {

  local parameter_name="${1}"

  echo "[INFO] Verifying '${APP_NAME}' incoming port matches VPN port '${INCOMING_PORT}'"

  if [[ -z "${INCOMING_PORT}" ]]; then
    return 1
  fi

  # Check if parameter exists in APP_PARAMETERS with correct value
  local i=0
  local current_port=""

  while [[ $i -lt ${#APP_PARAMETERS[@]} ]]; do
    if [[ "${APP_PARAMETERS[$i]}" == "${parameter_name}" && $((i + 1)) -lt ${#APP_PARAMETERS[@]} ]]; then
      current_port="${APP_PARAMETERS[$((i + 1))]}"
      break
    fi
    i=$((i + 1))
  done

  if [[ "${DEBUG}" == "yes" ]]; then
    echo "[DEBUG] Current ${APP_NAME} listen port parameter: '${current_port}', Expected: '${INCOMING_PORT}'"
  fi

  if [[ -z "${current_port}" ]]; then
    echo "[WARN] Unable to find ${parameter_name} parameter in ${APP_NAME} configuration"
    return 1
  fi

  if [[ "${current_port}" == "${INCOMING_PORT}" ]]; then
    echo "[INFO] ${APP_NAME} incoming port '${current_port}' matches VPN port '${INCOMING_PORT}'"
    return 0
  else
    echo "[WARN] ${APP_NAME} incoming port '${current_port}' does not match VPN port '${INCOMING_PORT}'"
    return 1
  fi

}

# deluge functions
####

function deluge_api_config() {

  echo "[INFO] Configuring '${APP_NAME}' for VPN..."

  /usr/bin/deluge-console -c /config "config --set random_port false" 2>/dev/null
  /usr/bin/deluge-console -c /config "config --set listen_ports (${INCOMING_PORT},${INCOMING_PORT})" 2>/dev/null
  /usr/bin/deluge-console -c /config "config --set listen_interface ${VPN_IP_ADDRESS}" 2>/dev/null
  /usr/bin/deluge-console -c /config "config --set outgoing_interface ${VPN_IP_ADDRESS}" 2>/dev/null

}

function deluge_start() {

  echo "[INFO] Starting '${APP_NAME}' with VPN incoming port '${INCOMING_PORT}'..."
  start_process_background

}

function deluge_verify_incoming_port() {

  local web_protocol
  local current_port

  echo "[INFO] Verifying '${APP_NAME}' incoming port matches VPN port '${INCOMING_PORT}'"

  # identify protocol, used by curl to connect to api
  if grep -q '"https": true,' "${DELUGE_WEB_CONFIG_FILEPATH}"; then
      web_protocol="https"
  else
      web_protocol="http"
  fi

  # Get current port from Deluge console
  current_port=$(/usr/bin/deluge-console -c /config "config listen_ports" 2>/dev/null | grep -P -o '\d+(?=\)$)')

  if [[ "${DEBUG}" == "yes" ]]; then
      echo "[DEBUG] Current ${APP_NAME} listen port: '${current_port}', Expected: '${INCOMING_PORT}'"
  fi

  # Check if the port was retrieved successfully
  if [[ "${current_port}" == "null" || -z "${current_port}" ]]; then
      echo "[WARN] Unable to retrieve current port from ${APP_NAME} API"
      return 1
  fi

  if [[ "${current_port}" == "${INCOMING_PORT}" ]]; then
      echo "[INFO] ${APP_NAME} incoming port '${current_port}' matches VPN port '${INCOMING_PORT}'"
      return 0
  else
      echo "[WARN] ${APP_NAME} incoming port '${current_port}' does not match VPN port '${INCOMING_PORT}'"
      return 1
  fi

}

# qBittorrent functions
####

function qbittorrent_start() {

  echo "[INFO] Starting '${APP_NAME}' with VPN incoming port '${INCOMING_PORT}'..."
  start_process_background

}

function qbittorrent_edit_config() {

  if [[ "${DEBUG}" == "yes" ]]; then
    echo "[DEBUG] Setting bypass authentication for localhost, required to configure ${APP_NAME} incoming port via API: ${QBITTORRENT_CONFIG_FILEPATH}"
  fi

  if ! grep -q 'WebUI\\LocalHostAuth=false' "${QBITTORRENT_CONFIG_FILEPATH}"; then
    sed -i 's~^WebUI\\LocalHostAuth.*~WebUI\\LocalHostAuth=false~' "${QBITTORRENT_CONFIG_FILEPATH}"
  fi

}

function qbittorrent_api_config() {

  # identify protocol, used by curl to connect to api
  if grep -q 'WebUI\\HTTPS\\Enabled=true' "${QBITTORRENT_CONFIG_FILEPATH}"; then
    web_protocol="https"
  else
    web_protocol="http"
  fi

  # Set network interface binding via API
  local interface_json="{
    \"listen_port\": \"${INCOMING_PORT}\",
    \"web_ui_upnp\": false,
    \"upnp\": false,
    \"random_port\": false,
    \"current_network_interface\": \"${VPN_ADAPTER_NAME}\",
    \"current_interface_name\": \"${VPN_ADAPTER_NAME}\",
    \"bypass_local_auth\": true
  }"

  if [[ "${DEBUG}" == "yes" ]]; then
    echo "[DEBUG] Setting network interface binding: ${interface_json}"
  fi

  curl_with_retry "${web_protocol}://localhost:${WEBUI_PORT}/api/v2/app/setPreferences" 3 2 -k -s -X POST -d "json=${interface_json}" >/dev/null

}

function qbittorrent_verify_incoming_port() {

  local web_protocol
  local current_port

  echo "[INFO] Verifying '${APP_NAME}' incoming port matches VPN port '${INCOMING_PORT}'"

  if [[ -z "${INCOMING_PORT}" ]]; then
    return 1
  fi

  # identify protocol, used by curl to connect to api
  if grep -q 'WebUI\\HTTPS\\Enabled=true' "${QBITTORRENT_CONFIG_FILEPATH}"; then
      web_protocol="https"
  else
      web_protocol="http"
  fi

  # Get current preferences from qBittorrent API using curl_with_retry
  preferences_response=$(curl_with_retry "${web_protocol}://localhost:${WEBUI_PORT}/api/v2/app/preferences" 10 1 -k -s)
  current_port=$(echo "${preferences_response}" | jq -r '.listen_port')

  if [[ "${DEBUG}" == "yes" ]]; then
      echo "[DEBUG] Current ${APP_NAME} listen port: '${current_port}', Expected: '${INCOMING_PORT}'"
  fi

  # Check if the port was retrieved successfully
  if [[ "${current_port}" == "null" || -z "${current_port}" ]]; then
      echo "[WARN] Unable to retrieve current port from ${APP_NAME} API"
      return 1
  fi

  if [[ "${current_port}" == "${INCOMING_PORT}" ]]; then
      echo "[INFO] ${APP_NAME} incoming port '${current_port}' matches VPN port '${INCOMING_PORT}'"
      return 0
  else
      echo "[WARN] ${APP_NAME} incoming port '${current_port}' does not match VPN port '${INCOMING_PORT}'"
      return 1
  fi

}

# nicotineplus functions
####

function nicotine_gluetun_incoming_port() {

  # if previous incoming port is not set then this is the initial run, nicotine will have been started with the default port, so no need to kill, edit and start
  if [[ -z "${PREVIOUS_INCOMING_PORT}" ]]; then
    return 0
  fi

  echo "[INFO] Killing '${APP_NAME}' process as we cannot reconfigure incoming port while it is running..."
  kill_process
  nicotine_edit_parameters
  nicotine_start

}

function nicotine_start() {

  echo "[INFO] Starting '${APP_NAME}' with VPN incoming port '${INCOMING_PORT}'..."
  start_process_background

}

function nicotine_edit_parameters() {

  edit_app_parameters "--port"

}

function nicotine_verify_incoming_port() {

  verify_app_parameters "--port"

}

# slskd functions
####

function slskd_gluetun_incoming_port() {

  # if previous incoming port is not set then this is the initial run, slskd will have been started with the default port, so no need to kill, edit and start
  if [[ -z "${PREVIOUS_INCOMING_PORT}" ]]; then
    return 0
  fi

  echo "[INFO] Killing '${APP_NAME}' process as we cannot reconfigure incoming port while it is running..."
  kill_process
  slskd_edit_parameters
  slskd_start

}

function slskd_start() {

  echo "[INFO] Starting '${APP_NAME}' with VPN incoming port '${INCOMING_PORT}'..."
  start_process_background

}

function slskd_edit_parameters() {

  edit_app_parameters "--slsk-listen-port"

}

function slskd_verify_incoming_port() {

  verify_app_parameters "--slsk-listen-port"

}

function show_help() {
  cat <<ENDHELP
Description:
  A simple bash script to monitor the VPN incoming port from gluetun and configure a predefined list of applications.
  ${ourScriptName} ${ourScriptVersion} - Created by binhex.

Syntax:
  ./${ourScriptName} [options] [command and arguments]

Where:
  -an or --app-name <deluge|qbittorrent|nicotineplus>
    Define the name of the application to configure for incoming port.
    Defaults to source contents of file '/etc/image-build-info'.

  -ap or --app-parameters <parameters>
    Define additional parameters to pass to the application command.
    No default, this should be the last argument, all remaining arguments will be passed to the application.

  -wp or --webui-port <port>
    Define the web UI port for the application.
    No default.

  -qcf or --qbittorrent-config-filepath <path>
    Define the file path to the qBittorrent configuration file (qBittorrent.conf).
    Defaults to '${defaultQbittorrentConfigFilepath}'.

  -dwcf or --deluge-web-config-filepath <path>
    Define the file path to the Deluge web configuration file (web.conf).
    Defaults to '${defaultDelugeWebConfigFilepath}'.

  -ncf or --nicotineplus-config-filepath <path>
    Define the file path to the Nicotine+ configuration file (nicotine.conf).
    Defaults to '${defaultNicotineplusConfigFilepath}'.

  -gcsp or --gluetun-control-server-port <port>
    Define the Gluetun Control Server port.
    Defaults to '${defaultGluetunControlServerPort}'.

  -gcsu or --gluetun-control-server-username <username>
    Define the Gluetun Control Server username.
    No default.

  -gcsp or --gluetun-control-server-password <password>
    Define the Gluetun Control Server password.
    No default.

  -gip or --gluetun-incoming-port <yes|no>
    Define whether to enable VPN port monitoring and application configuration.
    Defaults to '${defaultGluetunIncomingPort}'.

  -pd or --poll-delay <seconds>
    Define the polling delay in seconds between incoming port checks.
    Defaults to '${defaultPollDelay}'.

  --debug
    Define whether debug mode is enabled.
    Defaults to not set.

  -h or --help
    Displays this text.
Notes:
  - Any additional arguments provided after the options will be passed to the specified application.

Environment Variables:
  APP_NAME
    Set the name of the application to configure with the VPN incoming port.
  APP_PARAMETERS
    Set additional parameters to pass to the application command.
  WEBUI_PORT
    Set the web UI port for the applicaton.
  QBITTORRENT_CONFIG_FILEPATH
    Set the file path to the qBittorrent configuration file (qBittorrent.conf).
  DELUGE_WEB_CONFIG_FILEPATH
    Set the file path to the Deluge web configuration file (web.conf).
  NICOTINEPLUS_CONFIG_FILEPATH
    Set the file path to the Nicotine+ configuration file (nicotine.conf).
  GLUETUN_CONTROL_SERVER_PORT
    Set the port for the Gluetun Control Server.
  GLUETUN_INCOMING_PORT
    Set to 'yes' to enable VPN port monitoring and application configuration.
  POLL_DELAY
    Set the polling delay in seconds between incoming port checks.
  DEBUG
    Set to 'yes' to enable debug mode.
Notes:
  - Command line arguments take precedence over environment variables.

Examples:
  Start process and monitor VPN port for changes:
    GLUETUN_INCOMING_PORT=yes APP_NAME=nicotineplus ./${ourScriptName} --app-parameters /usr/bin/nicotine

  Start process and monitor VPN port for changes using custom port for gluetun Control Server and specific poll interval:
    GLUETUN_INCOMING_PORT=yes APP_NAME=nicotineplus ./${ourScriptName} --gluetun-control-server-port 9000 --poll-delay 5 --app-parameters /usr/bin/nicotine

ENDHELP
}

while [ "$#" != "0" ]
do
  case "$1"
  in
  -an|--app-name)
    APP_NAME="${2,,}"
    shift
    ;;
  -wp|--webui-port)
    WEBUI_PORT="${2}"
    shift
    ;;
  -qcf|--qbittorrent-config-filepath)
    QBITTORRENT_CONFIG_FILEPATH="${2}"
    shift
    ;;
  -dwcf|--deluge-web-config-filepath)
    DELUGE_WEB_CONFIG_FILEPATH="${2}"
    shift
    ;;
  -ncf|--nicotineplus-config-filepath)
    NICOTINEPLUS_CONFIG_FILEPATH="${2}"
    shift
    ;;
  -gcsp|--gluetun-control-server-port)
    GLUETUN_CONTROL_SERVER_PORT="${2}"
    shift
    ;;
  -gcsu|--gluetun-control-server-username)
    GLUETUN_CONTROL_SERVER_USERNAME="${2}"
    shift
    ;;
  -gcspa|--gluetun-control-server-password)
    GLUETUN_CONTROL_SERVER_PASSWORD="${2}"
    shift
    ;;
  -gip|--gluetun-incoming-port)
    GLUETUN_INCOMING_PORT="${2,,}"
    shift
    ;;
  -pd|--poll-delay)
    POLL_DELAY="${2}"
    shift
    ;;
  --debug)
    DEBUG="yes"
    ;;
  -ap|--app-parameters)
    shift  # Skip the --app-parameters flag itself
    # Capture ALL remaining arguments
    APP_PARAMETERS=("$@")
    break  # Exit the loop since we've captured everything
    ;;
  -h|--help)
    show_help
    exit 0
    ;;
  *)
    echo "[ERROR] Unknown option: $1"
    show_help
    exit 1
    ;;
  esac
  shift
done

if [[ -z "${APP_PARAMETERS[*]}" ]]; then
  echo "[ERROR] No application parameters specified via argument '-ap|--app-parameters' or environment variable 'APP_PARAMETERS', showing help before exit..."
  show_help
  exit 1
fi

if [[ "${GLUETUN_INCOMING_PORT}" != 'yes' ]]; then
  echo "[INFO] Configuration of incoming port is disabled via argument '-gip|--gluetun-incoming-port' or environment variable 'GLUETUN_INCOMING_PORT', executing remaining arguments '${APP_PARAMETERS[*]}'..."
  exec "${APP_PARAMETERS[@]}"
else
  if [[ -z "${APP_NAME}" ]]; then
    echo "[WARN] No application name specified via argument '-an|--app-name' or environment variable 'APP_NAME', cannot configure incoming port, executing remaining arguments '${APP_PARAMETERS[*]}'..."
    exec "${APP_PARAMETERS[@]}"
  fi

  if [[ -z "${WEBUI_PORT}" && "${APP_NAME}" != 'nicotineplus' && "${APP_NAME}" != 'slskd' ]]; then
    echo "[WARN] No web UI port specified via argument '-wp|--webui-port' or environment variable 'WEBUI_PORT', cannot configure incoming port, executing remaining arguments '${APP_PARAMETERS[*]}'..."
    exec "${APP_PARAMETERS[@]}"
  fi
fi

main
