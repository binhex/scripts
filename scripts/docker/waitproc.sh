#!/bin/bash

# script name
ourScriptName="$(basename -- "$0")"

function child_process_monitor(){
	echo "[info] Waiting for child processes to exit..."

	while true; do
		child_pid=$(jobs -rp)
		if [[ -z "${child_pid}" ]]; then
			echo "[info] All child processes exited, exiting while loop..."
			break
		fi
		sleep 0.5s
		echo "[info] Child process with pid id '${child_pid}' still running, waiting..."
	done
	echo "[info] All child processes exited, exiting '${ourScriptName}' script..."
	exit
}

# monitor for child processes on intialised shutdown
trap 'child_process_monitor' SIGTERM SIGINT
