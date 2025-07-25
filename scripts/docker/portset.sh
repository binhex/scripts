#!/bin/bash

# Script to get the incoming port from gluetun and configure a predefined list of applications. This script will block.
#
# In order for the script to work you need the following configured for gluetun:
# 1. Ensure VPN provider supports incoming port assignment and that its enabled in the gluetun container configuration.
# 2. Ensure the application running this script is sharing the gluetun container's network.

# TODO
# create deluge configure*  functions
# figue out how to handle deluge and deluge-web ui process start

# script name and path
readonly ourScriptName="$(basename -- "$0")"
readonly ourScriptVersion="v1.0.0"

# default values
readonly defaultDelugeWebConfigFilepath="/config/web.conf"
readonly defaultQbittorrentConfigFilepath="/config/qBittorrent/config/qBittorrent.conf"
readonly defaultGluetunControlServerPort="8000"
readonly defaultGluetunIncomingPort="no"
readonly defaultPollDelay="60"
readonly defaultDebug="no"

# read env var values if not empty, else use defaults
DELUGE_WEB_CONFIG_FILEPATH="${DELUGE_WEB_CONFIG_FILEPATH:-${defaultDelugeWebConfigFilepath}}"
QBITTORRENT_CONFIG_FILEPATH="${QBITTORRENT_CONFIG_FILEPATH:-${defaultQbittorrentConfigFilepath}}"
GLUETUN_CONTROL_SERVER_PORT="${GLUETUN_CONTROL_SERVER_PORT:-${defaultGluetunControlServerPort}}"
GLUETUN_INCOMING_PORT="${GLUETUN_INCOMING_PORT:-${defaultGluetunIncomingPort}}"
POLL_DELAY="${POLL_DELAY:-${defaultPollDelay}}"
DEBUG="${DEBUG:-${defaultDebug}}"

# utility functions
####

function curl_with_retry() {
  local url="${1}"
  shift

  # Check if second argument is a number (max_retries)
  local max_retries=3  # Default
  local retry_delay=2  # Default

  if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
    max_retries="${1}"
    shift
    if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
      retry_delay="${1}"
      shift
    fi
  fi

  local curl_args=("$@")  # Remaining arguments are curl options
  local retry_count=0
  local result
  local exit_code

  while [[ "${retry_count}" -lt "${max_retries}" ]]; do
    if [[ "${DEBUG}" == "yes" ]]; then
      echo "[DEBUG] Attempting curl request to '${url}', attempt $((retry_count + 1))/${max_retries}" >&2
    fi

    # Execute curl with all provided arguments
    result=$(curl "${curl_args[@]}" "${url}" 2>/dev/null)
    exit_code=$?

    if [[ "${exit_code}" -eq 0 ]]; then
      if [[ "${DEBUG}" == "yes" ]]; then
        echo "[DEBUG] Curl request successful on attempt $((retry_count + 1))" >&2
      fi
      echo "${result}"
      return 0
    else
      retry_count=$((retry_count + 1))
      if [[ "${DEBUG}" == "yes" ]]; then
        echo "[DEBUG] Curl request failed with exit code ${exit_code}, attempt ${retry_count}/${max_retries}" >&2
      fi

      if [[ "${retry_count}" -lt "${max_retries}" ]]; then
        if [[ "${DEBUG}" == "yes" ]]; then
          echo "[DEBUG] Retrying in ${retry_delay} seconds..." >&2
        fi
        sleep "${retry_delay}"
      fi
    fi
  done

  echo "[ERROR] Curl request to '${url}' failed after ${max_retries} attempts" >&2
  return 1
}

