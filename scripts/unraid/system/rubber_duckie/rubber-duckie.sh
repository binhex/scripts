#!/bin/bash

# script name and version
readonly ourScriptName=$(basename -- "$0")
readonly ourFriendlyScriptName="${ourScriptName%.*}"
readonly ourScriptVersion="v2.1.0"

# set defaults
readonly defaultConfirm='yes'
readonly defaultLogLevel='info'
readonly defaultVerifyWipe='no'
readonly defaultPasses='0'

CONFIRM="${defaultConfirm}"
LOG_LEVEL="${defaultLogLevel}"
VERIFY_WIPE="${defaultVerifyWipe}"
PASSES="${defaultPasses}"

# Global variables for disk processing (uppercase to denote globals)
# These can be extended in the future to arrays for parallel processing
DISK_NAME=""
DISK_SERIAL=""

# Trap to ensure cleanup on interrupt, or suspend
trap 'signal_handler' INT TERM TSTP

function cleanup() {

  if [[ "${ACTION}" == 'test' ]]; then
    if [[ -n "${DISK_SERIAL}" ]]; then
      logger info "Cleaning up: removing disk serial '${DISK_SERIAL}' from in-progress file..."
      remove_serial_from_in_progress_filepath
    fi
    if [[ -n "${DISK_NAME}" ]]; then
      logger info "Cleaning up: closing cryptsetup for disk '${DISK_NAME}'..."
      cryptsetup close "${DISK_NAME}" 2> /dev/null || true
    fi
  fi

}

function cleanup_and_exit(){

  exit_code="${1:-0}"
  shift

  cleanup
  logger info "Script finished at '$(date +"%Y-%m-%d %H:%M:%S")' with exit code '${exit_code}'"
  exit "${exit_code}"

}

function signal_handler() {

  logger warn "Script exiting due to signal"
  cleanup
  if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
    if [[ -n "${DISK_NAME}" && -n "${DISK_SERIAL}" ]]; then
      ntfy "[WARN] Script exited due to signal at '$(date +"%Y-%m-%d %H:%M:%S")' Serial: '${DISK_SERIAL}', Device Name: '/dev/${DISK_NAME}'"
    else
      ntfy "[WARN] Script exited due to signal at '$(date +"%Y-%m-%d %H:%M:%S")'"
    fi
  fi
  if [[ -n "${DISK_NAME}" && -n "${DISK_SERIAL}" ]]; then
    logger warn "Script exited due to signal at '$(date +"%Y-%m-%d %H:%M:%S")' Serial: '${DISK_SERIAL}', Device Name: '/dev/${DISK_NAME}'"
  else
    logger warn "Script exited due to signal at '$(date +"%Y-%m-%d %H:%M:%S")'"
  fi
  exit 1

}

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
    return 1
  fi

  if [[ "${ACTION}" != 'list' && "${ACTION}" != 'test' ]]; then
    logger warn "Action defined via -a or --action does not match 'test' or 'list', displaying help..."
    echo ""
    show_help
    return 1
  fi

  if [[ "${NOTIFY_SERVICE}" == 'ntfy' && -z "${NTFY_TOPIC}" ]]; then
    logger warn "Notify Service defined as 'ntfy', but no topic spcified via -nt or --ntfy-topic, displaying help..."
    echo ""
    show_help
    return 1
  fi

  logger info "All required parameters are defined"

  logger info "Checking we have all required tooling before running..."

  tools="smartctl grep sed shred cmp cryptsetup"
  for i in ${tools}; do
    if ! command -v "${i}" > /dev/null 2>&1; then
      logger error "Required tool '${i}' is missing, please install and re-run the script"
      return 1
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

  # Uses global DISK_NAME and DISK_SERIAL variables

  # if we cannot determine smart info then its unlikely to be a spinning disk
  if ! smartctl -a "/dev/${DISK_NAME}" > /dev/null 2>&1; then
    return 0
  fi

  # filter out non spinning disks, such as ssd's
  if smartctl -a "/dev/${DISK_NAME}" | grep -P -q -o -m 1 '^Device Model\:.*SSD'; then
    return 0
  fi

  # filter out any disks being already processed
  if read_serial_from_in_progress_filepath; then
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
        DISK_NAME=$(echo "${i}" | grep -P -o -m 1 '^[^,]+')
        DISK_SERIAL=$(echo "${i}" | grep -P -o -m 1 '[^,]+$')
        if filter_disks_not_in_scope; then
            disks_not_in_scope_array+=("${i}")
            continue
        fi
        if grep -P -o -q -a -m 1 "${DISK_SERIAL}" < "${unraid_super_filepath}"; then
            continue
        else
            DISKS_NOT_IN_ARRAY_ARRAY+=("${i}")
        fi
    done

    if [[ -z "${DISKS_NOT_IN_ARRAY_ARRAY[*]}" ]]; then
      logger warn "No disks not in the array found"
      return 1
    fi

}

