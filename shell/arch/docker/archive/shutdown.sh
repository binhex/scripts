#! /bin/bash

# script to send signal to child processes started by bash scripts,
# as bash does NOT forward signals to child processes.
#
# example call to this script using supervisor shown below:-
#
#[program:shutdown-script]
#autorestart = false
#startsecs = 0
#user = root
#command = /usr/local/bin/shutdown.sh '^/usr/bin/rtorrent,/home/nobody/bin/nginx'
#umask = 000

process="${1}"
signal="${2}"
owner="${3}"

# if process not defined then exit
if [ -z "${process}" ]; then
	if [[ "${DEBUG}" == "true" ]]; then
		echo "[crit] Full process path not specified as parameter 1, exiting script ..."
	fi
	exit 1
fi

# split comma separated string into list from process_list
IFS=',' read -ra process_list <<< "${process}"

# if signal not defined then default to '15' (SIGTERM - terminate whenever/soft kill, typically sends SIGHUP as well)
if [ -z "${signal}" ]; then
	if [[ "${DEBUG}" == "true" ]]; then
		echo "[info] Signal not specified as parameter 2, assuming signal '15' (sigterm)"
	fi
	signal=15
else
	if [[ "${DEBUG}" == "true" ]]; then
		echo "[info] Signal is '${signal}'"
	fi
fi

# if owner not defined then default to 'nobody'
if [ -z "${owner}" ]; then
	if [[ "${DEBUG}" == "true" ]]; then
		echo "[info] Process owner not specified as parameter 3, assuming owner 'nobody'"
	fi
	owner="nobody"
else
	if [[ "${DEBUG}" == "true" ]]; then
		echo "[info] Process owner is '${owner}'"
	fi
fi

function get_pid(){
	pid=$(pgrep -fu "${owner}" "${process_item}")
	if [[ "${DEBUG}" == "true" ]]; then
		if [ -z "${pid}" ]; then
			echo "[info] pid does not exist for process '${process_item}', process not running yet?"
		else
			echo "[info] pid is '${pid}' for process '${process_item}'"
		fi
	fi
}

function kill_process(){
	if [ -n "${pids}" ]; then
		if [[ "${DEBUG}" == "true" ]]; then
			echo "[info] Sending signal '${signal}' to pids '${pids}' ..."
		fi
		while kill -${signal} ${pids} 2> /dev/null; do
			sleep 0.1s
		done
	fi
	exit 0
}

function init_shutdown(){
	echo "[info] Initialising shutdown of process(es) '${process}' ..."
	for process_item in "${process_list[@]}"; do
		# get pid of process
		get_pid
		pids+="${pid} "
	done
	kill_process
}

# kill process on trap
trap "init_shutdown" SIGINT SIGTERM

# run indefinite sleep, using wait to allow us to interrupt sleep process
sleep infinity &
wait
