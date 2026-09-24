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

	# check if HTTPS is working by making a request to a known URL, the timeouts
	# bound the probe so an unresponsive host cannot stall the healthcheck until
	# Docker's HEALTHCHECK timeout kills the script (which would also report the
	# container as unhealthy)
	if ! curl -s --head --connect-timeout 5 --max-time 15 "https://${hostname_check}" > /dev/null; then
		echo "[warn] HTTPS request failed"
		return 1
	else
		echo "[info] HTTPS request is working."
		return 0
	fi
}

# Probes a list of independent external hosts and reports whether this container
# still has internet connectivity.
#
# A host only counts as reachable when both DNS resolution and an HTTPS request
# succeed. The container is reported as offline only when fewer than
# HEALTHCHECK_MIN_REACHABLE_HOSTS hosts are reachable, so a blip on a single
# upstream host (or a single host being unreachable) does not mark it unhealthy.
#
# Env: HEALTHCHECK_HOSTNAMES           - space or comma separated target list
#      HEALTHCHECK_HOSTNAME            - single target, legacy, used when
#                                        HEALTHCHECK_HOSTNAMES is not set
#      HEALTHCHECK_MIN_REACHABLE_HOSTS - reachable hosts required (default: 1)
#
# Returns 0 when connectivity is confirmed, 1 when it is not.
# CONNECTIVITY_PROBE_RESULT caches the outcome for the current healthcheck attempt
# so that check_app_specific does not probe a second time. Callers clear it before
# each retry so that every attempt re-verifies connectivity.
function check_internet_connectivity() {

	if [[ -n "${CONNECTIVITY_PROBE_RESULT}" ]]; then
		echo "[info] Reusing connectivity probe result from this healthcheck attempt (exit code '${CONNECTIVITY_PROBE_RESULT}')."
		return "${CONNECTIVITY_PROBE_RESULT}"
	fi

	echo "[info] Health checking internet connectivity..."

	local hosts=()
	if [[ -n "${HEALTHCHECK_HOSTNAMES}" ]]; then
		# split on spaces and commas so both 'a b' and 'a,b' lists work
		local host_list="${HEALTHCHECK_HOSTNAMES//,/ }"
		read -r -a hosts <<< "${host_list}"
	elif [[ -n "${HEALTHCHECK_HOSTNAME}" ]]; then
		hosts=("${HEALTHCHECK_HOSTNAME}")
	fi

	# fall back to the defaults when nothing usable was configured, an empty or
	# malformed HEALTHCHECK_HOSTNAMES must not leave every container unhealthy
	if [[ "${#hosts[@]}" -eq 0 ]]; then
		hosts=('cloudflare.com' 'google.com' 'github.com')
	fi

	local min_reachable="${HEALTHCHECK_MIN_REACHABLE_HOSTS:-1}"
	local reachable=0
	local host

	for host in "${hosts[@]}"; do

		# a host is only reachable when its name resolves and it answers over HTTPS
		if check_dns "${host}" && check_https "${host}"; then
			echo "[info] Host '${host}' is reachable."
			reachable=$((reachable + 1))
		else
			echo "[warn] Host '${host}' is not reachable."
		fi
	done

	echo "[info] Reachable connectivity hosts: ${reachable}/${#hosts[@]} (minimum required: ${min_reachable})."

	if [[ "${reachable}" -ge "${min_reachable}" ]]; then
		CONNECTIVITY_PROBE_RESULT=0
	else
		echo "[warn] Internet connectivity check failed"
		CONNECTIVITY_PROBE_RESULT=1
	fi

	return "${CONNECTIVITY_PROBE_RESULT}"
}