function read_serial_from_in_progress_filepath() {

  # Uses global DISK_SERIAL variable
  # construct required filepaths
  local in_progress_filepath="/tmp/${ourFriendlyScriptName}"

  # filter out any disks being already processed
  if [ -f "${in_progress_filepath}" ]; then
    if grep -P -o -q -m 1 "${DISK_SERIAL}" < "${in_progress_filepath}"; then
      return 0
    fi
  fi
  return 1
}

function add_serial_to_in_progress_filepath() {

  # Uses global DISK_SERIAL variable
  # construct required filepaths
  local in_progress_filepath="/tmp/${ourFriendlyScriptName}"

  if [[ -z "${DISK_SERIAL}" ]]; then
    logger warn "Disk serial is empty or undefined. Cannot add serial to in-progress file."
    return 1
  fi

  echo "${DISK_SERIAL}" >> "${in_progress_filepath}"
}

function remove_serial_from_in_progress_filepath() {

  # Uses global DISK_SERIAL variable
  if [[ -z "${DISK_SERIAL}" ]]; then
    logger warn "DISK_SERIAL is empty or undefined. Cannot remove serial from in-progress file."
    return 1
  fi

  # construct required filepaths
  local in_progress_filepath="/tmp/${ourFriendlyScriptName}"

  # Remove the line containing the disk serial
  sed -i "/${DISK_SERIAL}/d" "${in_progress_filepath}"

  # Remove any empty lines
  sed -i '/^$/d' "${in_progress_filepath}"
}

function check_smart_attributes() {

  # Uses global DISK_NAME variable
  local smart_attributes_monitor_list="UDMA_CRC_Error_Count Reallocated_Event_Count Reallocated_Sector_Ct Current_Pending_Sector"
  local smart_attribute_value

  for i in ${smart_attributes_monitor_list}; do
    # Get the SMART attribute value
    smart_attribute_value=$(smartctl -a "/dev/${DISK_NAME}" | grep "${i}" | rev | cut -d ' ' -f1)

    # Skip if the attribute is not found
    if [[ -z "${smart_attribute_value}" ]]; then
      logger warn "S.M.A.R.T. attribute '${i}' not found for disk_name '/dev/${DISK_NAME}', skipping..."
      continue
    fi

    # Check if the SMART attribute value is non-zero
    if [[ "${smart_attribute_value}" != 0 ]]; then
      if [[ "${i}" == "UDMA_CRC_Error_Count" ]]; then
        logger warn "S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk name '${DISK_NAME}', this normally indicates a cabling/power issue"
        if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
          ntfy "[WARN] S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk name '${DISK_NAME}', this normally indicates a cabling/power issue"
        fi
      else
        logger warn "S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk name '${DISK_NAME}', this indicates a FAILING DISK"
        if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
          ntfy "[FAILED] S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk name '${DISK_NAME}', this indicates a FAILING DISK"
        fi
        return 1
      fi
    fi
  done

  logger info "S.M.A.R.T. attributes for disk name '/dev/${DISK_NAME}' ALL PASSED"
  if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
    ntfy "[PASSED] S.M.A.R.T. attributes for disk name '/dev/${DISK_NAME}' ALL PASSED"
  fi
  return 0

}

function run_shred_test() {

  # Uses global DISK_NAME and DISK_SERIAL variables
  logger info "Running shred test for disk '/dev/${DISK_NAME}' started at '$(date +"%Y-%m-%d %H:%M:%S")'..."

  add_serial_to_in_progress_filepath

  if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
    ntfy "[INFO] Running shred test for disk '/dev/${DISK_NAME}' started at '$(date +"%Y-%m-%d %H:%M:%S")'."
  fi

  # Span a crypto layer above the device:
  if ! echo "" | cryptsetup open "/dev/${DISK_NAME}" "${DISK_NAME}" --type plain --cipher aes-xts-plain64 --batch-mode; then
    logger warn "Cryptsetup open command failed for disk '/dev/${DISK_NAME}'"
    if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
      ntfy "[WARN] Cryptsetup open command failed for disk '/dev/${DISK_NAME}'"
    fi
    cleanup
    return 1
  fi

  # Fill the now opened decrypted layer with zeroes, which get written as encrypted data:
  # Track progress and send notifications at key milestones
  local last_notified_milestone=0

  # Enable pipefail to capture exit code from shred command in pipeline
  set -o pipefail

  # Run shred and process output, capturing exit code
  if ! shred -v -n "${PASSES}" -z "/dev/mapper/${DISK_NAME}" 2>&1 | while IFS= read -r line; do
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
        logger info "Shred progress milestone reached: ${milestone}% for disk '/dev/${DISK_NAME}'"
        if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
          ntfy "[INFO] Shred progress: ${milestone}% complete for disk '/dev/${DISK_NAME}'"
        fi
        last_notified_milestone="${milestone}"
      fi
    fi
  done; then
    logger warn "Shred command failed for disk '/dev/${DISK_NAME}'"
    if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
      ntfy "[WARN] Shred command failed for disk '/dev/${DISK_NAME}'"
    fi
    # Reset pipefail
    set +o pipefail
    cleanup
    return 1
  fi

  # Reset pipefail
  set +o pipefail

  if [[ "${VERIFY_WIPE}" == 'yes' ]]; then
    # Compare fresh zeroes with the decrypted layer:
    logger info "[INFO] Running verification of zeroes for disk '/dev/${DISK_NAME}'..."
    if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
      ntfy "[INFO] Running verification of zeroes for disk '/dev/${DISK_NAME}'..."
    fi

    # TODO check if cmp exit code 1 trips up the script here
    cmp_output=$(cmp -b /dev/zero "/dev/mapper/${DISK_NAME}" 2>&1)
    if echo "${cmp_output}" | grep -q "cmp: EOF on ‘/dev/mapper/${DISK_NAME}’ after byte"; then
      logger info "Verification of wipe PASSED for disk '/dev/${DISK_NAME}'"
      if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
        ntfy "[INFO] Verification of wipe PASSED for disk '/dev/${DISK_NAME}'."
      fi
    else
      logger warn "Verification of wipe FAILED for disk '/dev/${DISK_NAME}'"
      if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
        ntfy "[WARN] Verification of wipe FAILED for disk '/dev/${DISK_NAME}'."
      fi
      cleanup
      return 1
    fi
  fi

  logger info "Shred test finished for disk '/dev/${DISK_NAME}' at '$(date +"%Y-%m-%d %H:%M:%S")'."
  if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
    ntfy "[INFO] Shred test finished for disk '/dev/${DISK_NAME}' at '$(date +"%Y-%m-%d %H:%M:%S")'."
  fi

}

