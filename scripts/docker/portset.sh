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
readonly defaultMaxAppRestartAttempts="3"
readonly defaultGluetunEscalationCooldown="300"
readonly defaultQbittorrentWebuiUser="admin"
readonly defaultQbittorrentCookieJar="/tmp/qbittorrent_sid.txt"
readonly defaultQbittorrentAutoPasswordFilepath="/config/qBittorrent/config/.webui_auto_password"
readonly defaultQbittorrentAutoPasswordHashFilepath="/config/qBittorrent/config/.webui_auto_password_hash"

# auto-generated qBittorrent password (populated by qbittorrent_edit_config if no existing password in config)
QBITTORRENT_AUTO_PASSWORD=""

# consecutive application restart attempts for the current outage, reset once the
# application is observed running again
APPLICATION_RESTART_ATTEMPTS=0

# marker written around restart_vpn_connection()'s stop->start window. Its presence
# records that this script may have left the VPN stopped, so the startup repair can
# distinguish that from an operator-requested stop.
VPN_STOP_INTENT_FILE="${VPN_STOP_INTENT_FILE:-/tmp/portset_vpn_stop_intent}"

# timestamp of the last VPN escalation (cycle). Rate-limits recovery so a broken
# port forward is retried periodically instead of cycling the VPN every pass, and
# so the port-verification budget cannot latch off for the process lifetime.
VPN_ESCALATION_LAST_FILE="${VPN_ESCALATION_LAST_FILE:-/tmp/portset_vpn_escalation_last}"

# Phase 4 escalation cooldown file, shared with healthcheck.sh. Injectable so a
# test never touches the live escalation state.
GLUETUN_ESCALATION_COOLDOWN_FILE="${GLUETUN_ESCALATION_COOLDOWN_FILE:-/tmp/gluetun_escalation_cooldown}"

# number of VPN restarts performed in this process, used to avoid cycling the
# tunnel twice for the same fault
VPN_RESTART_COUNT=0

# in-process fallback for the escalation timestamp: if the state file cannot be
# written (read-only /tmp, full disk) the limiter must still work in memory
VPN_ESCALATION_LAST_TS=""

# consecutive port verification failures. Deliberately module scope: the counter
# must survive outer loop iterations or MAX_PORT_VERIFY_RETRIES can never fire.
# It is reset only after a successful verification, so reaching the cap cannot
# re-arm into another burst of VPN restarts on every pass.
PORT_VERIFY_RETRY_COUNT=0

# consecutive inconclusive reachability probes (third-party service unusable).
# An inconclusive probe must never consume the port recovery budget, but must not
# park the supervision loop forever either, so it is separately bounded.
INCONCLUSIVE_VERIFY_COUNT=0

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
MAX_APP_RESTART_ATTEMPTS="${MAX_APP_RESTART_ATTEMPTS:-${defaultMaxAppRestartAttempts}}"
GLUETUN_ESCALATION_COOLDOWN="${GLUETUN_ESCALATION_COOLDOWN:-${defaultGluetunEscalationCooldown}}"
QBITTORRENT_WEBUI_USER="${QBITTORRENT_WEBUI_USER:-${defaultQbittorrentWebuiUser}}"
QBITTORRENT_WEBUI_PASSWORD="${QBITTORRENT_WEBUI_PASSWORD:-}"
QBITTORRENT_AUTO_PASSWORD_FILEPATH="${QBITTORRENT_AUTO_PASSWORD_FILEPATH:-${defaultQbittorrentAutoPasswordFilepath}}"
QBITTORRENT_AUTO_PASSWORD_HASH_FILEPATH="${QBITTORRENT_AUTO_PASSWORD_HASH_FILEPATH:-${defaultQbittorrentAutoPasswordHashFilepath}}"