function start_process_background() {

  echo "[INFO] Starting single process: ${APPLICATION_PARAMETERS[*]}"
  nohup "${APPLICATION_PARAMETERS[@]}" &
  APPLICATION_PID=$!

  if [[ "${DEBUG}" == "yes" ]]; then
    echo "[DEBUG] Started '${APPLICATION_NAME}' with main PID '${APPLICATION_PID}' (all processes running in background)"
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
    echo "[INFO] Killing ${APPLICATION_NAME} process with PID '${APPLICATION_PID}'"
    kill "${APPLICATION_PID}"
    wait "${APPLICATION_PID}" 2>/dev/null
    echo "[INFO] ${APPLICATION_NAME} process with PID '${APPLICATION_PID}' has been killed"
  else
    echo "[INFO] No PID found for ${APPLICATION_NAME}, ignoring kill"
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

function get_vpn_ip_address() {
  VPN_IP_ADDRESS="$(ifconfig "${VPN_ADAPTER_NAME}" | grep 'inet ' | awk '{print $2}')"
  if [[ "${DEBUG}" == "yes" ]]; then
    echo "[DEBUG] Internal IP address for VPN adapter: '${VPN_IP_ADDRESS}'"
  fi

  if [[ -z "${VPN_IP_ADDRESS}" ]]; then
    echo "[WARN] Unable to determine VPN IP address, please check your gluetun configuration and ensure the VPN is connected."
  fi
}

function get_vpn_adapter_name() {
  if [[ -n "${VPN_INTERFACE}" ]]; then
    VPN_ADAPTER_NAME="${VPN_INTERFACE}"
    if [[ "${DEBUG}" == "yes" ]]; then
      echo "[DEBUG] Using VPN interface from environment variable: '${VPN_ADAPTER_NAME}'"
    fi
    return 0
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

function get_incoming_port() {
  local control_server_url="http://127.0.0.1:${GLUETUN_CONTROL_SERVER_PORT}/v1"
  local vpn_public_ip
  local vpn_country_ip
  local vpn_city_ip

  # Test connection to gluetun Control Server
  if ! curl_with_retry "${control_server_url}" 10 1 -s >/dev/null; then
    echo "[ERROR] Failed to connect to gluetun Control Server after ${max_retries} attempts"
    echo "[INFO] Giving up on VPN port configuration, executing remaining arguments..."
    if [[ "${#APPLICATION_PARAMETERS[@]}" -gt 0 ]]; then
      echo "[INFO] Executing: ${APPLICATION_PARAMETERS[*]}"
      exec "${APPLICATION_PARAMETERS[@]}"
    fi
  fi

  # Get port and IP information using curl_with_retry
  portforwarded_response=$(curl_with_retry "${control_server_url}/openvpn/portforwarded" 10 1 -s)
  public_ip=$(curl_with_retry "${control_server_url}/publicip/ip" 10 1 -s)

  # parse results
  INCOMING_PORT="$(echo "${portforwarded_response}" | jq -r '.port')"
  vpn_public_ip="$(echo "${public_ip}" | jq -r '.public_ip')"
  vpn_country_ip="$(echo "${public_ip}" | jq -r '.country')"
  vpn_city_ip="$(echo "${public_ip}" | jq -r '.city')"

  if [[ "${DEBUG}" == "yes" ]]; then
    echo "[DEBUG] Current incoming port for VPN tunnel is '${INCOMING_PORT}'"
    echo "[DEBUG] Public IP for VPN tunnel is '${vpn_public_ip}'"
    echo "[DEBUG] Country for VPN tunnel is '${vpn_country_ip}'"
    echo "[DEBUG] City for VPN tunnel is '${vpn_city_ip}'"
  fi
}

function external_verify_incoming_port() {

  local result
  result="$(curl_with_retry "https://ifconfig.co/port/${INCOMING_PORT}" 10 1 -s | jq -r '.reachable')"

  if [[ "${result}" == "true" ]]; then
    echo "[INFO] External verification: Incoming port '${INCOMING_PORT}' is reachable."
    return 0
  else
    echo "[WARN] External verification: Incoming port '${INCOMING_PORT}' is NOT reachable."
    return 1
  fi

}

function get_vpn_ip_and_port() {

  get_vpn_ip_address
  get_incoming_port

}

function main {

  echo "[INFO] Running ${ourScriptName} ${ourScriptVersion} - created by binhex."

  # get vpn adapter name
  get_vpn_adapter_name

  # calling functions to generate required globals
  get_vpn_ip_and_port

  # run any initial pre-start configuration of the application and then start the application
  application_start

  while true; do

    # calling functions to generate required globals
    get_vpn_ip_and_port

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
      echo "[INFO] Previous VPN port forward '${PREVIOUS_INCOMING_PORT}' and current VPN port forward '${INCOMING_PORT}' are the same, checking again in ${POLL_DELAY} seconds..."
    fi

    echo "[INFO] Sleeping for ${POLL_DELAY} seconds before re-checking port assignment..."
    sleep "${POLL_DELAY}"
  done
}

function application_start() {

  if [[ "${APPLICATION_NAME}" == 'qbittorrent' ]]; then
    qbittorrent_start
    wait_for_port_to_be_listening "${WEBUI_PORT}"
  elif [[ "${APPLICATION_NAME}" == 'deluge' ]]; then
    deluge_start
    wait_for_port_to_be_listening "${WEBUI_PORT}"
  elif [[ "${APPLICATION_NAME}" == 'nicotineplus' ]]; then
    nicotine_edit_config
    nicotine_start
  else
    echo "[WARN] Application name '${APPLICATION_NAME}' unknown, executing remaining arguments '${APPLICATION_PARAMETERS[*]}'..."
    exec "${APPLICATION_PARAMETERS[@]}"
  fi

}

function application_configure_incoming_port() {

  if [[ "${APPLICATION_NAME}" == 'qbittorrent' ]]; then
    wait_for_port_to_be_listening "${WEBUI_PORT}"
    qbittorrent_api_config
  elif [[ "${APPLICATION_NAME}" == 'deluge' ]]; then
    wait_for_port_to_be_listening "${WEBUI_PORT}"
    deluge_api_config
  elif [[ "${APPLICATION_NAME}" == 'nicotineplus' ]]; then
    nicotine_gluetun_incoming_port
  fi

}

function application_verify_incoming_port() {

  if [[ "${APPLICATION_NAME}" == 'qbittorrent' ]]; then
    if ! qbittorrent_verify_incoming_port; then
      return 1
    fi
  elif [[ "${APPLICATION_NAME}" == 'nicotineplus' ]]; then
    if ! nicotine_verify_incoming_port; then
      return 1
    fi
  elif [[ "${APPLICATION_NAME}" == 'deluge' ]]; then
    if ! deluge_verify_incoming_port; then
      return 1
    fi
  fi
  return 0

}

# deluge functions
####

function deluge_api_config() {

  echo "[INFO] Configuring '${APPLICATION_NAME}' for VPN..."

  /usr/bin/deluge-console -c /config "config --set random_port false" 2>/dev/null
  /usr/bin/deluge-console -c /config "config --set listen_ports (${INCOMING_PORT},${INCOMING_PORT})" 2>/dev/null
  /usr/bin/deluge-console -c /config "config --set listen_interface ${VPN_IP_ADDRESS}" 2>/dev/null
  /usr/bin/deluge-console -c /config "config --set outgoing_interface ${VPN_IP_ADDRESS}" 2>/dev/null
}

function deluge_start() {

  echo "[INFO] Starting '${APPLICATION_NAME}' with VPN incoming port '${INCOMING_PORT}'..."
  start_process_background
}

function deluge_verify_incoming_port() {
  local web_protocol
  local current_port

  echo "[INFO] Verifying '${APPLICATION_NAME}' incoming port matches VPN port '${INCOMING_PORT}'"

  # identify protocol, used by curl to connect to api
  if grep -q '"https": true,' "${DELUGE_WEB_CONFIG_FILEPATH}"; then
      web_protocol="https"
  else
      web_protocol="http"
  fi

  # Get current port from Deluge console
  current_port=$(/usr/bin/deluge-console -c /config "config listen_ports" 2>/dev/null | grep -P -o '\d+(?=\)$)')

  if [[ "${DEBUG}" == "yes" ]]; then
      echo "[DEBUG] Current ${APPLICATION_NAME} listen port: '${current_port}', Expected: '${INCOMING_PORT}'"
  fi

  # Check if the port was retrieved successfully
  if [[ "${current_port}" == "null" || -z "${current_port}" ]]; then
      echo "[WARN] Unable to retrieve current port from ${APPLICATION_NAME} API"
      return 1
  fi

  if [[ "${current_port}" == "${INCOMING_PORT}" ]]; then
      echo "[INFO] ${APPLICATION_NAME} incoming port '${current_port}' matches VPN port '${INCOMING_PORT}'"
      return 0
  else
      echo "[WARN] ${APPLICATION_NAME} incoming port '${current_port}' does not match VPN port '${INCOMING_PORT}'"
      return 1
  fi

}

# qBittorrent functions
####

function qbittorrent_start() {

  echo "[INFO] Starting '${APPLICATION_NAME}' with VPN incoming port '${INCOMING_PORT}'..."
  start_process_background

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

  echo "[INFO] Verifying '${APPLICATION_NAME}' incoming port matches VPN port '${INCOMING_PORT}'"

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
      echo "[DEBUG] Current ${APPLICATION_NAME} listen port: '${current_port}', Expected: '${INCOMING_PORT}'"
  fi

  # Check if the port was retrieved successfully
  if [[ "${current_port}" == "null" || -z "${current_port}" ]]; then
      echo "[WARN] Unable to retrieve current port from ${APPLICATION_NAME} API"
      return 1
  fi

  if [[ "${current_port}" == "${INCOMING_PORT}" ]]; then
      echo "[INFO] ${APPLICATION_NAME} incoming port '${current_port}' matches VPN port '${INCOMING_PORT}'"
      return 0
  else
      echo "[WARN] ${APPLICATION_NAME} incoming port '${current_port}' does not match VPN port '${INCOMING_PORT}'"
      return 1
  fi
}

# nicotineplus functions
####

function nicotine_start() {
  echo "[INFO] Starting '${APPLICATION_NAME}' with VPN incoming port '${INCOMING_PORT}'..."
  start_process_background "--port ${INCOMING_PORT}"
}

function nicotine_edit_config() {
  local config_file='/home/nobody/.config/nicotine/config'
  echo "[INFO] Configuring '${APPLICATION_NAME}' with VPN incoming port '${INCOMING_PORT}'"
  sed -i -e "s~^portrange.*~portrange = (${INCOMING_PORT}, ${INCOMING_PORT})~g" "${config_file}"
}

function nicotine_gluetun_incoming_port() {

  # if previous incoming port is not set then this is the initial run, nicotine will of been started with the default port, so no need to kill, edit and start
  if [[ -z "${PREVIOUS_INCOMING_PORT}" ]]; then
    return 0
  fi
  echo "[INFO] Killing '${APPLICATION_NAME}' process as we cannot reconfigure incoming port while it is running..."
  kill_process
  nicotine_edit_config
  nicotine_start
}

function nicotine_verify_incoming_port() {
  local config_file='/home/nobody/.config/nicotine/config'
  local expected_line="portrange = (${INCOMING_PORT}, ${INCOMING_PORT})"

  echo "[INFO] Verifying '${APPLICATION_NAME}' incoming port matches VPN port '${INCOMING_PORT}'"

  if [[ "${DEBUG}" == "yes" ]]; then
    echo "[DEBUG] Looking for line: '${expected_line}' in config file '${config_file}'"
  fi

  # Check if the expected portrange line exists in the config file
  if grep -Fxq "${expected_line}" "${config_file}"; then
    echo "[INFO] ${APPLICATION_NAME} incoming port matches VPN port '${INCOMING_PORT}'"
    return 0
  else
    echo "[WARN] ${APPLICATION_NAME} incoming port does not match VPN port '${INCOMING_PORT}'"
    if [[ "${DEBUG}" == "yes" ]]; then
      echo "[DEBUG] Current portrange line in config:"
      grep "^portrange" "${config_file}" || echo "[DEBUG] No portrange line found"
    fi
    return 1
  fi
}

function show_help() {
  cat <<ENDHELP
Description:
  A simple bash script to monitor the VPN incoming port from gluetun and configure a predefined list of applications.
  ${ourScriptName} ${ourScriptVersion} - Created by binhex.

Syntax:
  ./${ourScriptName} [options] [command and arguments]

Where:
  -an or --application-name <deluge|qbittorrent|nicotineplus>
    Define the name of the application to configure for incoming port.
    No default.

  -apa or --application-parameters <parameters>
    Define additional parameters to pass to the application command.
    No default, this should be the last argument, all remaining arguments will be passed to the application.

  -ap or --webui-port <port>
    Define the web UI port for the application.
    No default.

  -qcf or --qbittorrent-config-filepath <path>
    Define the file path to the qBittorrent configuration file (qBittorrent.conf).
    Defaults to '${QBITTORRENT_CONFIG_FILEPATH}'.

  -dwcf or --deluge-web-config-filepath <path>
    Define the file path to the Deluge web configuration file (web.conf).
    Defaults to '${DELUGE_WEB_CONFIG_FILEPATH}'.

  -gcsp or --gluetun-control-server-port <port>
    Define the Gluetun Control Server port.
    Defaults to '${GLUETUN_CONTROL_SERVER_PORT}'.

  -gip or --gluetun-incoming-port <yes|no>
    Define whether to enable VPN port monitoring and application configuration.
    Defaults to '${GLUETUN_INCOMING_PORT}'.

  -pd or --poll-delay <seconds>
    Define the polling delay in seconds between incoming port checks.
    Defaults to '${POLL_DELAY}'.

  --debug
    Define whether debug mode is enabled.
    Defaults to not set.

  -h or --help
    Displays this text.
Notes:
  - Any additional arguments provided after the options will be passed to the specified application.

Environment Variables:
  APPLICATION_NAME
    Set the name of the application to configure with the VPN incoming port.
  APPLICATION_PARAMETERS
    Set additional parameters to pass to the application command.
  WEBUI_PORT
    Set the web UI port for the applicaton.
  QBITTORRENT_CONFIG_FILEPATH
    Set the file path to the qBittorrent configuration file (qBittorrent.conf).
  DELUGE_WEB_CONFIG_FILEPATH
    Set the file path to the Deluge web configuration file (web.conf).
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
    GLUETUN_INCOMING_PORT=yes APPLICATION_NAME=nicotineplus ./${ourScriptName} --application-parameters /usr/bin/nicotine

  Start process and monitor VPN port for changes using custom port for gluetun Control Server and specific poll interval:
    GLUETUN_INCOMING_PORT=yes APPLICATION_NAME=nicotineplus ./${ourScriptName} --gluetun-control-server-port 9000 --poll-delay 5 --application-parameters /usr/bin/nicotine

ENDHELP
}

while [ "$#" != "0" ]
do
  case "$1"
  in
  -an|--application-name)
    APPLICATION_NAME="${2,,}"
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
  -gcsp|--gluetun-control-server-port)
    GLUETUN_CONTROL_SERVER_PORT="${2}"
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
  -app|--application-parameters)
    shift  # Skip the --application-parameters flag itself
    # Capture ALL remaining arguments
    APPLICATION_PARAMETERS=("$@")
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

