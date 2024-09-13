#!/bin/bash

# what this script should do:
#
# detect drives not in unraid array
# check smart attributes
# run tmux session for each drive
# run badblocks on each drive
# compare smart attributes
# if smart attributes do not match, then report back to user

# TODO test tmux
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
readonly defaultTestPattern='0xaa 0x55 0xff 0x00'
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

	echo "[info] Checking we have all required parameters before running..."

	if [[ -z "${action}" ]]; then
		echo "[warn] Action not defined via parameter -a or --action, displaying help..."
		echo ""
		show_help
		exit 1
	fi

	if [[ "${action}" == 'test' ]]; then
		if [[ -z "${drive_name}" ]]; then
			echo "[warn] Drive name not defined via parameter -dn or --drive-name, displaying help..."
			echo ""
			show_help
			exit 2
		fi

		if [[ "${destructive_test}" == 'no' ]]; then
			if [[ "${#test_pattern}" -gt 4 ]]; then
				echo "[warn] Non destructive tests only supports a single test pattern via -tp or --test-pattern, displaying help..."
				echo ""
				show_help
				exit 3
			fi
		fi

	fi

	echo "[info] Checking we have all required tooling before running..."

	tools="smartctl tmux badblocks blockdev grep sed"
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
	# TODO need to find out how to filter out cache drives that are not SSD or NVME, ie. spinners, as we do not want to accidently process cache drives!!
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
	disks_not_in_array_array=()

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
	echo "${disk_serial}" >> "${in_progress_filepath}"
}

function remove_serial_from_in_progress_filepath() {
	sed -i "/${disk_serial}/d" "${in_progress_filepath}"
	# remove any empty lines
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
			else
				echo "[ERROR] S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk '${disk}', this indicates a failing disk"
				return 1
			fi
		fi
	done
	echo "[INFO] S.M.A.R.T. attribute for disk '/dev/${disk}' all passed"
	return 0
}


function run_badblocks_test() {

	local disk_name="${1}"

	for disk in ${disk_name}; do
		if [[ "${destructive_test}" == "yes" ]]; then
			if [[ "${confirm}" == "yes" ]]; then
				echo -n "Please confirm you wish to perform a DESTRUCTIVE test on drive '/dev/${disk}' by typing 'PROCEED': "
				read -r destructive_test_confirm

				if [[ "${destructive_test_confirm}" != "PROCEED" ]]; then
					echo "[info] Bad response '${destructive_test_confirm}', exiting script..."
					exit 1
				fi
			fi
			badblocks_destructive_test_flag="-w"
		else
			badblocks_destructive_test_flag=""
		fi

		test_pattern_flags=''
		# construct test pattern flags
		for pattern in ${test_pattern}; do
			test_pattern_flags+="-t ${pattern} "
		done

		# get block size of disk
		block_size=$(blockdev --getbsz "/dev/${disk}")

		echo "[INFO] Running Badblocks for disk '/dev/${disk}', this may take several days depending on the test pattern specified..."
		add_serial_to_in_progress_filepath
		# -d = Run daemonised in the background.
		# -s = Create tmux named session, named after the device name
		tmux new-session -d -s "/dev/${disk}" \
			# -b = Size of blocks in bytes.
			# -c = Number of blocks which are tested at a time.
			# -t = Test pattern to use.
			# -s = Show the progress of the scan.
			# -w = Use write-mode test.  With this option, badblocks scans for bad blocks by writing some patterns (0xaa, 0x55, 0xff, 0x00) on every block of the device, reading every block and comparing the contents.
			# -v = Verbose mode.
			badblocks \
			-b "${block_size}" \
			-c "${num_blocks}" ${test_pattern_flags} \
			-s "${badblocks_destructive_test_flag}" \
			-v "/dev/${disk}"
		remove_serial_from_in_progress_filepath
		if ! check_smart_attributes "${disk}"; then
			exit 1
		fi
	done
}

function main() {
	echo "[INFO] Running script ${ourScriptName}..."
	check_prereqs
	if [[ "${action}" == 'list' ]]; then
		find_all_disks_not_in_array
	fi
	if [[ "${action}" == 'test' ]]; then
		run_badblocks_test "${drive_name}"
	fi
	echo "[INFO] Script ${ourScriptName} finished"
}

function show_help() {
	cat <<ENDHELP
Description:
	A simple bash script to test disks using Badblocks prior to including in an UNRAID array.
	${ourScriptName} ${ourScriptVersion} - Created by binhex.

Syntax:
	${ourScriptName} [args]

Where:
	-h or --help
		Displays this text.

	-a or --action <list|test>
		Define whether to list drives for testing or to run the test.
		No default.

	-dn or --drive-name <drive name to test>
		Define the drive name to test.
		No default.

	-c or --confirm <yes|no>
		Define whether to confirm destructive testing.
		Defaults to '${defaultConfirm}'.

	-nb or --num-blocks <integer>
		Define the number of blocks to test at a time for Badblocks.
		Defaults to '${defaultNumBlocks}'.

	-dt or --destructive-test <yes|no>
		Define whether to perform destructive tests for Badblocks - See Note *
		Defaults to '${defaultDestructiveTest}'.

	-tp or --test-pattern <0xaa 0x55 0xff 0x00>
		Define the test pattern(s) to perform, space seperated - See Note **
		Defaults to '${defaultTestPattern}'.

	-lp or --log-path <absolute path>
		Define the absolute path to store the logs.
		Defaults to '${defaultLogPath}'.

	--debug <yes|no>
		Define whether debug is turned on or not.
		Defaults to '${defaultDebug}'.

Examples:
	List drives not in the UNRAID array, candidates for testing:
		${ourScriptName} --action 'list' --log-path '/tmp' --debug 'yes'

	Test drive sdX for a non-destructive test with tst pattern 0xff:
		${ourScriptName} --action 'test' --drive-name 'sdX' --destructive-test 'no' --test-pattern '0xff' --log-path '/tmp' --debug 'yes'

	Test drive sdX with no confirmation prompt, number of blocks to process at a time set to 10000, running a destructive test for all test patterns:
		${ourScriptName} --action 'test' --drive-name 'sdX' --confirm 'no' --num-blocks '10000' --destructive-test 'yes' --test-pattern '0xaa 0x55 0xff 0x00' --log-path '/tmp' --debug 'yes'

Notes:
	Non-destructive tests will result in longer process times. *
	If -dt or --destructive-test is set to 'yes' then only a single pattern can be specified. **
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
			echo "[warn] Unrecognised argument '$1', displaying help..." >&2
			echo ""
			show_help
			exit 1
			;;
	esac
	shift
done

# run main function
main
