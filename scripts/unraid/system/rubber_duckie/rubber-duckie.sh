#!/bin/bash

# script name and version
readonly ourScriptName=$(basename -- "$0")
readonly ourFriendlyScriptName="${ourScriptName%.*}"
readonly ourScriptVersion="v2.0.0"

# set defaults
readonly defaultConfirm='yes'
readonly defaultLogLevel='info'
readonly defaultVerifyWipe='no'

CONFIRM="${defaultConfirm}"
LOG_LEVEL="${defaultLogLevel}"
VERIFY_WIPE="${defaultVerifyWipe}"

# Global variable for cleanup
CURRENT_DISK_SERIAL=""

# Trap to ensure cleanup on exit, interrupt, or suspend
trap 'cleanup_and_exit' EXIT INT TERM TSTP

function cleanup_and_exit() {
  logger info "Script exiting, performing cleanup..."
  if [[ -n "${CURRENT_DISK_SERIAL}" ]]; then
    logger info "Cleaning up: removing disk serial '${CURRENT_DISK_SERIAL}' from in-progress file..."
    remove_serial_from_in_progress_filepath "${CURRENT_DISK_SERIAL}"
  fi
}

# TODO check if percentage notification works

# Logger function
function logger() {

  local message_log_level=$1
  shift
  local log_message="$*"

  # Get the current timestamp
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")

  # Map log levels to numeric values
  local log_levels
  declare -A log_levels
  log_levels=(["debug"]=0 ["info"]=1 ["warn"]=2 ["error"]=3 ["critical"]=4)

  # Determine the numeric value of the message log level and the configured log level
  local message_log_level_num=${log_levels[${message_log_level}]}
  local configured_log_level_num=${log_levels[${LOG_LEVEL}]}

  # Only log messages that match or exceed the configured log level
  if [[ ${message_log_level_num} -ge ${configured_log_level_num} ]]; then
    echo "[$timestamp] [${message_log_level,,}] $log_message"
  fi
}

function check_prereqs() {

  logger info "Checking we have all required parameters before running..."

  if [[ -z "${ACTION}" ]]; then
    logger warn "Action not defined via parameter -a or --action, displaying help..."
    echo ""
    show_help
    exit 1
  fi

  if [[ "${ACTION}" != 'list' && "${ACTION}" != 'test-shred' ]]; then
    logger warn "Action defined via -a or --action does not match 'test-shred' or 'list', displaying help..."
    echo ""
    show_help
    exit 2
  fi

  if [[ "${NOTIFY_SERVICE}" == 'ntfy' && -z "${NTFY_TOPIC}" ]]; then
    logger warn "Notify Service defined as 'ntfy', but no topic spcified via -nt or --ntfy-topic, displaying help..."
    echo ""
    show_help
    exit 5
  fi

  logger info "All required parameters are defined"

  logger info "Checking we have all required tooling before running..."

  tools="smartctl grep sed shred cmp cryptsetup"
  for i in ${tools}; do
    if ! command -v "${i}" > /dev/null 2>&1; then
      logger error "Required tool '${i}' is missing, please install and re-run the script, exiting..."
      exit 4
    fi
  done
  logger info "All required tools are available"
}

function get_disk_name_and_serial() {

  local disk_name_and_serial_filtered_disks_list

  # get name e.g. sda, sdb,... and serial number for each disk, filtering out loop*, md*, and nvme devices
  # use comma to separate name and serial number and a single space to separate each disk
  disk_name_and_serial_filtered_disks_list=$(lsblk --nodeps -no name,serial | tr -s '[:blank:]' ',' | grep -v '^loop*' | grep -v '^nvme*' | grep -v '^md*' | xargs)
  echo "${disk_name_and_serial_filtered_disks_list}"
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

    local disks_not_in_scope_array=()
    local disk_name_and_serial_filtered_disks_list
    local unraid_super_filepath='/boot/config/super.dat'
    DISKS_NOT_IN_ARRAY_ARRAY=()

    logger info "Identifying all disks not in the array, this may take a while whilst all drives are spun up and interrogated..."

    disk_name_and_serial_filtered_disks_list=$(get_disk_name_and_serial)

    for i in ${disk_name_and_serial_filtered_disks_list}; do
        disk_name=$(echo "${i}" | grep -P -o -m 1 '^[^,]+')
        disk_serial=$(echo "${i}" | grep -P -o -m 1 '[^,]+$')
        if filter_disks_not_in_scope "${disk_name}"; then
            disks_not_in_scope_array+=("${i}")
            continue
        fi
        if grep -P -o -q -a -m 1 "${disk_serial}" < "${unraid_super_filepath}"; then
            continue
        else
            DISKS_NOT_IN_ARRAY_ARRAY+=("${i}")
        fi
    done
    if [[ -z "${DISKS_NOT_IN_ARRAY_ARRAY[*]}" ]]; then
        logger warn "No disks not in the array found, exiting script..."
        exit 1
    fi

    return 0

}

