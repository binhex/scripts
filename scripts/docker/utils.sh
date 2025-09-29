#!/bin/bash

# extract filename of this script with relative path
ourScriptName="${BASH_SOURCE[-1]}"

# extract filename only with no relative path
ourScriptName=$(basename -- "${ourScriptName}")

# extract absolute path to this script
ourScriptPath=$(pwd)

# extract filename of this script without extension i.e. app name
ourAppName="${ourScriptName%.*}"

# set defaults
defaultGitHubDownloadPath="$(pwd)"
defaultGitHubAssetNumber="0"
defaultLogLevel=info
defaultLogSizeMB=10
defaultLogPath="${ourScriptPath}/logs"
defaultLogRotation=5

LOG_LEVEL="${defaultLogLevel}"
LOG_SIZE="${defaultLogSizeMB}"
LOG_PATH="${defaultLogPath}"
LOG_ROTATION="${defaultLogRotation}"
DOWNLOAD_PATH="${defaultGitHubDownloadPath}"
GITHUB_ASSET_NUMBER="${defaultGitHubAssetNumber}"

function download_github_release_asset() {

	while [ "$#" != "0" ]
	do
		case "$1"
		in
			-dp|--download-path)
				DOWNLOAD_PATH=$2
				shift
				;;
			-go|--github-owner)
				github_owner=$2
				shift
				;;
			-gr| --github-repo)
				github_repo=$2
				shift
				;;
			-gan|--github-asset-number)
				GITHUB_ASSET_NUMBER=$2
				shift
				;;
			-gar|--github-asset-regex)
				github_asset_regex=$2
				shift
				;;
			-ll|--log-level)
				LOG_LEVEL=$2
				shift
				;;
			-h|--help)
				show_help_download_github_release_asset
				return 0
				;;
			*)
				echo "[WARN] Unrecognised argument '$1', displaying help..." >&2
				echo ""
				show_help_download_github_release_asset
				return 1
				;;
		esac
		shift
	done

	# verify required options specified
	if [[ -z "${github_owner}" ]]; then
		shlog 2 "GitHub owner not specified, showing help..."
		show_help_download_github_release_asset
		return 1
	fi

	if [[ -z "${github_repo}" ]]; then
		shlog 2 "GitHub repo not specified, showing help..."
		show_help_download_github_release_asset
		return 1
	fi

	if [[ -z "${github_asset_regex}" ]]; then
		shlog 2 "GitHub asset regex not specified, showing help..."
		show_help_download_github_release_asset
		return 1
	fi

	# verify required tools installed
	if ! command -v jq &> /dev/null; then
		shlog 2 "jq not installed, please install jq before running this function..."
		return 1
	fi

	if ! command -v curl &> /dev/null; then
		shlog 2 "curl not installed, please install curl before running this function..."
		return 1
	fi

	# get url for github release asset
	asset_url=$(curl --silent "https://api.github.com/repos/${github_owner}/${github_repo}/releases" | jq -r "[.[].assets[] | select(.name | test(\"${github_asset_regex}\")).browser_download_url][${GITHUB_ASSET_NUMBER}]")

	shlog 2 "Downloading asset from '${asset_url}' to '${DOWNLOAD_PATH}'..."

	# download github release asset
	curl -o "${DOWNLOAD_PATH}/$(basename "${asset_url}")" -L "${asset_url}"
}

