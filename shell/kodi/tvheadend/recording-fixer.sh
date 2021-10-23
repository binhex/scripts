#!/bin/bash

# This script fixes up corrupt TV recordings which prevent fwd/rev/skip during playback

readonly ourScriptName="$(basename -- "$0")"
readonly ourScriptPath="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
readonly version="1.0.0"

ffmpeg_filepath="${1}"
input_video_path="${2}"

path="$(dirname "${input_video_path}")"
filename_with_extension=$(basename -- "$input_video_path")
filename="${filename_with_extension%.*}"
extension="${filename_with_extension##*.}"

tmp_file="${path}/${filename}.tmp.${extension}"
log_path="${ourScriptPath}/output.log"

echo "[info] Starting script '${ourScriptName}' version '${version}' by binhex - $(date)" >> "${log_path}"

echo "[info] Checking we have all required parameters before running..." >> "${log_path}"

if [[ -z "${ffmpeg_filepath}" ]]; then
	ffmpeg_filepath="/usr/bin/ffmpeg"
	echo "[info] Filepath to ffmpeg not defined via first parameter, assuming '${ffmpeg_filepath}'" >> "${log_path}"
fi

if [[ -z "${input_video_path}" ]]; then
	echo "[error] Please specify path to video file to process, exiting script..." >> "${log_path}"
	exit 1
fi

echo "[info] Deleting '${tmp_file}' to ensure no possible tmp file from previous run..." >> "${log_path}"
rm -f "${tmp_file}"

if "${ffmpeg_filepath}" -i "${input_video_path}" -c copy "${tmp_file}"; then
	echo "[info] Successfully processed video file '${input_video_path}', moving..." >> "${log_path}"
	mv -f "${tmp_file}" "${input_video_path}"
else
	echo "[warn] Error processing video file '${input_video_path}', removing tmp file and exiting script..." >> "${log_path}"
	rm -f "${tmp_file}"
	exit 1
fi

echo "[info] Script '${ourScriptName}' finished - $(date)" >> "${log_path}"
