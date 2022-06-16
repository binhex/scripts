#!/bin/bash

# set defaults
defaultLogLevel="WARN"
log_level="${defaultLogLevel}"
defaultNumberLogs="3"
number_of_logs_to_keep="${defaultNumberLogs}"
defaultFileSize="102048"
file_size_limit_kb="${defaultFileSize}"

# create associative array with permitted logging levels
declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)

function logger() {

	local log_message=$1
	local log_priority=$2

	# check if level is in array
	if [[ -z "${log_level[${log_priority}]:-}" ]]; then
		echo "[ERROR] Log level '${log_priority}' is not valid, exiting function"
		return 1
	fi

	# check if level is high enough to log
	if (( ${levels[$log_priority]} >= ${levels[$log_level]} )); then
		echo "[${log_priority}] ${log_message}" | ts '%Y-%m-%d %H:%M:%.S'
	fi
}

function log_rotate() {

	while [ "$#" != "0" ]
	do
		case "$1"
		in
			-lp|--log-path)
				log_path=$2
				shift
				;;
			-nl|--number-logs)
				number_of_logs_to_keep=$2
				shift
				;;
			-fs|--file-size)
				file_size_limit_kb=$2
				shift
				;;
			-h|--help)
				show_help_log_rotate
				exit 0
				;;
			*)
				echo "[WARN] Unrecognised argument '$1', displaying help..." >&2
				echo ""
				show_help_log_rotate
				return 1
				;;
		esac
		shift
	done

	# verify required options specified
	if [[ -z "${log_path}" ]]; then
		logger "Log path not specified, showing help..." "WARN"
		show_help_log_rotate
		return 1
	fi

	# wait for log file to exist before size checks proceed
	while [[ ! -f "${log_path}" ]]; do
		sleep 0.1
	done

	logger "Log rotate script running, monitoring log file '${log_path}'" "INFO"

	while true; do

		file_size_kb=$(du -k "${log_path}" | cut -f1)

		if [ "${file_size_kb}" -ge "${file_size_limit_kb}" ]; then

			logger "'${log_path}' log file larger than limit ${file_size_limit_kb} kb, rotating logs..." "INFO"

			if [[ -f "${log_path}.${number_of_logs_to_keep}" ]]; then
				logger "Deleting oldest log file '${log_path}.${number_of_logs_to_keep}'..." "INFO"
				rm -f "${log_path}.${number_of_logs_to_keep}"
			fi

			for log_number in $(seq "${number_of_logs_to_keep}" -1 0); do

				if [[ -f "${log_path}.${log_number}" ]]; then
					log_number_inc=$((log_number+1))
					mv "${log_path}.${log_number}" "${log_path}.${log_number_inc}"
				fi

			done

			logger "Copying current log '${log_path}' to ${log_path}.0..." "INFO"
			cp "${log_path}" "${log_path}.0"

			logger "Emptying current log '${log_path}' contents..." "INFO"
			> "${log_path}"

		fi

		sleep 30s

	done

}

