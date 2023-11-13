#!/bin/bash

function child_process_monitor(){
	echo "[info] Waiting for child processes to exit..."

	while true; do
		child_pid=$(jobs -rp)
		if [[ -z "${child_pid}" ]]; then
			echo "[info] All child processes exited"
			break
		fi
		sleep 0.5s
		echo "[info] Child process with pid id '${child_pid}' still running, waiting..."
	done
}

# monitor for child processes on intialised shutdown
trap 'child_process_monitor' SIGTERM