# source in image build info, includes tag name and app name
if [[ -f "${defaultImageBuildFilepath}" ]]; then
  echo "[INFO] Sourcing image build info from '${defaultImageBuildFilepath}'"
  # shellcheck disable=SC1090 # path is only known at runtime
  source "${defaultImageBuildFilepath}"
  # note that this will set env var APPNAME from source file, but we want APP_NAME for readability in this script
  # shellcheck disable=SC2153 # APPNAME is assigned by the sourced build info file
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
  # unquoted: auth can be empty or multi-word ('-u user:pass')
  # shellcheck disable=SC2086
  if ! curl_with_retry "${control_server_url}" 3 1 -s ${auth}; then
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
  fi

  # The main PID may have exited while the application is still running (apps that
  # daemonize), so fall back to matching the configured command, mirroring the
  # process check the container healthcheck already trusts.
  local app_command="${APP_PARAMETERS[0]:-}"
  local app_command_name="${app_command##*/}"
  if [[ -n "${app_command_name}" ]] && pgrep -x "${app_command_name}" >/dev/null 2>&1; then
    if [[ "${DEBUG}" == "yes" ]]; then
      echo "[DEBUG] Application matched by process name '${app_command_name}' (PID '${APPLICATION_PID}' has exited)"
    fi
    return 0
  fi

  echo "[WARN] Application with PID '${APPLICATION_PID}' is not running"
  return 1

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
  local public_ip
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
  if ! get_gluetun_forwarded_port 3 1; then
    return 1
  fi
  INCOMING_PORT="${GLUETUN_FORWARDED_PORT}"

  # a port outside 1-65535 (including the "0" gluetun reports when nothing is
  # forwarded) is not usable and must not be pushed into the application
  if [[ ! "${INCOMING_PORT}" =~ ^[0-9]+$ ]] || [[ ${INCOMING_PORT} -lt 1 ]] || [[ ${INCOMING_PORT} -gt 65535 ]]; then
    echo "[WARN] gluetun reported an unusable forwarded port '${INCOMING_PORT}'" >&2
    INCOMING_PORT=""
    return 1
  fi
  if [[ "${DEBUG}" == "yes" ]]; then
    echo "[DEBUG] Current incoming port for VPN tunnel is '${INCOMING_PORT}'"
  fi

  # Get public ip and location information from gluetun Control Server
  # unquoted: auth can be empty or multi-word
  # shellcheck disable=SC2086
  public_ip=$(curl_with_retry "${control_server_url}/publicip/ip" 3 1 -s ${auth})

  # The public IP is informational only: the forwarded port above is what matters,
  # so a metadata blip must not be reported as a port or VPN fault.
  if [[ -z "${public_ip}" ]]; then
    echo "[WARN] Unable to retrieve public IP information from gluetun Control Server API" >&2
    return 0
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

  # Bounded: a degraded tunnel must never freeze the supervision loop.
  result="$(curl_with_retry "https://ifconfig.co/port/${INCOMING_PORT}" 2 1 -s --connect-timeout 5 --max-time 15 | jq -r '.reachable' 2>/dev/null)"

  case "${result}" in
    true)
      echo "[INFO] External verification: Incoming port '${INCOMING_PORT}' is reachable."
      return 0
      ;;
    false)
      echo "[WARN] External verification: Incoming port '${INCOMING_PORT}' is NOT reachable."
      return 1
      ;;
    *)
      # Return 2 (unverifiable), not 1 (unreachable): a third party outage must
      # not be counted as a port failure and must not drive VPN recovery.
      echo "[WARN] External verification: service returned an unusable response ('${result}') for port '${INCOMING_PORT}', skipping recovery for this pass."
      return 2
      ;;
  esac

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
  # unquoted: auth can be empty or multi-word ('-u user:pass')
  # shellcheck disable=SC2086
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
    # A control server blip must not silently skip the restart: fall back to the
    # unconditional stop->start sequence rather than failing closed.
    echo "[WARN] Unable to determine current VPN status, falling back to stop then start"
    current_vpn_status="running"
  fi
  echo "[INFO] Current VPN status is '${current_vpn_status}'"

  local vpn_desired_states=()
  if [[ "${current_vpn_status}" == "stopped" ]]; then
    # A stopped VPN is only ours to restart when the stop-intent marker says this
    # script stopped it (interrupted restart or a Phase 4 escalation). Without the
    # marker the stop was requested by the operator, the gluetun API or its UI and
    # must be respected at runtime, not just at startup.
    if [[ ! -f "${VPN_STOP_INTENT_FILE}" ]]; then
      echo "[WARN] VPN is stopped and no stop intent was recorded by this script, leaving the operator-requested stop in place"
      return 1
    fi
    echo "[INFO] VPN is already stopped after our own stop intent, proceeding directly to start..."
    vpn_desired_states=("running")
  else
    vpn_desired_states=("stopped" "running")
  fi

  local json

  VPN_RESTART_COUNT=$((VPN_RESTART_COUNT + 1))

  for vpn_desired_state in "${vpn_desired_states[@]}"; do

    # Record the stop intent immediately before it happens, so the marker exists
    # whenever this script may have stopped the VPN (a failed PUT deliberately
    # keeps it). If the process dies inside the stop->start window gluetun keeps
    # the requested 'stopped' state, and the next start repairs it without
    # overriding an operator-requested stop.
    if [[ "${vpn_desired_state}" == "stopped" ]]; then
      if ! echo "$$" > "${VPN_STOP_INTENT_FILE}" 2>/dev/null; then
        echo "[ERROR] Unable to record the VPN stop intent in '${VPN_STOP_INTENT_FILE}', not stopping the VPN"
        return 1
      fi
    fi

    echo "[INFO] Setting VPN status to '${vpn_desired_state}' via gluetun Control Server API..."
    json="{
      \"status\": \"${vpn_desired_state}\"
    }"

    # unquoted: auth can be empty or multi-word ('-u user:pass')
    # shellcheck disable=SC2086
    if ! curl_with_retry "${control_server_url}/vpn/status" 3 2 -k -s ${auth} -X PUT -H "Content-Type: application/json" -d "${json}"; then
      echo "[ERROR] Failed to set VPN status to '${vpn_desired_state}'"
      # keep the stop-intent marker: the stop may have been applied even though the
      # response was lost, and ensure_vpn_running() clears it once the VPN is running
      return 1
    fi

    # Wait between state changes to allow VPN to process the command
    if [[ "${vpn_desired_state}" == "stopped" ]]; then
      echo "[INFO] Waiting 5 seconds for VPN to stop..."
      sleep 5
    fi

  done
  echo "[INFO] VPN connection successfully restarted."

  # the VPN is running again, so any pending stop-intent marker is satisfied
  rm -f "${VPN_STOP_INTENT_FILE}" 2>/dev/null
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
  # shellcheck source=utils.sh disable=SC1091
	source utils.sh

  # A non-numeric or zero cap silently disables the recovery it controls
  # (bash compares such values as 0), so normalise the knobs before use.
  MAX_STARTUP_RETRIES=$(validate_positive_integer MAX_STARTUP_RETRIES "${MAX_STARTUP_RETRIES}" "${defaultMaxStartupRetries}")
  MAX_PORT_VERIFY_RETRIES=$(validate_positive_integer MAX_PORT_VERIFY_RETRIES "${MAX_PORT_VERIFY_RETRIES}" "${defaultMaxPortVerifyRetries}")
  MAX_APP_RESTART_ATTEMPTS=$(validate_positive_integer MAX_APP_RESTART_ATTEMPTS "${MAX_APP_RESTART_ATTEMPTS}" "${defaultMaxAppRestartAttempts}")
  POLL_DELAY=$(validate_positive_integer POLL_DELAY "${POLL_DELAY}" "${defaultPollDelay}")
  GLUETUN_ESCALATION_COOLDOWN=$(validate_positive_integer GLUETUN_ESCALATION_COOLDOWN "${GLUETUN_ESCALATION_COOLDOWN}" "${defaultGluetunEscalationCooldown}")

  # An in-flight Phase 4 escalation wants gluetun left stopped until the watchdog
  # restarts it: wait that window out before repairing anything.
  local escalation_wait=0
  local escalation_wait_max=$(( (GLUETUN_ESCALATION_COOLDOWN * 2) / POLL_DELAY + 1 ))
  while gluetun_escalation_pending && [[ ${escalation_wait} -lt ${escalation_wait_max} ]]; do
    escalation_wait=$((escalation_wait + 1))
    echo "[WARN] Phase 4 escalation pending, waiting $(gluetun_escalation_remaining) seconds for the gluetun restart..."
    sleep "${POLL_DELAY}"
  done

  # repair a VPN left in the 'stopped' state by an interrupted restart before
  # waiting for a forwarded port that can never appear while the VPN is down
  if ! ensure_vpn_running; then
    echo "[WARN] VPN is not running, continuing with startup checks..."
  fi

  local startup_retry_count=0

  while true; do

    # run function to check all required conditions exist
    if ! check; then
      # An in-flight Phase 4 escalation deliberately leaves the VPN stopped until
      # the gluetun watchdog restarts it: wait it out instead of burning the
      # startup retry budget and then running the application unconfigured.
      if gluetun_escalation_pending; then
        echo "[WARN] Phase 4 escalation pending, waiting $(gluetun_escalation_remaining) seconds for the gluetun restart..."
        sleep "${POLL_DELAY}"
        continue
      fi

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
      # Application supervision must not depend on the VPN conditions: with both
      # the VPN and the app broken, the app would otherwise stay dead for the
      # whole outage (healthcheck suppression included).
      if ! check_process; then
        recover_unreachable_port
        local recover_conditions_status=$?
        if [[ ${recover_conditions_status} -eq 2 ]]; then
          echo "[ERROR] Application could not be restarted after ${MAX_APP_RESTART_ATTEMPTS} attempts"
        fi
        sleep "${POLL_DELAY}"
        continue
      fi

      # When check() fails (e.g. port=0 from gluetun, unreachable API,
      # missing VPN adapter), attempt recovery via the escalation handler.
      # The handler will retry the port query, and if still failing,
      # restart the VPN connection via gluetun Control Server API.
      # Respect an in-flight Phase 4 escalation: it deliberately stops the VPN so
      # gluetun's healthcheck fails and the watchdog restarts it. Restarting the
      # VPN here would undo that while healthcheck suppression stays armed.
      if gluetun_escalation_pending; then
        echo "[WARN] Phase 4 escalation pending, waiting $(gluetun_escalation_remaining) seconds for the gluetun restart..."
        sleep "${POLL_DELAY}"
        continue
      fi

      if ! vpn_escalation_due; then
        echo "[WARN] Required conditions not met, next recovery attempt in $(vpn_escalation_remaining) seconds..."
        sleep "${POLL_DELAY}"
        continue
      fi

      echo "[WARN] Required conditions not met, attempting recovery..."
      mark_vpn_escalation
      if ensure_incoming_port; then
        echo "[INFO] Incoming port available after recovery, re-validating all conditions..."
        APPLICATION_RESTART_ATTEMPTS=0
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

    while true; do

      # Application supervision comes first and never depends on the reachability
      # probe: a third-party outage must not stop a crashed application from being
      # restarted.
      if ! check_process; then
        recover_unreachable_port
        local recover_dead_status=$?
        if [[ ${recover_dead_status} -eq 2 ]]; then
          echo "[ERROR] Application could not be restarted after ${MAX_APP_RESTART_ATTEMPTS} attempts"
          echo "[ERROR] Continuing to poll; the container healthcheck will mark this container unhealthy"
          sleep "${POLL_DELAY}"
        elif [[ ${recover_dead_status} -ne 0 ]]; then
          sleep "${POLL_DELAY}"
        fi
        continue
      fi

      # The application is alive, so the crash-recovery budget for this outage is over.
      APPLICATION_RESTART_ATTEMPTS=0

      # A port rotated by the VPN provider cannot verify until it has been pushed
      # to the application, so hand control back to the configure step instead of
      # looping on an unreachable verdict forever.
      if [[ -n "${INCOMING_PORT}" ]] && [[ "${INCOMING_PORT}" != "${PREVIOUS_INCOMING_PORT}" ]]; then
        echo "[INFO] Forwarded port changed from '${PREVIOUS_INCOMING_PORT}' to '${INCOMING_PORT}', configuring application..."
        INCONCLUSIVE_VERIFY_COUNT=0
        break
      fi

      external_verify_incoming_port
      local verify_status=$?
      if [[ ${verify_status} -eq 0 ]]; then
        # the app is alive and the port verified: full budget available again
        APPLICATION_RESTART_ATTEMPTS=0
        INCONCLUSIVE_VERIFY_COUNT=0
        break
      fi

      # An unverifiable probe is not evidence of a port fault: it must not consume
      # the recovery budget or cycle the VPN, but it must also not park the loop
      # forever, so bail out to the outer loop after a bounded number of passes.
      if [[ ${verify_status} -eq 2 ]]; then
        INCONCLUSIVE_VERIFY_COUNT=$((INCONCLUSIVE_VERIFY_COUNT + 1))
        if [[ ${INCONCLUSIVE_VERIFY_COUNT} -gt ${MAX_PORT_VERIFY_RETRIES} ]]; then
          echo "[WARN] Port reachability could not be verified for ${INCONCLUSIVE_VERIFY_COUNT} passes, re-checking all conditions"
          INCONCLUSIVE_VERIFY_COUNT=0
          break
        fi
        sleep "${POLL_DELAY}"
        continue
      fi
      INCONCLUSIVE_VERIFY_COUNT=0

      if record_port_verify_failure; then
        if vpn_escalation_due; then
          local port_before_escalation="${INCOMING_PORT}"
          local vpn_restarts_before="${VPN_RESTART_COUNT}"
          local escalation_ok=1
          echo "[WARN] Port still unverified after ${MAX_PORT_VERIFY_RETRIES} attempts, escalating via ensure_incoming_port..."
          if ! ensure_incoming_port; then
            escalation_ok=0
            echo "[WARN] Port recovery failed, re-checking after ${POLL_DELAY} seconds..."
          fi
          # ensure_incoming_port only cycles the VPN when gluetun cannot report a
          # port at all. When it keeps reporting the SAME port while the forward is
          # dead, the tunnel itself has to be cycled - but only if the escalation
          # above neither cycled it (VPN_RESTART_COUNT) nor deliberately stopped it
          # for a gluetun restart (Phase 4 pending).
          if [[ ${escalation_ok} -eq 1 ]] && should_cycle_forward "${port_before_escalation}" "${vpn_restarts_before}"; then
            echo "[WARN] Forwarded port '${INCOMING_PORT}' unchanged and still unverified, cycling the VPN connection..."
            cycle_vpn_for_broken_forward || echo "[WARN] Failed to cycle the VPN connection, re-checking after ${POLL_DELAY} seconds..."
          fi
          mark_vpn_escalation
        else
          echo "[WARN] Port still unverified, next recovery attempt in $(vpn_escalation_remaining) seconds..."
        fi
        # Hand control back to the outer loop: it re-runs check() (refreshing
        # INCOMING_PORT from gluetun) and then reaches the configure gate, which
        # is the only code that can re-apply the port to the application. Looping
        # here instead would spin forever whenever the mismatch is app-side.
        reset_port_verify_failures
        INCONCLUSIVE_VERIFY_COUNT=0
        break
      fi

      # Below the cap: keep observing. Escalation happens only once the failure
      # budget is spent, so a single transient verdict cannot disturb the tunnel.
      echo "[INFO] Port forward verified unreachable (${PORT_VERIFY_RETRY_COUNT}/${MAX_PORT_VERIFY_RETRIES}), re-checking in ${POLL_DELAY} seconds..."
      sleep "${POLL_DELAY}"
    done

    # reached when the port verified, when a rotated port or a spent escalation
    # budget handed control back for reconfiguration, or when the probe stayed
    # inconclusive: in all cases start the counters fresh. Note the outer loop
    # re-runs check() (refreshing INCOMING_PORT) before the next configure attempt.
    reset_port_verify_failures

    # An empty INCOMING_PORT means gluetun reported nothing usable: configuring the
    # application with it would push an invalid listen port (or kill and restart a
    # healthy app with no port at all), so wait for the next outer pass instead.
    if [[ -n "${INCOMING_PORT}" ]] && { [[ "${INCOMING_PORT}" != "${PREVIOUS_INCOMING_PORT}" ]] || ! application_verify_incoming_port; }; then

      if [[ "${DEBUG}" == 'yes' ]]; then
        if [[ -z "${PREVIOUS_INCOMING_PORT}" ]]; then
          echo "[DEBUG] No previous VPN port forward found, assuming first run, configuring application..."
        else
          echo "[DEBUG] Previous VPN port forward '${PREVIOUS_INCOMING_PORT}' and current VPN port forward '${INCOMING_PORT}' are different, configuring application..."
        fi
      fi

      # skip configuration when the process is not running - supervise it first,
      # and back off when it cannot be restarted instead of spinning
      if ! check_process; then
        if ensure_application_running; then
          # give the restarted application time to bind before it is probed
          echo "[INFO] Waiting 10 seconds for the restarted application to settle..."
          sleep 10
        else
          sleep "${POLL_DELAY}"
        fi
        continue
      fi

      # configure applications incoming port
      if application_configure_incoming_port; then
        # only record success: a failed configure must be retried on the next pass
        PREVIOUS_INCOMING_PORT="${INCOMING_PORT}"
      else
        echo "[WARN] Failed to configure '${APP_NAME}' with incoming port '${INCOMING_PORT}', will retry"
      fi
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
  local cooldown_file="${GLUETUN_ESCALATION_COOLDOWN_FILE}"
  local cooldown_seconds="${GLUETUN_ESCALATION_COOLDOWN}"  # resolves to module-level default (300s)

  if [[ -f "${cooldown_file}" ]]; then
    local last_escalation
    last_escalation=$(cat "${cooldown_file}" 2>/dev/null)
    if [[ "${last_escalation}" =~ ^[0-9]+$ ]]; then
      local now
      now=$(date +%s)
      local elapsed=$((now - last_escalation))
      if [[ ${elapsed} -lt ${cooldown_seconds} ]]; then
        echo "[WARN] Skipping Phase 4 escalation — cooldown active ($((cooldown_seconds - elapsed))s remaining)"
        echo "[ERROR] Incoming port not available after all escalation phases exhausted"
        return 1
      fi
    fi
  fi

  echo "[WARN] Phase 4: Stopping VPN to trigger gluetun container restart (final escalation)..."

  # Record our own stop BEFORE it happens (mirrors restart_vpn_connection), so an
  # interrupted escalation is still repairable at the next start. If the marker
  # cannot be written, do not stop the VPN: an unattributable stop is unrecoverable.
  if ! echo "$$" > "${VPN_STOP_INTENT_FILE}" 2>/dev/null; then
    echo "[ERROR] Unable to record the VPN stop intent in '${VPN_STOP_INTENT_FILE}', skipping Phase 4 escalation"
    echo "[ERROR] Incoming port not available after all escalation phases exhausted"
    return 1
  fi

  # Only write the suppression flag files AFTER the API call succeeds — otherwise
  # we'd suppress the healthcheck while no actual escalation action was taken.
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

