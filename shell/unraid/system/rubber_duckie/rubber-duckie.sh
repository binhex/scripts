#!/bin/bash

# script name and version
readonly ourScriptName=$(basename -- "$0")
readonly ourFriendlyScriptName="${ourScriptName%.*}"
readonly ourScriptVersion="v2.0.0"

# set defaults
readonly defaultConfirm='yes'
readonly defaultNumBlocks="20000"
readonly defaultDestructiveTest='no'
readonly defaultTestPattern='0x00'
readonly defaultLogLevel='info'

CONFIRM="${defaultConfirm}"
NUM_BLOCKS="${defaultNumBlocks}"
DESTRUCTIVE_TEST="${defaultDestructiveTest}"
TEST_PATTERN="${defaultTestPattern}"
LOG_LEVEL="${defaultLogLevel}"

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

    if [[ "${ACTION}" != 'test' && "${ACTION}" != 'list' && "${ACTION}" != 'check-smart' ]]; then
        logger warn "Action defined via -a or --action does not match 'test', 'list', or 'check-smart', displaying help..."
        echo ""
        show_help
        exit 2
    fi

    if [[ "${ACTION}" == 'check-smart' ]]; then
        if [[ -z "${DRIVE_NAME}" ]]; then
            logger warn "Drive name not defined via parameter -dn or --drive-name, displaying help..."
            echo ""
            show_help
            exit 3
        fi

        if [[ "${DESTRUCTIVE_TEST}" == 'no' ]]; then
            if [[ "${#TEST_PATTERN}" -gt 4 ]]; then
                logger warn "Non destructive tests only supports a single test pattern via -tp or --test-pattern, displaying help..."
                echo ""
                show_help
                exit 4
            fi
        fi

    fi

    if [[ "${NOTIFY_SERVICE}" == 'ntfy' && -z "${NTFY_TOPIC}" ]]; then
        logger warn "Notify Service defined as 'ntfy', but no topic spcified via -nt or --ntfy-topic, displaying help..."
        echo ""
        show_help
        exit 5
    fi

    logger info "All required parameters are defined"

    logger info "Checking we have all required tooling before running..."

    tools="smartctl badblocks blockdev grep sed"
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

    local disk="${1}"
    local smart_attributes_monitor_list="UDMA_CRC_Error_Count Reallocated_Event_Count Reallocated_Sector_Ct Current_Pending_Sector"
    local smart_attribute_value

    for i in ${smart_attributes_monitor_list}; do
        # Get the SMART attribute value
        smart_attribute_value=$(smartctl -a "/dev/${disk}" | grep "${i}" | rev | cut -d ' ' -f1)

        # Skip if the attribute is not found
        if [[ -z "${smart_attribute_value}" ]]; then
            logger warn "S.M.A.R.T. attribute '${i}' not found for disk '/dev/${disk}', skipping..."
            continue
        fi

        # Check if the SMART attribute value is non-zero
        if [[ "${smart_attribute_value}" != 0 ]]; then
            if [[ "${i}" == "UDMA_CRC_Error_Count" ]]; then
                logger warn "S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk '${disk}', this normally indicates a cabling/power issue"
                if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
                    ntfy "[WARN] S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk '${disk}', this normally indicates a cabling/power issue" "${NTFY_TOPIC}"
                fi
            else
                logger warn "S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk '${disk}', this indicates a failing disk"
                if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
                    ntfy "[FAILED] S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk '${disk}', this indicates a failing disk" "${NTFY_TOPIC}"
                fi
                return 1
            fi
        fi
    done

    logger info "S.M.A.R.T. attributes for disk '/dev/${disk}' all passed"
    if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
        ntfy "[PASSED] S.M.A.R.T. attributes for disk '/dev/${disk}' all passed" "${NTFY_TOPIC}"
    fi
    return 0
}

