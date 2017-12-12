#!/bin/bash

readonly preclear_script_name="preclear_bjp.sh"
readonly ourScriptName=$(basename -- "$0")

function run_preclear() {
	# location of faster preclear script on flash drive
	cd /boot/preclear

	if [[ ! -f /boot/readvz ]]; then
		echo "Copying readvz 64bit to root of flash drive..."
		cp /boot/preclear/readvz /boot/
	fi

	# create empty array config file as we have never started the array.
	if [[ ! -f /boot/config/disk.cfg ]]; then
		echo "Creating empty array config file..."
		touch /boot/config/disk.cfg
	fi

	# patch preclear script - sfdisk -R not supported, and dd output change, 
	# pre-read and post-read status are showing time instead of speed.
	echo "Patching up script for sfdisk and dd..."
	sed -i -e "s/print \$9 /print \$8 /" -e "s/sfdisk -R /blockdev --rereadpt /" -e "s/  sed -n 3p [^\}]*}'/awk -F',' 'END{print \$NF}'/g" "./${preclear_script_name}"

	# run preclear script against drive
	echo "Running preclear script './${preclear_script_name} -f -A /dev/${device}'..."
	"./${preclear_script_name}" -f -A "/dev/${device}"
}

function show_help() {
	cat <<ENDHELP
Description:
	Wrapper script to call preclear script with params
Syntax:
	${ourScriptName} [args]
Where:
	-h or --help
		Displays this text.

	-d or --device <device name>
		Set the device we want to preclear
		No default.
Example:
	./runme.sh --device sdx
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

run_preclear "${device}"
