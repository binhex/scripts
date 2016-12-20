#!/bin/bash

# exit script if return code != 0
set -e

# send stdout and stderr to supervisor log file (to capture output from this script)
exec 3>&1 4>&2 1>>/config/supervisord.log 2>&1

cat << "EOF"
Created by...
___.   .__       .__                   
\_ |__ |__| ____ |  |__   ____ ___  ___
 | __ \|  |/    \|  |  \_/ __ \\  \/  /
 | \_\ \  |   |  \   Y  \  ___/ >    < 
 |___  /__|___|  /___|  /\___  >__/\_ \
     \/        \/     \/     \/      \/
   https://hub.docker.com/u/binhex/

EOF

if [[ "${HOST_OS}" == "unRAID" ]]; then
	echo "[info] Host is running unRAID" | ts '%Y-%m-%d %H:%M:%.S'
fi

echo "[info] System information $(uname -a)" | ts '%Y-%m-%d %H:%M:%.S'

export PUID=$(echo "${PUID}" | sed -e 's/^[ \t]*//')
if [[ ! -z "${PUID}" ]]; then
	echo "[info] PUID defined as '${PUID}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[warn] PUID not defined (via -e PUID), defaulting to '99'" | ts '%Y-%m-%d %H:%M:%.S'
	export PUID="99"
fi

# set user nobody to specified user id (non unique)
usermod -o -u "${PUID}" nobody &>/dev/null

export PGID=$(echo "${PGID}" | sed -e 's/^[ \t]*//')
if [[ ! -z "${PGID}" ]]; then
	echo "[info] PGID defined as '${PGID}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[warn] PGID not defined (via -e PGID), defaulting to '100'" | ts '%Y-%m-%d %H:%M:%.S'
	export PGID="100"
fi

# set group users to specified group id (non unique)
groupmod -o -g "${PGID}" users &>/dev/null

# check for presence of perms file, if it exists then skip setting
# permissions, otherwise recursively set on volume mappings for host
if [[ ! -f "/config/perms.txt" ]]; then

	echo "[info] Setting permissions recursively on volume mappings..." | ts '%Y-%m-%d %H:%M:%.S'
	
	if [[ -d "/data" ]]; then
		volumes="/config /data"
	else
		volumes="/config"
	fi

	set +e
	chown -R "${PUID}":"${PGID}" "${volumes}"
	exit_code_chown=$?
	chmod -R 775 "${volumes}"
	exit_code_chmod=$?
	set -e
	
	if (( ${exit_code_chown} != 0 || ${exit_code_chmod} != 0 )); then
		echo "[warn] Unable to chown/chmod ${volumes}, assuming SMB mountpoint"
	fi

	echo "This file prevents permissions from being applied/re-applied to /config, if you want to reset permissions then please delete this file and restart the container." > /config/perms.txt

else

	echo "[info] Permissions already set for volume mappings" | ts '%Y-%m-%d %H:%M:%.S'

fi

# ENVVARS_PLACEHOLDER

# PERMISSIONS_PLACEHOLDER

# restore stdout/stderr (to prevent duplicate logging from supervisor)
exec 1>&3 2>&4

echo "[info] Starting Supervisor..." | ts '%Y-%m-%d %H:%M:%.S'
exec /usr/bin/supervisord -c /etc/supervisor.conf -n
