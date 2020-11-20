#!/bin/bash
# This script adds additional retry and response code checking for curl to verify the download is successful
# Note this script can currently only cope with 'get' actions not 'post'

# setup default values
readonly ourScriptName=$(basename -- "$0")
readonly defaultConnectTimeout=5
readonly defaultRetryCount=5
readonly defaultRetryWait="10"
readonly defaultOutputFile=""
readonly defaultNoProgress="true"
readonly defaultNoOutput="false"

connect_timeout="${defaultConnectTimeout}"
retry_count="${defaultRetryCount}"
retry_wait="${defaultRetryWait}"
output_file="${defaultOutputFile}"
no_progress="${defaultNoProgress}"
no_output="${defaultNoOutput}"

function check_response_code() {

	local output_file="${1}"
	shift
	local retry_count="${1}"
	shift
	local retry_wait="${1}"
	shift
	local url="${1}"
	shift

	# construct retry max time from count and wait
	retry_max_time=$((${retry_count}*${retry_wait}))

	while true; do

		# check github return code is ok before we attempt download
		header=$(curl --head --location --silent --connect-timeout "${connect_timeout}" --max-time 600 --retry "${retry_count}" --retry-delay "${retry_wait}" --retry-max-time "${retry_max_time}" "${url}")
		exit_code=$?

		# get response code from header, in reverse to get last code in case of redirections (tac) with regex and awk to extract code
		response_code=$(echo "${header}" | tac | grep -m 1 'HTTP.*' | awk {'print $2'})

		# if response code is not an integer then we cannot identify response (non github url?)
		if [[ ! "${response_code}" == ?(-)+([0-9]) ]]; then

			return 0

		fi

		if [[ "${response_code}" -ge "200" ]] && [[ "${response_code}" -le "299" ]]; then

			return 0

		# github assets do not permit head requests so we look at 302 codes only (confirm it exists)
		elif [[ "${response_code}" -ge "403" ]]; then

			response_code=$(echo "${header}" | grep -m 1 'HTTP.*' | awk {'print $2'})

			if [[ "${response_code}" -eq "302" ]]; then

				return 0

			fi

		fi

		if [[ "${retry_count}" -eq "0" ]]; then

			echo -e "[warn] Response code ${response_code} from curl for url '${url}' != 2xx, exhausted retries"
			return 1

		# if output file specified then log warning, else if stdout then do not log warning
		elif [[ -n "${output_file}" ]]; then

			echo -e "[warn] Response code ${response_code} from curl for url '${url}' != 2xx"

			if [[ "${exit_code}" -ge "1" ]]; then
				echo -e "[warn] Exit code ${exit_code} from curl != 0"
			fi

			echo "[info] ${retry_count} retries left"
			echo "[info] Retrying in ${retry_wait} secs..."

		fi

		sleep "${retry_wait}"
		retry_count=$((retry_count-1))

	done

}

function get_response_body() {

	local retry_count="${1}"
	shift
	local retry_wait="${1}"
	shift
	local output_file="${1}"
	shift
	local no_progress="${1}"
	shift
	local no_output="${1}"
	shift
	local url="${1}"
	shift

	# construct retry max time from count and wait
	retry_max_time=$((${retry_count}*${retry_wait}))

	# add in silent flag if enabled (default is silent)
	if [[ "${no_progress}" == "true" ]]; then

		no_progress="--silent"

	fi

	# if output file specified then specify curl option
	if [[ -n "${output_file}" ]]; then

		# if output filename already exists then delete
		if [ -f "${output_file}" ]; then

			rm -f "${output_file}"

		fi

		output_file="--output ${output_file}"

	elif [[ "${no_output}" == "true" ]]; then

		output_file="--output /dev/null"

	fi

	while true; do

		# construct curl command, note do not single/double quote output_file variable
		response_body=$(curl --location --continue-at - --connect-timeout "${connect_timeout}" --max-time 600 --retry "${retry_count}" --retry-delay "${retry_wait}" --retry-max-time "${retry_max_time}" ${output_file} "${no_progress}" "${url}")
		exit_code=$?

		if [[ "${exit_code}" -ge "1" ]] || ( [[ -z "${output_file}" ]] && [[ -z "${response_body}" ]] ); then

			if [[ "${retry_count}" -eq "0" ]]; then

				echo -e "[warn] Exit code '${exit_code}' from curl != 0 or no response body received, exhausted retries"
				response_body_result=1; break

			else

				# if output file specified then log warning, else if stdout then do not log warning
				if [[ -n "${output_file}" ]]; then

					echo -e "[warn] Exit code '${exit_code}' from curl != 0 or no response body received"

					echo "[info] ${retry_count} retries left"
					echo "[info] Retrying in ${retry_wait} secs..."

				fi

				sleep "${retry_wait}"
				retry_count=$((retry_count-1))

			fi

		else

			if [[ -n "${output_file}" ]]; then

				response_body_result=0; break

			else

				response_body_result="${response_body}"; break

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

	-np or --no-progress <true|false>
		Define whether to show curl download progress bar.
		Defaults to '${defaultNoProgress}'.

	-no or --no-output <true|false>
		Define whether to show curl downloaded output if no output file specified.
		Defaults to '${defaultNoOutput}'.

	-url or --url <url>
		URL that curl will process.
		No default.
Example:
	curly.sh -of /tmp/curly_output -np true -url http://www.google.co.uk
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
		-np|--no-progress)
			no_progress=$2
			shift
			;;
		-no|--no-output)
			no_output=$2
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

check_response_code "${output_file}" "${retry_count}" "${retry_wait}" "${url}"

if [[ "${?}" -eq 0 ]]; then

	get_response_body "${retry_count}" "${retry_wait}" "${output_file}" "${no_progress}" "${no_output}" "${url}"

	if [[ -z "${output_file}" ]]; then

		if [[ -n "${response_body_result}" ]]; then

			echo "${response_body_result}"
			exit 0

		else

			echo "[warn] Unable to download response body from url '${url}', exiting script..."
			exit 1
		fi

	else

		if [[ "${response_body_result}" -eq 0 ]]; then

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
