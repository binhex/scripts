#!/bin/bash

# A simple bash script to make selected media read only, to prevent
# any possible Ransomware attacks.
#
# This script can also be used to protect against accidental or
# malicious attempted deletion of files.
#
# This script is inspired by this post (thanks BRiT):-
# https://forums.unraid.net/topic/46256-ransomware-resistance/?do=findComment&comment=603455

# setup default values
readonly ourScriptName=$(basename -- "$0")
readonly defaultLockFiles="no"
readonly defaultInlcudeExtensions="*.*"
readonly defaultExcludeExtensions=""
readonly defaultExcludeFolders=""
readonly defaultDebug="no"

lock_files="${defaultLockFiles}"
include_extensions="${defaultInlcudeExtensions}"
exclude_extensions="${defaultExcludeExtensions}"
exclude_folders="${defaultExcludeFolders}"
debug="{defaultDebug}"

function process_files() {

	# if read only then set chattr else undo read only
	if [[ "${lock_files}" == "yes" ]]; then
		chattr_cmd="chattr +i"
	else
		chattr_cmd="chattr -i"
	fi

	# get all disks in the array
	all_disks=$(ls -d /mnt/disk* | xargs)

	# split space separated disks in the array
	IFS=' ' read -ra all_disks_list <<< "${all_disks}"

	# split comma separated media user shares
	IFS=',' read -ra media_shares_list <<< "${media_shares}"

	# split comma separated include file extensions
	IFS=',' read -ra include_extensions_list <<< "${include_extensions}"

	# split comma separated exclude file extensions
	IFS=',' read -ra exclude_extensions_list <<< "${exclude_extensions}"

	# split comma separated exclude folders
	IFS=',' read -ra exclude_folders_list <<< "${exclude_folders}"

	include_extensions_cmd=""

	# loop over list of file extensions to process and add required flags
	for include_extensions_item in "${include_extensions_list[@]}"; do

		if [[ -z "${include_extensions_cmd}" ]]; then
			include_extensions_cmd+="-name \"${include_extensions_item}\""
		else
			include_extensions_cmd+=" -o -name \"${include_extensions_item}\""
		fi

	done

	if [[ -n "${include_extensions_cmd}" ]]; then
		include_extensions_cmd="\( ${include_extensions_cmd} \)"
	fi

	exclude_extensions_cmd=""

	# loop over list of file extensions to process and add required flags
	for exclude_extensions_item in "${exclude_extensions_list[@]}"; do

		if [[ -z "${exclude_extensions_cmd}" ]]; then
			exclude_extensions_cmd+="-not -name \"${exclude_extensions_item}\""
		else
			exclude_extensions_cmd+=" -o -not -name \"${exclude_extensions_item}\""
		fi

	done

	if [[ -n "${exclude_extensions_cmd}" ]]; then
		exclude_extensions_cmd="\( ${exclude_extensions_cmd} \)"
	fi

	exclude_folders_cmd=""

	if [[ -n "${exclude_folders}" ]]; then

		# loop over list of folders to exclude
		for exclude_folders_item in "${exclude_folders_list[@]}"; do

			if [[ -z "${exclude_folders_cmd}" ]]; then
				exclude_folders_cmd+="-not -path \"*/${exclude_folders_item}/*\""
			fi

		done

	fi

	# loop over list of disk shares looking for top level user share matches
	for all_disks_item in "${all_disks_list[@]}"; do

		# loop over list of media share names looking for media share names that match what we want
		for media_shares_item in "${media_shares_list[@]}"; do

			echo "[info] Finding share that match '${media_shares_item}' on disk '${all_disks_item}'..."
			if [[ "${debug}" == "yes" ]]; then
				echo "[debug] find ${all_disks_item} -maxdepth 1 -type d -name ${media_shares_item}"
			fi
			media_shares_match=$(find "${all_disks_item}" -maxdepth 1 -type d -name "${media_shares_item}")

			# if a match then process with chattr
			if [[ -n "${media_shares_match}" ]]; then

				echo "[info] Share found, processing media share '${media_shares_match}' using 'chattr' recursively..."
				if [[ "${debug}" == "yes" ]]; then
					echo "[debug] find ${media_shares_match} -type f ${exclude_folders_cmd} ${include_extensions_cmd} ${exclude_extensions_cmd} -exec ${chattr_cmd} {} \;"
				fi
				eval "find ${media_shares_match} -type f ${exclude_folders_cmd} ${include_extensions_cmd} ${exclude_extensions_cmd} -exec ${chattr_cmd} {} \;"

			else

				echo "[debug] No matching media share for disk '${all_disks_item}'"

			fi

			echo "[info] Processing finished for disk '${all_disks_item}'"
			echo "[info]"

		done

	done
}

function show_help() {
	cat <<ENDHELP
Description:
	A simple bash script to make selected media read only, to prevent any possible Ransomware attacks.
Syntax:
	${ourScriptName} [args]
Where:
	-h or --help
		Displays this text.

	-lf or --lock-files <yes|no>
		Define whether to make media read only or not.
		Defaults to '${defaultLockFiles}'.

	-ms or --media-shares <comma seperated list of user shares>
		Define the list of user sharews to make read only.
		No default.

	-ie or --include-extensions <comma seperated list of extensions>
		Define the list of file extensions to make read only.
		Defaults to '${defaultInlcudeExtensions}'.

	-ee or --exclude-extensions <comma seperated list of extensions>
		Define the list of file extensions to exclude from making read only.
		Defaults to '${defaultExcludeExtensions}'.

	-ef or --exclude-folders <comma seperated list of folders>
		Define the list of folders to exclude from making read only.
		Defaults to '${defaultExcludeFolders}'.

	--debug <yes|no>
		Define whether debug is turned on or not.
		Defaults to '${defaultDebug}'.

Examples:
	Make all files in a user share read only with no exclusions and debug turned on:
		${ourScriptName} --lock-files 'yes' --media-shares 'Movies, TV' --include-extensions '*.*' --debug 'yes'

	Make all files in a user share read only with excluded file extensions:
		${ourScriptName} --lock-files 'yes' --media-shares 'Movies, TV' --include-extensions '*.*' --exclude-extensions '*.jpg,*.png'

	Make all files in a user share read only with excluded file extensions and excluded folders:
		${ourScriptName} --lock-files 'yes' --media-shares 'Movies, TV' --include-extensions '*.*' --exclude-extensions '*.jpg,*.png' --exclude-folders 'temp,downloaded'

ENDHELP
}

while [ "$#" != "0" ]
do
	case "$1"
	in
		-lf|--lock-files)
			lock_files=$2
			shift
			;;
		-ms|--media-shares)
			media_shares=$2
			shift
			;;
		-ie| --include-extensions)
			include_extensions=$2
			shift
			;;
		-ee| --exclude-extensions)
			exclude_extensions=$2
			shift
			;;
		-ef|--exclude-folders)
			exclude_folders=$2
			shift
			;;
		--debug)
			debug=$2
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

echo "[info] Running ${ourScriptName} script..."

echo "[info] Checking we have all required parameters before running..."

if [[ -z "${media_shares}" ]]; then
	echo "[warn] Array user shares not defined via parameter -ms or --media-shares, displaying help..."
	echo ""
	show_help
	exit 1
fi

# run main function
process_files

echo "[info] ${ourScriptName} script finished"