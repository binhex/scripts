#!/bin/bash

# A simple bash script to make selected media read only, to prevent
# any possible Ransomware attacks.
#
# This script can also be used to protect against accidental or
# malicious attempted deletion of files.
#
# This script is inspired by this post (thanks BRiT):-
# https://forums.unraid.net/topic/46256-ransomware-resistance/?do=findComment&comment=603455

# script name and version
readonly ourScriptName=$(basename -- "$0")
readonly ourScriptVersion="v2.0.0"

# setup default values
readonly defaultInlcudeExtensions="*"
readonly defaultExcludeExtensions=""
readonly defaultIncludeFolders=""
readonly defaultExcludeFolders=""
readonly defaultDebug="no"
readonly defaultSecureChattr="yes"
readonly defaultSecureChattrRename="rttahc"
readonly defaultLockType="files"

include_extensions="${defaultInlcudeExtensions}"
exclude_extensions="${defaultExcludeExtensions}"
include_folders="${defaultIncludeFolders}"
exclude_folders="${defaultExcludeFolders}"
secure_chattr="${defaultSecureChattr}"
secure_chattr_rename="${defaultSecureChattrRename}"
lock_type="${defaultLockType}"
debug="{defaultDebug}"

if [[ ! -f '/usr/bin/chattr' && ! -f "/usr/bin/${secure_chattr_rename}" ]]; then
	echo "[warn] 'chattr' is required but is not installed, please install 'chattr', exiting script..."
	exit 1
fi

function lock_chattr(){

	if [ -f '/usr/bin/chattr' ]; then

		# identify user running this script
		user_id=$(id -u)

		# if not root then we cannot lock chattr
		if [[ "${user_id}" == "0" ]]; then

			if [[ "${debug}" == "yes" ]]; then
				echo "[debug] Locking chattr..."
			fi

			# remove execute permissions (all users) to prevent execution by ransomware
			chmod -x '/usr/bin/chattr'

			# rename chattr to make it harder for ransomware to run
			mv '/usr/bin/chattr' "/usr/bin/${secure_chattr_rename}"

		else

			echo "[warn] User ID '${user_id}' is not 'root', skipping locking of chattr"

		fi

	fi
}

function unlock_chattr(){

	if [ -f "/usr/bin/${secure_chattr_rename}" ]; then

		# identify user running this script
		user_id=$(id -u)

		# if not root then we cannot lock chattr
		if [[ "${user_id}" == "0" ]]; then

			if [[ "${debug}" == "yes" ]]; then
				echo "[debug] Unlocking chattr..."
			fi

			# reset permissions to correct values
			chmod 755 "/usr/bin/${secure_chattr_rename}"

			# rename chattr back to correct name
			mv "/usr/bin/${secure_chattr_rename}" '/usr/bin/chattr'

		else

			echo "[warn] User ID '${user_id}' is not 'root', skipping unlocking of chattr"

		fi

	fi

}

function process_files() {

	# unlock chattr by resetting permissions and renaming
	unlock_chattr

	# get all disks in the array, -v sorts numbers in natural order
	all_disks=$(ls -dv /mnt/disk* | xargs)

	# check that disks exists
	if [[ -z "${all_disks}" ]]; then
		echo "[warn] No disks found when issuing command 'ls -dv /mnt/disk*', array may not be accessible or host is not running UNRAID, exiting script..."; exit 1
	fi

	# split space separated disks in the array
	IFS=' ' read -ra all_disks_list <<< "${all_disks}"

	# split comma separated media user shares
	IFS=',' read -ra media_shares_list <<< "${media_shares}"

	# split comma separated include file extensions
	IFS=',' read -ra include_extensions_list <<< "${include_extensions}"

	# split comma separated exclude file extensions
	IFS=',' read -ra exclude_extensions_list <<< "${exclude_extensions}"

	# split comma separated include folders
	IFS=',' read -ra include_folders_list <<< "${include_folders}"

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
			exclude_extensions_cmd+="! -name \"${exclude_extensions_item}\""
		else
			exclude_extensions_cmd+=" ! -name \"${exclude_extensions_item}\""
		fi

	done

	if [[ -n "${exclude_extensions_cmd}" ]]; then
		exclude_extensions_cmd="\( ${exclude_extensions_cmd} \)"
	fi

	include_folders_cmd=""

	if [[ -n "${include_folders}" ]]; then

		# loop over list of folders to include
		for include_folders_item in "${include_folders_list[@]}"; do

			if [[ -z "${include_folders_cmd}" ]]; then

				include_folders_cmd+="-path \"*/${include_folders_item}/*\""
			else
				include_folders_cmd+=" -o -path \"*/${include_folders_item}/*\""
			fi

		done

	fi

	if [[ -n "${include_folders_cmd}" ]]; then
		include_folders_cmd="\( ${include_folders_cmd} \)"
	fi

	exclude_folders_cmd=""

	if [[ -n "${exclude_folders}" ]]; then

		# loop over list of folders to exclude
		for exclude_folders_item in "${exclude_folders_list[@]}"; do

			if [[ -z "${exclude_folders_cmd}" ]]; then

				exclude_folders_cmd+="! -path \"*/${exclude_folders_item}/*\""
			else
				exclude_folders_cmd+=" ! -path \"*/${exclude_folders_item}/*\""
			fi

		done

	fi

	if [[ -n "${exclude_folders_cmd}" ]]; then
		exclude_folders_cmd="\( ${exclude_folders_cmd} \)"
	fi

	# if lock files then set chattr to +i
	if [[ "${lock}" == "yes" ]]; then
		chattr_cmd="chattr +i"
	else
		chattr_cmd="chattr -i"
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

				# define lock type
				if [[ "${lock_type}" == "files" ]]; then
					find_type="-type f"
				elif [[ "${lock_type}" == "folders" ]]; then
					find_type="-type d"
				elif [[ "${lock_type}" == "both" ]]; then
					find_type=""
				fi

				if [[ "${debug}" == "yes" ]]; then
					echo "[debug] find '${media_shares_match}' ${find_type} ${include_folders_cmd} ${include_extensions_cmd} ${exclude_folders_cmd} ${exclude_extensions_cmd} -exec ${chattr_cmd} {} \;"
				fi
				eval "find '${media_shares_match}' ${find_type} ${include_folders_cmd} ${include_extensions_cmd} ${exclude_folders_cmd} ${exclude_extensions_cmd} -exec ${chattr_cmd} {} \;"

			else

				if [[ "${debug}" == "yes" ]]; then
					echo "[debug] No matching media share for disk '${all_disks_item}'"
				fi

			fi

			echo "[info] Processing finished for disk '${all_disks_item}'"
			echo "[info]"

		done

	done

	if [[ "${secure_chattr}" == "yes" ]]; then
		# lock chattr by removing execute permissions and renaming
		lock_chattr
	fi

}

