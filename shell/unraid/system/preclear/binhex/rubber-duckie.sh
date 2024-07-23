#!/bin/bash

# script name and version
readonly ourScriptName=$(basename -- "$0")
readonly ourFriendlyName="${ourScriptName%.*}"
readonly ourScriptVersion="v1.0.0"

# construct required filepaths
unraid_super_filepath='/boot/config/super.dat'
in_progress_filepath="/tmp/${ourFriendlyName}"

function check_prereqs() {
	tools="smartctl badblocks dd grep sed"
	for i in ${tools}; do
		if ! command -v "${i}" > /dev/null 2>&1; then
			echo "[CRIT] Required tool '${i}' is missing, please install and re-run the script, exiting..." ; exit 1
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
	local disk_serial="${2}"

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
	# create empty arrays
	local disks_in_array_array=()
	local disks_not_in_scope_array=()
	disks_not_in_array_array=()

	get_disk_name_and_serial
	for i in ${disk_name_and_serial_filtered_disks_list}; do
		disk_name=$(echo "${i}" | grep -P -o -m 1 '^[^,]+')
		disk_serial=$(echo "${i}" | grep -P -o -m 1 '[^,]+$')
		if filter_disks_not_in_scope "${disk_name}" "${disk_serial}"; then
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
	echo "[DEBUG] Disks in the array (do not check) are '${disks_in_array_array[*]}'"
	echo "[DEBUG] Disks NOT in scope (do not check) are '${disks_not_in_scope_array[*]}'"
	echo "[DEBUG] Disks NOT in the array (candidates for testing) are '${disks_not_in_array_array[*]}'"
	return 0
}

function prompt_for_test_selection() {

	local test_type="${1}"
	local disk_name="${2}"
	local disk_serial="${3}"

	if [[ "${test_type}" == "Non-destructive" ]]; then
		tests_options=("Badblocks" "Quit")
	else
		tests_options=("Badblocks" "DD" "All" "Quit")
	fi
	PS3='Please enter the test you want to run: '
	select opt in "${tests_options[@]}"
	do
		case $opt in
			"Badblocks")
				echo "[INFO] Option '${REPLY}' selected, running test '${opt}'..."
				write_serial_to_in_progress_filepath "${disk_serial}"

				if [[ "${test_type}" == "Destructive" ]]; then

					run_badblocks_test "${disk_name}" "w"

				else

					run_badblocks_test "${disk_name}" "n"

				fi
				remove_serial_from_in_progress_filepath "${disk_serial}"
				continue
				;;
			"DD")
				echo "[INFO] Option '${REPLY}' selected, running test '${opt}'..."
				write_serial_to_in_progress_filepath "${disk_serial}"

				run_dd_zeros_test "${disk_name}"
				remove_serial_from_in_progress_filepath "${disk_serial}"
				continue
				;;
			"All")
				echo "[INFO] Option '${REPLY}' selected, running test '${opt}'..."
				write_serial_to_in_progress_filepath "${disk_serial}"

				if [[ "${test_type}" == "Destructive" ]]; then

					run_badblocks_test "${disk_name}" "w"
					run_dd_zeros_test "${disk_name}"

				else

					run_badblocks_test "${disk_name}" "n"

				fi

				run_hdparm_test "${disk_name}"
				remove_serial_from_in_progress_filepath "${disk_serial}"
				continue
				;;
			"Quit")
				echo "[INFO] Option '${REPLY}' selected, exiting test selection..."
				break
				;;
			*) echo "invalid option $REPLY";;
		esac
	done
}

