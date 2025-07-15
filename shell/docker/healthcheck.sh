#!/bin/bash

# function to check DNS resolution
# and HTTPS connectivity, with optional custom command
# exit script if return code != 0

function check_dns() {
	# check if DNS is working by resolving a known domain
	if ! nslookup google.com > /dev/null 2>&1; then
		echo "[error] DNS resolution failed"
		return 1
	else
		echo "[info] DNS resolution is working."
		return 0
	fi
}

function check_http() {
	# check if HTTP is working by making a request to a known URL
	if ! curl -s --head https://google.com > /dev/null; then
		echo "[error] HTTPS request failed"
		return 1
	else
		echo "[info] HTTPS request is working."
		return 0
	fi
}

function healthcheck_command() {
	local exit_code=0

	if [[ -n "${HEALTHCHECK_COMMAND}" ]]; then
			echo "[info] Running custom healthcheck command: ${HEALTHCHECK_COMMAND}"
			eval "${HEALTHCHECK_COMMAND}"
			exit_code="${?}"
	else
			echo "[info] No custom healthcheck command defined, running standard checks..."
			check_dns
			local dns_exit_code="${?}"
			check_http
			local http_exit_code="${?}"

			# If either check failed, set exit code to 1
			if [[ "${dns_exit_code}" -ne 0 ]] || [[ "${http_exit_code}" -ne 0 ]]; then
					exit_code=1
			fi
	fi

	# If any check failed, run the healthcheck action
	if [[ "${exit_code}" -ne 0 ]]; then
			echo "[warn] Healthcheck failed"
	else
			echo "[info] Healthcheck passed"
	fi
	healthcheck_action "${exit_code}"
}

function healthcheck_action() {

	local exit_code="${1}"
	shift

	if [[ -n "${HEALTHCHECK_ACTION}" ]]; then
		echo "[info] Healthcheck action specified, running '${HEALTHCHECK_ACTION}'..."
		eval "${HEALTHCHECK_ACTION}"
	else
		echo "[info] No healthcheck action specified, defaulting to exit code ${exit_code}"
		exit "${exit_code}"
	fi
}

healthcheck_command