function read_serial_from_in_progress_filepath() {

# construct required filepaths
  local in_progress_filepath="/tmp/${ourFriendlyScriptName}"

  # filter out any disks being already processed
  if [ -f "${in_progress_filepath}" ]; then
    if grep -P -o -q -m 1 "${disk_serial}" < "${in_progress_filepath}"; then
      return 0
    fi
  fi
  return 1
}

function add_serial_to_in_progress_filepath() {

  local disk_serial="${1}"

  # construct required filepaths
  local in_progress_filepath="/tmp/${ourFriendlyScriptName}"

  if [[ -z "${disk_serial}" ]]; then
    logger warn "disk_serial is empty or undefined. Cannot add serial to in-progress file."
    return 1
  fi

  echo "${disk_serial}" >> "${in_progress_filepath}"
}

function remove_serial_from_in_progress_filepath() {

  local disk_serial="${1}"

  if [[ -z "${disk_serial}" ]]; then
    logger warn "disk_serial is empty or undefined. Cannot remove serial from in-progress file."
    return 1
  fi

  # construct required filepaths
  local in_progress_filepath="/tmp/${ourFriendlyScriptName}"

  # Remove the line containing the disk serial
  sed -i "/${disk_serial}/d" "${in_progress_filepath}"

  # Remove any empty lines
  sed -i '/^$/d' "${in_progress_filepath}"
}

function check_smart_attributes() {

  local disk_name="${1}"
  shift

  local smart_attributes_monitor_list="UDMA_CRC_Error_Count Reallocated_Event_Count Reallocated_Sector_Ct Current_Pending_Sector"
  local smart_attribute_value

  for i in ${smart_attributes_monitor_list}; do
    # Get the SMART attribute value
    smart_attribute_value=$(smartctl -a "/dev/${disk_name}" | grep "${i}" | rev | cut -d ' ' -f1)

    # Skip if the attribute is not found
    if [[ -z "${smart_attribute_value}" ]]; then
      logger warn "S.M.A.R.T. attribute '${i}' not found for disk_name '/dev/${disk_name}', skipping..."
      continue
    fi

    # Check if the SMART attribute value is non-zero
    if [[ "${smart_attribute_value}" != 0 ]]; then
      if [[ "${i}" == "UDMA_CRC_Error_Count" ]]; then
        logger warn "S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk name '${disk_name}', this normally indicates a cabling/power issue"
        if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
          ntfy "[WARN] S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk name '${disk_name}', this normally indicates a cabling/power issue" "${NTFY_TOPIC}"
        fi
      else
        logger warn "S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk name '${disk_name}', this indicates a FAILING DISK"
        if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
          ntfy "[FAILED] S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk name '${disk_name}', this indicates a FAILING DISK" "${NTFY_TOPIC}"
        fi
        return 1
      fi
    fi
  done

  logger info "S.M.A.R.T. attributes for disk name '/dev/${disk_name}' ALL PASSED"
  if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
    ntfy "[PASSED] S.M.A.R.T. attributes for disk name '/dev/${disk_name}' ALL PASSED" "${NTFY_TOPIC}"
  fi
  return 0
}

