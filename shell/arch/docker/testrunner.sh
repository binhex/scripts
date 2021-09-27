#!/bin/bash

# script name and version
readonly ourScriptName="$(basename -- "$0")"
readonly ourScriptPath="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

readonly defaultNetworkType="bridge"
readonly defaultContainerName="test"
readonly defaultRetryCount="60"
readonly defaultProtocol="http"

# set defaults
network_type="${defaultNetworkType}"
container_name="${defaultContainerName}"
retry_count="${defaultRetryCount}"
protocol="${defaultProtocol}"

function cleanup() {

	echo "[info] Running post test cleanup"

	echo "[info] Deleting container '${container_name}'..."
	docker rm -f "${container_name}"

	echo "[info] Deleting container bind mounts '/tmp/config', '/tmp/data', '/tmp/media' ..."
	sudo rm -rf '/tmp/config' '/tmp/data' '/tmp/media'
}

function test_result(){

	if [[ "${tests_passed}" == "false" ]]; then
		echo "==================="
		echo "[info] TESTS FAILED"
		echo "==================="
		echo "[info] Displaying contents of container log file '/tmp/config/supervisord.log'..."
		cat '/tmp/config/supervisord.log'
		echo "[info] Displaying contents of curl log file '/tmp/curl/curl.log'..."
		cat '/tmp/curl/curl.log'
		cleanup
		exit 1
	fi

	echo "==================="
	echo "[info] TESTS PASSED"
	echo "==================="
	cleanup

}

function check_port_listening() {

	mkdir -p '/tmp/curl'

	echo "[info] Creating Docker container 'docker run -d --name ${container_name} --net ${network_type} ${env_vars} ${additional_args} -v '/tmp/config':'/config' -v '/tmp/data':'/data' -v '/tmp/media':'/media' ${container_ports} ${image_name}'"
	docker run -d --name ${container_name} --net ${network_type} ${env_vars}  ${additional_args} -v '/tmp/config':'/config' -v '/tmp/data':'/data' -v '/tmp/media':'/media' ${container_ports} ${image_name}

	echo "[info] Showing running containers..."
	docker ps

	# get host ports to check
	host_ports=$(echo "${container_ports}" | grep -P -o -m 1 '(?<=-p\s)[0-9]+' | xargs)

	# split space separated host ports into array
	IFS=' ' read -ra host_ports_array <<< "${host_ports}"

	# loop over list of host ports
	for host_port in "${host_ports_array[@]}"; do

		echo "[info] Waiting for port '${host_port}' to be in listen state..."
		while ! curl -o '/tmp/curl/curl.log' -L "${protocol}://localhost:${host_port}"; do
			retry_count=$((retry_count-1))
			if [ "${retry_count}" -eq "0" ]; then
				tests_passed="false"
				test_result
			fi
			sleep 1s
		done
		echo "[info] SUCCESS, port '${host_port}' is in listening state"

	done

	tests_passed="true"
	test_result
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

	-cp or --container-ports
		Define the container port(s) for the container.
		No default.

	-cn or --container-name
		Define the name for the container.
		Defaults to '${defaultContainerName}'.

	-nt or --network-type
		Define the network type for the container.
		Defaults to '${defaultNetworkType}'.

	-rc or --retry-count
		Define the number of retries before test is marked as failed
		Defaults to '${defaultRetryCount}'.

	-ev or --env-vars
		Define the env vars for the container.
		No default.

	-aa or --additional-args
		Define any additional docker arguments for the container.
		No default.

	-p or --protocol
		Define protocol for test, valid values are <http|https>.
		defaults to '${defaultProtocol}'.

Examples:
	Run test for image with VPN disabled via env var:
		${ourScriptPath}/${ourScriptName} --image-name 'binhex/arch-sabnzbd:latest' --container-ports '-p 9999:8080' --container-name 'test' --network-type 'bridge' --retry-count '60' --env-vars '-e VPN_ENABLED=no' --additional-args '--privileged=true' --protocol 'http'
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
		-cp|--container-ports)
			container_ports="${2}"
			shift
			;;
		-cn|--container-name)
			container_name="${2}"
			shift
			;;
		-nt|--network-type)
			network_type="${2}"
			shift
			;;
		-rc|--retry-count)
			retry_count="${2}"
			shift
			;;
		-ev|--env-vars)
			env_vars="${2}"
			shift
			;;
		-aa|--additional-args)
			additional_args="${2}"
			shift
			;;
		-p|--protocol)
			protocol="${2}"
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

if [[ -z "${container_ports}" ]]; then
	echo "[warn] Please specify '--container-ports' option, displaying help..."
	echo ""
	show_help
	exit 1
fi

check_port_listening