function ensure_vpn_running() {

  # A VPN left in the 'stopped' state by an interrupted restart is not repaired
  # by the startup path: the gluetun Control Server keeps the requested state
  # until it is told otherwise. This happens when a restart is interrupted
  # between the stop and start calls (for example the container is restarted
  # during the 5 second stop wait), and it leaves no tunnel interface and no
  # forwarded port, so every later port query fails and the application never
  # starts.
  #
  # Only an interrupted restart of OUR making is repaired: the stop-intent marker
  # written by restart_vpn_connection() records that the stop came from this script,
  # so a deliberate operator stop (or an in-flight Phase 4 escalation) is respected.
  local max_attempts="${1:-3}"
  local attempt=0
  local vpn_status

  if [[ ! -f "${VPN_STOP_INTENT_FILE}" ]]; then
    echo "[INFO] No interrupted VPN restart recorded, leaving VPN state untouched"
    return 0
  fi

  # A marker older than twice the escalation cooldown is stale: the escalation it
  # belonged to (Phase 4) has long since been resolved by the gluetun watchdog, so
  # it must not override a later operator-requested stop.
  local marker_mtime=""
  if ! marker_mtime=$(stat -c %Y "${VPN_STOP_INTENT_FILE}" 2>/dev/null); then
    # unknown age must not be treated as ancient, or a repairable stop is lost
    echo "[WARN] Unable to read the stop-intent marker timestamp, treating it as current"
  elif [[ "${marker_mtime}" =~ ^[0-9]+$ ]]; then
    local marker_age=$(( $(date +%s) - marker_mtime ))
    if [[ ${marker_age} -gt $((GLUETUN_ESCALATION_COOLDOWN * 2)) ]]; then
      echo "[INFO] Discarding stale stop-intent marker (age ${marker_age}s)"
      rm -f "${VPN_STOP_INTENT_FILE}" 2>/dev/null
      return 0
    fi
  fi

  while [[ ${attempt} -lt ${max_attempts} ]]; do
    attempt=$((attempt + 1))

    if ! vpn_status=$(get_vpn_status); then
      # a transient control server blip must not abandon the repair
      echo "[WARN] Unable to determine VPN status via gluetun Control Server API (attempt ${attempt}/${max_attempts})"
      sleep 5
      continue
    fi

    if [[ "${vpn_status}" == "running" ]]; then
      echo "[INFO] VPN status is 'running'"
      rm -f "${VPN_STOP_INTENT_FILE}" 2>/dev/null
      return 0
    fi

    echo "[WARN] VPN status is '${vpn_status}' after an interrupted restart, setting VPN status to 'running' via gluetun Control Server API (attempt ${attempt}/${max_attempts})..."
    if ! set_vpn_status "running"; then
      echo "[ERROR] Failed to set VPN status to 'running'"
      return 1
    fi

    # give the tunnel time to establish before re-checking (not after the last attempt)
    if [[ ${attempt} -lt ${max_attempts} ]]; then
      sleep 5
    fi
  done

  # the last attempt may have succeeded after its own status check: re-verify
  if vpn_status=$(get_vpn_status) && [[ "${vpn_status}" == "running" ]]; then
    echo "[INFO] VPN status is 'running'"
    rm -f "${VPN_STOP_INTENT_FILE}" 2>/dev/null
    return 0
  fi

  echo "[ERROR] VPN status is not 'running' after ${max_attempts} attempts"
  return 1

}

