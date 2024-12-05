#!/bin/bash

# fail on non zero exit code, unset variables, and pipefail
set -euo pipefail

# TODO Add in logging

# script name
ourScriptName=$(basename -- "$0")
# absolute filepath to this script
ourScriptFilePath=$(realpath "$0")
# absolute path to this script
ourScriptPath=$(dirname "${ourScriptFilePath}")
ourScriptVersion="v1.0.0"

defaultSavePath="/data/completed"
defaultDirectoryName="subs"

SAVE_PATH="${defaultSavePath}"
DIRECTORY_NAME="${defaultDirectoryName}"

function check_prereqs() {

    if [[ -z "${CONTENT_PATH}" ]]; then
        echo "[warn] Exiting script as --content-path appears to be set to an empty string..."
        show_help
        exit 1
    fi

    if [[ -z "${SAVE_PATH}" ]]; then
        echo "[warn] Exiting script as --save-path appears to be set to an empty string..."
        show_help
        exit 2
    fi

    if [[ "${SAVE_PATH}" == "/" || "${SAVE_PATH}" == "/data" || "${SAVE_PATH}" == "/media" ]]; then
        echo "[warn] Exiting script as '--save-path' appears to be set to '/', '/data' or '/media', exiting script..."
        show_help
        exit 3
    fi

    if [[ "${CONTENT_PATH}" == "${SAVE_PATH}" ]]; then
        echo "[warn] Exiting script as '--content-path' and '--save-path' appear to be the same, exiting script..."
        show_help
        exit 4
    fi

}

function find_filenames(){

    local file_regex="$1"
    shift
    local path="$1"

    local find_result

    find_result="$(find "${path}" -regextype egrep -regex "${file_regex}")"
    echo "${find_result}"

}

function delete_files(){

    local param_regex="$1"
    shift
    local path="$1"

    IFS=',' read -r -a param_regex_array <<< "${param_regex}"

    for param_regex_iter in "${param_regex_array[@]}"; do
        find "${path}" -regextype egrep -iregex "${param_regex_iter}" -exec rm -rf {} \; 2>/dev/null || true
    done

}

function detect_media_type() {

    local find_video_filepaths
    find_video_filepaths="$(find_filenames '.*mkv' "${CONTENT_PATH}")"

    if [[ -n "${find_video_filepaths}" ]]; then
        delete_files "${FILE_NAME}" "${CONTENT_PATH}"
        delete_files "${DIRECTORY_NAME}" "${CONTENT_PATH}"
        delete_files ".*part" "${SAVE_PATH}"
    fi

}

function main() {

    echo "[INFO] Running script '${ourScriptName}'..."

    # Detect media type, if video file then delete extras, else do nothing
    detect_media_type

    echo "[INFO] Script '${ourScriptName}' finished"
}


function show_help() {

    cat <<ENDHELP
Description:
    A simple bash script to remove crud from qBittorrent save path.
    ${ourScriptName} ${ourScriptVersion}.

Syntax:
    ./${ourScriptName} [args]

Where:
    -h or --help
        Displays this text.

    -cp or --content-path <path>
        Define the content path (same as root path for multi-file torrent) in qBittorrent.
        No default.

    -sp or --save-path <path>
        Define the save path in qBittorrent.
        Defaults to '${defaultSavePath}'.

    -f or --filename <path>
        Define the filename regex you wish to delete.
        No default.

    -d or --directory <path>
        Define the directory regex you wish to delete.
        Defaults to '${defaultDirectoryName}'.

Example:
    /bin/bash -c "${ourScriptPath}/${ourScriptName} --content-path '%F' --save-path '%D' --filename 'rarbg.*,.*jpg,.*png,.*txt,.*nfo,.*lnk,.*srt,.*sub,.*cmd,.*bat,.*ps1,.*zipx,.*url' --directory '.*subs.*,.*sample.*,.*featurettes.*,.*screenshots.*' >> '%D/script.log'"

Notes:
    Be careful, this script CAN delete files and folders!.
ENDHELP

}

while [ "$#" != "0" ]
do
    case "$1"
    in
        -cp|--content-path)
            CONTENT_PATH=$2
            shift
            ;;
        -sp|--save-path)
            SAVE_PATH=$2
            shift
            ;;
        -f|--filename)
            FILE_NAME=$2
            shift
            ;;
        -d|--directory)
            DIRECTORY_NAME=$2
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

# run
check_prereqs
main