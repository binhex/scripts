#!/bin/bash

readonly ourScriptName=$(basename -- "$0")
readonly defaultPreclearFilename="preclear_bjp.sh"
readonly defaultPreclearPath="/boot/scripts/fast-preclear"

preclear_filename="${defaultPreclearFilename}"
preclear_path="${defaultPreclearPath}"

function run_preclear() {
	if [[ ! -d "${preclear_path}" ]]; then
		echo "[error] Incorrect path to preclear script (does not exist), exiting..."
		exit 1
	fi

	if [[ ! -f "${preclear_path}/${preclear_filename}" ]]; then
		echo "[error] Incorrect filename for preclear script (does not exist), exiting..."
		exit 1
	fi

	cd "${preclear_path}"

	if [[ ! -f "/boot/readvz" ]]; then
		echo "[info] Copying readvz 64bit to root of flash drive..."
		cp "${preclear_path}/readvz" /boot/
	fi

	# create empty array config file as we have never started the array.
	if [[ ! -f "/boot/config/disk.cfg" ]]; then
		echo "[info] Creating empty array config file..."
		touch "/boot/config/disk.cfg"
	fi

	# patch preclear script - sfdisk -R not supported, and dd output change, 
	# pre-read and post-read status are showing time instead of speed.
	echo "[info] Patching up script for sfdisk and dd..."
	sed -i -e "s/print \$9 /print \$8 /" -e "s/sfdisk -R /blockdev --rereadpt /" -e "s/  sed -n 3p [^\}]*}'/awk -F',' 'END{print \$NF}'/g" "./${preclear_filename}"

	# run preclear script against drive
	echo "[info] Running preclear script './${preclear_filename} -f -A /dev/${device}'..."
	"./${preclear_filename}" -f -A "/dev/${device}"
}

function show_help() {
	cat <<ENDHELP
Description:
	Wrapper script to patch and then call the fast-preclear script with paramaters
Syntax:
	./${ourScriptName} [args]
Where:
	-h or --help
		Displays this text.

	-f or --preclear-filename <filename>
		Set the filename for the fast preclear script to patch and run.
		Default preclear filename to patch and run is '${defaultPreclearFilename}'

	-p or --preclear-path <path>
		Set the path to the fast preclear script.
		Default path to preclear script is '${defaultPreclearPath}'

	-d or --device <device name>
		Set the device we want to preclear
		No default.
Example:
	./${ourScriptName} --preclear-filename preclear_bjp.sh --preclear-path /boot/scripts/fast-preclear --device sdx
ENDHELP
}

while [ "$#" != "0" ]
do
	case "$1"
	in
		-p|--preclear-path)
			preclear_path=$2
			shift
			;;
		-f|--preclear-filename)
			preclear_filename=$2
			shift
			;;
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
	"./${preclear_filename}" -l
	exit 1
fi

run_preclear "${device}"
