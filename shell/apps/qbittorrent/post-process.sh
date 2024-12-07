#!/bin/bash

# fail on non zero exit code, unset variables, and pipefail
set -euo pipefail

# TODO add in more logging and make use of logging levels
# TODO add param to specify file types in content path to process (currently hard set to .mkv)

# script name
ourScriptName=$(basename -- "$0")
# absolute filepath to this script
ourScriptFilePath=$(realpath "$0")
# absolute path to this script
ourScriptPath=$(dirname "${ourScriptFilePath}")
ourScriptVersion="v1.0.0"

defaultSavePath="/data/completed"
defaultDirectoryName="subs"
defaultLogLevel=debug
defaultLogSizeMB=10
defaultLogPath="${ourScriptPath}/logs"

SAVE_PATH="${defaultSavePath}"
DIRECTORY_NAME="${defaultDirectoryName}"

# Set default values for logging
LOG_LEVEL="${defaultLogLevel}"
LOG_SIZE="${defaultLogSizeMB}"
LOG_PATH="${defaultLogPath}"

function check_prereqs() {

    if [[ -z "${CONTENT_PATH:-}" ]]; then
        logger 1 "Exiting script as --content-path appears to be set to an empty string..."
        show_help
        exit 1
    fi

    if [[ -z "${SAVE_PATH:-}" ]]; then
        logger 1 "Exiting script as --save-path appears to be set to an empty string..."
        show_help
        exit 2
    fi

    if [[ "${SAVE_PATH}" == "/" || "${SAVE_PATH}" == "/data" || "${SAVE_PATH}" == "/media" ]]; then
        logger 1 "Exiting script as '--save-path' appears to be set to '/', '/data' or '/media', exiting script..."
        exit 3
    fi

    if [[ "${CONTENT_PATH}" == "${SAVE_PATH}" ]]; then
        logger 1 "Exiting script as '--content-path' and '--save-path' appear to be the same, exiting script..."
        exit 4
    fi

}

function logger() {

    local log_level=$1
    shift
    local log_message="$*"

    local log_entry
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Define log levels
    local log_level_debug=0
    local log_level_info=1
    local log_level_warn=2
    local log_level_error=3

    if [[ -z "${log_message}" ]]; then
        logger 1 "[ERROR] ${timestamp} :: No log message passed to logger function"
        exit 1
    fi

    if [[ -z "${LOG_PATH}" ]]; then
        logger 1 "[ERROR] ${timestamp} :: Log path not defined. Exiting script..."
        exit 1
    fi

    mkdir -p "${LOG_PATH}"

    # Construct full filepath to log file
    LOG_FILEPATH="${LOG_PATH}/${ourScriptName}.log"

    # Convert human-friendly log levels to numeric
    case "${LOG_LEVEL}" in
        'debug') LOG_LEVEL=0 ;;
        'info') LOG_LEVEL=1 ;;
        'warn') LOG_LEVEL=2 ;;
        'error') LOG_LEVEL=3 ;;
        *) LOG_LEVEL=0 ;;
    esac

    if [[ ${log_level} -ge ${LOG_LEVEL} ]]; then
        case ${log_level} in
            "${log_level_debug}")
                log_entry="[DEBUG] ${timestamp} :: ${log_message}"
                ;;
            "${log_level_info}")
                log_entry="[INFO] ${timestamp} :: ${log_message}"
                ;;
            "${log_level_warn}")
                log_entry="[WARN] ${timestamp} :: ${log_message}"
                ;;
            "${log_level_error}")
                log_entry="[ERROR] ${timestamp} :: ${log_message}"
                ;;
            *)
                log_entry="[UNKNOWN] ${timestamp} :: ${log_message}"
                ;;
        esac

        # Print to console
        echo "${log_entry}"

        # Rotate log file if necessary
        rotate_log_file

        # Append to log file
        echo "${log_entry}" >> "${LOG_FILEPATH}"
    fi

}

function rotate_log_file() {

    # Convert human friendly size to bytes
    local log_size_in_bytes=$((LOG_SIZE * 1024 * 1024))

    if [[ -f "${LOG_FILEPATH}" && $(stat -c%s "${LOG_FILEPATH}") -ge ${log_size_in_bytes} ]]; then
        mv "${LOG_FILEPATH}" "${LOG_FILEPATH}.1"
        touch "${LOG_FILEPATH}"
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
        logger 1 "Deleting files with regex: ${param_regex_iter}"
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
    else
        logger 1 "Files with extension '.mkv' not found in content path '${CONTENT_PATH}', exiting script..."
    fi

}

function main() {

    logger 1 "Running script '${ourScriptName}'..."

    # Detect media type, if video file then delete extras, else do nothing
    detect_media_type

    logger 1 "Script '${ourScriptName}' finished"
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

    -ll or --log-level <debug|info|warn|error>
        Define thelogging level, debug being the most verbose and error being the least.
        Defaults to '${defaultLogLevel}'.

    -lp or --log-path <path>
        Define the logging level, debug being the most verbose and error being the least.
        Defaults to '${defaultLogPath}'.

    -ls or --log-size <size>
        Define the maximum logging file size in MB before being rotated.
        Defaults to '${defaultLogSizeMB}'.

Example:
    /bin/bash -c "${ourScriptPath}/${ourScriptName} --content-path '%F' --save-path '%D' --filename 'rarbg.*,.*jpg,.*png,.*txt,.*nfo,.*lnk,.*srt,.*sfv,.*sub,.*cmd,.*bat,.*ps1,.*zipx,.*url' --directory '.*subs.*,.*sample.*,.*featurettes.*,.*screenshots.*'"

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
        -ll|--log-level)
            LOG_LEVEL=$2
            shift
            ;;
        -lp|--log-path)
            LOG_PATH=$2
            shift
            ;;
        -ls|--log-size)
            LOG_SIZE=$2
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            logger 3 "Unrecognised argument '$1', displaying help..." >&2
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