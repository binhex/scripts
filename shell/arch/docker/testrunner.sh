#!/bin/bash

# script name and version
readonly ourScriptName="$(basename -- "$0")"
readonly ourScriptPath="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

readonly defaultHostPort="9999"
readonly defaultNetworkType="bridge"

# set defaults
host_port="${defaultHostPort}"
network_type="${defaultNetworkType}"

function cleanup() {

	echo "[info] Running post test cleanup..."
	docker system prune -a -y
}

function run_smoketests() {

	local retry_count=60

	echo "[info] Creating Docker container 'docker run -d --rm --net=${network_type} ${env_vars} -v /tmp/config:/config -v /tmp/data:/data -v /tmp/media:/media -p ${host_port}:${container_port} ${image_name}'"
	docker run -d --rm "--net=${network_type}" ${env_vars} -v /tmp/config:/config -v /tmp/data:/data -v /tmp/media:/media -p "${host_port}:${container_port}" ${image_name}

	echo "[info] Showing running containers..."
	docker ps

	echo "[info] Waiting for port '${host_port}' to be in listen state..."
	until sudo lsof -i:${host_port}; do
		retry_count=$((retry_count-1))
		if [ "${retry_count}" -eq "0" ]; then
			echo "[info] Test FAILED, Showing output for 'lsof' and supervisord log file..."
			timeout 10s sudo lsof
			cat '/tmp/config/supervisord.log'
			cleanup
			exit 1
		fi
		sleep 1s
	done

	echo "[info] Test PASSED, port is open"
	cleanup
}

function show_help() {
	cat <<ENDHELP
Description:
	Testrunner for binhex repo's.
	${ourScriptName} - Created by binhex.
Syntax:
	${ourScriptName} [args]
Where:
	-h or --help
		Displays this text.

	-in or --image-name
		Define the image and tag name for the container.
		No default.

	-hp or --host-port
		Define the host port for the container.
		Defaults to '${defaultHostPort}'.

	-cp or --container-port
		Define the container port for the container.
		No default.

	-nt or --network-type
		Define the network type for the container.
		Defaults to '${defaultNetworkType}'.

	-ev or --env-vars
		Define the env vars for the container.
		No default.

Examples:
	Run test for container with VPN disabled via env var:
		${ourScriptPath}/${ourScriptName} --image-name 'binhex/arch-sabnzbd:latest' --host-port '9999' --container-port '8090' --network-type 'bridge' --env-vars '-e VPN_ENABLED=no'
ENDHELP
}

while [ "$#" != "0" ]
do
	case "$1"
	in
		-in|--image-name)
			image_name="${2}"
			shift
			;;
		-hp|--host-port)
			host_port="${2}"
			shift
			;;
		-cp|--container-port)
			container_port="${2}"
			shift
			;;
		-nt|--network-type)
			network_type="${2}"
			shift
			;;
		-ev|--env-vars)
			env_vars="${2}"
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

echo "[info] Running ${ourScriptName} script..."

echo "[info] Checking we have all required parameters before running..."

if [[ -z "${image_name}" ]]; then
	echo "[warn] Please specify '--image-name' option, displaying help..."
	echo ""
	show_help
	exit 1
fi

if [[ -z "${container_port}" ]]; then
	echo "[warn] Please specify '--container-port' option, displaying help..."
	echo ""
	show_help
	exit 1
fi

run_smoketests