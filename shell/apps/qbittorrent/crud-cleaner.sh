#!/bin/bash

# fail on non zero exit code, unset variables, and pipefail
set -euo pipefail

# TODO add in more logging and make use of logging levels
# TODO add param to specify file types in content path to process (currently hard set to .mkv)

# extract filename of this script
ourScriptName=$(basename -- "$0")

# extract absolute path to this script
ourScriptPath=$(dirname "$(realpath "$0")")

# extract filename of this script without extension i.e. app name
ourAppName="${ourScriptName%.*}"

# script version
ourScriptVersion="v1.0.0"

# default values
defaultFileName="rarbg.*,.*jpg,.*png,.*txt,.*nfo,.*lnk,.*srt,.*srr,.*sfv,.*sub,.*cmd,.*bat,.*ps1,.*zipx,.*url"
defaultDirectoryName=".*subs.*,.*sample.*,.*featurettes.*,.*screenshots.*,.*proof.*"

defaultLogLevel=info
defaultLogSizeMB=10
defaultLogPath="${ourScriptPath}/logs"
defaultLogRotation=5

FILE_NAME="${defaultFileName}"
DIRECTORY_NAME="${defaultDirectoryName}"

LOG_LEVEL="${defaultLogLevel}"
LOG_SIZE="${defaultLogSizeMB}"
LOG_PATH="${defaultLogPath}"
LOG_ROTATION="${defaultLogRotation}"

function check_prereqs() {

    if [[ -z "${CONTENT_PATH:-}" ]]; then
        logger 3 "Exiting script as --content-path appears to be set to an empty string..."
        show_help
        exit 1
    fi

    if [[ -z "${SAVE_PATH:-}" ]]; then
        logger 3 "Exiting script as --save-path appears to be set to an empty string..."
        show_help
        exit 2
    fi

    if [[ -z "${ROOT_PATH:-}" ]]; then
        logger 3 "Exiting script as --root-path appears to be set to an empty string..."
        show_help
        exit 3
    fi

    if [[ "${SAVE_PATH}" == "/" || "${SAVE_PATH}" == "/data" || "${SAVE_PATH}" == "/media" ]]; then
        logger 2 "Exiting script as '--save-path' appears to be set to '/', '/data' or '/media', exiting script..."
        exit 4
    fi

    if [[ "${SAVE_PATH}" == "${ROOT_PATH}" ]]; then
        logger 2 "Exiting script as '--save-path' and '--root-path' appear to be the same, exiting script..."
        exit 5
    fi

}

function logger() {

    local log_level=$1
    shift
    local log_message="$*"

    local log_level_numeric
    local log_entry
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Define log levels
    local log_level_debug=0
    local log_level_info=1
    local log_level_warn=2
    local log_level_error=3

    if [[ -z "${log_message}" ]]; then
        echo "[ERROR] ${timestamp} :: No log message passed to logger function"
        exit 1
    fi

    if [[ -z "${LOG_PATH}" ]]; then
        echo "[ERROR] ${timestamp} :: Log path not defined. Exiting script..."
        exit 1
    fi

    mkdir -p "${LOG_PATH}"

    # Construct full filepath to log file
    LOG_FILEPATH="${LOG_PATH}/${ourAppName}.log"

    # Convert human-friendly log levels to numeric
    case "${LOG_LEVEL}" in
        'debug') log_level_numeric=0 ;;
        'info') log_level_numeric=1 ;;
        'warn') log_level_numeric=2 ;;
        'error') log_level_numeric=3 ;;
        *) log_level_numeric=0 ;;
    esac

    if [[ ${log_level} -ge ${log_level_numeric} ]]; then
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

    # Convert human-friendly size to bytes
    local log_size_in_bytes=$((LOG_SIZE * 1024 * 1024))

    if [[ -f "${LOG_FILEPATH}" && $(stat -c%s "${LOG_FILEPATH}") -ge ${log_size_in_bytes} ]]; then
        # Rotate log files
        for ((i=LOG_ROTATION-1; i>=1; i--)); do
            if [[ -f "${LOG_FILEPATH}.${i}" ]]; then
                mv "${LOG_FILEPATH}.${i}" "${LOG_FILEPATH}.$((i+1))"
            fi
        done

        # Move the current log file to .1
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

function delete_files_and_dirs(){

    local param_regex="$1"
    shift
    local path="$1"
    shift
    local file_type="$1"

    logger 1 "Looking for matching ${file_type} to delete for path: '${path}'..."

    IFS=',' read -r -a param_regex_array <<< "${param_regex}"

    for param_regex_iter in "${param_regex_array[@]}"; do
        logger 0 "Searching for ${file_type} with regex: '${param_regex_iter}'..."
        # Find matching files and log them, csse insensitive (iregex)
        find "${path}" -regextype egrep -iregex "${param_regex_iter}" -print | \
        while read -r file; do
            logger 1 "Deleting ${file_type}: '${file}'"
            if [[ "${file_type}" == "file" ]]; then
                rm -f "${file}"
            elif [[ "${file_type}" == "directory" ]]; then
                if [[ "${file}" == "/" || "${file}" == "/data" || "${file}" == "/media" ]]; then
                    logger 2 "Directory delete appears to be attempting to recursively delete to '/', '/data' or '/media', skipping..."
                    continue
                else
                    rm -rf "${file}"
                fi
            fi
        done 2>/dev/null || true
    done

}

function detect_media_type() {

    local find_video_filepaths
    find_video_filepaths="$(find_filenames '.*mkv' "${ROOT_PATH}")"

    if [[ -n "${find_video_filepaths}" ]]; then
        delete_files_and_dirs "${FILE_NAME}" "${ROOT_PATH}" "file"
        delete_files_and_dirs "${DIRECTORY_NAME}" "${ROOT_PATH}" "directory"
    else
        logger 1 "Media file type with extension '.mkv' NOT found in content path '${ROOT_PATH}', skipping file and directory deletion"
    fi

}

function delete_partial_files() {

    logger 1 "Deleting .part files generated when selecting partial downloads in qBittorrent '${SAVE_PATH}/*.parts'..."
    rm -f "${SAVE_PATH}/"*.parts

}

function main() {

    logger 1 "Running script '${ourScriptName}'..."

    logger 0  "Content Path: ${CONTENT_PATH}"
    logger 0  "Save Path: ${SAVE_PATH}"
    logger 0  "Root Path: ${ROOT_PATH}"

    detect_media_type
    delete_partial_files

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
        Define the content path of the torrent download in qBittorrent.
        No default.

    -sp or --save-path <path>
        Define the save path in qBittorrent.
        No default.

    -rp or --root-path <path>
        Define the root path for the torrent download in qBittorrent.
        No default.

    -f or --filename <path>
        Define the filename regex you wish to delete.
        Defaults to '${defaultFileName}'.

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

    -lr or --log-rotation <file count>
        Define the maximum number of log files to be created.
        Defaults to '${defaultLogRotation}'.

Example:
    /bin/bash -c "${ourScriptPath}/${ourScriptName} --log-level 'info' --content-path '%F' --save-path '%D' --root-path '%R' --filename 'rarbg.*,.*sample.*,.*jpg,.*png,.*txt,.*nfo,.*lnk,.*srt,.*sfv,.*sub,.*cmd,.*bat,.*ps1,.*zipx,.*url,.*exe,.*sh' --directory '.*subs.*,.*sample.*,.*featurettes.*,.*screenshots.*'"

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
        -rp|--root-path)
            ROOT_PATH=$2
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
        -lr|--log-rotation)
            LOG_ROTATION=$2
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