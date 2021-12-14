#!/bin/bash

if [[ -z "${1}" ]]; then
	echo "[crit] No path to log file specified as first parameter, exiting script..."
fi

log_path="${1}"
number_of_logs_to_keep=3
file_size_limit_kb=10240

# wait for log file to exist before size checks proceed
while [[ ! -f "${log_path}" ]]; do
	sleep 0.1
done

echo "[info] Log rotate script running, monitoring log file '${log_path}'"

while true; do

	file_size_kb=$(du -k "${log_path}" | cut -f1)

	if [ "${file_size_kb}" -ge "${file_size_limit_kb}" ]; then

		echo "[info] '${log_path}' log file larger than limit ${file_size_limit_kb} kb, rotating logs..."

		if [[ -f "${log_path}.${number_of_logs_to_keep}" ]]; then
			echo "[info] Deleting oldest log file '${log_path}.${number_of_logs_to_keep}'..."
			rm -f "${log_path}.${number_of_logs_to_keep}"
		fi

		for log_number in $(seq "${number_of_logs_to_keep}" -1 0); do

			if [[ -f "${log_path}.${log_number}" ]]; then
				log_number_inc=$((log_number+1))
				mv "${log_path}.${log_number}" "${log_path}.${log_number_inc}"
			fi

		done

		echo "[info] Copying current log '${log_path}' to ${log_path}.0..."
		cp "${log_path}" "${log_path}.0"

		echo "[info] Emptying current log '${log_path}' contents..."
		> "${log_path}"

	fi

	sleep 30s

done
