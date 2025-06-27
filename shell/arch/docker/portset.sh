#!/bin/bash

set -x
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
readonly defaultQbittorrentConfigFilepath="/config/qBittorrent/config/qBittorrent.conf"
readonly defaultQbittorrentBindAdapter="yes"
readonly defaultGluetunControlServerPort="8000"
readonly defaultConfigureIncomingPort="no"
readonly defaultPollDelay="30"
readonly defaultDebug="no"

# read env var values if not empty, else use defaults
QBITTORRENT_CONFIG_FILEPATH="${QBITTORRENT_CONFIG_FILEPATH:-${defaultQbittorrentConfigFilepath}}"
QBITTORRENT_BIND_ADAPTER="${QBITTORRENT_BIND_ADAPTER:-${defaultQbittorrentBindAdapter}}"
GLUETUN_CONTROL_SERVER_PORT="${GLUETUN_CONTROL_SERVER_PORT:-${defaultGluetunControlServerPort}}"
CONFIGURE_INCOMING_PORT="${CONFIGURE_INCOMING_PORT:-${defaultConfigureIncomingPort}}"
POLL_DELAY="${POLL_DELAY:-${defaultPollDelay}}"
DEBUG="${DEBUG:-${defaultDebug}}"

# Initialize array for remaining arguments
REMAINING_ARGS=()

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