function run_badblocks_test() {

    local disk_name="${1}"
    shift
    local disk_serial="${1}"

    local temp_file
    local block_size
    local badblocks_destructive_test_flag
    local confirm_drive

    temp_file=$(mktemp)

    if [[ "${DESTRUCTIVE_TEST}" == "yes" ]]; then
        badblocks_destructive_test_flag="-w"
    else
        badblocks_destructive_test_flag=""
    fi

    if [[ "${CONFIRM}" == "yes" ]]; then
        echo -n "Please confirm you wish to perform a badblocks test on drive '/dev/${disk_name}' by typing 'YES': "
        read -r confirm_drive

        if [[ "${confirm_drive}" != "YES" ]]; then
            logger info "Bad user response '${confirm_drive}', exiting script..."
            exit 1
        fi
    fi

    # get block size of disk
    block_size=$(blockdev --getbsz "/dev/${disk_name}")

    if [[ -z "${block_size}" ]]; then
        logger error "Failed to get block size for disk '/dev/${disk_name}', exiting script..."
        exit 1
    fi

    if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
        ntfy "[INFO] Running badblocks for disk '/dev/${disk_name}' started at '$(date)', this may take several days depending on the test pattern specified"
    fi

    logger info "Running badblocks for disk '/dev/${disk_name}' started at '$(date)', this may take several days depending on the test pattern specified..."

    add_serial_to_in_progress_filepath "${disk_serial}"

    # run badblocks and capture its output
    #
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
        -c "${NUM_BLOCKS}" \
        -t "${TEST_PATTERN}" \
        "${badblocks_destructive_test_flag}" \
        "/dev/${disk_name}" 2>&1 | tee "${temp_file}"
        while read -r line; do
            echo "${line}"
            # Check for the specific error message
            if [[ "${line}" == *"badblocks: invalid last block"* ]]; then
                logger error "badblocks encountered an error: 'invalid last block', possible faulty drive, displaying S.M.A.R.T. before exiting script..."
                smartctl -a "/dev/${disk_name}"
                exit 1
            fi
            # Extract the percentage from the output
            if [[ "${line}" =~ ([0-9]+\.[0-9]+)% ]]; then
                progress=${BASH_REMATCH[1]%%.*}  # Get the integer part of the percentage
                case "${progress}" in
                    0|25|50|75|100)
                        logger info "Progress: ${progress}% completed for disk '/dev/${disk_name}'"
                        if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
                            ntfy "[INFO] Progress: ${progress}% completed for disk '/dev/${disk_name}'"
                        fi
                        ;;
                esac
            fi
        done < "${temp_file}"
        rm -f "${temp_file}"

    if [[ "${NOTIFY_SERVICE}" == 'ntfy' ]]; then
        ntfy "[INFO] badblocks finished for disk '/dev/${disk_name}' at '$(date)'."
    fi

    logger info "badblocks finished for disk '/dev/${disk_name}' at '$(date)'."

    remove_serial_from_in_progress_filepath "${disk_serial}"

}

function ntfy() {

    local message="${1}"
    curl -s -d "[${ourFriendlyScriptName}] ${message}" "ntfy.sh/${NTFY_TOPIC}" &> /dev/null
}

function main() {

    local DISKS_NOT_IN_ARRAY_ARRAY
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

    for disk_entry in "${DISKS_NOT_IN_ARRAY_ARRAY[@]}"; do

        disk_name=$(echo "${disk_entry}" | cut -d ',' -f 1)
        disk_serial=$(echo "${disk_entry}" | cut -d ',' -f 2)

        if [[ "${ACTION}" == 'list' || "${ACTION}" == 'test' ]]; then
            logger info "Disks NOT in the array (candidates for testing) are '${disk_name}'"

            # Run smartctl -i on the device
            logger info "Displaying S.M.A.R.T. information for device '/dev/${disk_name}'..."
            smartctl -i "/dev/${disk_name}"

        fi

        if [[ "${ACTION}" == 'test' ]]; then
                run_badblocks_test "${disk_name}" "${disk_serial}"
        fi

        if [[ "${ACTION}" == 'check-smart' || "${ACTION}" == 'test' ]]; then
            check_smart_attributes "${disk_name}"
        fi

    done

    logger info "Script '${ourScriptName}' has finished at '$(date)'"
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

    --ll or --log-level <debug|info|warn|error|critical>
        Define the log level for the script's output.
        Defaults to '${defaultLogLevel}'.

Examples:
    Check S.M.A.R.T. attributes for a specific drive:
        ./${ourScriptName} --action 'check-smart' --drive-name 'sdX'

    List drives not in the UNRAID array, candidates for testing:
        ./${ourScriptName} --action 'list'

    Check S.M.A.R.T. attributes for failure:
        ./${ourScriptName} --action 'check-smart' --drive-name 'sdX'

    Test drive sdX with confirmation prompt, running a destructive test for all test patterns with debug logging:
        ./${ourScriptName} --action 'test' --destructive-test 'yes' --log-level 'debug'

    Test drive sdX with confirmation prompt, running a destructive test with notify and specifying number of blocks (recommended):
        ./${ourScriptName} --action 'test' --destructive-test 'yes' --notify-service 'ntfy' --ntfy-topic 'my_topic'

    Test drive sdX with confirmation prompt, running a destructive test for 2 test patterns and sending push notifications to ntfy:
        ./${ourScriptName} --action 'test' --destructive-test 'yes' --test-pattern '0xaa 0x00' --notify-service 'ntfy' --ntfy-topic 'my_topic'

    Test drive sdX for a non-destructive test with test pattern 0xff:
        ./${ourScriptName} --action 'test' --destructive-test 'no' --test-pattern '0xff'

    Test drive sdX with no confirmation prompt, number of blocks to process at a time set to 10000, running a destructive test for specific test patterns:
        ./${ourScriptName} --action 'test' --confirm 'no' --num-blocks '10000' --destructive-test 'yes' --test-pattern '0xaa 0xff 0x00'

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
            ACTION=$2
            shift
            ;;
        -dn|--drive-name)
            DRIVE_NAME=$2
            shift
            ;;
        -c|--confirm)
            CONFIRM=$2
            shift
            ;;
        -bs| --num-blocks)
            NUM_BLOCKS=$2
            shift
            ;;
        -dt| --destructive-test)
            DESTRUCTIVE_TEST=$2
            shift
            ;;
        -tp| --test-pattern)
            TEST_PATTERN=$2
            shift
            ;;
        -ns| --notify-service)
            NOTIFY_SERVICE=$2
            shift
            ;;
        -nt| --ntfy-topic)
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
