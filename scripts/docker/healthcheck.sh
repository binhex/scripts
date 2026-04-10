#!/bin/bash

# Script to check DNS resolution, HTTPS connectivity and processes, with optional custom
# command and custom action defined via environment variables HEALTHCHECK_COMMAND and
# HEALTHCHECK_ACTION and exit script with appropriate exit code.
#
# This script is called via the Dockerfile HEALTHCHECK instruction.

function check_dns() {

	local hostname_check="${1}"
	shift

	echo "[info] Health checking DNS..."

	# check if DNS is working by resolving a known domain (ipv4 only)
	if ! nslookup "${hostname_check}" > /dev/null 2>&1; then
		echo "[warn] DNS resolution failed"
		return 1
	else
		echo "[info] DNS resolution is working."
		return 0
	fi
}

function check_https() {

	local hostname_check="${1}"
	shift

	echo "[info] Health checking HTTPS..."

	# check if HTTPS is working by making a request to a known URL
	if ! curl -s --head "https://${hostname_check}" > /dev/null; then
		echo "[warn] HTTPS request failed"
		return 1
	else
		echo "[info] HTTPS request is working."
		return 0
	fi
}

function check_process() {

	echo "[info] Health checking processes..."

	# get env vars from buildx arguments stored in /etc/image-build-info
	# shellcheck disable=SC1091
	source /etc/image-build-info

	if [[ -z "${APPNAME}" ]]; then
		echo "[warn] APPNAME is not defined, cannot check process."
		return 0
	else
		echo "[info] Application name is '${APPNAME}'."
	fi

	# notes
	# - portset can cause incorrect process running detection as process path will be a part of the arguments passed to portset
	# - novnc can also cause incorrect process running detection as it will be a part of the arguments passed to the process

	# convert app name into process name(s) to monitor
	local process_names=()
	if [[ "${APPNAME}" == 'bitmagnet' ]]; then
		process_names=('bitmagnet')
	elif [[ "${APPNAME}" == 'code-server' ]]; then
		process_names=('code-server')
	elif [[ "${APPNAME}" == 'crafty-4' ]]; then
		process_names=('python.*crafty.*')
	elif [[ "${APPNAME}" == 'deluge' ]]; then
		process_names=('^/usr/bin/python /usr/bin/deluged' '^deluge-web')
	elif [[ "${APPNAME}" == 'delugevpn' ]]; then
		process_names=('^/usr/bin/python /usr/bin/deluged' '^deluge-web' 'openvpn|wg')
	elif [[ "${APPNAME}" == 'emby' ]]; then
		process_names=('EmbyServer')
	elif [[ "${APPNAME}" == 'filebrowser' ]]; then
		process_names=('filebrowser')
	elif [[ "${APPNAME}" == 'flaresolverr' ]]; then
		process_names=('flaresolverr')
	elif [[ "${APPNAME}" == 'fleet' ]]; then
		process_names=('jetbrains-fleet')
	elif [[ "${APPNAME}" == 'goland' ]]; then
		process_names=('^/usr/sbin/goland')
	elif [[ "${APPNAME}" == 'gonic' ]]; then
		process_names=('gonic')
	elif [[ "${APPNAME}" == 'hexchat' ]]; then
		process_names=('^hexchat')
	elif [[ "${APPNAME}" == 'intellij' ]]; then
		process_names=('idea')
	elif [[ "${APPNAME}" == 'jackett' ]]; then
		process_names=('jackett')
	elif [[ "${APPNAME}" == 'jellyfin' ]]; then
		process_names=('jellyfin')
	elif [[ "${APPNAME}" == 'jenkins' ]]; then
		process_names=('jenkins')
	elif [[ "${APPNAME}" == 'krusader' ]]; then
		process_names=('^krusader')
	elif [[ "${APPNAME}" == 'libreoffice' ]]; then
		process_names=('^/usr/lib/libreoffice')
	elif [[ "${APPNAME}" == 'lidarr' ]]; then
		process_names=('Lidarr')
	elif [[ "${APPNAME}" == 'makemkv' ]]; then
		process_names=('^makemkv')
	elif [[ "${APPNAME}" == 'medusa' ]]; then
		process_names=('medusa')
	elif [[ "${APPNAME}" == 'minecraftbedrockserver' ]]; then
		process_names=('bedrock_server')
	elif [[ "${APPNAME}" == 'minecraftserver' ]]; then
		process_names=('^java.*minecraft.*')
	elif [[ "${APPNAME}" == 'minidlna' ]]; then
		process_names=('minidlnad')
	elif [[ "${APPNAME}" == 'nginx' ]]; then
		process_names=('nginx')
	elif [[ "${APPNAME}" == 'nicotineplus' ]]; then
		process_names=('^/usr/bin/python /usr/bin/nicotine')
	elif [[ "${APPNAME}" == 'nzbget' ]]; then
		process_names=('nzbget')
	elif [[ "${APPNAME}" == 'nzbhydra2' ]]; then
		process_names=('^java.*nzbhydra2.*')
	elif [[ "${APPNAME}" == 'overseerr' ]]; then
		process_names=('/usr/bin/node')
	elif [[ "${APPNAME}" == 'plex' ]]; then
		process_names=('Plex Media Server')
	elif [[ "${APPNAME}" == 'plexpass' ]]; then
		process_names=('Plex Media Server')
	elif [[ "${APPNAME}" == 'privoxyvpn' ]]; then
		process_names=('privoxy|microsocks' 'openvpn|wg')
	elif [[ "${APPNAME}" == 'prowlarr' ]]; then
		process_names=('Prowlarr')
	elif [[ "${APPNAME}" == 'pycharm' ]]; then
		process_names=('^/usr/share/pycharm')
	elif [[ "${APPNAME}" == 'qbittorrent' ]]; then
		process_names=('^/usr/bin/qbittorrent-nox')
	elif [[ "${APPNAME}" == 'qbittorrentvpn' ]]; then
		process_names=('^/usr/bin/qbittorrent-nox' 'openvpn|wg')
	elif [[ "${APPNAME}" == 'radarr' ]]; then
		process_names=('Radarr')
	elif [[ "${APPNAME}" == 'rclone' ]]; then
		process_names=('rclone')
	elif [[ "${APPNAME}" == 'readarr' ]]; then
		process_names=('Readarr')
	elif [[ "${APPNAME}" == 'resilio-sync' ]]; then
		process_names=('rslsync')
	elif [[ "${APPNAME}" == 'rider' ]]; then
		process_names=('^/usr/share/rider')
	elif [[ "${APPNAME}" == 'rustrover' ]]; then
		process_names=('^/opt/rustrover')
	elif [[ "${APPNAME}" == 'sabnzbd' ]]; then
		process_names=('python.*SABnzbd.*')
	elif [[ "${APPNAME}" == 'sabnzbdvpn' ]]; then
		process_names=('python.*SABnzbd.*' 'openvpn|wg')
	elif [[ "${APPNAME}" == 'siphonator' ]]; then
		process_names=('siphonator')
	elif [[ "${APPNAME}" == 'slskd' ]]; then
		process_names=('slskd')
	elif [[ "${APPNAME}" == 'sonarr' ]]; then
		process_names=('Sonarr')
	elif [[ "${APPNAME}" == 'syncthing' ]]; then
		process_names=('syncthing')
	elif [[ "${APPNAME}" == 'teamspeak' ]]; then
		process_names=('ts3server')
	elif [[ "${APPNAME}" == 'tvheadend' ]]; then
		process_names=('tvheadend')
	elif [[ "${APPNAME}" == 'urbackup' ]]; then
		process_names=('urbackupsrv')
	elif [[ "${APPNAME}" == 'webstorm' ]]; then
		process_names=('^/opt/webstorm')
	else
		echo "[info] Application name '${APPNAME}' not in the known list for process monitoring."
		return 0
	fi

	# loop over each process name in the array
	for process_name in "${process_names[@]}"; do

		# -f flag matches $process_name against the full command line (partial match)
		if pgrep -f "${process_name}" > /dev/null; then
			echo "[info] Process '${process_name}' is running."
		else
			echo "[warn] Process '${process_name}' is not running."
			return 1
		fi
	done
	return 0
}