if [[ -z "${APPLICATION_PARAMETERS[*]}" ]]; then
  echo "[ERROR] No application parameters specified via argument '-app|--application-parameters' or environment variable 'APPLICATION_PARAMETERS', showing help before exit..."
  show_help
  exit 1
fi

if [[ "${GLUETUN_INCOMING_PORT}" != 'yes' ]]; then
  echo "[INFO] Configuration of incoming port is disabled via argument '-gip|--gluetun-incoming-port' or environment variable 'GLUETUN_INCOMING_PORT', executing remaining arguments '${APPLICATION_PARAMETERS[*]}'..."
  exec "${APPLICATION_PARAMETERS[@]}"
else
  if [[ -z "${APPLICATION_NAME}" ]]; then
    echo "[WARN] No application name specified via argument '-an|--application-name' or environment variable 'APPLICATION_NAME', cannot configure incoming port, executing remaining arguments '${APPLICATION_PARAMETERS[*]}'..."
    exec "${APPLICATION_PARAMETERS[@]}"
  fi

  if [[ -z "${WEBUI_PORT}" && "${APPLICATION_NAME}" != 'nicotineplus' ]]; then
    echo "[WARN] No web UI port specified via argument '-wp|--webui-port' or environment variable 'WEBUI_PORT', cannot configure incoming port, executing remaining arguments '${APPLICATION_PARAMETERS[*]}'..."
    exec "${APPLICATION_PARAMETERS[@]}"
  fi
fi

main
