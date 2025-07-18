#!/bin/bash

# Script to check DNS resolution, HTTPS connectivity and processes, with optional custom
# command and custom action defined via environment variables HEALTHCHECK_COMMAND and
# HEALTHCHECK_ACTION and exit script with appropriate exit code.
#
# This script is called via the Dockerfile HEALTHCHECK instruction.

function check_dns() {

	echo "[info] Health checking DNS..."
	local hostname_check="${1:-google.com}"
	shift

	# check if DNS is working by resolving a known domain
	if ! nslookup "${hostname_check}" > /dev/null 2>&1; then
		echo "[error] DNS resolution failed"
		return 1
	else
		echo "[info] DNS resolution is working."
		return 0
	fi
}

function check_https() {

	echo "[info] Health checking HTTPS..."
	local hostname_check="${1:-google.com}"
	shift

	# check if HTTPS is working by making a request to a known URL
	if ! curl -s --head "https://${hostname_check}" > /dev/null; then
		echo "[error] HTTPS request failed"
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

	# convert app name into process name(s) to monitor
	local process_names=()
	if [[ "${APPNAME}" == 'bitmagnet' ]]; then
		process_names=('bitmagnet')
	elif [[ "${APPNAME}" == 'code-server' ]]; then
		process_names=('code-server')
	elif [[ "${APPNAME}" == 'crafty-4' ]]; then
		process_names=('python.*crafty.*')
	elif [[ "${APPNAME}" == 'deluge' ]]; then
		process_names=('deluged' 'deluge-web')
	elif [[ "${APPNAME}" == 'delugevpn' ]]; then
		process_names=('deluged' 'deluge-web' 'openvpn|wg')
	elif [[ "${APPNAME}" == 'emby' ]]; then
		process_names=('EmbyServer')
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
		process_names=('qbittorrent-nox')
	elif [[ "${APPNAME}" == 'qbittorrentvpn' ]]; then
		process_names=('qbittorrent-nox' 'openvpn|wg')
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
			echo "[error] Process '${process_name}' is not running."
			return 1
		fi
	done
	return 0
}

function healthcheck_command() {

	local exit_code=0
	shift

	if [[ -n "${HEALTHCHECK_COMMAND}" ]]; then
		echo "[info] Running custom healthcheck command: ${HEALTHCHECK_COMMAND}"
		eval "${HEALTHCHECK_COMMAND}"
		exit_code="${?}"
	else
		echo "[info] No custom healthcheck command defined via env var 'HEALTHCHECK_COMMAND', running default healthchecks..."
		local hostname_check="google.com"
		check_dns "${hostname_check}"
		local dns_exit_code="${?}"
		check_https "${hostname_check}"
		local http_exit_code="${?}"
		check_process
		local process_exit_code="${?}"

		# If either check failed, set exit code to 1
		if [[ "${dns_exit_code}" -ne 0 ]] || [[ "${http_exit_code}" -ne 0 ]] || [[ "${process_exit_code}" -ne 0 ]]; then
			exit_code=1
		fi
	fi

	# check return code from healthcheck command and perform healthcheck action if required
	if [[ "${exit_code}" -ne 0 ]]; then
		echo "[warn] Healthcheck failed, running healthcheck action..."
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