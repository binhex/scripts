#!/bin/bash

# this script removes all torrents from rtorrent that have
# a status of 'seeding'.
# note this script will block, either run via cron or nohup

readonly ourScriptName=$(basename -- "$0")

# define connection to rtorrent xmlrpc
xmlrpc_connection="localhost:9080"

# define period to sleep (in seconds)
sleep_period_secs=30

# simple function to exit script
function exit_script() {
	echo "[info] Script '${ourScriptName}' finished" ; exit 1
}

# trap ctrl+c and go to exit_script function (must go above infinite loop)
trap exit_script SIGINT

echo "[info] Script '${ourScriptName}' starting..."

# infinite loop
while true; do

	# get infohashes from rtorrent for all torrents (space separated)
	rtorrent_infohashes=$(xmlrpc "${xmlrpc_connection}" download_list | grep -P -o "(?<=\s\')[a-zA-Z0-9]+" | xargs)

	# split space separated string into list from rtorrent_infohashes
	IFS=' ' read -ra rtorrent_infohashes_list <<< "${rtorrent_infohashes}"

	echo "[info] Processing all torrents..."
	for rtorrent_infohash in "${rtorrent_infohashes_list[@]}"; do

		# check if torrent is seeding (finished) by grabbing the 64 bit integer value from the timestamp.finished, if the value is NOT 0 then its seeding
		rtorrent_timestamp=$(xmlrpc "${xmlrpc_connection}" d.timestamp.finished "${rtorrent_infohash}" | grep -P -o "(?<=\s)[0-9]+$" | xargs)

		# if rtorrent_timestamp != 0 then seeding - remove torrent
		if [[ "${rtorrent_timestamp}" -ne 0 ]]; then

			echo "[info] Erasing seeding torrent with hash ${rtorrent_infohash} from rtorrent..."
			xmlrpc "${xmlrpc_connection}" d.erase "${rtorrent_infohash}"

		fi

	done

	echo "[info] All torrents processed, sleeping for ${sleep_period_secs} seconds..."

	# wait for next invocation
	sleep "${sleep_period_secs}"s

done

echo "[info] Script '${ourScriptName}' finished"
