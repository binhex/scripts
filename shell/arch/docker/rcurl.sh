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

# this function checks the header statuc code before we actually attempt download
function get_http_status_code() {

	# get last space separated field using awk 'NF' to give us the url
	url=$(echo "${curl_user_options}" | awk '{print $NF }')

	# construct curl command to get http status code
	curl_http_code="$(curl --dump-header - --location --silent --output /dev/null --write-out %{http_code} ${url} | grep -P -m 1 '^[0-9]+')"

	# if response code is not an integer then we cannot identify response, assume ok
	if [[ ! "${curl_http_code}" == ?(-)+([0-9]) ]]; then
		return 0

	else

		retry_count="${retry}"
		retry_wait="${retry_delay}"

		while true; do

			if [[ "${retry_count}" -eq "0" ]]; then
				echo -e "[warn] Exhausted retries, exiting script..."
				return 1
			fi

			# accept the following http status codes, informational responses (100–199), successful responses (200–299) and redirects (300–399)
			if [[ "${curl_http_code}" -ge "100" ]] && [[ "${curl_http_code}" -le "399" ]]; then
				return 0
			else
				echo -e "[warn] HTTP status code ${curl_http_code} indicates failure to curl URL '${url}'."
			fi

			retry_count=$((retry_count-1))
			echo "[info] ${retry_count} retries left"
			echo "[info] Retrying in ${retry_wait} secs..."
			sleep "${retry_wait}"s

		done
	fi

}

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
		retry_max_time=$((${retry}*${retry_delay}))
		curl_command="${curl_command} --retry-max-time ${retry_max_time}"
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

# find out http status code from header before attempting download of body
get_http_status_code

if [ "${?}" -eq 0 ]; then
	# build curl command with defaults and/or user options
	build_curl_command

	# evaluate and run curl command to get/put body
	run_curl_command
else
	echo -e "[warn] Exiting ${ourScriptName} due to bad HTTP status code '${curl_http_code}'"
fi
