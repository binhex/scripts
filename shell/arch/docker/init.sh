#!/bin/bash

# exit script if return code != 0
set -e

# redirect new file descriptors and then tee stdout & stderr to supervisor log and console (captures output from this script)
exec 3>&1 4>&2 &> >(tee -a /config/supervisord.log)

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

if [[ "${HOST_OS,,}" == "unraid" ]]; then
	echo "[info] Host is running unRAID" | ts '%Y-%m-%d %H:%M:%.S'
fi

echo "[info] System information $(uname -a)" | ts '%Y-%m-%d %H:%M:%.S'

export OS_ARCH=$(cat /etc/os-release | grep -P -o -m 1 "(?=^ID\=).*" | grep -P -o -m 1 "[a-z]+$")
if [[ ! -z "${OS_ARCH}" ]]; then
	if [[ "${OS_ARCH}" == "arch" ]]; then
		OS_ARCH="x86-64"
	else
		OS_ARCH="aarch64"
	fi
	echo "[info] OS_ARCH defined as '${OS_ARCH}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[warn] Unable to identify OS_ARCH, defaulting to 'x86-64'" | ts '%Y-%m-%d %H:%M:%.S'
	export OS_ARCH="x86-64"
fi

export PUID=$(echo "${PUID}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${PUID}" ]]; then
	echo "[info] PUID defined as '${PUID}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[warn] PUID not defined (via -e PUID), defaulting to '99'" | ts '%Y-%m-%d %H:%M:%.S'
	export PUID="99"
fi

# set user nobody to specified user id (non unique)
usermod -o -u "${PUID}" nobody &>/dev/null

export PGID=$(echo "${PGID}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${PGID}" ]]; then
	echo "[info] PGID defined as '${PGID}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[warn] PGID not defined (via -e PGID), defaulting to '100'" | ts '%Y-%m-%d %H:%M:%.S'
	export PGID="100"
fi

# set group users to specified group id (non unique)
groupmod -o -g "${PGID}" users &>/dev/null

# set umask to specified value if defined
if [[ ! -z "${UMASK}" ]]; then
	echo "[info] UMASK defined as '${UMASK}'" | ts '%Y-%m-%d %H:%M:%.S'
	sed -i -e "s~umask.*~umask = ${UMASK}~g" /etc/supervisor/conf.d/*.conf
else
	echo "[warn] UMASK not defined (via -e UMASK), defaulting to '000'" | ts '%Y-%m-%d %H:%M:%.S'
	sed -i -e "s~umask.*~umask = 000~g" /etc/supervisor/conf.d/*.conf
fi

# check for presence of perms file, if it exists then skip setting
# permissions, otherwise recursively set on /config for host
if [[ ! -f "/config/perms.txt" ]]; then

	echo "[info] Setting permissions recursively on '/config'..." | ts '%Y-%m-%d %H:%M:%.S'

	set +e
	chown -R "${PUID}":"${PGID}" "/config"
	exit_code_chown=$?
	chmod -R 775 "/config"
	exit_code_chmod=$?
	set -e

	if (( ${exit_code_chown} != 0 || ${exit_code_chmod} != 0 )); then
		echo "[warn] Unable to chown/chmod '/config', assuming SMB mountpoint"
	fi

	echo "This file prevents permissions from being applied/re-applied to '/config', if you want to reset permissions then please delete this file and restart the container." > /config/perms.txt

else

	echo "[info] Permissions already set for '/config'" | ts '%Y-%m-%d %H:%M:%.S'

fi

# calculate disk usage for /tmp in bytes
disk_usage_tmp=$(du -s /tmp | awk '{print $1}')

# if disk usage of /tmp exceeds 1GB then do not clear down (could possibly be volume mount to media)
if [ "${disk_usage_tmp}" -gt 1073741824 ]; then

	echo "[warn] /tmp directory contains 1GB+ of data, skipping clear down as this maybe mounted media" | ts '%Y-%m-%d %H:%M:%.S'
	echo "[info] Showing contents of /tmp..." | ts '%Y-%m-%d %H:%M:%.S'
	ls -al /tmp

else

	echo "[info] Deleting files in /tmp (non recursive)..." | ts '%Y-%m-%d %H:%M:%.S'
	rm -f /tmp/* > /dev/null 2>&1 || true
	rm -rf /tmp/tmux*

fi

function symlink_home_dir {

	app_name="${1}"

	# if container folder exists then rename and use as default restore
	if [[ -d "/home/nobody" && ! -L "/home/nobody" ]]; then
		echo "[info] /home/nobody folder storing user general settings already exists, renaming..."
		mv "/home/nobody" "/home/nobody-backup"
	fi

	# if /config/home doesnt exist then restore from backup (see note above)
	if [[ ! -d "/config/${app_name}/home" ]]; then
		if [[ -d "/home/nobody-backup" ]]; then
			echo "[info] /config/${app_name}/home folder storing user general settings does not exist, copying defaults..."
			mkdir -p "/config/${app_name}/home" ; cp -R "/home/nobody-backup/"* "/config/${app_name}/home"
		fi
	else
		echo "[info] /config/${app_name}/home folder storing user general settings already exists, skipping copy"
	fi

	# create soft link to /home/nobody/${folder} storing general settings
	echo "[info] Creating soft link from /config/${app_name}/home to /home/nobody..."
	mkdir -p "/config/${app_name}/home" ; rm -rf "/home/nobody" ; ln -s "/config/${app_name}/home/" "/home/nobody"

	# reset permissions after file copy
	chown -R "${PUID}":"${PGID}" "/config/${app_name}/home" "/home/nobody"

}

# ENVVARS_COMMON_PLACEHOLDER

# ENVVARS_PLACEHOLDER

# PERMISSIONS_PLACEHOLDER

# CONFIG_PLACEHOLDER

echo "[info] Starting Supervisor..." | ts '%Y-%m-%d %H:%M:%.S'

# restore file descriptors to prevent duplicate stdout & stderr to supervisord.log
exec 1>&3 2>&4

exec /usr/bin/supervisord -c /etc/supervisor.conf -n
