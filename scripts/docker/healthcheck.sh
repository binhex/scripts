#!/bin/bash

# Script to check DNS resolution, HTTPS connectivity and processes, with optional custom
# command and custom action defined via environment variables HEALTHCHECK_COMMAND and
# HEALTHCHECK_ACTION and exit script with appropriate exit code.
#
# This script is called via the Dockerfile HEALTHCHECK instruction.

function check_dns() {

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

	# get env vars from buildx arguments stored in /etc/image-build-info
	# shellcheck disable=SC1091
	source /etc/image-build-info

	if [[ -z "${APPNAME}" ]]; then
		echo "[error] APPNAME is not defined, cannot check process."
		return 1
	fi

	# convert app name into process name(s) to monitor
	#
	# note exceptions for monitoring are:
	# get-iplayer - Process does not run all the time, thus unable to monitor
	local process_names=()
	if [[ "${APPNAME}" == 'deluge' ]]; then
		process_names=('deluged' 'deluge-web')
	elif [[ "${APPNAME}" == 'delugevpn' ]]; then
		process_names=('deluged' 'deluge-web' 'openvpn|wg')
	elif [[ "${APPNAME}" == 'qbittorrent' ]]; then
		process_names=('qbittorrent-nox')
	elif [[ "${APPNAME}" == 'qbittorrentvpn' ]]; then
		process_names=('qbittorrent-nox' 'openvpn|wg')
	else
		# app name not defined, exit with success
		return 0
	fi

	# loop over each process name in the array
	for process_name in "${process_names[@]}"; do

		if pgrep -x "${process_name}" > /dev/null; then
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
		echo "[info] No custom healthcheck command defined, running standard checks..."
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
		echo "[info] No healthcheck action specified, defaulting to exiting script with exit code '${exit_code}'"
		exit "${exit_code}"
	fi
}

healthcheck_command