function show_help() {
	cat <<ENDHELP
Description:
	A simple bash script to make selected media read only, to prevent any possible Ransomware attacks.
	${ourScriptName} ${ourScriptVersion} - Created by binhex.

Syntax:
	${ourScriptName} [args]

Where:
	-h or --help
		Displays this text.

	-l or --lock <yes|no>
		Define whether to make media read only or not.
		No default.

	-lt or --lock-type <files|folders|both>
		Define whether to lock files, folders or both.
		Defaults to '${defaultLockType}'.

	-ms or --media-shares <comma seperated list of user shares>
		Define the list of user share names to process.
		No default.

	-ie or --include-extensions <comma seperated list of extensions>
		Define the list of file extensions to process.
		Defaults to '${defaultInlcudeExtensions}'.

	-ee or --exclude-extensions <comma seperated list of extensions>
		Define the list of file extensions to exclude from processing.
		Defaults to no exclusions.

	-if or --include-folders <comma seperated list of folders>
		Define the list of folders to include (recursive) in processing.
		Defaults to include all folders.

	-ef or --exclude-folders <comma seperated list of folders>
		Define the list of folders to exclude (recursive) from processing.
		Defaults to no excluded folders.

	-sc or --secure-chattr <yes|no>
		Define whether you want to remove execution permissions and rename chattr to prevent it being run.
		Defaults to '${defaultSecureChattr}'.

	--debug <yes|no>
		Define whether debug is turned on or not.
		Defaults to '${defaultDebug}'.

Examples:
	Make all files and folders in a user share read only with no exclusions and debug turned on:
		${ourScriptName} --lock 'yes' --lock-type 'both' --media-shares 'Movies,TV' --debug 'yes'

	Make files in a user share read only with specific included file extensions:
		${ourScriptName} --lock 'yes' --lock-type 'files' --media-shares 'Movies,TV' --include-extensions '*.mkv,*.mp4'

	Make files in a user share read only with excluded file extensions:
		${ourScriptName} --lock 'yes' --lock-type 'files'--media-shares 'Movies,TV' --exclude-extensions '*.jpg,*.png'

	Make files in a user share read only with excluded file extensions and specific included folders:
		${ourScriptName} --lock 'yes' --lock-type 'files' --media-shares 'Movies,TV' --exclude-extensions '*.jpg,*.png' --include-folders 'tvshows,movies'

	Make files in a user share read only with excluded file extensions and excluded folders:
		${ourScriptName} --lock 'yes' --lock-type 'files' --media-shares 'Movies,TV' --exclude-extensions '*.jpg,*.png' --exclude-folders 'to_sort,temp'

	Make all files in a user share writeable with no exclusions and debug turned on:
		${ourScriptName} --lock 'no' --lock-type 'files' --media-shares 'Movies,TV' --debug 'yes'

	Make all files and folders in a user share writeable with no exclusions and debug turned on:
		${ourScriptName} --lock 'no' --lock-type 'both' --media-shares 'Movies,TV' --debug 'yes'

Notes:
	If you specify --lock-type 'both' then the specified media be read only, you will not be able to create new files/folders or alter any existing files/folders.
ENDHELP
}

while [ "$#" != "0" ]
do
	case "$1"
	in
		-l|--lock)
			lock=$2
			shift
			;;
		-lt|--lock-type)
			lock_type=$2
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
		-if|--include-folders)
			include_folders=$2
			shift
			;;
		-ef|--exclude-folders)
			exclude_folders=$2
			shift
			;;
		-sc|--secure-chattr)
			secure_chattr=$2
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

if [[ -z "${lock}" ]]; then
	echo "[warn] Lock files not defined via parameter -l or --lock, displaying help..."
	echo ""
	show_help
	exit 1
fi

if [[ -z "${media_shares}" ]]; then
	echo "[warn] Array user shares not defined via parameter -ms or --media-shares, displaying help..."
	echo ""
	show_help
	exit 1
fi

# run main function
process_files

echo "[info] ${ourScriptName} script finished"