function check_process() {

	echo "[info] Health checking processes..."

	# get env vars from buildx arguments stored in /etc/image-build-info
	local build_info_file="${IMAGE_BUILD_INFO_FILE:-/etc/image-build-info}"
	if [[ -f "${build_info_file}" ]]; then
		# shellcheck source=/dev/null
		source "${build_info_file}"
	fi

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

# Scans a log file for network-level error patterns within a recent time window and
# reports the distinct remote hosts that failed.
#
# Continuation lines (e.g. .NET stack frames) are included when they follow a
# timestamped line that falls within the window, so multi-line exceptions are caught.
#
# Errors that do not indicate a loss of connectivity are filtered out first.
# 'Connection refused' in particular proves the network path works and the remote
# service is simply down (for example prowlarr still referencing a removed Readarr),
# so it must never be reported as a connectivity failure.
#
# Finding errors here is evidence, not a verdict: callers must confirm with a live
# connectivity probe before marking the container unhealthy, because a single host
# being down, a dropped DNS query and an unreachable IPv6 address all look alike.
#
# Args: log_file [pattern ...]
# Env:  APP_LOG_CHECK_MINUTES  - window size in minutes (default: 5)
# Sets: APP_LOG_NET_ERROR_HOSTS - space separated distinct hosts that failed
#       APP_LOG_NET_ERROR_COUNT - number of distinct hosts that failed
# Returns: 0 when no network-level errors were found, 1 when they were found.
function check_app_logs() {

	local log_file="${1}"
	shift
	local error_patterns=("${@}")
	local window_minutes="${APP_LOG_CHECK_MINUTES:-5}"

	APP_LOG_NET_ERROR_HOSTS=""
	APP_LOG_NET_ERROR_COUNT=0

	if [[ "${#error_patterns[@]}" -eq 0 ]]; then
		echo "[info] No log error patterns configured, skipping log check."
		return 0
	fi

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

	# Errors that are never evidence of lost internet connectivity:
	#   - Connection refused (111) the remote service is down, the network is fine
	#   - Operation canceled (125) request cancellation artefact
	#   - SSL / HTTP2           protocol level, not reachability
	#   - short reads           connection dropped mid response
	#   - request timeouts      one slow indexer, not a connectivity loss
	local error_exclusions=(
		'Connection refused'
		'Operation canceled'
		'SSL connection could not be established'
		'HTTP/2'
		'Failed to read complete'
		'Http request timed out'
	)

	local pattern_regex exclusion_regex
	pattern_regex=$(printf '%s|' "${error_patterns[@]}")
	pattern_regex="${pattern_regex%|}"
	exclusion_regex=$(printf '%s|' "${error_exclusions[@]}")
	exclusion_regex="${exclusion_regex%|}"

	local matched_lines
	matched_lines=$(printf '%s\n' "${recent_logs}" | grep -iE -- "${pattern_regex}" | grep -ivE -- "${exclusion_regex}")

	if [[ -z "${matched_lines}" ]]; then
		echo "[info] No network connectivity errors found in recent application logs."
		return 0
	fi

	# Remote hosts are reported by .NET as the trailing '(host:port)' of the exception
	# header, for example '...(Network is unreachable) (1337x.to:443)'.
	local failed_hosts
	failed_hosts=$(printf '%s\n' "${matched_lines}" | grep -oE '\([a-zA-Z0-9._-]+:[0-9]+\)' | tr -d '()' | sort -u)

	if [[ -z "${failed_hosts}" ]]; then
		APP_LOG_NET_ERROR_HOSTS='unknown'
		APP_LOG_NET_ERROR_COUNT=1
	else
		APP_LOG_NET_ERROR_HOSTS=$(printf '%s\n' "${failed_hosts}" | tr '\n' ' ')
		APP_LOG_NET_ERROR_HOSTS="${APP_LOG_NET_ERROR_HOSTS% }"
		APP_LOG_NET_ERROR_COUNT=$(printf '%s\n' "${failed_hosts}" | grep -c .)
	fi

	echo "[warn] Network connectivity errors found in recent application logs (${APP_LOG_NET_ERROR_COUNT} host(s): ${APP_LOG_NET_ERROR_HOSTS})."
	return 1
}

# Runs app-specific health checks based on APPNAME.
#
# Supervised *arr apps keep running when they lose internet connectivity, so their
# logs are scanned for network-level errors. A logged error on its own is not proof
# of a connectivity loss — a single unreachable host, a dropped DNS query and an
# unreachable IPv6 address all produce the same exceptions while the app is fine —
# so the container is only marked unhealthy when a live connectivity probe fails too.
function check_app_specific() {

	echo "[info] Health checking application-specific state..."

	local build_info_file="${IMAGE_BUILD_INFO_FILE:-/etc/image-build-info}"
	if [[ -f "${build_info_file}" ]]; then
		# shellcheck source=/dev/null
		source "${build_info_file}"
	fi

	if [[ -z "${APPNAME}" ]]; then
		echo "[info] APPNAME is not defined, skipping app-specific checks."
		return 0
	fi

	local supervisord_log="${APP_LOG_FILE:-/config/supervisord.log}"

	# OS-level error messages that mean the app could not reach a remote host at all.
	# Bare SocketException/HttpRequestException/WebException are intentionally excluded:
	# they also fire on protocol-level errors (4xx/5xx responses, auth rejections,
	# connection refused) that do not indicate a network outage. TaskCanceledException is
	# covered via 'HttpClient.Timeout' rather than the bare exception name, which would
	# also match routine request cancellations.
	local net_error_patterns=(
		'Network is unreachable'            # ENETUNREACH (errno 101)
		'No route to host'                  # EHOSTUNREACH (errno 113)
		'Connection timed out'              # ETIMEDOUT (errno 110)
		'Name or service not known'         # DNS resolution failure
		'Resource temporarily unavailable'  # EAGAIN (errno 11) - DNS resolver blip
		'No data available'                 # ENODATA (errno 61) - DNS NODATA response
		'HttpClient.Timeout'                # HTTP client timeout
	)

	# Apps that write .NET exceptions to supervisord.log.
	local supervised_apps=('jackett' 'lidarr' 'prowlarr' 'radarr' 'readarr' 'sonarr')

	local app
	for app in "${supervised_apps[@]}"; do
		if [[ "${APPNAME}" == "${app}" ]]; then

			if check_app_logs "${supervisord_log}" "${net_error_patterns[@]}"; then
				return 0
			fi

			# confirm the logged errors against live connectivity before failing
			if check_internet_connectivity; then
				echo "[info] Live connectivity check passed, treating the logged errors as transient or host specific."
				return 0
			fi

			echo "[warn] Live connectivity check failed, application has lost internet connectivity."
			return 1
		fi
	done

	return 0
}

function check_incoming_port() {

	# Use shared function from utils.sh to query gluetun for the forwarded port
	if ! get_gluetun_forwarded_port 3 2; then
		echo "[warn] Failed to retrieve forwarded port from gluetun API"
		return 1
	fi

	local incoming_port="${GLUETUN_FORWARDED_PORT}"

	echo "[info] Verifying incoming port '${incoming_port}' reachability via external service..."

	local result
	result=$(curl_with_retry "https://ifconfig.co/port/${incoming_port}" 3 2 -s | jq -r '.reachable' 2>/dev/null)

	if [[ "${result}" == "true" ]]; then
		echo "[info] Incoming port '${incoming_port}' is reachable."
		return 0
	else
		echo "[warn] Incoming port '${incoming_port}' is NOT reachable."
		return 1
	fi
}

function healthcheck_command() {

	local exit_code=0

	# source in curl_with_retry function and vpn ip and adapter name functions
	# shellcheck source=/dev/null
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

		while [[ "${retry_count}" -lt "${max_retries}" ]]; do

			if [[ "${retry_count}" -gt 0 ]]; then
				echo "[info] Retry attempt ${retry_count}/${max_retries}, retrying in ${retry_delay} second(s)..."
				sleep "${retry_delay}"
			fi

			exit_code=0

			# clear the cached probe so that every attempt re-verifies connectivity,
			# a transient failure that has since recovered must not keep the container
			# unhealthy for the remainder of the run
			CONNECTIVITY_PROBE_RESULT=""

			if ! check_internet_connectivity; then
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

				# Also verify the forwarded port is actually reachable from outside.
				# This catches cases where the VPN tunnel is up but port forwarding
				# is broken -- otherwise the healthcheck would pass (because the VPN
				# adapter is healthy) while qbit's web UI and API are unreachable.
				# Check if portset.sh has already attempted gluetun-unhealthy escalation.
				# If so, don't mark this container unhealthy — the escalation either worked
				# (gluetun will restart) or it didn't, and repeatedly marking qbittorrent
				# unhealthy only triggers useless external restarts.
				if ! check_incoming_port; then
					if [[ -f "/tmp/gluetun_escalation_attempted" ]]; then
						local escalation_time
						escalation_time=$(cat /tmp/gluetun_escalation_attempted 2>/dev/null)
						escalation_time="${escalation_time:-0}"
						local now
						now=$(date +%s)
						local elapsed=$((now - escalation_time))
						# Derive the suppression window from portset.sh's escalation cooldown.
						# Use 2x the cooldown to give gluetun time to restart after the watchdog
						# detects the failure (default: 300s * 2 = 600s = 10 minutes).
						# Check emptiness first before arithmetic to avoid brittle
						# arithmetic-on-empty behaviour in $(( )).
						local escalation_cooldown_secs="${GLUETUN_ESCALATION_COOLDOWN:-300}"
						local suppression_window=$((escalation_cooldown_secs * 2))
						if [[ ${elapsed} -lt ${suppression_window} ]]; then
							echo "[info] Incoming port unavailable but escalation attempted ${elapsed}s ago — deferring to gluetun restart"
						else
							echo "[warn] Incoming port healthcheck failed (escalation cooldown expired)"
							exit_code=1
						fi
					else
						echo "[warn] Incoming port healthcheck failed"
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
		echo "[info] Healthcheck action completed, exiting with code '${exit_code}'"
		exit "${exit_code}"
	else
		echo "[info] No custom healthcheck action defined via env var 'HEALTHCHECK_ACTION', defaulting to exiting script with exit code '${exit_code}'"
		exit "${exit_code}"
	fi
}

# Allow sourcing for testing without running the healthcheck.
if [[ -z "${HEALTHCHECK_TEST_MODE}" ]]; then
	healthcheck_command
fi