function shlog() {

	local log_message_level="${1}"
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

    if [[ -z "${log_message_level}" ]]; then
        echo "[ERROR] ${timestamp} :: No log message level passed to log function, showing help..."
        show_help_shlog
		return 1
    fi

    if [[ -z "${log_message}" ]]; then
        echo "[ERROR] ${timestamp} :: No log message passed to log function, showing help..."
        show_help_shlog
		return 1
    fi

    mkdir -p "${LOG_PATH}"

    # Construct full filepath to log file
    LOG_FILEPATH="${LOG_PATH}/${ourAppName}.log"

    # Convert human-friendly log levels to numeric
    case "${LOG_LEVEL,,}" in
        'debug') log_level_numeric=0 ;;
        'info') log_level_numeric=1 ;;
        'warn') log_level_numeric=2 ;;
        'error') log_level_numeric=3 ;;
        *) log_level_numeric=0 ;;
    esac

    if [[ ${log_message_level} -ge ${log_level_numeric} ]]; then
        case ${log_message_level} in
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
			-h|--help)
				show_help_symlink
				return 0
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
		shlog 2 "Source path not specified, showing help..."
		show_help_symlink
		return 1
	fi

	if [[ -z "${dst_path}" ]]; then
		shlog 2 "Destination path not specified, showing help..."
		show_help_symlink
		return 1
	fi

	if [[ -z "${link_type}" ]]; then
		shlog 2 "Link type not specified, showing help..."
		show_help_symlink
		return 1
	fi

	# verify link type
	if [[ "${link_type}" == "softlink" ]]; then
		link_type="-s"
	elif [[ "${link_type}" == "hardlink" ]]; then
		link_type=""
	else
		shlog 2 "Unknown link type of '${link_type}' specified, exiting function..."
		return 1
	fi

	# remove forward slash from end of src_path and dst_path if it exists
	src_path=${src_path%/}
	dst_path=${dst_path%/}

	# if the dst_path is already a symlink then exit
	if [[ -L "${dst_path}" ]]; then
		shlog 2 "'${src_path}' path already symlinked to '${dst_path}', nothing to do, exiting function..."
		return 0
	fi

	# helper function to create appropriate directories
	create_path_directories() {
		local path="$1"
		if [[ ! -e "${path}" ]]; then
			if [[ "${path}" == *.* ]]; then
				# path appears to be a file, create parent directory
				local parent_dir="${path%/*}"
				mkdir -p "${parent_dir}"
			else
				# path appears to be a directory, create the full path
				mkdir -p "${path}"
			fi
		fi
	}

	# create directories for src_path
	create_path_directories "${src_path}"
	create_path_directories "${dst_path}"

	# if the dst_path exists and is not empty then move to backup
	if [[ -e "${dst_path}" ]]; then
		if ! test -n "$(find "${dst_path}" -maxdepth 0 -empty)" ; then
			if ! stderr=$(mv "${dst_path}" "${dst_path}-backup" 2>&1 >/dev/null); then
				shlog 2 "Unable to move dst path '${dst_path}' to backup path '${dst_path}-backup' error is '${stderr}', exiting function..."
				return 1
			fi
		fi
	fi

	# if src_path is empty and the dst_path-backup is not empty then copy from ${dst_path}-backup to src_path recursively
	if test -n "$(find "${src_path}" -maxdepth 0 -empty)" ; then
		if ! test -n "$(find "${dst_path}-backup" -maxdepth 0 -empty)" ; then
			if [[ -d "${dst_path}-backup" ]]; then
				# Use cp -a with . to copy all contents including hidden files/directories
				if ! stderr=$(cp -a "${dst_path}-backup/." "${src_path}/" 2>&1 >/dev/null); then
					shlog 2 "Unable to copy from backup path '${dst_path}-backup' to source path '${src_path}' error is '${stderr}', exiting function..."
					return 1
				fi
			else
				if ! stderr=$(cp -a "${dst_path}-backup" "${src_path}" 2>&1 >/dev/null); then
					shlog 2 "Unable to copy from backup path '${dst_path}-backup' to source path '${src_path}' error is '${stderr}', exiting function..."
					return 1
				fi
			fi
		fi
	fi

	# if src_path is a directory then use glob
	if [[ -d "${src_path}" ]]; then
		# if src_path is a directory then symlink hidden files/directories
		if ! stderr=$(ln "${link_type}" "${src_path}/".* "${dst_path}" 2>&1 >/dev/null); then
			shlog 2 "Unable to symlink from path '${src_path}/.*' to '${dst_path}' error is '${stderr}', exiting function..."
			return 1
		fi
		# if src_path is a directory then symlink normal files/directories
		if ! stderr=$(ln "${link_type}" "${src_path}/"* "${dst_path}" 2>&1 >/dev/null); then
			shlog 2 "Unable to symlink from path '${src_path}/*' to '${dst_path}' error is '${stderr}', exiting function..."
			return 1
		fi
	else
		# if src_path is a file then symlink without glob
		if ! stderr=$(ln "${link_type}" "${src_path}" "${dst_path}" 2>&1 >/dev/null); then
			shlog 2 "Unable to symlink from path '${src_path}' to '${dst_path}' error is '${stderr}', exiting function..."
			return 1
		fi
	fi

	# reset ownership after symlink creation
	if [[ -n "${PUID}" && -n "${PGID}" ]]; then
		chown -R "${PUID}":"${PGID}" "${src_path}" "${dst_path}"
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
			-h|--help)
				show_help_dos2unix
				return 0
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
		shlog 2 "File path not specified, showing help..."
		show_help_dos2unix
		return 1
	fi

	# verify file path exists
	if [ ! -f "${file_path}" ]; then
		shlog 2 "File path '${file_path}' does not exist, exiting function..."
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
			-h|--help)
				show_help_dos2unix
				return 0
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
		shlog 2 "String to trim not specified, showing help..."
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

