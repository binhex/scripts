#!/bin/bash

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
readonly defaultLogLevel='info'

confirm="${defaultConfirm}"
num_blocks="${defaultNumBlocks}"
destructive_test="${defaultDestructiveTest}"
debug="${defaultDebug}"
test_pattern="${defaultTestPattern}"
log_level="${defaultLogLevel}"

# construct required filepaths
unraid_super_filepath='/boot/config/super.dat'
in_progress_filepath="/tmp/${ourFriendlyScriptName}"

# Logger function
function logger() {
    local message_log_level=$1
    shift
    local log_message="$*"

    # Get the current timestamp
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Map log levels to numeric values
    declare -A log_levels
    log_levels=(["debug"]=0 ["info"]=1 ["warn"]=2 ["error"]=3 ["critical"]=4)

    # Determine the numeric value of the message log level and the configured log level
    local message_log_level_num=${log_levels[${message_log_level}]}
    local configured_log_level_num=${log_levels[${log_level}]}

    # Only log messages that match or exceed the configured log level
    if [[ ${message_log_level_num} -ge ${configured_log_level_num} ]]; then
        echo "[$timestamp] [${message_log_level^^}] $log_message"
    fi
}

function check_prereqs() {

    logger info "Checking we have all required parameters before running..."

    if [[ -z "${action}" ]]; then
        logger warn "Action not defined via parameter -a or --action, displaying help..."
        echo ""
        show_help
        exit 1
    fi

    if [[ "${action}" != 'test' && "${action}" != 'list' && "${action}" != 'check-smart' ]]; then
        logger warn "Action defined via -a or --action does not match 'test', 'list', or 'check-smart', displaying help..."
        echo ""
        show_help
        exit 2
    fi

    if [[ "${action}" == 'test' || "${action}" == 'check-smart' ]]; then
        if [[ -z "${drive_name}" ]]; then
            logger warn "Drive name not defined via parameter -dn or --drive-name, displaying help..."
            echo ""
            show_help
            exit 3
        fi

        if [[ "${destructive_test}" == 'no' ]]; then
            if [[ "${#test_pattern}" -gt 4 ]]; then
                logger warn "Non destructive tests only supports a single test pattern via -tp or --test-pattern, displaying help..."
                echo ""
                show_help
                exit 4
            fi
        fi

    fi

    if [[ "${notify_service}" == 'ntfy' && -z "${ntfy_topic}" ]]; then
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

    logger info "Gathering potential candidates for processing, please wait whilst all disks are spun up..."
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
        logger info "No candidates for processing found, exiting..."
        return 1
    fi
    if [[ "${debug}" == 'yes' ]]; then
        logger debug "Disks in the array (do not check) are '${disks_in_array_array[*]}'"
        logger debug "Disks NOT in scope (do not check) are '${disks_not_in_scope_array[*]}'"
    fi
    logger info "Disks NOT in the array (candidates for testing) are '${disks_not_in_array_array[*]}'"

    for disk_entry in "${disks_not_in_array_array[@]}"; do
        # Extract the device name (everything before the comma)
        device_name=$(echo "${disk_entry}" | cut -d ',' -f 1)

        # Run smartctl -i on the device
        logger info "Displaying S.M.A.R.T. information for device '/dev/${device_name}'..."
        smartctl -i "/dev/${device_name}"
    done
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
        logger warn "disk_serial is empty or undefined. Cannot add serial to in-progress file."
        return 1
    fi

    echo "${disk_serial}" >> "${in_progress_filepath}"
}

function remove_serial_from_in_progress_filepath() {
    if [[ -z "${disk_serial}" ]]; then
        logger warn "disk_serial is empty or undefined. Cannot remove serial from in-progress file."
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
                logger warn "S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk '${disk}', this normally indicates a cabling/power issue"
                if [[ "${notify_service}" == 'ntfy' ]]; then
                    ntfy "[FAILED] S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk '${disk}', this normally indicates a cabling/power issue" "${ntfy_topic}"
                fi
            else
                logger warn "S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk '${disk}', this indicates a failing disk"
                if [[ "${notify_service}" == 'ntfy' ]]; then
                    ntfy "[FAILED] S.M.A.R.T. attribute '${i}' has value '${smart_attribute_value}' for disk '${disk}', this indicates a failing disk" "${ntfy_topic}"
                fi
                return 1
            fi
        fi
    done
    logger info "S.M.A.R.T. attribute for disk '/dev/${disk}' all passed"
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
            logger info "Please confirm you wish to perform a badblocks test on drive '/dev/${disk}' by typing 'YES': "
            read -r confirm_drive

            if [[ "${confirm_drive}" != "YES" ]]; then
                logger info "Bad user response '${confirm_drive}', exiting script..."
                exit 1
            fi
        fi

        # get block size of disk
        block_size=$(blockdev --getbsz "/dev/${disk}")

        if [[ "${notify_service}" == 'ntfy' ]]; then
            ntfy "[INFO] Running badblocks for disk '/dev/${disk}' started at '$(date)', this may take several days depending on the test pattern specified"
        fi

        logger info "Running badblocks for disk '/dev/${disk}' started at '$(date)', this may take several days depending on the test pattern specified..."

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

        logger info "badblocks finished for disk '/dev/${disk}' at '$(date)'."

        remove_serial_from_in_progress_filepath
        check_smart_attributes "${disk}"
    done
}

function ntfy() {

    local message="${1}"
    curl -s -d "${message}" "ntfy.sh/${ntfy_topic}" &> /dev/null
}

function main() {

    logger info "Script '${ourScriptName}' started at '$(date)'"

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

    -lp or --log-path <absolute path>
        Define the absolute path to store the logs.
        Defaults to '${defaultLogPath}'.

    --ll or --log-level <debug|info|warn|error|critical>
        Define the log level for the script's output.
        Defaults to '${defaultLogLevel}'.

Examples:
    Check S.M.A.R.T. attributes for a specific drive:
        ./${ourScriptName} --action 'check-smart' --drive-name 'sdX'

    List drives not in the UNRAID array, candidates for testing:
        ./${ourScriptName} --action 'list' --log-level 'info'

    Test drive sdX with confirmation prompt, running a destructive test for all test patterns:
        ./${ourScriptName} --action 'test' --drive-name 'sdX' --destructive-test 'yes' --log-level 'info'

    Test drive sdX with confirmation prompt, running a destructive test with notify and specifying number of blocks (recommended):
        ./${ourScriptName} --action 'test' --drive-name 'sdX' --destructive-test 'yes' --notify-service 'ntfy' --ntfy-topic 'my_topic' --log-level 'info'

    Test drive sdX with confirmation prompt, running a destructive test for 2 test patterns and sending push notifications to ntfy:
        ./${ourScriptName} --action 'test' --drive-name 'sdX' --destructive-test 'yes' --test-pattern '0xaa 0x00' --notify-service 'ntfy' --ntfy-topic 'my_topic' --log-level 'info'

    Test drive sdX for a non-destructive test with test pattern 0xff:
        ./${ourScriptName} --action 'test' --drive-name 'sdX' --destructive-test 'no' --test-pattern '0xff' --log-level 'info'

    Test drive sdX with no confirmation prompt, number of blocks to process at a time set to 10000, running a destructive test for specific test patterns:
        ./${ourScriptName} --action 'test' --drive-name 'sdX' --confirm 'no' --num-blocks '10000' --destructive-test 'yes' --test-pattern '0xaa 0xff 0x00' --log-level 'info'

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
        -ll|--log-level)
            log_level=$2
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