# Checks a log file for error patterns within a recent time window.
# Continuation lines (e.g. .NET stack frames) are included when they follow a
# timestamped line that falls within the window, so multi-line exceptions are caught.
#
# Args: log_file [pattern ...]
# Env:  APP_LOG_CHECK_MINUTES  - window size in minutes (default: 5)
function check_app_logs() {

	local log_file="${1}"
	shift
	local error_patterns=("${@}")
	local window_minutes="${APP_LOG_CHECK_MINUTES:-5}"

	if [[ ! -f "${log_file}" ]]; then
		echo "[info] Log file '${log_file}' not found, skipping log check."
		return 0
	fi

	echo "[info] Health checking application logs (last ${window_minutes} minute(s))..."

	local cutoff
	cutoff=$(date -d "${window_minutes} minutes ago" '+%Y-%m-%d %H:%M')

	# Extract lines from the time window. Timestamped lines set in_window; continuation
	# lines (stack frames, inner exceptions) inherit the in_window state of the last
	# timestamped line, so multi-line exception blocks are captured in full.
	local recent_logs
	recent_logs=$(tail -n 10000 "${log_file}" | awk -v cutoff="${cutoff}" '
		/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]/ {
			in_window = (substr($0, 1, 16) >= cutoff)
		}
		in_window { print }
	')

	if [[ -z "${recent_logs}" ]]; then
		echo "[info] No log entries found within the last ${window_minutes} minute(s)."
		return 0
	fi

	for pattern in "${error_patterns[@]}"; do
		if echo "${recent_logs}" | grep -qi -- "${pattern}"; then
			echo "[warn] Error pattern '${pattern}' detected in recent application logs."
			return 1
		fi
	done

	echo "[info] No critical errors found in recent application logs."
	return 0
}

