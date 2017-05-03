#!/bin/bash
# this script adds additional retry and response code checking for curl to verify the download is successful

# exit on non zero return code
set -e

retry_count=5
retry_period="10s"
url="https://github.com/binhex/scripts/archive/master.zip"
output="/tmp/scripts-master.zip"

echo -e "Attempting to curl ${url}...\n"

while true; do

	response_code=$(curl --connect-timeout 5 --max-time 10 --retry 5 --retry-delay 0 --retry-max-time 60 -o "${output}" -L -w "%{http_code}" "${url}")

	if [ "${response_code}" -ge "200" ] && [ "${response_code}" -le "299" ]; then
		echo -e "\ncurl successful for ${url}, response code ${response_code}\n"
		break
	else
		if [ "${retry_count}" -eq "0" ]; then
			echo -e "\nResponse code ${response_code} from curl != 200, exausted retries exiting script...\n"; exit 1
		else
			echo -e "\nResponse code ${response_code} from curl != 200, retrying in 10 secs...\n"; sleep "${retry_period}"
			retry_count=$((retry_count-1))
		fi
	fi

done
