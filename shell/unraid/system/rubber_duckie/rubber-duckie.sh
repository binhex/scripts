#!/bin/bash

# what this script should do:
#
# detect drives not in unraid array
# check smart attributes
# run badblocks on each drive
# compare smart attributes
# if smart attributes do not match, then report back to user

# TODO finish off logger

# script name and version
readonly ourScriptName=$(basename -- "$0")
readonly ourFriendlyScriptName="${ourScriptName%.*}"
readonly ourScriptVersion="v2.0.0"

# set defaults
readonly defaultConfirm='yes'
readonly defaultNumBlocks="20000"
readonly defaultDestructiveTest='no'
readonly defaultDebug='no'
readonly defaultTestPattern='0x00'
readonly defaultLogPath='/tmp'

confirm="${defaultConfirm}"
num_blocks="${defaultNumBlocks}"
destructive_test="${defaultDestructiveTest}"
debug="${defaultDebug}"
test_pattern="${defaultTestPattern}"
log_path="${defaultLogPath}"

# construct required filepaths
unraid_super_filepath='/boot/config/super.dat'
in_progress_filepath="/tmp/${ourFriendlyScriptName}"

function logger() {
	local action="${1}"
	local run_cmd="${2}"

	if [[ "${debug}" == 'yes' ]]; then
		set -x
		${run_cmd} 2>&1 | tee -a "${log_path}"
		set +x
	fi
}

function check_prereqs() {

	echo "[INFO] Checking we have all required parameters before running..."

	if [[ -z "${action}" ]]; then
		echo "[WARN] Action not defined via parameter -a or --action, displaying help..."
		echo ""
		show_help
		exit 1
	fi

	if [[ "${action}" != 'test' && "${action}" != 'list' && "${action}" != 'check-smart' ]]; then
		echo "[WARN] Action defined via -a or --action does not match 'test', 'list', or 'check-smart', displaying help..."
		echo ""
		show_help
		exit 2
	fi

	if [[ "${action}" == 'test' || "${action}" == 'check-smart' ]]; then
		if [[ -z "${drive_name}" ]]; then
			echo "[WARN] Drive name not defined via parameter -dn or --drive-name, displaying help..."
			echo ""
			show_help
			exit 3
		fi

		if [[ "${destructive_test}" == 'no' ]]; then
			if [[ "${#test_pattern}" -gt 4 ]]; then
				echo "[WARN] Non destructive tests only supports a single test pattern via -tp or --test-pattern, displaying help..."
				echo ""
				show_help
				exit 4
			fi
		fi

	fi

	if [[ "${notify_service}" == 'ntfy' && -z "${ntfy_topic}" ]]; then
		echo "[WARN] Notify Service defined as 'ntfy', but no topic spcified via -nt or --ntfy-topic, displaying help..."
		echo ""
		show_help
		exit 5
	fi

	echo "[INFO] Checking we have all required tooling before running..."

	tools="smartctl badblocks blockdev grep sed"
	for i in ${tools}; do
		if ! command -v "${i}" > /dev/null 2>&1; then
			echo "[CRIT] Required tool '${i}' is missing, please install and re-run the script, exiting..."
			exit 4
		fi
	done
}

function get_disk_name_and_serial() {
	# get name e.g. sda, sdb,... and serial number for each disk, filtering out loop*, md*, and nvme devices
	# use comma to separate name and serial number and a single space to separate each disk
	disk_name_and_serial_filtered_disks_list=$(lsblk --nodeps -no name,serial | tr -s '[:blank:]' ',' | grep -v '^loop*' | grep -v '^nvme*' | grep -v '^md*' | xargs)
}