function ntfy() {

  local message="${1}"
  curl -s -d "[${ourFriendlyScriptName}] ${message}" "ntfy.sh/${NTFY_TOPIC}" &> /dev/null
}

function main() {

  local disk_entry

  logger info "Script '${ourScriptName}' started at '$(date +"%Y-%m-%d %H:%M:%S")'"

  if ! check_prereqs; then
    cleanup_and_exit 1
  fi

  if ! find_all_disks_not_in_array; then
    cleanup_and_exit 1
  fi

  for disk_entry in "${DISKS_NOT_IN_ARRAY_ARRAY[@]}"; do

    # Set global variables for this disk
    DISK_NAME=$(echo "${disk_entry}" | cut -d ',' -f 1)
    DISK_SERIAL=$(echo "${disk_entry}" | cut -d ',' -f 2)

    logger info "Disk(s) found NOT in the array: Serial: '${DISK_SERIAL}', Device Name: '/dev/${DISK_NAME}'"
    logger info "Displaying S.M.A.R.T. information for device '/dev/${DISK_NAME}'..."
    smartctl -i "/dev/${DISK_NAME}"

    if [[ "${ACTION}" == 'list' ]]; then
      continue
    fi

    if [[ "${CONFIRM}" == "yes" ]]; then
      echo -n "Please confirm you wish to perform a DESTRUCTIVE test on drive '/dev/${DISK_NAME}' by typing 'YES': "
      read -r confirm_drive

      if [[ "${confirm_drive}" != "YES" ]]; then
        logger info "Bad user response '${confirm_drive}', exiting script..."
        cleanup_and_exit 1
      fi
    fi

    if [[ "${ACTION}" == 'test' ]]; then
      if ! run_shred_test; then
        cleanup_and_exit 1
      fi
      if ! check_smart_attributes; then
        cleanup_and_exit 1
      fi
      cleanup
    fi

    # Clear global variables since we're done
    DISK_NAME=""
    DISK_SERIAL=""

  done

  cleanup_and_exit 0

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

    -a or --action <list|test>
        Define whether to list drives for testing, test using shred.
        No default.

    -c or --confirm <yes|no>
        Define whether to confirm destructive testing.
        Defaults to '${defaultConfirm}'.

    --vw or --verify-wipe <yes|no>
        Define whether to verify the wipe after running shred.
        Defaults to '${defaultVerifyWipe}'.

    -p or --passes <number>
        Define the number of passes for shred.
        Defaults to '${defaultPasses}'.

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
    List drive(s) not in the UNRAID array, candidates for testing:
        ./${ourScriptName} --action 'list'

    Test drive with confirmation prompt, running shred with a single pass (default):
        ./${ourScriptName} --action 'test'

    Test drive with no confirmation prompt, running shred with a single pass (default):
        ./${ourScriptName} --action 'test' --confirm 'no'

    Test drive with confirmation prompt, running shred with a single pass (default) and set logging to 'debug':
        ./${ourScriptName} --action 'test' --log-level 'debug'

    Test drive with confirmation prompt, running shred with a single pass (default), verify the wipe and send notification via ntfy (recommended):
        ./${ourScriptName} --action 'test' --notify-service 'ntfy' --ntfy-topic 'my-topic' --verify-wipe 'yes'

    Test drive with confirmation prompt, running shred with 3 passes, verify the wipe and send notification via ntfy (long):
        ./${ourScriptName} --action 'test' --notify-service 'ntfy' --ntfy-topic 'my-topic' --passes '3' --verify-wipe 'yes'

Notes:
    shred typically takes around 36 hours for a 18TB drive for a single pass (connected via USB 3.0) to complete, if you enable verify-wipe this will add additional time.

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
    -p|--passes)
      PASSES=$2
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
