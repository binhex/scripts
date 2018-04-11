#!/bin/bash

readonly ourScriptName=$(basename -- "$0")


# set status of vms, can be stopped/paused/running/all
# stopped = --state-shutoff
# running = --state-running
# paused = --state-paused
# all = --all
vm_exists=$(virsh list --all --name)

# attempt to cleanly shutdown the vm.
virsh shutdown "$vm"

# wait for status of vm to be "shut off"
vm_state=$(virsh domstate "$vm")

# get location of vdisk, will need to loop over these in case of more than 1
virsh domblklist "$vm" --details

# copy vdisk to backup location

# tar vdisk and xml backups and then gzip
tar zcvSf "$backup_location/$vm/$vm.tar.gz" "$backup_location/$vm/"*.{xml,fd,img,qcow2}

# attempt to start vm
virsh start "$vm"

# wait for status of vm to be "running", if not started in time period then send email
vm_state=$(virsh domstate "$vm")






function show_help() {
	#cat <<ENDHELP
Description:
	Wrapper script to call preclear script with params
Syntax:
	${ourScriptName} [args]
Where:
	-h or --help
		Displays this text.

	-vn or --vm_name <name of vms to backup>
		Backup VM(s) that have a set name.
		Default is all vms

	-x or --backup_xml <yes/no>
		Decide if you want to backup VM XML.
		Default is 'yes'

	-p or --poll_period_secs <seconds>
		How long to wait in seconds between polls for shutdown
		Default is '10' seconds

	-f or --force_shutdown_secs <yes/no>
		How long to wait in seconds before forced shutdown occurs, a value of 0 means infinite wait.
		Default is '0'.

	-s or --failed_startup_secs <seconds>
		How long to wait in seconds before startup is assumed failed.
		Default is '120' seconds

	-b or --backup_location <path>
		Path used for backups.
		No default

	-n or --number_of_backups <number of backups>
		Number of backups to keep.
		Default is '5' backups

	-es or --email_sender <senders email address>
		Senders email address shown in notification messages.
		Default is 'unRAIDVMBackup'

	-er or --email_recipient <recipients email address>
		Recipients email address notification messages will be sent to.
		No default

	-ns or --notify_backup_started <yes/no>
		Whether to send notification on backup started.
		Default is 'no'

	-nf or --notify_backup_finished <yes/no>
		Whether to send notification on backup finished.
		Default is 'yes'

Example:
	./"${ourScriptName}" \
	--daemon \
	--vm_state "all" \
	--backup_xml "yes" \
	--poll_period_secs "10" \
	--forced_shutdown_secs "120" \
	--failed_startup_secs "120" \
	--backup_location "/mnt/user/Backups/" \
	--number_of_backups "5" \
	--email_notification "yes" \
	--email_sender "unRAIDVMBackup" \
	--email_recipient "fred@blogs.com" \
	--notify_backup_started "yes" \
	--notify_backup_finished "yes"
ENDHELP
}

while [ "$#" != "0" ]
do
	case "$1"
	in
		-d|--device)
			device=$2
			shift
			;;
		-h|--help)
			show_help
			exit 0
			;;
		*)
			echo "${ourScriptName}: ERROR: Unrecognised argument '$1'." >&2
			show_help
			 exit 1
			 ;;
	 esac
	 shift
done

# check we have mandatory parameters, else exit with warning
if [[ -z "${device}" ]]; then
	echo "[warning] device not defined via parameter -d or --device, displaying help..."
	show_help
	echo "Listing available devices before exit..."
	"./${preclear_script_name}" -l
	exit 1
fi