function filter_disks_not_in_scope() {

	local disk_name="${1}"

	# if we cannot determine smart info then its unlikely to be a spinning disk
	if ! smartctl -a "/dev/${disk_name}" > /dev/null 2>&1; then
		return 0
	fi

	# filter out non spinning disks, such as ssd's
	if smartctl -a "/dev/${disk_name}" | grep -P -q -o -m 1 '^Device Model\:.*SSD'; then
		return 0
	fi

	# filter out any disks being already processed
	if read_serial_from_in_progress_filepath "${disk_serial}"; then
		return 0
	fi
	return 1
}

function find_all_disks_not_in_array() {

	local disks_in_array_array=()
	local disks_not_in_scope_array=()
	local disks_not_in_array_array=()

	echo "[INFO] Gathering potential candidates for processing, please wait whilst all disks are spun up..."
	get_disk_name_and_serial
	for i in ${disk_name_and_serial_filtered_disks_list}; do
		disk_name=$(echo "${i}" | grep -P -o -m 1 '^[^,]+')
		disk_serial=$(echo "${i}" | grep -P -o -m 1 '[^,]+$')
		if filter_disks_not_in_scope "${disk_name}"; then
			disks_not_in_scope_array+=("${i}")
			continue
		fi
		if grep -P -o -q -a -m 1 "${disk_serial}" < "${unraid_super_filepath}"; then
			disks_in_array_array+=("${i}")
			continue
		else
			disks_not_in_array_array+=("${i}")
		fi
	done
	if [[ -z "${disks_not_in_array_array[*]}" ]]; then
		echo "[INFO] No candidates for processing found, exiting..."
		return 1
	fi
	if [[ "${debug}" == 'yes' ]]; then
		echo "[DEBUG] Disks in the array (do not check) are '${disks_in_array_array[*]}'"
		echo "[DEBUG] Disks NOT in scope (do not check) are '${disks_not_in_scope_array[*]}'"
	fi
	echo "[INFO] Disks NOT in the array (candidates for testing) are '${disks_not_in_array_array[*]}'"
	return 0
}

function read_serial_from_in_progress_filepath() {
	# filter out any disks being already processed
	if [ -f "${in_progress_filepath}" ]; then
		if grep -P -o -q -m 1 "${disk_serial}" < "${in_progress_filepath}"; then
			return 0
		fi
	fi
	return 1
}

function add_serial_to_in_progress_filepath() {
    if [[ -z "${disk_serial}" ]]; then
        echo "[ERROR] disk_serial is empty or undefined. Cannot add serial to in-progress file."
        return 1
    fi

	echo "${disk_serial}" >> "${in_progress_filepath}"
}

function remove_serial_from_in_progress_filepath() {
    if [[ -z "${disk_serial}" ]]; then
        echo "[ERROR] disk_serial is empty or undefined. Cannot remove serial from in-progress file."
        return 1
    fi

    # Remove the line containing the disk serial
    sed -i "/${disk_serial}/d" "${in_progress_filepath}"

    # Remove any empty lines
    sed -i '/^$/d' "${in_progress_filepath}"
}

function check_smart_attributes() {

	local disk="${1}"
	local smart_attributes_monitor_list="UDMA_CRC_Error_Count Reallocated_Event_Count Current_Pending_Sector"

	for i in ${smart_attributes_monitor_list}; do
		smart_attribute_value=$(smartctl -a "/dev/${disk}" | grep "${i}" | rev | cut -d ' ' -f1)
		if [[ "${smart_attribute_value}" != 0 ]]; then
			if [[ "${i}" == "UDMA_CRC_Error_Count" ]]; then
				echo "[WARN] S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk '${disk}', this normally indicates a cabling/power issue"
				if [[ "${notify_service}" == 'ntfy' ]]; then
					ntfy "[WARN] S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk '${disk}', this normally indicates a cabling/power issue" "${ntfy_topic}"
				fi
			else
				echo "[FAILED] S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk '${disk}', this indicates a failing disk"
				if [[ "${notify_service}" == 'ntfy' ]]; then
					ntfy "[FAILED] S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk '${disk}', this indicates a failing disk" "${ntfy_topic}"
				fi
				return 1
			fi
		fi
	done
	echo "[PASSED] S.M.A.R.T. attribute for disk '/dev/${disk}' all passed"
	if [[ "${notify_service}" == 'ntfy' ]]; then
		ntfy "[PASSED] S.M.A.R.T. attribute for disk '/dev/${disk}' all passed" "${ntfy_topic}"
	fi
	return 0
}