function symlink() {

	while [ "$#" != "0" ]
	do
		case "$1"
		in
			-sp|--src-path)
				src_path=$2
				shift
				;;
			-dp|--dst-path)
				dst_path=$2
				shift
				;;
			-lt| --link-type)
				link_type=$2
				shift
				;;
			-ll|--log-level)
				log_level=$2
				shift
				;;
			-h|--help)
				show_help_symlink
				exit 0
				;;
			*)
				echo "[WARN] Unrecognised argument '$1', displaying help..." >&2
				echo ""
				show_help_symlink
				return 1
				;;
		esac
		shift
	done

	# verify required options specified
	if [[ -z "${src_path}" ]]; then
		logger "Source path not specified, showing help..." "WARN"
		show_help_symlink
		return 1
	fi

	if [[ -z "${dst_path}" ]]; then
		logger "Destination path not specified, showing help..." "WARN"
		show_help_symlink
		return 1
	fi

	if [[ -z "${link_type}" ]]; then
		logger "Link type not specified, showing help..." "WARN"
		show_help_symlink
		return 1
	fi

	# verify link type
	if [[ "${link_type}" == "softlink" ]]; then
		link_type="-s"
	elif [[ "${link_type}" == "hardliunk" ]]; then
		link_type=""
	else
		logger "Unknown link type of '${link_type}' specified, exiting function..." "WARN"
		return 1
	fi

	# if container folder exists then rename and use as default restore
	if [[ -d "${src_path}" && ! -L "${src_path}" ]]; then
		logger "'${src_path}' path already exists, renaming..." "INFO"
		if ! stderr=$(mv "${src_path}" "${src_path}-backup" 2>&1 >/dev/null); then
			logger "Unable to move src path '${src_path}' to backup path '${src_path}-backup' error is '${stderr}', exiting function..." "ERROR"
			return 1
		fi
	fi

	# if ${dst_path} doesnt exist then restore from backup
	if [[ ! -d "${dst_path}" ]]; then
		if [[ -d "${src_path}-backup" ]]; then
			logger "'${dst_path}' path does not exist, copying defaults..." "INFO"
			if ! stderr=$(mkdir -p "${dst_path}" 2>&1 >/dev/null); then
				logger "Unable to mkdir '${dst_path}' error is '${stderr}', exiting function..." "ERROR"
				return 1
			fi
			if ! stderr=$(rsync -av "${src_path}-backup/" "${dst_path}" 2>&1 >/dev/null); then
				logger "Unable to copy from '${src_path}-backup/' to '${dst_path}' error is '${stderr}', exiting function..." "ERROR"
				return 1
			fi
		fi
	else
		logger "'${dst_path}' path already exists, skipping copy" "INFO"
	fi

	# create soft link to ${src_path}/${folder} storing general settings
	logger "Creating '${link_type}' from '${dst_path}' to '${src_path}'..." "INFO"
	if ! stderr=$(mkdir -p "${dst_path}" 2>&1 >/dev/null); then
		logger "Unable to mkdir '${dst_path}' error is '${stderr}', exiting function..." "ERROR"
		return 1
	fi
	if ! stderr=$(rm -rf "${src_path}" 2>&1 >/dev/null); then
		logger "Unable to recursively delete path '${src_path}' error is '${stderr}', exiting function..." "ERROR"
		return 1
	fi
	if ! stderr=$(ln "${link_type}" "${dst_path}/" "${src_path}" 2>&1 >/dev/null); then
		logger "Unable to symlink from path '${link_type}' to '${dst_path}/' error is '${stderr}', exiting function..." "ERROR"
		return 1
	fi
	if [[ -n "${PUID}" && -n "${PGID}" ]]; then
		# reset permissions after file copy
		chown -R "${PUID}":"${PGID}" "${dst_path}" "${src_path}"
	fi
}

function dos2unix() {

	while [ "$#" != "0" ]
	do
		case "$1"
		in
			-fp|--file-path)
				file_path=$2
				shift
				;;
			-ll|--log-level)
				log_level=$2
				shift
				;;
			-h|--help)
				show_help_dos2unix
				exit 0
				;;
			*)
				echo "[WARN] Unrecognised argument '$1', displaying help..." >&2
				echo ""
				show_help_dos2unix
				return 1
				;;
		esac
		shift
	done

	# verify required options specified
	if [[ -z "${file_path}" ]]; then
		logger "File path not specified, showing help..." "WARN"
		show_help_dos2unix
		return 1
	fi

	# verify file path exists
	if [ ! -f "${file_path}" ]; then
		logger "File path '${file_path}' does not exist, exiting function..." "WARN"
		return 1
	fi

	# run sed to switch line endings (in-place edit)
	sed -i $'s/\r$//' "${file_path}"
}