function run_shred_test() {

  local disk_name="${1}"
  shift
  local disk_serial="${1}"
  shift

  # Set global variable for cleanup trap
  CURRENT_DISK_SERIAL="${disk_serial}"

  logger info "Running shred test for disk '/dev/${disk_name}' started at '$(date)'..."

  add_serial_to_in_progress_filepath "${disk_serial}"

  if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
    ntfy "[INFO] Running shred test for disk '/dev/${disk_name}' started at '$(date)'."
  fi

  # Span a crypto layer above the device:
  echo "" | cryptsetup open "/dev/${disk_name}" "${disk_name}" --type plain --cipher aes-xts-plain64 --batch-mode

  # Fill the now opened decrypted layer with zeroes, which get written as encrypted data:
  # Track progress and send notifications at key milestones
  local last_notified_milestone=0
  shred -v -n 0 -z "/dev/mapper/${disk_name}" 2>&1 | while IFS= read -r line; do
    # Log the shred progress line
    logger info "Shred progress: ${line}"

    # Extract percentage from shred output (e.g., "shred: /dev/mapper/sdb: pass 1/1 (000000)...1.1TiB/3.7TiB 30%")
    if [[ "${line}" =~ ([0-9]+)%$ ]]; then
      local current_percentage="${BASH_REMATCH[1]}"

      # Check for milestone notifications (0%, 25%, 50%, 75%, 100%)
      local milestone=0
      if [[ "${current_percentage}" -eq 0 ]]; then
        milestone=0
      elif [[ "${current_percentage}" -ge 25 && "${last_notified_milestone}" -lt 25 ]]; then
        milestone=25
      elif [[ "${current_percentage}" -ge 50 && "${last_notified_milestone}" -lt 50 ]]; then
        milestone=50
      elif [[ "${current_percentage}" -ge 75 && "${last_notified_milestone}" -lt 75 ]]; then
        milestone=75
      elif [[ "${current_percentage}" -eq 100 ]]; then
        milestone=100
      fi

      # Send notification if we hit a milestone
      if [[ "${milestone}" -gt 0 && "${milestone}" -gt "${last_notified_milestone}" ]]; then
        logger info "Shred progress milestone reached: ${milestone}% for disk '/dev/${disk_name}'"
        if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
          ntfy "[INFO] Shred progress: ${milestone}% complete for disk '/dev/${disk_name}'"
        fi
        last_notified_milestone="${milestone}"
      fi
    fi
  done

  if [[ "${VERIFY_WIPE}" == 'yes' ]]; then
    # Compare fresh zeroes with the decrypted layer:
    if ! cmp -b /dev/zero "/dev/mapper/${disk_name}"; then
      logger error "Verification of wipe FAILED for disk '/dev/${disk_name}'"
      if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
        ntfy "[ERROR] Verification of wipe FAILED for disk '/dev/${disk_name}'."
      fi
      # Close the device
      cryptsetup close "${disk_name}"
      remove_serial_from_in_progress_filepath "${disk_serial}"
      exit 1
    else
      logger info "Verification of wipe PASSED for disk '/dev/${disk_name}'"
      if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
        ntfy "[INFO] Verification of wipe PASSED for disk '/dev/${disk_name}'."
      fi
    fi
  fi

  # Close the device
  cryptsetup close "${disk_name}"

  if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
    ntfy "[INFO] Shred test finished for disk '/dev/${disk_name}' at '$(date)'."
  fi

  logger info "Shred test finished for disk '/dev/${disk_name}' at '$(date)'."

  remove_serial_from_in_progress_filepath "${disk_serial}"

  # Clear global variable since we're done
  CURRENT_DISK_SERIAL=""

}

function ntfy() {

  local message="${1}"
  curl -s -d "[${ourFriendlyScriptName}] ${message}" "ntfy.sh/${NTFY_TOPIC}" &> /dev/null
}