function start_process() {

  # Single command - start in background
  echo "[INFO] Starting single process: ${REMAINING_ARGS[*]}"
  nohup "${REMAINING_ARGS[@]}" &
  APPLICATION_PID=$!

  echo "[INFO] Started '${APPLICATION_NAME}' with main PID '${APPLICATION_PID}' (all processes running in background)"
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

  if [[ "${CONFIGURE_INCOMING_PORT}" != 'yes' ]]; then
    echo "[INFO] Configuration of VPN incoming port is disabled."
    if [[ "${#REMAINING_ARGS[@]}" -gt 0 ]]; then
      echo "[INFO] Executing: ${REMAINING_ARGS[*]}"
      exec "${REMAINING_ARGS[@]}"
    else
      echo "[INFO] No command provided to execute, exiting script..."
      exit 0
    fi
  fi

  # Test connection to gluetun Control Server
  if ! curl_with_retry "${control_server_url}" 10 1 -s >/dev/null; then
    echo "[ERROR] Failed to connect to gluetun Control Server after ${max_retries} attempts"
    echo "[INFO] Giving up on VPN port configuration, executing remaining arguments..."
    if [[ "${#REMAINING_ARGS[@]}" -gt 0 ]]; then
      echo "[INFO] Executing: ${REMAINING_ARGS[*]}"
      exec "${REMAINING_ARGS[@]}"
    else
      echo "[INFO] No command provided to execute, exiting script..."
      exit 1
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

function main {

  echo "[INFO] Running ${ourScriptName} ${ourScriptVersion} - created by binhex."

  # calling functions to generate required globals
  get_vpn_adapter_name
  get_vpn_ip_address
  get_incoming_port

  # run any initial pre-start configuration of the application and then start the application
  application_config_and_start

  while true; do

    # calling functions to generate required globals
    get_vpn_adapter_name
    get_vpn_ip_address
    get_incoming_port

    if [[ "${INCOMING_PORT}" != "${PREVIOUS_INCOMING_PORT}" ]] || ! application_verify_incoming_port; then

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

    sleep "${POLL_DELAY}"
  done
}

function application_config_and_start() {
  if [[ "${APPLICATION_NAME}" == 'qbittorrent' ]]; then
    qbittorrent_config
    qbittorrent_start
  elif [[ "${APPLICATION_NAME}" == 'nicotineplus' ]]; then
    nicotine_config
    nicotine_start
  elif [[ "${APPLICATION_NAME}" == 'deluge' ]]; then
    deluge_config
    deluge_start
  fi
}

function application_configure_incoming_port() {

  if [[ "${APPLICATION_NAME}" == 'qbittorrent' ]]; then
    wait_for_port_to_be_listening "${APPLICATION_PORT}"
    qbittorrent_configure_incoming_port
  elif [[ "${APPLICATION_NAME}" == 'nicotineplus' ]]; then
    nicotine_configure_incoming_port
  elif [[ "${APPLICATION_NAME}" == 'deluge' ]]; then
    wait_for_port_to_be_listening "${APPLICATION_PORT}"
    deluge_configure_incoming_port
    deluge_configure_listen_interface
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

function deluge_config() {

  local pid_filepath="/config/deluged.pid"
  local config_filepath="/config/deluge.conf"

  echo "[INFO] Configuring '${APPLICATION_NAME}' with pre-defined configuration file '${INCOMING_PORT}'..."

  if [[ ! -f "${config_filepath}" ]]; then
    cat <<EOF > "${config_filepath}"
{
}{
    "allow_remote": true,
    "auto_managed": true,
    "autoadd_location": "/data/watched",
    "daemon_port": 58846,
    "download_location": "/data/incomplete",
    "download_location_paths_list": [],
    "listen_interface": "${VPN_IP_ADDRESS}",
    "listen_ports": [
        ${INCOMING_PORT},
        ${INCOMING_PORT}
    ],
    "listen_random_port": null,
    "listen_reuse_port": true,
    "listen_use_sys_port": false,
    "random_port": false,
    "upnp": false
}
EOF

  else
    echo "[INFO] ${APPLICATION_NAME} configuration file already exists at '${config_filepath}'"
    deluge_configure_listen_interface
    deluge_configure_listen_port
    deluge_configure_other
  fi

}

function deluge_start() {

  echo "[info] Removing deluge pid file (if it exists)..."
  rm -f "${pid_filepath}"

  echo "[INFO] Starting '${APPLICATION_NAME}' with VPN incoming port '${INCOMING_PORT}'..."
  start_process
}

function deluge_configure_incoming_port() {

  echo "[INFO] Configuring '${APPLICATION_NAME}' with VPN incoming port '${INCOMING_PORT}'"
  /usr/bin/deluge-console -c /config "config --set listen_ports (${INCOMING_PORT},${INCOMING_PORT})"
}

function deluge_configure_listen_interface() {

  echo "[INFO] Configuring '${APPLICATION_NAME}' with VPN listen interface '${VPN_IP_ADDRESS}'"
  /usr/bin/deluge-console -c /config "config --set listen_interface ${VPN_IP_ADDRESS}"
}

# qBittorrent functions
####

function qbittorrent_config() {
  mkdir -p "$(dirname "${QBITTORRENT_CONFIG_FILEPATH}")"
  if [[ ! -f "${QBITTORRENT_CONFIG_FILEPATH}" ]]; then
    qbittorrent_create_config_file
  else
    echo "[INFO] ${APPLICATION_NAME} configuration file already exists at '${QBITTORRENT_CONFIG_FILEPATH}'"
    qbittorrent_configure_protection
    qbittorrent_configure_bind_adapter
    qbittorrent_configure_other
  fi
}

function qbittorrent_start() {
  echo "[info] Removing ${APPLICATION_NAME} session lock file (if it exists)..."
  rm -f /config/qBittorrent/data/BT_backup/session.lock
  start_process
}

function qbittorrent_create_config_file() {
  echo "[INFO] Creating ${APPLICATION_NAME} configuration file at '${QBITTORRENT_CONFIG_FILEPATH}'"
  cat <<EOF > "${QBITTORRENT_CONFIG_FILEPATH}"
[BitTorrent]
Session\Interface=${VPN_ADAPTER_NAME}
Session\InterfaceName=${VPN_ADAPTER_NAME}
Session\Port=${INCOMING_PORT}

[LegalNotice]
Accepted=true

[Preferences]
Connection\UPnP=false
Connection\Interface=${VPN_ADAPTER_NAME}
Connection\InterfaceName=${VPN_ADAPTER_NAME}
General\UseRandomPort=false
WebUI\CSRFProtection=false
WebUI\LocalHostAuth=false
WebUI\UseUPnP=false
WebUI\Port=${APPLICATION_PORT}
EOF

  echo "[INFO] Created ${APPLICATION_NAME} configuration file"
}

function qbittorrent_update_or_add_config_section() {
  local config_file="${1}"
  shift
  local section="${1}"
  shift
  local key="${1}"
  shift
  local value="${1}"
  shift

  # Check if the entry exists in the file
  if grep -q "^${key}=" "${config_file}"; then
      # Entry exists, update it
      sed -i -e "s~^${key}=.*~${key}=${value}~g" "${config_file}"
  else
      # Entry doesn't exist, add it to the correct section
      if grep -q "^\[${section}\]" "${config_file}"; then
          # Section exists, add the entry after the section header
          sed -i "/^\[${section}\]/a ${key}=${value}" "${config_file}"
      else
          # Section doesn't exist, create it with the entry
          echo -e "\n[${section}]\n${key}=${value}" >> "${config_file}"
      fi
  fi
}

function qbittorrent_configure_other() {
  qbittorrent_update_or_add_config_section "${QBITTORRENT_CONFIG_FILEPATH}" "Preferences" "WebUI\\\\UseUPnP=false" "${VPN_ADAPTER_NAME}"
  qbittorrent_update_or_add_config_section "${QBITTORRENT_CONFIG_FILEPATH}" "Preferences" "Connection\\\\UPnP=false" "${VPN_ADAPTER_NAME}"
  qbittorrent_update_or_add_config_section "${QBITTORRENT_CONFIG_FILEPATH}" "Preferences" "General\\\\UseRandomPort=false" "${VPN_ADAPTER_NAME}"
}

function qbittorrent_configure_protection() {
  qbittorrent_update_or_add_config_section "${QBITTORRENT_CONFIG_FILEPATH}" "Preferences" "WebUI\\\\CSRFProtection=false" "${VPN_ADAPTER_NAME}"
  qbittorrent_update_or_add_config_section "${QBITTORRENT_CONFIG_FILEPATH}" "Preferences" "WebUI\\\\LocalHostAuth=false" "${VPN_ADAPTER_NAME}"
}

function qbittorrent_configure_bind_adapter() {
  if [[ "${QBITTORRENT_BIND_ADAPTER}" == 'yes' ]]; then
    echo "[INFO] Binding '${APPLICATION_NAME}' to gluetun network interface"

      # get vpn adapter name (wg0/tun0/tap0)
      get_vpn_adapter_name

    qbittorrent_update_or_add_config_section "${QBITTORRENT_CONFIG_FILEPATH}" "Preferences" "Connection\\\\Interface" "${VPN_ADAPTER_NAME}"
    qbittorrent_update_or_add_config_section "${QBITTORRENT_CONFIG_FILEPATH}" "Preferences" "Connection\\\\InterfaceName" "${VPN_ADAPTER_NAME}"
    qbittorrent_update_or_add_config_section "${QBITTORRENT_CONFIG_FILEPATH}" "BitTorrent" "Session\\\\Interface" "${VPN_ADAPTER_NAME}"
    qbittorrent_update_or_add_config_section "${QBITTORRENT_CONFIG_FILEPATH}" "BitTorrent" "Session\\\\InterfaceName" "${VPN_ADAPTER_NAME}"
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

  if [[ "${DEBUG}" == "yes" ]]; then
    echo "[INFO] Sending POST requests to URL '${web_protocol}://localhost:${APPLICATION_PORT}'..."
  fi

  # Use curl_with_retry for API calls
  curl_with_retry "${web_protocol}://localhost:${APPLICATION_PORT}/api/v2/app/setPreferences" 10 1 -k -i -X POST -d "json={\"random_port\": false}" >/dev/null
  curl_with_retry "${web_protocol}://localhost:${APPLICATION_PORT}/api/v2/app/setPreferences" 10 1 -k -i -X POST -d "json={\"listen_port\": ${INCOMING_PORT}}" >/dev/null
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
  preferences_response=$(curl_with_retry "${web_protocol}://localhost:${APPLICATION_PORT}/api/v2/app/preferences" 10 1 -k -s)
  current_port=$(echo "${preferences_response}" | jq -r '.listen_port')

  if [[ "${DEBUG}" == "yes" ]]; then
      echo "[DEBUG] Current qBittorrent listen port: '${current_port}', Expected: '${INCOMING_PORT}'"
  fi

  # Check if the port was retrieved successfully and matches
  if [[ "${current_port}" == "null" || -z "${current_port}" ]]; then
      echo "[WARN] Unable to retrieve current port from qBittorrent API"
      return 1
  fi

  if [[ "${current_port}" == "${INCOMING_PORT}" ]]; then
      echo "[INFO] qBittorrent incoming port '${current_port}' matches VPN port '${INCOMING_PORT}'"
      return 0
  else
      echo "[WARN] qBittorrent incoming port '${current_port}' does not match VPN port '${INCOMING_PORT}'"
      return 1
  fi
}

# nicotineplus functions
####

function nicotine_start() {
  echo "[INFO] Starting '${APPLICATION_NAME}' with VPN incoming port '${INCOMING_PORT}'..."
  start_process "--port ${INCOMING_PORT}"
}

function nicotine_config() {
  local config_file='/home/nobody/.config/nicotine/config'
  echo "[INFO] Configuring '${APPLICATION_NAME}' with VPN incoming port '${INCOMING_PORT}'"
  sed -i -e "s~^portrange.*~portrange = (${INCOMING_PORT}, ${INCOMING_PORT})~g" "${config_file}"
}

function nicotine_configure_incoming_port() {

  # if previous incoming port is not set then this is the initial run, nicotine will of been started with the default port, so we can skip kill//start
  if [[ -z "${PREVIOUS_INCOMING_PORT}" ]]; then
    return 0
  fi
  echo "[INFO] Killing '${APPLICATION_NAME}' process as we cannot reconfigure incoming port while it is running..."
  kill_process
  nicotine_config
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
  -an or --application-name <name>
    Define the name of the application to configure for incoming port.
    No default.

  -ap or --application-port <port>
    Define the web UI port for the application.
    No default.

  -qcf or --qbittorrent-config-filepath <path>
    Define the file path to the qBittorrent configuration file.
    Defaults to '${QBITTORRENT_CONFIG_FILEPATH}'.

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
  APPLICATION_PORT
    Set the web UI port for the applicaton.
  QBITTORRENT_CONFIG_FILEPATH
    Set the file path to the qBittorrent configuration file.
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
  Start process and monitor VPN port for changes:
    ./${ourScriptName} /usr/bin/nicotine

  Start process and monitor VPN port for changes using custom port for gluetun Control Server and specific poll interval:
    ./${ourScriptName} --gluetun-control-server-port 9000 --poll-delay 5 /usr/bin/qbittorrent

  Manually executing the script for debug:
    CONFIGURE_INCOMING_PORT=yes APPLICATION_NAME=nicotineplus ./${ourScriptName} --debug /usr/bin/nicotine

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
  -ap|--application-port)
    APPLICATION_PORT="${2}"
    shift
    ;;
  -qcf|--qbittorrent-config-filepath)
    QBITTORRENT_CONFIG_FILEPATH="${2}"
    shift
    ;;
  -qba|--qbittorrent-bind-adapter)
    QBITTORRENT_BIND_ADAPTER="${2,,}"
    shift
    ;;
  -gcsp|--gluetun-control-server-port)
    GLUETUN_CONTROL_SERVER_PORT="${2}"
    shift
    ;;
  -cip|--configure-incoming-port)
    CONFIGURE_INCOMING_PORT="${2,,}"
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

if [[ -z "${APPLICATION_PORT}" ]]; then
  echo "[INFO] No application port specified via argument '-ap|--application-port' or environment variable 'APPLICATION_PORT', showing help..."
  show_help
fi

echo "[INFO] Configuration of VPN incoming port is enabled, starting incoming port watchdog..."
main