function run_badblocks_test() {

	local disk_name="${1}"

	for disk in ${disk_name}; do
		if [[ "${destructive_test}" == "yes" ]]; then
			badblocks_destructive_test_flag="-w"
		else
			badblocks_destructive_test_flag=""
		fi

		if [[ "${confirm}" == "yes" ]]; then
			echo -n "[INFO] Please confirm you wish to perform a badblocks test on drive '/dev/${disk}' by typing 'YES': "
			read -r confirm_drive

			if [[ "${confirm_drive}" != "YES" ]]; then
				echo "[INFO] Bad user response '${confirm_drive}', exiting script..."
				exit 1
			fi
		fi

		# get block size of disk
		block_size=$(blockdev --getbsz "/dev/${disk}")

		if [[ "${notify_service}" == 'ntfy' ]]; then
			ntfy "[INFO] Running badblocks for disk '/dev/${disk}' started at '$(date)', this may take several days depending on the test pattern specified"
		fi

		echo "[INFO] Running badblocks for disk '/dev/${disk}' started at '$(date)', this may take several days depending on the test pattern specified..."

		add_serial_to_in_progress_filepath
		# -b = Size of blocks in bytes.
		# -c = Number of blocks which are tested at a time.
		# -t = Test pattern to use.
		# -s = Show the progress of the scan.
		# -w = Use write-mode test.  With this option, badblocks scans for bad blocks by writing some patterns (0xaa, 0x55, 0xff, 0x00) on every block of the device, reading every block and comparing the contents.
		# -v = Verbose mode.
		badblocks \
			-s \
			-v \
			-b "${block_size}" \
			-c "${num_blocks}" \
			-t "${test_pattern}" \
			"${badblocks_destructive_test_flag}" \
			"/dev/${disk}"

		if [[ "${notify_service}" == 'ntfy' ]]; then
			ntfy "[INFO] badblocks finished for disk '/dev/${disk}' at '$(date)'."
		fi

		echo "[INFO] badblocks finished for disk '/dev/${disk}' at '$(date)'."

		remove_serial_from_in_progress_filepath
		check_smart_attributes "${disk}"
	done
}

function ntfy() {

	local message="${1}"
	curl -s -d "${message}" "ntfy.sh/${ntfy_topic}" &> /dev/null
}

function main() {

	echo "Script '${ourScriptName}' started at '$(date)'"

    check_prereqs

    if [[ "${action}" == 'list' ]]; then
        find_all_disks_not_in_array
    fi

    if [[ "${action}" == 'test' ]]; then
        run_badblocks_test "${drive_name}"
    fi

    if [[ "${action}" == 'check-smart' ]]; then
        check_smart_attributes "${drive_name}"
    fi

	echo "Script '${ourScriptName}' has finished at '$(date)'"
}