function main() {

  local disk_name
  local disk_serial
  local disk_entry

  logger info "Script '${ourScriptName}' started at '$(date)'"

  check_prereqs

  find_all_disks_not_in_array

  if [[ -z "${DISKS_NOT_IN_ARRAY_ARRAY}" ]]; then
    logger info "No disks found that are not in the array, exiting script..."
    exit 0
  fi

  if [[ "${ACTION}" == 'list' ]]; then
    logger info "Disks listed above are NOT in the array (candidates for testing), operation complete for 'list' action, exiting script..."
    return 0
  fi

  for disk_entry in "${DISKS_NOT_IN_ARRAY_ARRAY[@]}"; do

    disk_name=$(echo "${disk_entry}" | cut -d ',' -f 1)
    disk_serial=$(echo "${disk_entry}" | cut -d ',' -f 2)

    # Run smartctl -i on the device
    logger info "Displaying S.M.A.R.T. information for device '/dev/${disk_name}'..."
    smartctl -i "/dev/${disk_name}"

    if [[ "${CONFIRM}" == "yes" ]]; then
      echo -n "Please confirm you wish to perform a DESTRUCTIVE test on drive '/dev/${disk_name}' by typing 'YES': "
      read -r confirm_drive

      if [[ "${confirm_drive}" != "YES" ]]; then
        logger info "Bad user response '${confirm_drive}', exiting script..."
        exit 1
      fi
    fi

    logger info "Disks NOT in the array (candidates for testing) are '${disk_name}'"

    if [[ "${ACTION}" == 'test-shred' ]]; then
      run_shred_test "${disk_name}" "${disk_serial}"
      check_smart_attributes "${disk_name}"
    fi

  done

  logger info "Script '${ourScriptName}' has finished at '$(date)'"
}

function show_help() {
  cat <<ENDHELP
Description:
    A simple bash script to test disks using shred prior to including in an UNRAID array.
    ${ourScriptName} ${ourScriptVersion} - Created by binhex.

Syntax:
    ${ourScriptName} [args]

Where:
    -h or --help
        Displays this text.

    -a or --action <list|test-shred>
        Define whether to list drives for testing, test using shred.
        No default.

    -c or --confirm <yes|no>
        Define whether to confirm destructive testing.
        Defaults to '${defaultConfirm}'.

    -c or --confirm <yes|no>
        Define whether to confirm destructive testing.
        Defaults to '${defaultConfirm}'.

    --vw or --verify-wipe <yes|no>
        Define whether to verify the wipe after running shred.
        Defaults to '${defaultVerifyWipe}'.

    -ns or --notify-service <ntfy>
        Define the service used to notify the user when a test has been started or completed.
        No default.

    -nt or --ntfy-topic <topic>
        Define the ntfy topic name.
        No default.

    --ll or --log-level <debug|info|warn|error|critical>
        Define the log level for the script's output.
        Defaults to '${defaultLogLevel}'.

Examples:
    List drives not in the UNRAID array, candidates for testing:
        ./${ourScriptName} --action 'list'

    Test drive sdX with shred:
        ./${ourScriptName} --action 'test-shred'

    Test drive sdX with confirmation prompt, running shred with debug logging:
        ./${ourScriptName} --action 'test-shred' --log-level 'debug'

    Test drive sdX with confirmation prompt, running shred with notify (recommended):
        ./${ourScriptName} --action 'test-shred' --notify-service 'ntfy' --ntfy-topic 'my-topic'

    Test drive sdX with confirmation prompt, running shred and then verifying the wipe with notify:
        ./${ourScriptName} --action 'test-shred' --notify-service 'ntfy' --verify-wipe 'yes' --ntfy-topic 'my-topic'

    Test drive sdX with no confirmation prompt, running shred:
        ./${ourScriptName} --action 'test-shred' --confirm 'no'
Notes:
    shred typically takes around 36 hours for a 18TB drive (connected via USB 3.0) to complete.

ENDHELP
}

while [ "$#" != "0" ]
do
  case "$1"
  in
    -a|--action)
      ACTION=$2
      shift
      ;;
    -c|--confirm)
      CONFIRM=$2
      shift
      ;;
    --vw|--verify-wipe)
      VERIFY_WIPE=$2
      shift
      ;;
    -ns|--notify-service)
      NOTIFY_SERVICE=$2
      shift
      ;;
    -nt|--ntfy-topic)
      NTFY_TOPIC=$2
      shift
      ;;
    -ll|--log-level)
      LOG_LEVEL=$2
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
