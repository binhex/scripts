#!/bin/bash

readonly defaultDebug="no"
debug="${defaultDebug}"

function symlink {

	while [ "$#" != "0" ]
	do
		case "$1"
		in
			-sp|--src-path)
				src_path=$2
				shift
				;;
			-dp|--dst-path)
				dst_path=$2
				shift
				;;
			-lt| --link-type)
				link_type=$2
				shift
				;;
			--debug)
				debug=$2
				shift
				;;
			-h|--help)
				show_help_symlink
				exit 0
				;;
			*)
				echo "[warn] Unrecognised argument '$1', displaying help..." >&2
				echo ""
				show_help_symlink
				return 1
				;;
		esac
		shift
	done

	# verify required options specified
	if [[ -z "${src_path}" ]]; then
		echo "[WARN] Source path not specified, showing help..."
		show_help_symlink
		return 1
	fi

	if [[ -z "${dst_path}" ]]; then
		echo "[WARN] Destination path not specified, showing help..."
		show_help_symlink
		return 1
	fi

	if [[ -z "${link_type}" ]]; then
		echo "[WARN] Link type not specified, showing help..."
		show_help_symlink
		return 1
	fi

	# verify link type
	if [[ "${link_type}" == "softlink" ]]; then
		link_type="-s"
	elif [[ "${link_type}" == "hardliunk" ]]; then
		link_type=""
	else
		echo "[WARN] Unknown link type of '${link_type}' specified, exiting function..."
		return 1
	fi

	# if container folder exists then rename and use as default restore
	if [[ -d "${src_path}" && ! -L "${src_path}" ]]; then
		echo "[info] '${src_path}' path already exists, renaming..."
		mv "${src_path}" "${src_path}-backup"
	fi

	# if ${dst_path} doesnt exist then restore from backup
	if [[ ! -d "${dst_path}" ]]; then
		if [[ -d "${src_path}-backup" ]]; then
			echo "[info] '${dst_path}' path does not exist, copying defaults..."
			mkdir -p "${dst_path}" ; cp -R "${src_path}-backup/"* "${dst_path}"
		fi
	else
		echo "[info] '${dst_path}' path already exists, skipping copy"
	fi

	# create soft link to ${src_path}/${folder} storing general settings
	echo "[info] Creating soft link from '${dst_path}' to '${src_path}'..."
	mkdir -p "${dst_path}" ; rm -rf "${src_path}" ; ln "${link_type}" "${dst_path}/" "${src_path}"

	if [[ -n "${PUID}" && -n "${PGID}" ]]; then
		# reset permissions after file copy
		chown -R "${PUID}":"${PGID}" "${dst_path}" "${src_path}"
	fi
}

function dos2unix() {

	while [ "$#" != "0" ]
	do
		case "$1"
		in
			-fp|--file-path)
				file_path=$2
				shift
				;;
			--debug)
				debug=$2
				shift
				;;
			-h|--help)
				show_help_dos2unix
				exit 0
				;;
			*)
				echo "[warn] Unrecognised argument '$1', displaying help..." >&2
				echo ""
				show_help_dos2unix
				return 1
				;;
		esac
		shift
	done

	# verify required options specified
	if [[ -z "${file_path}" ]]; then
		echo "[WARN] File path not specified, showing help..."
		show_help_dos2unix
		return 1
	fi

	# verify file path exists
	if [ ! -f "${file_path}" ]; then
		echo "[WARN] File path '${file_path}' does not exist, exiting function..."
		return 1
	fi

	# run sed to switch line endings (in-place edit)
	sed -i $'s/\r$//' "${file_path}"
}

function show_help_symlink() {
	cat <<ENDHELP
Description:
	A function to symlink a source path to a destination path.
Syntax:
	source ./utils.sh && symlink [args]
Where:
	-h or --help
		Displays this text.

	-sp or --src-path <path>
		Define source path to symlink
		No default.

	-dp or --dst-path <path>
		Define destinaiton path to symlink
		No default.

	-lt or --link-type <softlink|hardlink>
		Define the symlink type.
		No default.

	--debug <yes|no>
		Define whether debug is turned on or not.
		Defaults to '${defaultDebug}'.

Examples:
	Create softlink from /home/nobody to /config/code-server/home with debugging on:
		source '/usr/local/bin/utils.sh' && symlink --src-path '/home/nobody' --dst-path '/config/code-server/home' --link-type 'softlink' --debug 'yes'

	Create hardlink from /home/nobody to /config/code-server/home with debugging on:
		source '/usr/local/bin//utils.sh' && symlink --src-path '/home/nobody' --dst-path '/config/code-server/home' --link-type 'hardlink' --debug 'yes'

ENDHELP
}

function show_help_dos2unix() {
	cat <<ENDHELP
Description:
	A function to change line endings from dos to unix
Syntax:
	source ./utils.sh && dos2unix [args]
Where:
	-h or --help
		Displays this text.

	-fp or --file-path <path>
		Define file path to file to convert from DOS line endings to UNIX.
		No default.

	--debug <yes|no>
		Define whether debug is turned on or not.
		Defaults to '${defaultDebug}'.

Examples:
	Convert line endings for wireguard config file 'config/wireguard/wg0.conf' with debugging on:
		source '/usr/local/bin/utils.sh' && dos2unix --file-path '/config/wireguard/wg0.conf' --debug 'yes'

ENDHELP
}