function ensure_application_running() {

  # The application is started once and then supervised here. Without this a
  # crashed application is never restarted: nothing else in the container owns
  # the process (supervisord only supervises the start script), so the container
  # stays up with no application and no Web UI until the healthcheck fails.
  if check_process; then
    APPLICATION_RESTART_ATTEMPTS=0
    return 0
  fi

  APPLICATION_RESTART_ATTEMPTS=$((APPLICATION_RESTART_ATTEMPTS + 1))

  if [[ ${APPLICATION_RESTART_ATTEMPTS} -gt ${MAX_APP_RESTART_ATTEMPTS} ]]; then
    echo "[ERROR] Application is not running and ${MAX_APP_RESTART_ATTEMPTS} restart attempts were unsuccessful"
    echo "[ERROR] Leaving further recovery to the container healthcheck and watchdog"
    return 1
  fi

  echo "[WARN] Application is not running, restarting (attempt ${APPLICATION_RESTART_ATTEMPTS}/${MAX_APP_RESTART_ATTEMPTS})..."

  if ! application_start; then
    # For qbittorrent/deluge this status is the WebUI port wait, so a slow-binding
    # but alive application must not be counted as a failed restart.
    echo "[WARN] Start command for '${APP_NAME}' did not confirm readiness, checking the process"
  fi

  # a start command that returns successfully can still leave the process dead
  if ! check_process; then
    echo "[WARN] Application is still not running after restart attempt ${APPLICATION_RESTART_ATTEMPTS}/${MAX_APP_RESTART_ATTEMPTS}"
    return 1
  fi

  return 0

}

