#!/bin/bash
# This script adds additional retry and response code checking for curl to verify the download is successful
# Note this script can currently only cope with 'get' actions not 'post'

# setup default values
readonly ourScriptName=$(basename -- "$0")
readonly defaultConnectTimeout=5
readonly defaultRetryCount=5
readonly defaultRetryWait="10"
readonly defaultOutputFile=""
readonly defaultSilentMode="true"

connect_timeout="${defaultConnectTimeout}"
retry_count="${defaultRetryCount}"
retry_wait="${defaultRetryWait}"
output_file="${defaultOutputFile}"
silent_mode="${defaultSilentMode}"

function check_response_code() {

	echo -e "[info] Attempting to curl ${url}..."

	# construct retry max time from count and wait
	retry_max_time=$((${retry_count}*${retry_wait}))

	while true; do

		# construct curl command, note do not single/double quote output_file variable
		response_code=$(curl --head --location --silent --connect-timeout "${connect_timeout}" --max-time 600 --retry "${retry_count}" --retry-delay "${retry_wait}" --retry-max-time "${retry_max_time}" "${url}" | tac | grep -m 1 'HTTP.*' | awk {'print $2'})
		exit_code=$?

		if [[ "${response_code}" -ge "200" ]] && [[ "${response_code}" -le "299" ]]; then

			echo -e "[info] Curl successful for ${url}, response code ${response_code}"
			return 0

		else

			if [[ "${retry_count}" -eq "0" ]]; then

				echo -e "[warn] Response code ${response_code} from curl != 2xx, exhausted retries"
				return 1

			else

				echo -e "[warn] Response code ${response_code} from curl != 2xx"

				if [[ "${exit_code}" -ge "1" ]]; then
					echo -e "[warn] Exit code ${exit_code} from curl != 0"
				fi

				echo "[info] ${retry_count} retries left"
				echo "[info] Retrying in ${retry_wait} secs..."; sleep "${retry_wait}"
				retry_count=$((retry_count-1))

			fi

		fi

	done

}

function get_response_body() {

	echo -e "[info] Attempting to curl ${url}..."

	local _resultvar="${1}"
	shift

	# construct retry max time from count and wait
	retry_max_time=$((${retry_count}*${retry_wait}))

	# add in silent flag if enabled (default is silent)
	if [[ "${silent_mode}" == "true" ]]; then
		silent_mode="--silent"
	else
		silent_mode=""
	fi

	# if output file specified then specify curl option
	if [[ -n "${output_file}" ]]; then

		# if output filename already exists then delete
		if [ -f "${output_file}" ]; then
			rm -f "${output_file}"
		fi

		output_file="--output ${output_file}"

	fi

	while true; do

		# construct curl command, note do not single/double quote output_file variable
		response_body=$(curl --location --continue-at - --connect-timeout "${connect_timeout}" --max-time 600 --retry "${retry_count}" --retry-delay "${retry_wait}" --retry-max-time "${retry_max_time}" ${output_file} "${silent_mode}" "${url}")
		exit_code=$?

		if [[ "${exit_code}" -ge "1" ]] || ( [[ -z "${output_file}" ]] && [[ -z "${response_body}" ]] ); then

			if [[ "${retry_count}" -eq "0" ]]; then

				echo -e "[warn] Exit code '${exit_code}' from curl != 0 or no response body received, exhausted retries"
				_resultvar=1; break

			else

				echo -e "[warn] Exit code '${exit_code}' from curl != 0 or no response body received"

				echo "[info] ${retry_count} retries left"
				echo "[info] Retrying in ${retry_wait} secs..."; sleep "${retry_wait}"
				retry_count=$((retry_count-1))

			fi

		else

			if [[ -n "${output_file}" ]]; then

				echo -e "[info] Curl successful for ${url}"
				_resultvar=0; break

			else

				echo -e "[info] Curl successful for ${url}"
				_resultvar="${response_body}"; break

			fi

		fi

	done
}

function show_help() {
	cat <<ENDHELP
Description:
	Wrapper for curl to ensure it retries when failing to download (non 2xx code).
Syntax:
	${ourScriptName} [args]
Where:
	-h or --help
		Displays this text.

	-ct or --connect-timeout <number>
		Set the number of seconds to wait before connection timeout.
		Defaults to '${defaultConnectTimeout}'.

	-rc or --retry-count <number>
		Set the number of retries before we give up.
		Defaults to '${defaultRetryCount}'.

	-rw or --retry-wait <number>
		Time in seconds to wait between retries.
		Defaults to '${defaultRetryWait}'.

	-of or --output-file <path+filename>
		Path to filename to store result from curl.
		Defaults to '${defaultOutputFile}' i.e. do not save.

	-sm or --silent-mode <true|false>
		Define whether to run curl silently or not.
		Defaults to '${defaultSilentMode}'.

	-url or --url <url>
		URL that curl will process.
		No default.
Example:
	curly.sh -rc 6 -rw 10 -of /tmp/curly_output -sm true -url http://www.google.co.uk
ENDHELP
}

while [ "$#" != "0" ]
do
	case "$1"
	in
		-ct|--connect-timeout)
			connect_timeout=$2
			shift
			;;
		-rc|--retry-count)
			retry_count=$2
			shift
			;;
		-rw|--retry-wait)
			retry_wait=$2
			shift
			;;
		-of|--output-file)
			output_file=$2
			shift
			;;
		-sm|--silent-mode)
			silent_mode=$2
			shift
			;;
		-url|--url)
			url=$2
			shift
			;;
		-h|--help)
			show_help
			exit 0
			;;
		*)
			echo "${ourScriptName}: ERROR: Unrecognised argument '$1'." >&2
			show_help
			 exit 1
			 ;;
	 esac
	 shift
done

# check we have mandatory parameters, else exit with warning
if [[ -z "${url}" ]]; then

	echo "[warn] URL not defined via parameter -url or --url, displaying help..."
	show_help
	exit 1

fi

check_response_code "${retry_count}" "${retry_wait}" "${url}"

if [[ "${?}" -eq 0 ]]; then

	echo "[info] Response code OK, proceeding to download body..."

	get_response_body "${response_body_result}" "${retry_count}" "${retry_wait}" "${output_file}" "${silent_mode}" "${url}"

	if [[ -z "${output_file}" ]]; then

		if [[ -n "${response_body}" ]]; then

			echo "${response_body}"
			exit 0

		else

			echo "[warn] Unable to download response body from url '${url}', exiting script..."
			exit 1
		fi

	else

		if [[ "${response_body_result}" -eq 0 ]]; then

			echo "[info] Successfully downloaded file from url '${url}'"
			exit 0

		else

			echo "[warn] Unable to download file from url '${url}', exiting script..."
			exit 1

		fi

	fi

else

	echo "[warn] Response code != 2XX for url '${url}', exiting script..."
	exit 1

fi
