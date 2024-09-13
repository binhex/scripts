#!/bin/bash

# script name and version
readonly ourScriptName=$(basename -- "$0")
readonly ourScriptVersion="v1.0.0"

# set defaults
readonly defaultDebug='no'
readonly defaultPreferencesPath='/config/Plex Media Server'

preferences_filename='Preferences.xml'
preferences_path="${defaultPreferencesPath}"
preferences_filepath="${preferences_path}/${preferences_filename}"
debug="${defaultDebug}"

# TODO verify script works as expected

function check_prereqs() {

	# Check if the required tools are installed
	if ! command -v curl &> /dev/null; then
	echo "[WARN] curl could not be found, please install and re-run, exiting script..."
	exit 1
	fi

	if [[ -z "${claim_code}" ]]; then
		echo "[WARN] Claim Code not defined via parameter -cc or --claim-code, displaying help..."
		echo ""
		show_help
		exit 1
	fi

}

function set_preferences() {

	local key="${1}"
	local value="${2}"

	if grep -q "${key}" "$preferences_filepath}"; then
		# replace existing value for key in preferences.xml by using backref group match
		# note groups start at 0, thus this is group 1 as denoted by '\1'
		sed -i -E "s~(${key}=\")([^\"]+)~\1${value}~g" "$preferences_filepath}"
	else
		# add new key value pair to preferences.xml after AcceptedEULA
		sed -i -E "s~AcceptedEULA=\"1\"~AcceptedEULA=\"1\" ${key}=${value}~g" "${preferences_filepath}"
	fi
}

function get_preferences() {

	local key_name="${1}"

	# get value for key in preferences.xml
	grep -P -o -m 1 "(?<=${key_name}=\")[^\"]+" "${preferences_filepath}"

}

function process_preferences() {

	# attempt to get machine identifier from preferences.xml, if its not found then generate
	machine_identifier=$(get_preferences "MachineIdentifier")
	if [[ -z "${machine_identifier}" ]]; then
		echo "[INFO] MachineIdentifier not found in Preferences.xml, creating using 'uuidgen'..."
		machine_identifier="$(uuidgen)"
	fi

	# attempt to get processed machine identifier from preferences.xml, if its not found then generate
	processed_machine_identifier=$(get_preferences "ProcessedMachineIdentifier")
	if [[ -z "${processed_machine_identifier}" ]]; then
		processed_machine_identifier="$(echo -n "${machine_identifier}- Plex Media Server" | sha1sum | cut -b 1-40)"
	fi

	# if plex online token not found in prefereces.xml then proceed
	plex_online_token=$(get_preferences "PlexOnlineToken")
	if [[ -z "${plex_online_token}" ]]; then
		get_plex_online_token
	else
		echo "[INFO] Plex Online Token already found in Preferences.xml, nothing to do."
	fi

}

function get_plex_online_token() {

	echo "[info] Attempting to obtain Plex Online Token from claim token"
	exchange_claim_code_response="$(curl -X POST \
		-H 'X-Plex-Client-Identifier: '"${processed_machine_identifier}" \
		-H 'X-Plex-Product: Plex Media Server'\
		-H 'X-Plex-Version: 1.1' \
		-H 'X-Plex-Provides: server' \
		-H 'X-Plex-Platform: Linux' \
		-H 'X-Plex-Platform-Version: 1.0' \
		-H 'X-Plex-Device-Name: PlexMediaServer' \
		-H 'X-Plex-Device: Linux' \
		"https://plex.tv/api/claim/exchange?token=${claim_code}")"

	plex_online_token="$(echo "$exchange_claim_code_response" | sed -n 's/.*<authentication-token>\(.*\)<\/authentication-token>.*/\1/p')"

	if [[ -n "${plex_online_token}" ]]; then
		set_preferences "PlexOnlineToken" "${plex_online_token}"
	else
		echo "[error] Failed to obtain Plex Online Token from claim token, exiting..."
		exit 1
	fi

}

function main() {
	echo "[INFO] Running script ${ourScriptName}..."
	check_prereqs
	process_preferences
	echo "[INFO] Script ${ourScriptName} finished"
}

function show_help() {
	cat <<ENDHELP
Description:
	A simple bash script to (re)claim a Plex Media Server.
	${ourScriptName} ${ourScriptVersion} - Created by binhex.

Syntax:
	${ourScriptName} [args]

Where:
	-h or --help
		Displays this text.

	-cc or --claim-code <code>
		Define the Plex Claim Code, generated from https://plex.tv/claim
		No default.

	-pp or --preferences-path <path>
		Define the absolute path to the Plex Media Server preferences file.
		Defaults to '${defaultPreferencesPath}'.

	--debug <yes|no>
		Define whether debug is turned on or not.
		Defaults to '${defaultDebug}'.

Examples:
	Generate Plex Server Token:
		./${ourScriptName} --claim-code 'claim-1mKHLRjJgyi5aq8kRB6L' --preferences-path '/config/Plex Media Server' --debug 'yes'

Notes:
	Claim Codes are only valid for a maximum duration of 4 minutes.
ENDHELP
}

while [ "$#" != "0" ]
do
	case "$1"
	in
		-cc|--claim-code)
			claim_code=$2
			shift
			;;
		-pp|--preferences-path)
			preferences_path=$2
			shift
			;;
		--debug)
			debug=$2
			shift
			;;
		-h|--help)
			show_help
			exit 0
			;;
		*)
			echo "[warn] Unrecognised argument '$1', displaying help..." >&2
			echo ""
			show_help
			exit 1
			;;
	esac
	shift
done