function should_cycle_forward() {

  # The application is alive and the port could not be verified. Cycling the VPN is
  # only justified when nothing else already acted: no VPN restart during the
  # escalation, no Phase 4 escalation in flight, and the forwarded port unchanged
  # (a changed or empty port means gluetun is reporting something new).
  local port_before="${1:-}"
  local restarts_before="${2:-0}"

  if [[ "${VPN_RESTART_COUNT}" -ne "${restarts_before}" ]]; then
    return 1
  fi

  if gluetun_escalation_pending; then
    return 1
  fi

  [[ -n "${INCOMING_PORT}" ]] || return 1
  [[ "${INCOMING_PORT}" == "${port_before}" ]]

}

function cycle_vpn_for_broken_forward() {

  # Single implementation of "the application is alive but the forwarded port is
  # not": gate on the Phase 4 window, rate-limit, cycle, then re-read the port.
  if gluetun_escalation_pending; then
    echo "[INFO] Phase 4 escalation pending, leaving the VPN alone"
    return 1
  fi

  if ! vpn_escalation_due; then
    echo "[INFO] Port recovery is cooling down, next attempt in $(vpn_escalation_remaining) seconds..."
    return 1
  fi

  mark_vpn_escalation

  if ! restart_vpn_connection; then
    echo "[WARN] Failed to restart VPN connection"
    return 1
  fi

  echo "[INFO] Waiting 10 seconds for VPN to stabilize before getting new incoming port..."
  sleep 10
  if get_incoming_port; then
    echo "[INFO] Retrieved incoming port '${INCOMING_PORT}' after VPN restart"
  else
    echo "[WARN] Unable to retrieve a new incoming port after VPN restart, previous port '${INCOMING_PORT}' may be stale"
  fi
  return 0

}