function show_help_download_github_release_asset() {
	cat <<ENDHELP
Description:
	A function to download assets from GitHub using curl and jq only.

Syntax:
	source "${ourScriptPath}/${ourScriptName}" && download_github_release_asset [args]

Where:
	-h or --help
		Displays this text.

	-dp or --download-path <path>
		Define path to download assets to.
		Defaults to '${defaultGitHubDownloadPath}'.

	-go or --github-owner <owners name>
		Define GitHub owner/org name.
		No default.

	-gr or --github-repo <repo name>
		Define GitHub repo name.
		No default.

	-gra or --github-release-asset <asset number>
		Define GitHub asset number, '0' being the first asset in the release, in date order.
		Defaults to '${defaultGitHubAssetNumber}'.

	-gar or --github-asset-regex <regex of asset>
		Define GitHub asset to match.
		No default.

Examples:
	Download AUR helper 'Paru' from the latest GitHub release with minimal supplied flags:
		source "${ourScriptPath}/${ourScriptName}" && download_github_release_asset --github-owner 'Morganamilo' --github-repo 'paru' --github-asset-regex 'paru-v2.0.3-1.*aarch64.*'

ENDHELP
}

function show_help_symlink() {
	cat <<ENDHELP
Description:
	A function to symlink a source path to a destination path.

Syntax:
	source "${ourScriptPath}/${ourScriptName}" && symlink [args]

Where:
	-h or --help
		Displays this text.

	-sp or --src-path <path>
		Define source path containing files you want to symlink to dst-path.
		No default.

	-dp or --dst-path <path>
		Define destinaiton path for symlink.
		No default.

	-lt or --link-type <softlink|hardlink>
		Define the symlink type.
		No default.

Notes:
	If src-path is empty or does not exist and dst-path is not empty then files from
	dst-path will be copied to the src-path before symlink creation.

Examples:
	Create softlink from /config/code-server/home to /home/nobody with debugging on:
		source "${ourScriptPath}/${ourScriptName}" && symlink --src-path '/config/code-server/home' --dst-path '/home/nobody' --link-type 'softlink'

	Create hardlink from /config/code-server/home to /home/nobody with debugging on:
		source "${ourScriptPath}/${ourScriptName}" && symlink --src-path '/config/code-server/home' --dst-path '/home/nobody' --link-type 'hardlink'

ENDHELP
}

function show_help_dos2unix() {
	cat <<ENDHELP
Description:
	A function to change line endings from dos to unix

Syntax:
	source "${ourScriptPath}/${ourScriptName}" && dos2unix [args]

Where:
	-h or --help
		Displays this text.

	-fp or --file-path <path>
		Define file path to file to convert from DOS line endings to UNIX.
		No default.

Examples:
	Convert line endings for wireguard config file 'config/wireguard/wg0.conf' with debugging on:
		source "${ourScriptPath}/${ourScriptName}" && dos2unix --file-path '/config/wireguard/wg0.conf'

ENDHELP
}

function show_help_trim() {
	cat <<ENDHELP
Description:
	A function to trim whitespace from start and end of string

Syntax:
	source "${ourScriptPath}/${ourScriptName}" && trim [args]

Where:
	-h or --help
		Displays this text.

	-s or --string <string to trim>
		Define the string to trim whitespace from.
		No default.

Examples:
	Trim whitespace from the following string '    abc    ' with debugging on:
		source "${ourScriptPath}/${ourScriptName}" && trim --string '    abc    '

ENDHELP
}

function show_help_shlog() {

	cat <<ENDHELP
Description:
	A function to log messages to console and file with defined log level and rotation.

Syntax:
	source "${ourScriptPath}/${ourScriptName}" && shlog [args]

Where:
	-h or --help
		Displays this text.

	-ll or --log-level <debug|info|warn|error>
		Define the logging level, debug being the most verbose and error being the least.
		Defaults to '${defaultLogLevel}'.

	-lp or --log-path <path>
		Define the logging path.
		Defaults to '${defaultLogPath}'.

	-ls or --log-size <size>
		Define the maximum logging file size in MB before being rotated.
		Defaults to '${defaultLogSizeMB}'.

	-lr or --log-rotation <file count>
		Define the maximum number of log files to be created.
		Defaults to '${defaultLogRotation}'.

Examples:
	Send a log message with the log level 1 (info):
		source "\${ourScriptPath}/\${ourScriptName}" && shlog 1 'Debug message'

	Send a log message with the log level 2 (warn):
		source "${ourScriptPath}/${ourScriptName}" && shlog 2 'Debug message'

ENDHELP

}

