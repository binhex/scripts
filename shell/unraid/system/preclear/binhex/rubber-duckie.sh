#!/bin/bash

# script name and version
readonly ourScriptName=$(basename -- "$0")
readonly ourFriendlyName="${ourScriptName%.*}"
readonly ourScriptVersion="v1.0.0"

# define default values
readonly default_smartctl_test="short"
readonly default_badblocks_write_mode="non-destructive"
readonly default_dd_minutes_to_run_random_test="480"

smartctl_test="${default_smartctl_test}"
badblocks_write_mode="${default_badblocks_write_mode}"
dd_minutes_to_run_random_test="${default_dd_minutes_to_run_random_test}"

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
	echo "[DEBUG] Disks in the array (do not check) are '${disks_in_array_array[*]}'"
	echo "[DEBUG] Disks NOT in scope (do not check) are '${disks_not_in_scope_array[*]}'"
	echo "[DEBUG] Disks NOT in the array (candidates for checking) are '${disks_not_in_array_array[*]}'"
}

 # TODO need to add in prompt for non destructive or destructive
 # TODO prompt for tests to run, or all
 # TODO prompt for multi disk selection (or all) and run in background
function prompt_user_for_disk_selection() {
	local disk_name
	local disk_serial
	echo "[INFO] The following disks are candidates for processing with ${ourScriptName}:"
	echo "[DEBUG] array is '${disks_not_in_array_array[*]}'"
	for i in "${disks_not_in_array_array[@]}"; do
		disk_name=$(echo "${i}" | grep -P -o -m 1 '^[^,]+')
		disk_serial=$(echo "${i}" | grep -P -o -m 1 '[^,]+$')
		run_smartctl_get_info "${disk_name}" "i"
		echo "[INFO] Do you want to check the above drive?"
		select yn in "Yes" "No"; do
    		case $yn in
        		Yes ) run_non_destructive_tests "${disk_name}" "${disk_serial}"; break;;
        		No ) break;;
    		esac
		done
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

function run_destructive_tests() {
	local disk_name="${1}"
	local disk_serial="${2}"

	write_serial_to_in_progress_filepath "${disk_serial}"
	run_smartctl_get_attributes "${disk_name}" # TODO grep for all attributes
	run_badblocks_test "${disk_name}" "w"
	run_dd_zeros_test "${disk_name}"
	run_dd_random_test "${disk_name}" "${dd_minutes_to_run_random_test}"
	remove_serial_from_in_progress_filepath "${disk_serial}"
}

function run_non_destructive_tests() {
	local disk_name="${1}"
	local disk_serial="${2}"

	write_serial_to_in_progress_filepath "${disk_serial}"
	run_smartctl_get_attributes "${disk_name}" # TODO grep for all attributes
	run_smartctl_health "${disk_name}"
	run_smartctl_test "${disk_name}" "${smartctl_test}"
	run_badblocks_test "${disk_name}" "n"
	remove_serial_from_in_progress_filepath "${disk_serial}"
}

function run_smartctl_get_attributes() {
	local disk_name="${1}"
	echo "[INFO] Running smartctl with flag '${smartctl_flag}' for disk '/dev/${disk_name}'..."
	smartctl -a "/dev/${disk_name}"
}

function run_smartctl_check_for_fail() {
	local disk_name="${1}"
	local smartctl_flag="${2}"
	echo "[INFO] Running smartctl with flag '${smartctl_flag}' for disk '/dev/${disk_name}'..."
	if smartctl -a "/dev/${disk_name}" | xargs | grep -q 'No Errors Logged'; then
		echo "[INFO] Drive '/dev/${disk_name}' PASSED S.M.A.R.T."
		return 0
	else
		echo "[INFO] Drive '/dev/${disk_name}' FAILED S.M.A.R.T."
		return 1
	fi
}

function run_smartctl_test() {
	local disk_name="${1}"
	local smartctl_test="${2}"
	echo "[INFO] Running smartctl '${smartctl_test}' test for disk '/dev/${disk_name}', this may take some time..."
	smartctl -t "${smartctl_test}" "/dev/${disk_name}"
	run_smartctl_check_for_fail "${disk_name}"
}

function run_smartctl_health() {
	local disk_name="${1}"
	echo "[INFO] Running smartctl health check for disk '/dev/${disk_name}'..."
	smartctl -H "/dev/${disk_name}"
	run_smartctl_check_for_fail "${disk_name}"
}

function run_dd_zeros_test() {
	local disk_name="${1}"
	echo "[INFO] Running dd with write zero's for disk '/dev/${disk_name}', this may take some time..."
	# if=/dev/zero = write zeros to disk
	# bs=128k = block size, may speed up process
	dd if=/dev/zero "of=/dev/${disk_name}" bs=128k status=progress
	run_smartctl_check_for_fail "${disk_name}"
}

function run_dd_random_test() {
	local disk_name="${1}"
	local dd_minutes_to_run_random_test="${2}"
	local dd_secs_to_run_random_test=$(( dd_minutes_to_run_random_test * 60 ))
	echo "[INFO] Running dd with random write pattern for '${dd_minutes_to_run_random_test}' minutes for disk '/dev/${disk_name}', this may take some time..."

	SECONDS=0
	while (( SECONDS < dd_secs_to_run_random_test )); do
		random_block_number=$(( RANDOM * 32768 + RANDOM ))
		# if=/dev/urandom = write random data to disk
		# bs=128k = block size, may speed up process
		# seek = skip n blocks then begin writing
		dd if=/dev/urandom "of=/dev/${disk_name}" "seek=${random_block_number}" count=1 bs=128k status=progress
	done
	run_smartctl_check_for_fail "${disk_name}"
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
	run_smartctl_check_for_fail "${disk_name}"
}

function run() {
	echo "[INFO] Running script ${ourScriptName}..."
	check_prereqs
	echo "[INFO] Gathering potential candidates for processing, please wait..."
	find_all_disks_not_in_array
	prompt_user_for_disk_selection
	# prompt_user_for
	# read smartctl attribs and store in memory
	# run tests
	# send email oncee processed?
	# read smartctl attribs and compare and show to user changed attribs
	echo "[INFO] Script ${ourScriptName} finished"
}

run