function trim() {

	while [ "$#" != "0" ]
	do
		case "$1"
		in
			-s|--string)
				string=$2
				shift
				;;
			-ll|--log-level)
				log_level=$2
				shift
				;;
			-h|--help)
				show_help_dos2unix
				exit 0
				;;
			*)
				echo "[WARN] Unrecognised argument '$1', displaying help..." >&2
				echo ""
				show_help_trim
				return 1
				;;
		esac
		shift
	done

	# verify required options specified
	if [[ -z "${string}" ]]; then
		logger "String to trim not specified, showing help..." "WARN"
		show_help_trim
		return 1
	fi

	# remove leading whitespace characters
	string="${string#"${string%%[![:space:]]*}"}"

	# remove trailing whitespace characters
	string="${string%"${string##*[![:space:]]}"}"

	# return stripped string
	echo "${string}"
}


function show_help_symlink() {
	cat <<ENDHELP
Description:
	A function to symlink a source path to a destination path.
Syntax:
	source ./utils.sh && symlink [args]
Where:
	-h or --help
		Displays this text.

	-sp or --src-path <path>
		Define source path containing files you want to copy to dst-path.
		No default.

	-dp or --dst-path <path>
		Define destinaiton path to store files copied from src-path,
		this is then symlinked back (src-path renamed to *-backup).
		No default.

	-lt or --link-type <softlink|hardlink>
		Define the symlink type.
		No default.

	-ll or --log-level <DEBUG|INFO|WARN|ERROR>
		Define logging level.
		Defaults to '${defaultLogLevel}'.

Examples:
	Create softlink from /home/nobody to /config/code-server/home with debugging on:
		source '/usr/local/bin/utils.sh' && symlink --src-path '/home/nobody' --dst-path '/config/code-server/home' --link-type 'softlink' --log-level 'WARN'

	Create hardlink from /home/nobody to /config/code-server/home with debugging on:
		source '/usr/local/bin//utils.sh' && symlink --src-path '/home/nobody' --dst-path '/config/code-server/home' --link-type 'hardlink' --log-level 'WARN'

ENDHELP
}

function show_help_log_rotate() {
	cat <<ENDHELP
Description:
	A function to rotate log files
Syntax:
	source ./utils.sh && log_rotate [args]
Where:
	-h or --help
		Displays this text.

	-lp or --log-path <path>
		Define path to log file.
		No default.

	-nl or --number-logs <number of logs>
		Define number of log files to keep.
		Defaults to '${defaultNumberLogs}'.

	-fs or --file-size <size of log in kb>
		Define size of each log file in Kb.
		Defaults to '${defaultFileSize}'.

Examples:
	Log rotate rclone log file keeping 3 log files and switching log file when size exceeds 1-2-48 Kb::
		source '/usr/local/bin/utils.sh' && log_rotate --log-path '/config/rclone/logs/rclone.log' --number-logs '3' --file-size '102048'

ENDHELP
}

function show_help_dos2unix() {
	cat <<ENDHELP
Description:
	A function to change line endings from dos to unix
Syntax:
	source ./utils.sh && dos2unix [args]
Where:
	-h or --help
		Displays this text.

	-fp or --file-path <path>
		Define file path to file to convert from DOS line endings to UNIX.
		No default.

	-ll or --log-level <DEBUG|INFO|WARN|ERROR>
		Define logging level.
		Defaults to '${defaultLogLevel}'.

Examples:
	Convert line endings for wireguard config file 'config/wireguard/wg0.conf' with debugging on:
		source '/usr/local/bin/utils.sh' && dos2unix --file-path '/config/wireguard/wg0.conf' --log-level 'WARN'

ENDHELP
}

function show_help_trim() {
	cat <<ENDHELP
Description:
	A function to trim whitespace from start and end of string
Syntax:
	source ./utils.sh && trim [args]
Where:
	-h or --help
		Displays this text.

	-s or --string <string to trim>
		Define the string to trim whitespace from.
		No default.

	-ll or --log-level <DEBUG|INFO|WARN|ERROR>
		Define logging level.
		Defaults to '${defaultLogLevel}'.

Examples:
	Trim whitespace from the following string '    abc    ' with debugging on:
		source '/usr/local/bin/utils.sh' && trim --string '    abc    ' --log-level 'WARN'

ENDHELP
}
