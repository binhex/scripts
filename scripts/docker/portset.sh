#!/bin/bash

# Script to get the incoming port from gluetun and configure a predefined list of applications. This script will block.
#
# In order for the script to work you need the following configured for gluetun:
# 1. Ensure VPN provider supports incoming port assignment and that its enabled in the gluetun container configuration.
# 2. Ensure the application running this script is sharing the gluetun container's network.

# script name and path
ourScriptName="$(basename -- "$0")"
ourScriptVersion="v1.0.0"

# default values
readonly defaultImageBuildFilepath="/etc/image-build-info"
readonly defaultDelugeWebConfigFilepath="/config/web.conf"
readonly defaultQbittorrentConfigFilepath="/config/qBittorrent/config/qBittorrent.conf"
readonly defaultNicotineplusConfigFilepath="/home/nobody/.config/nicotine/config"
readonly defaultGluetunControlServerPort="8000"
readonly defaultGluetunIncomingPort="no"
readonly defaultPollDelay="60"
readonly defaultDebug="no"
readonly defaultMaxStartupRetries="10"
readonly defaultMaxPortVerifyRetries="3"
readonly defaultGluetunEscalationCooldown="300"
readonly defaultQbittorrentWebuiUser="admin"
readonly defaultQbittorrentCookieJar="/tmp/qbittorrent_sid.txt"

# auto-generated qBittorrent password (populated by qbittorrent_edit_config if no existing password in config)
QBITTORRENT_AUTO_PASSWORD=""

# read env var values if not empty, else use defaults
DELUGE_WEB_CONFIG_FILEPATH="${DELUGE_WEB_CONFIG_FILEPATH:-${defaultDelugeWebConfigFilepath}}"
QBITTORRENT_CONFIG_FILEPATH="${QBITTORRENT_CONFIG_FILEPATH:-${defaultQbittorrentConfigFilepath}}"
NICOTINEPLUS_CONFIG_FILEPATH="${NICOTINEPLUS_CONFIG_FILEPATH:-${defaultNicotineplusConfigFilepath}}"
GLUETUN_CONTROL_SERVER_PORT="${GLUETUN_CONTROL_SERVER_PORT:-${defaultGluetunControlServerPort}}"
GLUETUN_INCOMING_PORT="${GLUETUN_INCOMING_PORT:-${defaultGluetunIncomingPort}}"
POLL_DELAY="${POLL_DELAY:-${defaultPollDelay}}"
DEBUG="${DEBUG:-${defaultDebug}}"
MAX_STARTUP_RETRIES="${MAX_STARTUP_RETRIES:-${defaultMaxStartupRetries}}"
MAX_PORT_VERIFY_RETRIES="${MAX_PORT_VERIFY_RETRIES:-${defaultMaxPortVerifyRetries}}"
GLUETUN_ESCALATION_COOLDOWN="${GLUETUN_ESCALATION_COOLDOWN:-${defaultGluetunEscalationCooldown}}"
QBITTORRENT_WEBUI_USER="${QBITTORRENT_WEBUI_USER:-${defaultQbittorrentWebuiUser}}"
QBITTORRENT_WEBUI_PASSWORD="${QBITTORRENT_WEBUI_PASSWORD:-}"

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

