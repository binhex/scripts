#!/bin/bash
# this script adds additional retry and response code checking for curl to verify the download is successful

# exit on non zero return code
set -e

readonly ourScriptName=$(basename -- "$0")
readonly defaultRetryCount=5
readonly defaultRetryWait="10"
readonly defaultOutputFile="/tmp/curly_output"
retry_count="${defaultRetryCount}"
retry_wait="${defaultRetryWait}"
output_file="${defaultOutputFile}"

function run_curl() {
	echo -e "Attempting to curl ${url}...\n"

	# construct retry max time from count and wait
	retry_max_time=$((${retry_count}*${retry_wait}))

	while true; do

		response_code=$(curl --connect-timeout 5 --max-time 10 --retry "${retry_count}" --retry-delay "${retry_wait}" --retry-max-time "${retry_max_time}" -o "${output_file}" -L -w "%{http_code}" "${url}")

		if [ "${response_code}" -ge "200" ] && [ "${response_code}" -le "299" ]; then
			echo -e "\ncurl successful for ${url}, response code ${response_code}\n"
			break
		else
			if [ "${retry_count}" -eq "0" ]; then
				echo -e "\nResponse code ${response_code} from curl != 200, exausted retries exiting script...\n"; exit 1
			else
				echo -e "\nResponse code ${response_code} from curl != 200, retrying in 10 secs...\n"; sleep "${retry_wait}"
				retry_count=$((retry_count-1))
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

  -rc or --retry-count <number>
    Set the number of retries before we give up.
    Defaults to '${defaultRetryCount}'.

  -rw or --retry-wait <number>
    Time in seconds to wait between retries.
    Defaults to '${defaultRetryWait}'.

  -of or --output-file <path+filename>
    Path to filename to store result from curl.
    Defaults to '${defaultOutputFile}'.

  -url or --url <url>
    URL that curl will process.
    No default.
Example:
  curly.sh -rc 6 -rw 10 -of /tmp/curly_output -url http://www.google.co.uk
  
ENDHELP
}

while [ "$#" != "0" ]
do
  case "$1"
  in
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

run_curl "${retry_count}" "${retry_wait}" "${output_file}" "${url}"