# run tests for multiple disks by backgrounding operation?
function prompt_for_test_type() {

	local disk_name
	local disk_serial

	echo "[INFO] The following disks are candidates for testing with ${ourScriptName}:"
	echo "[DEBUG] array is '${disks_not_in_array_array[*]}'"

	for i in "${disks_not_in_array_array[@]}"; do

		disk_name=$(echo "${i}" | grep -P -o -m 1 '^[^,]+')
		disk_serial=$(echo "${i}" | grep -P -o -m 1 '[^,]+$')

		run_smartctl_with_flag "-i" "${disk_name}"
		echo -n "Please confirm you wish to check the above drive by typing 'PROCEED': "
		read -r drive_confirm

		if [[ "${drive_confirm}" == "PROCEED" ]]; then

			PS3='Please choose the test type you wish to run (Non-destructive is slower): '
			type_options=("Non-destructive" "Destructive" "Quit")

			select opt in "${type_options[@]}"
			do
				case $opt in
					"Non-destructive")
						prompt_for_test_selection "${opt}" "${disk_name}" "${disk_serial}"
						break
						;;
					"Destructive")
						echo -n "Are you sure?, data maybe (depending on test selection) erased from device '${disk_name}', type 'CONFIRM': "
						read -r destructive_confirm
						if [[ "${destructive_confirm}" == "CONFIRM" ]]; then
							prompt_for_test_selection "${opt}" "${disk_name}" "${disk_serial}"
							break
						else
							echo "[info] Bad response '${destructive_confirm}', exiting script..."
							break
						fi
						;;
					"Quit")
						break
						;;
					*) echo "invalid option $REPLY";;
				esac
			done

		else
			echo "[info] Bad response '${drive_confirm}', continuing to next drive..."
			continue
		fi

	done
}

function read_serial_from_in_progress_filepath() {
	local disk_serial="${1}"
	# filter out any disks being already processed
	if [ -f "${in_progress_filepath}" ]; then
		if grep -P -o -q -m 1 "${disk_serial}" < "${in_progress_filepath}"; then
			return 0
		fi
	fi
	return 1
}

function write_serial_to_in_progress_filepath() {
	local disk_serial="${1}"
	echo "${disk_serial}" >> "${in_progress_filepath}"
}

function remove_serial_from_in_progress_filepath() {
	local disk_serial="${1}"
	sed -i "/${disk_serial}/d" "${in_progress_filepath}"
	# remove any empty lines
	sed -i '/^$/d' "${in_progress_filepath}"
}

function check_smart_attributes() {

	local disk="${1}"
	local smart_warn_list="UDMA_CRC_Error_Count Reallocated_Sector_Ct"
	local smart_error_list="Reallocated_Event_Count Current_Pending_Sector"

	for i in ${smart_warn_list}; do
		smart_attribute_value=$(smartctl -a "/dev/${disk}" | grep "${i}" | rev | cut -d ' ' -f1)
		if [[ "${smart_attribute_value}" != 0 ]]; then
			echo "[INFO] S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk '${disk}'"
		fi
	done
	for i in ${smart_error_list}; do
		smart_attribute_value=$(smartctl -a "/dev/${disk}" | grep "${i}" | rev | cut -d ' ' -f1)
		if [[ "${smart_attribute_value}" != 0 ]]; then
			echo "[WARN] S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk '${disk}'"
			return 1
		fi
	done
	echo "[INFO] S.M.A.R.T. attribute for disk '/dev/${disk}' all passed"
	return 0
}

function run_smartctl_with_flag() {
	local flag="${1}"
	local disk="${2}"
	echo "[INFO] Running smartctl with flags '${flag}' for disk '/dev/${disk}'..."
	smartctl ${flag} "/dev/${disk}"
}

function run_dd_zeros_test() {
	local disk_name="${1}"
	echo "[INFO] Running dd with write zero's for disk '/dev/${disk_name}', this may take some time..."
	# if=/dev/zero = write zeros to disk
	# bs=128k = block size, may speed up process
	dd if=/dev/zero "of=/dev/${disk_name}" bs=128k status=progress
	if ! check_smart_attributes "${disk_name}"; then
		exit 1
	fi
}

function run_badblocks_test() {
	local disk_name="${1}"
	local badblocks_flag="${2}"
	echo "[INFO] Running badblocks for disk '/dev/${disk_name}', this may take several days..."
	# -b 4096 = need to specify block size for large drives
	# -c 200000 = number of blocks to be processed, may speed up process
	# -v = display bad sectors
	# -s = display progress
	#
	# note non-destructive write mode (default) will result in longer process times
	badblocks -b 4096 -c 200000 "-s${badblocks_flag}v" "/dev/${disk_name}"
	if ! check_smart_attributes "${disk_name}"; then
		exit 1
	fi
}

function run() {
	echo "[INFO] Running script ${ourScriptName}..."
	check_prereqs
	echo "[INFO] Gathering potential candidates for processing, please wait whilst all disks are spun up..."
	if find_all_disks_not_in_array; then
		prompt_for_test_type
	fi
	echo "[INFO] Script ${ourScriptName} finished"
}

# kickoff
run