function check_gluetun_cs_api() {

	echo "[INFO] Health checking gluetun Control Server API connectivity..."

	local auth
	if [[ -n "${GLUETUN_CONTROL_SERVER_USERNAME}" ]]; then
		auth="-u ${GLUETUN_CONTROL_SERVER_USERNAME}:${GLUETUN_CONTROL_SERVER_PASSWORD}"
	else
		auth=""
	fi

	local control_server_url="http://127.0.0.1:${GLUETUN_CONTROL_SERVER_PORT}/v1/vpn/status"
  if ! curl_with_retry "${control_server_url}" 10 1 -s ${auth}; then
    echo "[WARN] Failed to connect to gluetun Control Server API 'http://127.0.0.1:${GLUETUN_CONTROL_SERVER_PORT}/v1/vpn/status'"
		return 1
	else
    if [[ "${DEBUG}" == "yes" ]]; then
      echo "[DEBUG] Successfully connected to gluetun Control Server"
    fi
		return 0
  fi

}

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

  # Get port forward information from gluetun Control Server (shared function)
  if ! get_gluetun_forwarded_port 10 1; then
    return 1
  fi
  INCOMING_PORT="${GLUETUN_FORWARDED_PORT}"
  if [[ "${DEBUG}" == "yes" ]]; then
    echo "[DEBUG] Current incoming port for VPN tunnel is '${INCOMING_PORT}'"
  fi

  # Get public ip and location information from gluetun Control Server
  # unquoted: auth can be empty or multi-word
  # shellcheck disable=SC2086
  public_ip=$(curl_with_retry "${control_server_url}/publicip/ip" 10 1 -s ${auth})

  if [[ -z "${public_ip}" ]]; then
    return 1
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

function get_vpn_status() {

  local control_server_url="http://127.0.0.1:${GLUETUN_CONTROL_SERVER_PORT}/v1"

  local auth
  if [[ -n "${GLUETUN_CONTROL_SERVER_USERNAME}" ]]; then
    auth="-u ${GLUETUN_CONTROL_SERVER_USERNAME}:${GLUETUN_CONTROL_SERVER_PASSWORD}"
  else
    auth=""
  fi

  local status_response
  status_response=$(curl_with_retry "${control_server_url}/vpn/status" 3 2 -k -s ${auth})
  if [[ -z "${status_response}" ]]; then
    echo "[WARN] Unable to retrieve VPN status from gluetun Control Server API" >&2
    return 1
  fi

  local vpn_status
  vpn_status=$(echo "${status_response}" | jq -r '.status')
  if [[ -z "${vpn_status}" || "${vpn_status}" == "null" ]]; then
    echo "[WARN] Unable to parse VPN status from gluetun Control Server API response" >&2
    return 1
  fi

  echo "${vpn_status}"
  return 0

}

function restart_vpn_connection() {

  local control_server_url="http://127.0.0.1:${GLUETUN_CONTROL_SERVER_PORT}/v1"

  local auth
  if [[ -n "${GLUETUN_CONTROL_SERVER_USERNAME}" ]]; then
    auth="-u ${GLUETUN_CONTROL_SERVER_USERNAME}:${GLUETUN_CONTROL_SERVER_PASSWORD}"
  else
    auth=""
  fi

  echo "[INFO] Restarting VPN connection..."

  # Check the current VPN state before taking any action. If the script previously
  # crashed mid-restart (e.g. after sending 'stopped' but before sending 'running'),
  # the VPN may already be stopped. Querying state first ensures we only send the
  # transitions that are actually needed, making the restart idempotent.
  local current_vpn_status
  if ! current_vpn_status=$(get_vpn_status); then
    echo "[ERROR] Unable to determine current VPN status, cannot safely restart"
    return 1
  fi
  echo "[INFO] Current VPN status is '${current_vpn_status}'"

  local vpn_desired_states=()
  if [[ "${current_vpn_status}" == "stopped" ]]; then
    echo "[INFO] VPN is already stopped, skipping stop step and proceeding directly to start..."
    vpn_desired_states=("running")
  else
    vpn_desired_states=("stopped" "running")
  fi

  for vpn_desired_state in "${vpn_desired_states[@]}"; do

    echo "[INFO] Setting VPN status to '${vpn_desired_state}' via gluetun Control Server API..."
    json="{
      \"status\": \"${vpn_desired_state}\"
    }"

    if ! curl_with_retry "${control_server_url}/vpn/status" 3 2 -k -s ${auth} -X PUT -H "Content-Type: application/json" -d "${json}"; then
      echo "[ERROR] Failed to set VPN status to '${vpn_desired_state}'"
      return 1
    fi

    # Wait between state changes to allow VPN to process the command
    if [[ "${vpn_desired_state}" == "stopped" ]]; then
      echo "[INFO] Waiting 5 seconds for VPN to stop..."
      sleep 5
    fi

  done
  echo "[INFO] VPN connection successfully restarted."
}

