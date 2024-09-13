#!/bin/bash

readonly ourScriptName="$(basename -- "$0")"
readonly ourScriptPath="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
readonly ourScriptVersion="1.1.0"

readonly defaultFfmpegFilepath='/usr/bin/ffmpeg'
readonly defaultLogFilepath="${ourScriptPath}/${ourScriptName}.log"
readonly defaultLogLevel="INFO"

ffmpeg_filepath="${defaultFfmpegFilepath}"
log_filepath="${defaultLogFilepath}"
log_level="${defaultLogLevel}"

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
		echo "[${log_priority}] [$(date)] ${log_message}" | tee -a "${log_filepath}"
	fi
}

function run() {

	path="$(dirname "${video_filepath}")"
	filename_with_extension=$(basename -- "$video_filepath")
	filename="${filename_with_extension%.*}"
	extension="${filename_with_extension##*.}"
	tmp_file="${path}/${filename}.tmp.${extension}"

	logger "Starting script '${ourScriptName}'..." "INFO"

	logger "Deleting '${tmp_file}' to ensure no possible tmp file from previous run..." "INFO"
	rm -f "${tmp_file}"

	if "${ffmpeg_filepath}" -i "${video_filepath}" -c copy "${tmp_file}"; then
		logger "Successfully processed video file '${video_filepath}', moving..." "INFO"
		mv -f "${tmp_file}" "${video_filepath}"
	else
		logger "Error processing video file '${video_filepath}', removing tmp file and exiting script..." "ERROR"
		rm -f "${tmp_file}"
		exit 1
	fi

	logger "Script '${ourScriptName}' finished." "INFO"

}

function show_help() {
	cat <<ENDHELP
Description:

	This script fixes up corrupt TV recordings which prevent fwd/rev/skip during playback.
	${ourScriptName} ${ourScriptVersion} - Created by binhex.

Syntax:

	${ourScriptName} [args]

Where:

	-h or --help
		Displays this text.

	-vf or --video-filepath
		Define filepath to Live TV recording to process.
		No default.

	-ff or --ffmpeg-filepath
		Define filepath to ffmpeg.
		Defaults to '${defaultFfmpegFilepath}'.

	-lf or --log-filepath
		Define filepath to log file.
		Defaults to '${defaultLogFilepath}'.

	-ll or --log-level
		Define logging level, valid values are DEBUG, INFO, WARN, ERROR.
		Defaults to '${defaultLogLevel}'.

Examples:

	Process Live TV recording:
		${ourScriptPath}/${ourScriptName} --video-filepath '/data/TV/Recordings/BBC1/Strictly Come Shooting/Shotguns Are Badass.mkv' --ffmpeg-filepath '/usr/bin/ffmpeg' --log-filepath '/tmp/output.log'

ENDHELP
}

while [ "$#" != "0" ]
do
	case "$1"
	in
		-vf|--video-filepath)
			video_filepath="${2}"
			shift
			;;
		-ff|--ffmpeg-filepath)
			ffmpeg_filepath="${2}"
			shift
			;;
		-lf|--log-filepath)
			log_filepath="${2}"
			shift
			;;
		-ll|--log-level)
			log_level="${2}"
			shift
			;;
		-h|--help)
			show_help
			exit 0
			;;
		*)
			echo "[warn] Unrecognised argument '$1', displaying help..." >&2
			echo ""
			show_help
			exit 1
			;;
	 esac
	 shift
done

logger "Checking we have all required parameters before running..." "INFO"

if [[ -z "${video_filepath}" ]]; then
	logger "Filepath to video file not defined via parameter '-vf' or '--video-filepath', displaying help..." "ERROR"
	echo ""
	show_help
	exit 1
fi

run