# Runs app-specific health checks based on APPNAME.
# Currently checks supervisord.log for network-related exceptions in apps that use
# supervisord. A network exception in the recent window means the app has lost
# connectivity and is silently failing, even though the process is still running.
function check_app_specific() {

	echo "[info] Health checking application-specific state..."

	# shellcheck disable=SC1091
	source /etc/image-build-info

	if [[ -z "${APPNAME}" ]]; then
		echo "[info] APPNAME is not defined, skipping app-specific checks."
		return 0
	fi

	local supervisord_log="/config/supervisord.log"

	# Network-specific exception class name and OS-level error messages.
	# Uses SocketException (the root .NET transport exception, low false-positive risk)
	# plus OS error strings unique to connectivity failures. Bare HttpRequestException
	# and WebException are intentionally excluded — they also fire on protocol-level
	# errors (4xx/5xx responses, auth rejections) that do not indicate a network outage.
	# TaskCanceledException is covered via 'HttpClient.Timeout' rather than the bare
	# exception name, which would also match routine request cancellations.
	local net_error_patterns=(
		# Root .NET exception for socket-level failures (DNS, connect, unreachable, EAGAIN)
		'SocketException'
		# OS error messages that accompany socket failures — unique to network failures
		'Resource temporarily unavailable'  # EAGAIN  (errno 11) — user's reported case
		'Network is unreachable'            # ENETUNREACH (errno 101)
		'No route to host'                  # EHOSTUNREACH (errno 113)
		'Name or service not known'         # DNS resolution failure
		'Connection timed out'              # ETIMEDOUT (errno 110)
		# HTTP client timeout: TaskCanceledException message specific to network timeouts
		'HttpClient.Timeout'
	)

	# Apps that write .NET exceptions to supervisord.log.
	local supervised_apps=('jackett' 'lidarr' 'prowlarr' 'radarr' 'readarr' 'sonarr')

	local app
	for app in "${supervised_apps[@]}"; do
		if [[ "${APPNAME}" == "${app}" ]]; then
			check_app_logs "${supervisord_log}" "${net_error_patterns[@]}"
			return "${?}"
		fi
	done

	return 0
}