function check(){

  if ! check_gluetun_cs_api; then
    return 1
  fi

  if ! get_incoming_port; then
    return 1
  fi

  if ! vpn_adapter_name=$(get_vpn_adapter_name); then
    return 1
  fi

  if ! get_vpn_adapter_ip_address "${vpn_adapter_name}" >/dev/null; then
    return 1
  fi

}

function main {

  echo "[INFO] Running ${ourScriptName} ${ourScriptVersion} - created by binhex."

	# source in curl_with_retry function and vpn ip address and vpn adapter name
	source utils.sh

  local startup_retry_count=0

  while true; do

    # run function to check all required conditions exist
    if ! check; then
      startup_retry_count=$((startup_retry_count + 1))
      echo "[WARN] Required conditions not met (attempt ${startup_retry_count}/${MAX_STARTUP_RETRIES}), checking again in ${POLL_DELAY} seconds..."

      if [[ ${startup_retry_count} -ge ${MAX_STARTUP_RETRIES} ]]; then
        echo "[WARN] Maximum startup retries (${MAX_STARTUP_RETRIES}) reached, VPN conditions not met - executing application without VPN port configuration: '${APP_PARAMETERS[*]}'..."
        exec "${APP_PARAMETERS[@]}"
      fi

      sleep "${POLL_DELAY}"
      continue
    else
      # run any initial pre-start configuration of the application and then start the application
      application_start
      break
    fi

  done

  while true; do

    # run function to check all required conditions exist
    if ! check; then
      # When check() fails (e.g. port=0 from gluetun, unreachable API,
      # missing VPN adapter), attempt recovery via the escalation handler.
      # The handler will retry the port query, and if still failing,
      # restart the VPN connection via gluetun Control Server API.
      echo "[WARN] Required conditions not met, attempting recovery..."
      if ensure_incoming_port; then
        echo "[INFO] Incoming port recovered after escalation, re-validating all conditions..."
      else
        echo "[WARN] Recovery failed, checking again in ${POLL_DELAY} seconds..."
      fi
      # Always sleep before re-checking, regardless of recovery outcome.
      # This prevents a busy-loop when check() fails for a non-port reason
      # (e.g. adapter name/IP missing) while the port is healthy — in that
      # case ensure_incoming_port returns immediately, and without the sleep
      # the loop would spin at 100% CPU re-entering check().
      sleep "${POLL_DELAY}"
      continue
    fi

    local port_verify_retry_count=0

    while ! external_verify_incoming_port; do

      port_verify_retry_count=$((port_verify_retry_count + 1))

      if [[ ${port_verify_retry_count} -ge ${MAX_PORT_VERIFY_RETRIES} ]]; then
        echo "[WARN] Maximum port verification retries (${MAX_PORT_VERIFY_RETRIES}) reached, VPN port not verified - executing application without VPN port configuration: '${APP_PARAMETERS[*]}'..."
        exec "${APP_PARAMETERS[@]}"
      fi

      if ! restart_vpn_connection; then
        continue
      fi

      # wait for VPN to stabilize and get new port
      echo "[INFO] Waiting 10 seconds for VPN to stabilize before getting new incoming port..."
      sleep 10

      # get potentially new incoming port after VPN restart
      get_incoming_port

      if [[ -n "${INCOMING_PORT}" ]]; then
        echo "[INFO] Retrieved incoming port '${INCOMING_PORT}' after VPN restart"
        break
      fi

    done

    if [[ "${INCOMING_PORT}" != "${PREVIOUS_INCOMING_PORT}" ]] || ! application_verify_incoming_port; then

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

# Escalation handler for when get_incoming_port() fails (port=0 or unreachable).
# Retries, then restarts the VPN connection and retries again.
# Returns 0 if a valid port was obtained, 1 if recovery failed.
function ensure_incoming_port() {

  local max_retries="${1:-3}"
  local retry_count=0

  # Phase 1: Retry getting the port (may recover on its own)
  while [[ ${retry_count} -lt ${max_retries} ]]; do
    echo "[WARN] Attempting to retrieve incoming port (attempt $((retry_count + 1))/${max_retries})..."
    if get_incoming_port; then
      return 0
    fi
    retry_count=$((retry_count + 1))
    if [[ ${retry_count} -lt ${max_retries} ]]; then
      sleep 10
    fi
  done

  # Phase 2: Restart VPN connection via gluetun Control Server API
  echo "[WARN] Port not available after ${max_retries} retries, restarting VPN connection..."
  if ! restart_vpn_connection; then
    echo "[ERROR] Failed to restart VPN connection via gluetun API"
    return 1
  fi

  echo "[INFO] Waiting 10 seconds for VPN to stabilize after restart..."
  sleep 10

  # Phase 3: Retry after the VPN restart (incorporates the single
  # post-restart attempt that used to precede this phase)
  echo "[WARN] Re-checking incoming port after VPN restart..."
  retry_count=0
  while [[ ${retry_count} -lt ${max_retries} ]]; do
    echo "[WARN] Attempting to retrieve incoming port after VPN restart (attempt $((retry_count + 1))/${max_retries})..."
    if get_incoming_port; then
      echo "[INFO] Incoming port recovered after VPN restart and retries"
      return 0
    fi
    retry_count=$((retry_count + 1))
    if [[ ${retry_count} -lt ${max_retries} ]]; then
      sleep 10
    fi
  done

  echo "[ERROR] Incoming port not available after VPN restart and multiple retries"

  # Phase 4: Final escalation — stop VPN to trigger gluetun container restart.
  # Stops the VPN via gluetun Control Server API. This causes gluetun's
  # Docker healthcheck (queries health server every 5s) to return 500,
  # marking the container unhealthy. The watchdog restarts gluetun,
  # giving us a fresh VPN connection and a new port from PIA.
  #
  # A cooldown file prevents this from firing more than once per 5 minutes,
  # avoiding repeated gluetun restarts in a tight loop.
  local cooldown_file="/tmp/gluetun_escalation_cooldown"
  local cooldown_seconds="${GLUETUN_ESCALATION_COOLDOWN}"  # resolves to module-level default (300s)

  if [[ -f "${cooldown_file}" ]]; then
    local last_escalation
    last_escalation=$(cat "${cooldown_file}")
    local now
    now=$(date +%s)
    local elapsed=$((now - last_escalation))
    if [[ ${elapsed} -lt ${cooldown_seconds} ]]; then
      echo "[WARN] Skipping Phase 4 escalation — cooldown active ($((cooldown_seconds - elapsed))s remaining)"
      echo "[ERROR] Incoming port not available after all escalation phases exhausted"
      return 1
    fi
  fi

  echo "[WARN] Phase 4: Stopping VPN to trigger gluetun container restart (final escalation)..."

  # Only write flag files AFTER the API call succeeds — otherwise we'd suppress
  # the healthcheck while no actual escalation action was taken.
  if ! set_vpn_status "stopped"; then
    echo "[ERROR] Phase 4 escalation failed — could not stop VPN via gluetun API"
    echo "[ERROR] Incoming port not available after all escalation phases exhausted"
    return 1
  fi

  # Write the escalation_attempted flag FIRST, then the cooldown file.
  # If a crash occurs between the two writes, the escalation flag exists
  # (healthcheck suppresses) but the cooldown is missing (Phase 4 can
  # re-fire). This is safe — the alternative (cooldown exists but flag
  # missing) would permanently block both escalation AND suppression.
  local ts; ts=$(date +%s)
  echo "${ts}" > /tmp/gluetun_escalation_attempted
  echo "${ts}" > "${cooldown_file}"

  echo "[WARN] VPN stopped via gluetun API. Waiting for Docker healthcheck to detect failure..."
  echo "[WARN] Watchdog should restart gluetun container with a fresh VPN connection."
  echo "[ERROR] Incoming port not available after all escalation phases exhausted"
  return 1
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

  # set listening port to vpn port
  /usr/bin/deluge-console -c /config "config --set random_port false" 2>/dev/null
  /usr/bin/deluge-console -c /config "config --set listen_ports (${INCOMING_PORT},${INCOMING_PORT})" 2>/dev/null

  local vpn_adapter_name
  vpn_adapter_name=$(get_vpn_adapter_name)

  # set network interface for incoming and outgoing traffic to vpn adapter name
  /usr/bin/deluge-console -c /config "config --set listen_interface ${vpn_adapter_name}" 2>/dev/null
  /usr/bin/deluge-console -c /config "config --set outgoing_interface ${vpn_adapter_name}" 2>/dev/null

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

function qbittorrent_api_login() {

  # identify protocol
  local web_protocol="http"
  if grep -q 'WebUI\\HTTPS\\Enabled=true' "${QBITTORRENT_CONFIG_FILEPATH}" 2>/dev/null; then
    web_protocol="https"
  fi

  local cookie_jar="${defaultQbittorrentCookieJar}"

  # Determine which password to use for API auth:
  #   1. QBITTORRENT_WEBUI_PASSWORD (from env var / template arg) — highest priority
  #   2. QBITTORRENT_AUTO_PASSWORD (auto-generated in edit_config when no existing password)
  #   3. Neither — can't authenticate
  local login_password="${QBITTORRENT_WEBUI_PASSWORD}"
  if [[ -z "${login_password}" ]]; then
    login_password="${QBITTORRENT_AUTO_PASSWORD}"
  fi

  if [[ -z "${login_password}" ]]; then
    echo "[WARN] No qBittorrent WebUI password available for API authentication."
    echo "[WARN] Set QBITTORRENT_WEBUI_PASSWORD env var to enable API-based port configuration."
    return 1
  fi

  if [[ "${DEBUG}" == "yes" ]]; then
    echo "[DEBUG] Authenticating with qBittorrent WebUI API at ${web_protocol}://localhost:${WEBUI_PORT}..."
  fi

  # login and capture SID cookie
  rm -f "${cookie_jar}"

  local login_response
  login_response=$(curl_with_retry "${web_protocol}://localhost:${WEBUI_PORT}/api/v2/auth/login" 3 2 -k -s \
    -c "${cookie_jar}" \
    --header "Referer: ${web_protocol}://localhost:${WEBUI_PORT}" \
    --data-urlencode "username=${QBITTORRENT_WEBUI_USER}" \
    --data-urlencode "password=${login_password}")

  if [[ ! -f "${cookie_jar}" ]] || ! grep -q "SID" "${cookie_jar}" 2>/dev/null; then
    echo "[WARN] Failed to authenticate with qBittorrent API (response: '${login_response}')"
    return 1
  fi

  if [[ "${DEBUG}" == "yes" ]]; then
    echo "[DEBUG] Successfully authenticated with qBittorrent WebUI API"
  fi

  return 0

}

function qbittorrent_start() {

  echo "[INFO] Starting '${APP_NAME}' with VPN incoming port '${INCOMING_PORT}'..."
  start_process_background

}

function qbittorrent_edit_config() {

  local qbittorrent_config_dir
  qbittorrent_config_dir="$(dirname "${QBITTORRENT_CONFIG_FILEPATH}")"

  # ensure config directory exists
  mkdir -p "${qbittorrent_config_dir}"

  # Ensure config file exists on disk before qBittorrent starts.
  # On first run we copy the pre-generated template (has VPN binding, UPnP=false, etc.);
  # on subsequent runs the config from the previous session is already present.
  local qbittorrent_template_config="/home/nobody/qbittorrent/config/qBittorrent.conf"

  if [[ ! -f "${QBITTORRENT_CONFIG_FILEPATH}" ]]; then
    if [[ ! -f "${qbittorrent_template_config}" ]]; then
      echo "[warn] qBittorrent template config not found at '${qbittorrent_template_config}'"
      echo "[warn] Cannot pre-configure WebUI credentials; qBittorrent will generate a temporary password"
      return 1
    fi
    if [[ "${DEBUG}" == "yes" ]]; then
      echo "[DEBUG] Copying pre-generated config from '${qbittorrent_template_config}'"
    fi
    cp "${qbittorrent_template_config}" "${QBITTORRENT_CONFIG_FILEPATH}"
  fi

  # Remove obsolete LocalHostAuth setting (removed in qBittorrent 5)
  sed -i '/^WebUI\\LocalHostAuth/d' "${QBITTORRENT_CONFIG_FILEPATH}"

  # Always update the username (harmless — this is the login name, not a secret)
  if grep -q '^WebUI\\Username' "${QBITTORRENT_CONFIG_FILEPATH}"; then
    sed -i "s~^WebUI\\Username.*~WebUI\\\\Username=${QBITTORRENT_WEBUI_USER}~" "${QBITTORRENT_CONFIG_FILEPATH}"
  else
    sed -i "/^\\[Preferences\\]/a\\WebUI\\\\Username=${QBITTORRENT_WEBUI_USER}" "${QBITTORRENT_CONFIG_FILEPATH}"
  fi

  # ── Password handling ─────────────────────────────────────────────────
  # CRITICAL: Never overwrite an existing Password_PBKDF2 in the user's config.
  # If the user already has a WebUI password set, overwriting it would lock them
  # out of the WebUI on next restart — a support nightmare.
  #
  # Rules:
  #   1. If Password_PBKDF2 already has a value in the config → leave it alone.
  #      The user's existing password is preserved. We can't extract the plaintext
  #      from the PBKDF2 hash, so API auth will only work if QBITTORRENT_WEBUI_PASSWORD
  #      env var is provided.
  #   2. If Password_PBKDF2 is absent/empty → we are the first to set it.
  #      Auto-generate a password, store its PBKDF2 hash in the config, and save
  #      the plaintext in QBITTORRENT_AUTO_PASSWORD for later API login.
  #   3. If QBITTORRENT_WEBUI_PASSWORD env var is provided → it takes priority for
  #      API auth regardless, but we still don't overwrite an existing hash in the
  #      config (the user would change it via the WebUI preferences if they wanted to).

  local existing_password_hash
  existing_password_hash=$(grep '^WebUI\\Password_PBKDF2' "${QBITTORRENT_CONFIG_FILEPATH}" 2>/dev/null | cut -d= -f2-)

  if [[ -n "${existing_password_hash}" ]]; then
    # Password already exists in config — preserve it
    if [[ "${DEBUG}" == "yes" ]]; then
      echo "[DEBUG] WebUI password already set in config, preserving existing credentials"
    fi
    if [[ -n "${QBITTORRENT_WEBUI_PASSWORD}" ]]; then
      echo "[info] Using QBITTORRENT_WEBUI_PASSWORD from env var for API authentication"
    else
      echo "[info] WebUI password already configured. To enable API-based port configuration,"
      echo "[info] set QBITTORRENT_WEBUI_PASSWORD env var to match your qBittorrent WebUI password."
    fi
    return 0
  fi

  # No existing password — determine what plaintext to use
  local qbittorrent_password="${QBITTORRENT_WEBUI_PASSWORD}"

  if [[ -z "${qbittorrent_password}" ]]; then
    # No password supplied via env var or arg; auto-generate one (9 chars, matching qBittorrent's own approach)
    if command -v python3 &> /dev/null; then
      qbittorrent_password="$(python3 -c "
import secrets
alphabet = '23456789ABCDEFGHIJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz'
print(''.join(secrets.choice(alphabet) for _ in range(9)))
")"
    else
      # fallback: use openssl rand
      qbittorrent_password="$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 9)"
    fi
    echo "[info] QBITTORRENT_WEBUI_PASSWORD not set, auto-generated password: ${qbittorrent_password}"
    echo "[info] Set QBITTORRENT_WEBUI_PASSWORD env var to use a custom password"
  fi

  # Store plaintext for later API login
  QBITTORRENT_AUTO_PASSWORD="${qbittorrent_password}"

  # generate PBKDF2-SHA512 hash
  local pbkdf2_hash
  if command -v python3 &> /dev/null; then
    pbkdf2_hash="$(QBITTORRENT_PBKDF2_PASSWORD="${qbittorrent_password}" python3 -c "
import os
import hashlib
import base64

password = os.environ['QBITTORRENT_PBKDF2_PASSWORD'].encode()
salt = os.urandom(16)
iterations = 100000
dk = hashlib.pbkdf2_hmac('sha512', password, salt, iterations, dklen=64)

result = base64.b64encode(salt).decode('ascii') + ':' + base64.b64encode(dk).decode('ascii')
print(result)
")"
  else
    echo "[warn] python3 not available, cannot pre-hash qBittorrent password. API auth may fail."
    return 1
  fi

  if [[ -z "${pbkdf2_hash}" ]]; then
    echo "[warn] Failed to generate PBKDF2 hash for qBittorrent password"
    return 1
  fi

  # Write Password_PBKDF2 to config
  if grep -q '^WebUI\\Password_PBKDF2' "${QBITTORRENT_CONFIG_FILEPATH}"; then
    sed -i "s~^WebUI\\Password_PBKDF2.*~WebUI\\\\Password_PBKDF2=${pbkdf2_hash}~" "${QBITTORRENT_CONFIG_FILEPATH}"
  else
    sed -i "/^\\[Preferences\\]/a\\WebUI\\\\Password_PBKDF2=${pbkdf2_hash}" "${QBITTORRENT_CONFIG_FILEPATH}"
  fi

  if [[ "${DEBUG}" == "yes" ]]; then
    echo "[DEBUG] qBittorrent config updated with new WebUI credentials"
  fi

}

function qbittorrent_api_config() {

  # identify protocol, used by curl to connect to api
  local web_protocol="http"
  if grep -q 'WebUI\\HTTPS\\Enabled=true' "${QBITTORRENT_CONFIG_FILEPATH}" 2>/dev/null; then
    web_protocol="https"
  fi

  local cookie_jar="${defaultQbittorrentCookieJar}"

  # authenticate first (required by qBittorrent 5+)
  if ! qbittorrent_api_login; then
    echo "[WARN] Unable to authenticate with qBittorrent API, port config may fail"
    return 1
  fi

  local vpn_adapter_name
  vpn_adapter_name=$(get_vpn_adapter_name)

  # Set network interface binding via API - use adapter name only if successfully retrieved
  local interface_json
  interface_json="{
    \"listen_port\": \"${INCOMING_PORT}\",
    \"web_ui_upnp\": false,
    \"upnp\": false,
    \"random_port\": false,
    \"current_network_interface\": \"${vpn_adapter_name}\",
    \"current_interface_name\": \"${vpn_adapter_name}\",
    \"bypass_local_auth\": true
  }"

  if [[ "${DEBUG}" == "yes" ]]; then
    echo "[DEBUG] Setting network interface binding: ${interface_json}"
  fi

  curl_with_retry "${web_protocol}://localhost:${WEBUI_PORT}/api/v2/app/setPreferences" 3 2 -k -s \
    -b "${cookie_jar}" \
    --header "Referer: ${web_protocol}://localhost:${WEBUI_PORT}" \
    -X POST -d "json=${interface_json}"

}

function qbittorrent_verify_incoming_port() {

  local web_protocol
  local current_port

  echo "[INFO] Verifying '${APP_NAME}' incoming port matches VPN port '${INCOMING_PORT}'"

  # identify protocol, used by curl to connect to api
  local web_protocol="http"
  if grep -q 'WebUI\\HTTPS\\Enabled=true' "${QBITTORRENT_CONFIG_FILEPATH}" 2>/dev/null; then
      web_protocol="https"
  fi

  local cookie_jar="${defaultQbittorrentCookieJar}"

  # authenticate first (required by qBittorrent 5+)
  if ! qbittorrent_api_login; then
    echo "[WARN] Unable to authenticate with qBittorrent API, cannot verify port"
    return 1
  fi

  # Get current preferences from qBittorrent API using curl_with_retry
  preferences_response=$(curl_with_retry "${web_protocol}://localhost:${WEBUI_PORT}/api/v2/app/preferences" 10 1 -k -s \
    -b "${cookie_jar}" \
    --header "Referer: ${web_protocol}://localhost:${WEBUI_PORT}")
  current_port=$(echo "${preferences_response}" | jq -r '.listen_port')

  # Check if the port was retrieved successfully
  if [[ "${current_port}" == "null" || -z "${current_port}" ]]; then
      echo "[WARN] Unable to retrieve current port from ${APP_NAME} API"
      return 1
  fi

  if [[ "${DEBUG}" == "yes" ]]; then
      echo "[DEBUG] Current ${APP_NAME} listen port: '${current_port}', Expected: '${INCOMING_PORT}'"
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

  -gcspa or --gluetun-control-server-password <password>
    Define the Gluetun Control Server password.
    No default.

  -gip or --gluetun-incoming-port <yes|no>
    Define whether to enable VPN port monitoring and application configuration.
    Defaults to '${defaultGluetunIncomingPort}'.

  -qbu or --qbittorrent-webui-user <username>
    Define the qBittorrent WebUI username for API authentication.
    Only used when APP_NAME is 'qbittorrent'.
    Defaults to '${defaultQbittorrentWebuiUser}'.

  -qbp or --qbittorrent-webui-password <password>
    Define the qBittorrent WebUI password for API authentication.
    Only used when APP_NAME is 'qbittorrent'. If left empty, a random password
    will be auto-generated and written to the config before qBittorrent starts.

  -pd or --poll-delay <seconds>
    Define the polling delay in seconds between incoming port checks.
    Defaults to '${defaultPollDelay}'.

  -msr or --max-startup-retries <number>
    Define the maximum number of startup retries before executing application without VPN configuration.
    Defaults to '${defaultMaxStartupRetries}'.

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
  QBITTORRENT_WEBUI_USER
    Set the qBittorrent WebUI username used to authenticate with the API.
    Only used when APP_NAME is 'qbittorrent'. Defaults to 'admin'.
  QBITTORRENT_WEBUI_PASSWORD
    Set the qBittorrent WebUI password used to authenticate with the API.
    Only used when APP_NAME is 'qbittorrent'. If empty, auto-generated.
  GLUETUN_INCOMING_PORT
    Set to 'yes' to enable VPN port monitoring and application configuration.
  POLL_DELAY
    Set the polling delay in seconds between incoming port checks.
  MAX_STARTUP_RETRIES
    Set the maximum number of startup retries before executing application without VPN configuration.
  GLUETUN_ESCALATION_COOLDOWN
    Set the cooldown period in seconds between Phase 4 escalation attempts (default: 300).
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

# ── Execution gate ────────────────────────────────────────────────
# Allow sourcing for testing without running argument parsing or main.
if [[ -z "${PORTSET_TEST_MODE}" ]]; then

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
    GLUETUN_INCOMING_PORT="${2}"
    shift
    ;;
  -qbu|--qbittorrent-webui-user)
    QBITTORRENT_WEBUI_USER="${2}"
    shift
    ;;
  -qbp|--qbittorrent-webui-password)
    QBITTORRENT_WEBUI_PASSWORD="${2}"
    shift
    ;;
  -pd|--poll-delay)
    POLL_DELAY="${2}"
    shift
    ;;
  -msr|--max-startup-retries)
    MAX_STARTUP_RETRIES="${2}"
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

fi