function recover_unreachable_port() {

  # An unreachable forwarded port has two distinct causes and they must not be
  # conflated:
  #   1. the application is dead - nothing is listening, so cycling the VPN can
  #      never make the port reachable; restart the application instead.
  #   2. the application is alive but the port forward is broken - cycle the VPN.
  # Returns 0 when recovery was attempted, 1 when the VPN restart failed,
  # 2 when the application could not be restarted.
  if ! check_process; then
    echo "[WARN] Application is not running, restarting application instead of restarting VPN..."
    if ensure_application_running; then
      # a fresh app is a fresh episode: pre-crash port failures must not count
      reset_port_verify_failures
      # give the restarted application time to bind before the port is re-probed
      echo "[INFO] Waiting 10 seconds for the restarted application to settle..."
      sleep 10
      return 0
    fi

    # The attempt failed. Only report an unrecoverable state once the budget for
    # this outage is spent; otherwise the caller retries after its poll delay.
    if [[ ${APPLICATION_RESTART_ATTEMPTS} -gt ${MAX_APP_RESTART_ATTEMPTS} ]]; then
      return 2
    fi

    echo "[WARN] Application restart attempt ${APPLICATION_RESTART_ATTEMPTS}/${MAX_APP_RESTART_ATTEMPTS} failed, retrying later"
    return 1
  fi

  # The application is alive, so any previous crash outage is over: the restart
  # budget must be restored or the cap would act as a lifetime limit.
  APPLICATION_RESTART_ATTEMPTS=0

  cycle_vpn_for_broken_forward

}

function record_port_verify_failure() {

  PORT_VERIFY_RETRY_COUNT=$((PORT_VERIFY_RETRY_COUNT + 1))

  if [[ ${PORT_VERIFY_RETRY_COUNT} -ge ${MAX_PORT_VERIFY_RETRIES} ]]; then
    return 0
  fi
  return 1

}

function reset_port_verify_failures() {

  PORT_VERIFY_RETRY_COUNT=0

}

function validate_positive_integer() {

  # Returns the value when it is a positive integer, otherwise the fallback, so a
  # typo'd or zero cap cannot silently disable the recovery it controls.
  local name="${1}"
  local value="${2}"
  local fallback="${3}"

  if [[ "${value}" =~ ^[0-9]+$ ]] && [[ ${value} -gt 0 ]]; then
    echo "${value}"
    return 0
  fi

  echo "[WARN] '${name}' value '${value}' is not a positive integer, using default '${fallback}'" >&2
  echo "${fallback}"
  return 0

}

function vpn_escalation_due() {

  local last_escalation=""

  if [[ -f "${VPN_ESCALATION_LAST_FILE}" ]]; then
    last_escalation=$(cat "${VPN_ESCALATION_LAST_FILE}" 2>/dev/null)
  fi
  if [[ ! "${last_escalation}" =~ ^[0-9]+$ ]]; then
    last_escalation="${VPN_ESCALATION_LAST_TS}"
  fi

  # No previous escalation means the first one is always allowed.
  if [[ ! "${last_escalation}" =~ ^[0-9]+$ ]]; then
    return 0
  fi


  local now elapsed
  now=$(date +%s)
  elapsed=$((now - last_escalation))
  [[ ${elapsed} -ge ${GLUETUN_ESCALATION_COOLDOWN} ]]

}

function vpn_escalation_remaining() {

  local remaining=0
  local last_escalation=""

  if [[ -f "${VPN_ESCALATION_LAST_FILE}" ]]; then
    last_escalation=$(cat "${VPN_ESCALATION_LAST_FILE}" 2>/dev/null)
  fi
  if [[ ! "${last_escalation}" =~ ^[0-9]+$ ]]; then
    last_escalation="${VPN_ESCALATION_LAST_TS}"
  fi

  if [[ "${last_escalation}" =~ ^[0-9]+$ ]]; then
    local now
    now=$(date +%s)
    remaining=$((GLUETUN_ESCALATION_COOLDOWN - (now - last_escalation)))
    [[ ${remaining} -gt 0 ]] || remaining=0
  fi

  echo "${remaining}"

}