function show_help() {
	cat <<ENDHELP
Description:
	A simple bash script to test disks using badblocks prior to including in an UNRAID array.
	${ourScriptName} ${ourScriptVersion} - Created by binhex.

Syntax:
	${ourScriptName} [args]

Where:
	-h or --help
		Displays this text.

	-a or --action <list|test|check-smart>
		Define whether to list drives for testing, run badblocks, or check smart attributes.
		No default.

	-dn or --drive-name <drive name to test>
		Define the drive name to test.
		No default.

	-c or --confirm <yes|no>
		Define whether to confirm destructive testing.
		Defaults to '${defaultConfirm}'.

	-nb or --num-blocks <integer>
		Define the number of blocks to test at a time for Badblocks - See Note ****
		Defaults to '${defaultNumBlocks}'.

	-dt or --destructive-test <yes|no>
		Define whether to perform destructive tests for Badblocks - See Note *
		Defaults to '${defaultDestructiveTest}'.

	-tp or --test-pattern <0xaa 0x55 0xff 0x00>
		Define the test pattern(s) to perform, space seperated - See Note ** ***
		Defaults to '${defaultTestPattern}'.

	-ns or --notify-service <ntfy>
		Define the service used to notify the user when a test has been started or completed.
		No default.

	-nt or --ntfy-topic <topic>
		Define the ntfy topic name.
		No default.

	-lp or --log-path <absolute path>
		Define the absolute path to store the logs.
		Defaults to '${defaultLogPath}'.

	--debug <yes|no>
		Define whether debug is turned on or not.
		Defaults to '${defaultDebug}'.

Examples:
    Check S.M.A.R.T. attributes for a specific drive:
        ./${ourScriptName} --action 'check-smart' --drive-name 'sdX'

	List drives not in the UNRAID array, candidates for testing:
		./${ourScriptName} --action 'list' --log-path '/tmp' --debug 'yes'

	Test drive sdX with confirmation prompt, running a destructive test for all test patterns:
		./${ourScriptName} --action 'test' --drive-name 'sdX' --destructive-test 'yes' --log-path '/tmp' --debug 'yes'

	Test drive sdX with confirmation prompt, running a destructive test with notify and specifying number of blocks (recommended):
		./${ourScriptName} --action 'test' --drive-name 'sdX' --destructive-test 'yes' --notify-service 'ntfy' --ntfy-topic 'my_topic' --log-path '/tmp' --debug 'yes'

	Test drive sdX with confirmation prompt, running a destructive test for 2 test patterns and sending push notifications to ntfy:
		./${ourScriptName} --action 'test' --drive-name 'sdX' --destructive-test 'yes' --test-pattern '0xaa 0x00' --notify-service 'ntfy' --ntfy-topic 'my_topic' --log-path '/tmp' --debug 'yes'

	Test drive sdX for a non-destructive test with test pattern 0xff:
		./${ourScriptName} --action 'test' --drive-name 'sdX' --destructive-test 'no' --test-pattern '0xff' --log-path '/tmp' --debug 'yes'

	Test drive sdX with no confirmation prompt, number of blocks to process at a time set to 10000, running a destructive test for specific test patterns:
		./${ourScriptName} --action 'test' --drive-name 'sdX' --confirm 'no' --num-blocks '10000' --destructive-test 'yes' --test-pattern '0xaa 0xff 0x00' --log-path '/tmp' --debug 'yes'

Notes:
	*  Non-destructive tests will result in longer process times.
	** If -dt or --destructive-test is set to 'yes' then only a single pattern can be specified.
	*** Each badblocks pattern will take approximately 2 days to complete.
	**** Ensure to specify the number of blocks for optimal performance.

ENDHELP
}

while [ "$#" != "0" ]
do
	case "$1"
	in
		-a|--action)
			action=$2
			shift
			;;
		-dn|--drive-name)
			drive_name=$2
			shift
			;;
		-c|--confirm)
			confirm=$2
			shift
			;;
		-bs| --num-blocks)
			num_blocks=$2
			shift
			;;
		-dt| --destructive-test)
			destructive_test=$2
			shift
			;;
		-tp| --test-pattern)
			test_pattern=$2
			shift
			;;
		-ns| --notify-service)
			notify_service=$2
			shift
			;;
		-nt| --ntfy-topic)
			ntfy_topic=$2
			shift
			;;
		-lp| --log-path)
			log_path=$2
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
			echo "[WARN] Unrecognised argument '$1', displaying help..." >&2
			echo ""
			show_help
			exit 1
			;;
	esac
	shift
done

# run main function
main