function healthcheck_command() {

	local exit_code=0

	# source in curl_with_retry function and vpn ip and adapter name functions
	source utils.sh

	if [[ "${ENABLE_HEALTHCHECK,,}" != "yes" ]]; then
		echo "[info] Healthchecks are disabled via env var 'ENABLE_HEALTHCHECK', exiting script with exit code '0'"
		exit 0
	fi

	if [[ -n "${HEALTHCHECK_COMMAND}" ]]; then
		echo "[info] Running custom healthcheck command: ${HEALTHCHECK_COMMAND}"
		eval "${HEALTHCHECK_COMMAND}"
		exit_code="${?}"
	else
		# Set retry count from environment variable, set default if not set
		local max_retries="${HEALTHCHECK_RETRIES:-12}"
		local retry_count=0
		local retry_delay=5
		echo "[info] No custom healthcheck command defined via env var 'HEALTHCHECK_COMMAND', running default healthchecks..."

		if [[ -n "${HEALTHCHECK_HOSTNAME}" ]]; then
			local hostname_check="${HEALTHCHECK_HOSTNAME}"
		else
			local hostname_check="cloudflare.com"
		fi

		while [[ "${retry_count}" -lt "${max_retries}" ]]; do

			if [[ "${retry_count}" -gt 0 ]]; then
				echo "[info] Retry attempt ${retry_count}/${max_retries}, retrying in ${retry_delay} second(s)..."
				sleep "${retry_delay}"
			fi

			exit_code=0
			if ! check_dns "${hostname_check}"; then
				exit_code=1
			fi

			if ! check_https "${hostname_check}"; then
				exit_code=1
			fi

			if ! check_process; then
				exit_code=1
			fi

			if ! check_app_specific; then
				exit_code=1
			fi

			if [[ "${GLUETUN_INCOMING_PORT}" == "yes" ]]; then

				if ! vpn_adapter_name=$(get_vpn_adapter_name); then
					echo "[warn] Could not determine VPN adapter name"
					exit_code=1
				else
					if ! get_vpn_adapter_ip_address "${vpn_adapter_name}" >/dev/null; then
						echo "[warn] Could not determine VPN adapter IP address"
						exit_code=1
					fi
				fi

			fi

			# If all checks pass, break out of retry loop
			if [[ "${exit_code}" -eq 0 ]]; then
				echo "[info] All healthchecks passed on attempt $((retry_count + 1))"
				break
			fi

			retry_count=$((retry_count + 1))

			if [[ "${retry_count}" -lt "${max_retries}" ]]; then
				echo "[warn] Healthcheck failed on attempt ${retry_count}/${max_retries}, retrying..."
			else
				echo "[warn] All ${max_retries} healthcheck attempts failed"
			fi
		done
	fi

	# check return code from healthcheck command and perform healthcheck action if exit code != 0
	if [[ "${exit_code}" -ne 0 ]]; then
		echo "[fatal] Healthcheck failed, running healthcheck action..."
		healthcheck_action "${exit_code}"
	else
		echo "[info] Healthcheck passed, exiting script with exit code '${exit_code}'"
		exit "${exit_code}"
	fi

}

function healthcheck_action() {

	local exit_code="${1}"
	shift

	if [[ -n "${HEALTHCHECK_ACTION}" ]]; then
		echo "[info] Healthcheck action specified, running '${HEALTHCHECK_ACTION}'..."
		eval "${HEALTHCHECK_ACTION}"
	else
		echo "[info] No custom healthcheck action defined via env var 'HEALTHCHECK_ACTION', defaulting to exiting script with exit code '${exit_code}'"
		exit "${exit_code}"
	fi
}

healthcheck_command