function mark_vpn_escalation() {

  VPN_ESCALATION_LAST_TS=$(date +%s)
  echo "${VPN_ESCALATION_LAST_TS}" > "${VPN_ESCALATION_LAST_FILE}" 2>/dev/null || true

}

function gluetun_escalation_pending() {

  # Phase 4 (ensure_incoming_port) stops the VPN and relies on the gluetun
  # healthcheck and watchdog to restart it, suppressing this container's own
  # unhealthy verdict for twice the cooldown. While that window is open, portset
  # must not restart the VPN itself or the escalation is silently undone.
  local cooldown_file="${GLUETUN_ESCALATION_COOLDOWN_FILE}"

  [[ -f "${cooldown_file}" ]] || return 1

  local last_escalation
  last_escalation=$(cat "${cooldown_file}" 2>/dev/null)
  [[ "${last_escalation}" =~ ^[0-9]+$ ]] || return 1

  # Must match healthcheck.sh's suppression window, which is twice the cooldown:
  # while that window is open the escalation is still in flight (gluetun is meant
  # to be restarted by the watchdog) and portset must not restart the VPN itself.
  local now
  now=$(date +%s)
  [[ $((now - last_escalation)) -lt $((GLUETUN_ESCALATION_COOLDOWN * 2)) ]]

}

