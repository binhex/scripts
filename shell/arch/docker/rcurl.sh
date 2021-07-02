#!/bin/bash

# This script adds additional retry and response code checking for curl to verify the download is successful

readonly ourScriptName=$(basename -- "$0")
readonly defaultConnectTimeout=5
readonly defaultRetry=12
readonly defaultRetryDelay=10
readonly defaultMaxTime=600

connect_timeout="${defaultConnectTimeout}"
retry="${defaultRetry}"
retry_delay="${defaultRetryDelay}"
max_time="${defaultMaxTime}"

header="user-agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Safari/537.36"

function build_curl_command() {

	# add default options regardless
	curl_command="curl --location --continue-at -"

	if [[ "${curl_command}" != *"--connect-timeout"* ]]; then
		curl_command="${curl_command} --connect-timeout ${connect_timeout}"
	fi

	if [[ "${curl_command}" != *"--retry"* ]]; then
		curl_command="${curl_command} --retry ${retry}"
	fi

	if [[ "${curl_command}" != *"--retry-delay"* ]]; then
		curl_command="${curl_command} --retry-delay ${retry_delay}"
	fi

	if [[ "${curl_command}" != *"--max-time"* ]]; then
		curl_command="${curl_command} --max-time ${max_time}"
	fi

	if [[ "${curl_command}" != *"--retry-max-time"* ]]; then
		# construct retry max time from count and wait
		retry_max_time=$((retry*retry_delay))
		curl_command="${curl_command} --retry-max-time ${retry_max_time}"
	fi

	if [[ "${curl_command}" != *"--retry-max-time"* ]]; then
		# construct retry max time from count and wait
		retry_max_time=$((retry*retry_delay))
		curl_command="${curl_command} --retry-max-time ${retry_max_time}"
	fi

	if [[ "${curl_command}" != *"--header"* ]]; then
		curl_command="${curl_command} --header '${header}'"
	fi

}

function run_curl_command() {
	curl_command="${curl_command} ${curl_user_options}"
	eval "${curl_command}"
}

# check we have user specified parameters as we require at least a url
if [[ -z "${1}" ]]; then
	echo "[warn] No parameters specified, please include the url and any additional curl options, exiting script '${ourScriptName}'..."
	exit 1
fi

# get all options specified by the user as parameters to this script
curl_user_options="${@}"

# build curl command with defaults and/or user options
build_curl_command

# evaluate and run curl command to get/put body
run_curl_command