function gluetun_escalation_remaining() {

  local cooldown_file="${GLUETUN_ESCALATION_COOLDOWN_FILE}"
  local remaining=0

  if [[ -f "${cooldown_file}" ]]; then
    local last_escalation
    last_escalation=$(cat "${cooldown_file}" 2>/dev/null)
    if [[ "${last_escalation}" =~ ^[0-9]+$ ]]; then
      local now
      now=$(date +%s)
      remaining=$(((GLUETUN_ESCALATION_COOLDOWN * 2) - (now - last_escalation)))
      [[ ${remaining} -gt 0 ]] || remaining=0
    fi
  fi

  echo "${remaining}"

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

  # identify the configured protocol from the Deluge web config (the port itself
  # is read from the Deluge console, not from the API)
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

  # login and capture SID cookie; pre-created 0600 so the session id is never
  # readable by other users in the container, even briefly
  rm -f "${cookie_jar}"
  ( umask 077; : > "${cookie_jar}" ) 2>/dev/null

  # The credentials go through a private curl config file rather than argv, so the
  # password never appears in /proc/<pid>/cmdline. A file (not stdin) is required
  # because curl_with_retry re-invokes curl on retry, and stdin is consumed by the
  # first attempt.
  if [[ "${QBITTORRENT_WEBUI_USER}" == *$'\n'* ]] || [[ "${login_password}" == *$'\n'* ]]; then
    echo "[WARN] WebUI credentials contain a newline, refusing to build a curl config"
    return 1
  fi

  local login_config
  login_config=$(mktemp -t qbittorrent_login.XXXXXX) || return 1
  chmod 600 "${login_config}" 2>/dev/null
  {
    # escape backslashes first, then double quotes: curl's config parser honours
    # both inside a quoted value
    local safe_user="${QBITTORRENT_WEBUI_USER//\\/\\\\}"
    local safe_password="${login_password//\\/\\\\}"
    printf 'data-urlencode = "username=%s"\n' "${safe_user//\"/\\\"}"
    printf 'data-urlencode = "password=%s"\n' "${safe_password//\"/\\\"}"
  } > "${login_config}" 2>/dev/null

  local login_response
  login_response=$(curl_with_retry "${web_protocol}://localhost:${WEBUI_PORT}/api/v2/auth/login" 3 2 -k -s \
    -c "${cookie_jar}" \
    --header "Referer: ${web_protocol}://localhost:${WEBUI_PORT}" \
    -K "${login_config}")

  rm -f "${login_config}" 2>/dev/null

  # the session id is a credential: keep it owner-readable only
  [[ -f "${cookie_jar}" ]] && chmod 600 "${cookie_jar}" 2>/dev/null

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

  # Always update the username (harmless — this is the login name, not a secret).
  # Escape sed metacharacters once and use the result in both branches.
  local safe_username="${QBITTORRENT_WEBUI_USER//\\/\\\\}"
  safe_username="${safe_username//&/\\&}"
  safe_username="${safe_username//~/\\~}"
  if grep -q '^WebUI\\Username' "${QBITTORRENT_CONFIG_FILEPATH}"; then
    sed -i "s~^WebUI\\\\Username.*~WebUI\\\\Username=${safe_username}~" "${QBITTORRENT_CONFIG_FILEPATH}"
  else
    sed -i "/^\\[Preferences\\]/a\\WebUI\\\\Username=${safe_username}" "${QBITTORRENT_CONFIG_FILEPATH}"
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

  local password_generated="no"
  local existing_password_hash
  existing_password_hash=$(grep '^WebUI\\Password_PBKDF2' "${QBITTORRENT_CONFIG_FILEPATH}" 2>/dev/null | cut -d= -f2-)

  if [[ -n "${existing_password_hash}" ]]; then
    # Password already exists in config — preserve it
    if [[ "${DEBUG}" == "yes" ]]; then
      echo "[DEBUG] WebUI password already set in config, preserving existing credentials"
    fi
    if [[ -n "${QBITTORRENT_WEBUI_PASSWORD}" ]]; then
      echo "[info] Using QBITTORRENT_WEBUI_PASSWORD from env var for API authentication"
    elif [[ -r "${QBITTORRENT_AUTO_PASSWORD_FILEPATH}" ]] && [[ -r "${QBITTORRENT_AUTO_PASSWORD_HASH_FILEPATH}" ]]; then
      # A password generated by an earlier run: reuse it only when the stored hash
      # still matches the config, otherwise the user changed it and we must not
      # keep retrying a password that cannot work.
      local persisted_hash
      persisted_hash=$(cat "${QBITTORRENT_AUTO_PASSWORD_HASH_FILEPATH}" 2>/dev/null)
      if [[ -n "${persisted_hash}" ]] && [[ "${persisted_hash}" == "${existing_password_hash}" ]]; then
        QBITTORRENT_AUTO_PASSWORD="$(cat "${QBITTORRENT_AUTO_PASSWORD_FILEPATH}" 2>/dev/null)"
      fi
      if [[ -n "${QBITTORRENT_AUTO_PASSWORD}" ]]; then
        echo "[info] Reusing the previously generated qBittorrent WebUI password for API authentication"
      else
        echo "[info] WebUI password already configured. To enable API-based port configuration,"
        echo "[info] set QBITTORRENT_WEBUI_PASSWORD env var to match your qBittorrent WebUI password."
      fi
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
    password_generated="yes"
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
    sed -i "s~^WebUI\\\\Password_PBKDF2.*~WebUI\\\\Password_PBKDF2=${pbkdf2_hash}~" "${QBITTORRENT_CONFIG_FILEPATH}"
  else
    sed -i "/^\\[Preferences\\]/a\\WebUI\\\\Password_PBKDF2=${pbkdf2_hash}" "${QBITTORRENT_CONFIG_FILEPATH}"
  fi

  # Persist the generated password for later runs: the config only receives the
  # one-way hash, so without this the plaintext would be lost on the next start and
  # API-based port configuration would silently stop working. The sidecar hash
  # records which config hash the plaintext belongs to, so a user-changed password
  # is never overridden by a stale secret. Owner-readable only.
  if [[ -z "${QBITTORRENT_WEBUI_PASSWORD}" ]] && [[ -n "${QBITTORRENT_AUTO_PASSWORD_FILEPATH}" ]]; then
    if ( umask 077; echo "${QBITTORRENT_AUTO_PASSWORD}" > "${QBITTORRENT_AUTO_PASSWORD_FILEPATH}" ) 2>/dev/null; then
      chmod 600 "${QBITTORRENT_AUTO_PASSWORD_FILEPATH}" 2>/dev/null
      if ( umask 077; echo "${pbkdf2_hash}" > "${QBITTORRENT_AUTO_PASSWORD_HASH_FILEPATH}" ) 2>/dev/null; then
        chmod 600 "${QBITTORRENT_AUTO_PASSWORD_HASH_FILEPATH}" 2>/dev/null
      else
        echo "[WARN] Unable to persist the WebUI password hash marker, the generated password will not be reusable after a restart"
      fi
    else
      echo "[WARN] Unable to persist the generated WebUI password to '${QBITTORRENT_AUTO_PASSWORD_FILEPATH}', API port configuration will stop working after a restart"
    fi
  fi

  if [[ "${password_generated}" == "yes" ]] && grep -qF "${pbkdf2_hash}" "${QBITTORRENT_CONFIG_FILEPATH}" 2>/dev/null; then
    echo "[info] QBITTORRENT_WEBUI_PASSWORD not set, a random WebUI password was generated and written to the config"
    echo "[info] Set QBITTORRENT_WEBUI_PASSWORD env var to control the WebUI password (the value is never logged)"
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

  curl_with_retry "${web_protocol}://localhost:${WEBUI_PORT}/api/v2/app/setPreferences" 3 2 -k -s -f \
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
  -an or --app-name <deluge|qbittorrent|nicotineplus|slskd>
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
    Define the file path to the Nicotine+ configuration file (config).
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
    Only used when APP_NAME is 'qbittorrent'. If left empty the existing stored
    password is reused; a random password is generated and written to the config
    only when no password is stored there yet.

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
    Set the file path to the Nicotine+ configuration file (config).
  GLUETUN_CONTROL_SERVER_PORT
    Set the port for the Gluetun Control Server.
  GLUETUN_CONTROL_SERVER_USERNAME
    Set the username for Gluetun Control Server authentication.
  GLUETUN_CONTROL_SERVER_PASSWORD
    Set the password for Gluetun Control Server authentication.
  QBITTORRENT_WEBUI_USER
    Set the qBittorrent WebUI username used to authenticate with the API.
    Only used when APP_NAME is 'qbittorrent'. Defaults to 'admin'.
  QBITTORRENT_WEBUI_PASSWORD
    Set the qBittorrent WebUI password used to authenticate with the API.
    Only used when APP_NAME is 'qbittorrent'. If empty the existing stored
    password is reused; a random password is generated only when none is stored.
  GLUETUN_INCOMING_PORT
    Set to 'yes' to enable VPN port monitoring and application configuration.
  POLL_DELAY
    Set the polling delay in seconds between incoming port checks.
  MAX_STARTUP_RETRIES
    Set the maximum number of startup retries before executing application without VPN configuration.
  MAX_PORT_VERIFY_RETRIES
    Set the maximum number of consecutive port verification failures before escalating
    via the incoming port recovery handler (default: 3).
  MAX_APP_RESTART_ATTEMPTS
    Set the maximum number of consecutive application restart attempts before leaving
    recovery to the container healthcheck and watchdog (default: 3).
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
