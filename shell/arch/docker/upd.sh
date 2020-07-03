#!/bin/bash

# exit script if return code != 0
set -e

pacman -S reflector --noconfirm

# use reflector to overwriting existing mirrorlist, args explained below
# --sort rate                       = sort by download rate
# --age 1                           = Only return mirrors that have synchronized in the last 1 hours.
# --latest 5                        = Limit the list to the 5 most recently synchronized servers.
# --score 5                         = Limit the list to the n servers with the highest score.
# --save /etc/pacman.d/mirrorlist   = Save the mirrorlist to the given path.
# mirrorlist does not always populate, retry if exit code not 0

echo "[info] Updating mirrorlist for pacman using reflector..."
retry_count=5
while true; do

	reflector --connection-timeout 60 --cache-timeout 60 --sort rate --age 1 --latest 5 --score 5 --save /etc/pacman.d/mirrorlist
	exit_code=$?

	if [[ "${exit_code}" -ne "0" ]]; then

		retry_count=$((retry_count-1))

		if [ "${retry_count}" -eq "0" ]; then

			echo "[crit] Failed to download mirrorlist, too many retries" ; exit 1

		else

			echo '[warn] Failed to download mirrorlist, sleeping for 60 seconds before retrying...'

		fi

		sleep 60s

	else

		echo "[info] Successfully downloaded the mirrorlist"
		break

	fi

done

echo "[info] Show contents of reflector generated mirrorlist for pacman..."
cat /etc/pacman.d/mirrorlist

if [[ ! -z "${pacman_ignore_packages}" ]]; then

	echo "[info] Ignoring package(s) '${pacman_ignore_packages}' from upgrade/install"
	sed -i -e "s~^#IgnorePkg.*~IgnorePkg = ${pacman_ignore_packages}~g" "/etc/pacman.conf"

fi

if [[ ! -z "${pacman_ignore_group_packages}" ]]; then

	echo "[info] Ignoring package group(s) '${pacman_ignore_group_packages}' from upgrade/install"
	sed -i -e "s~^#IgnoreGroup.*~IgnoreGroup = ${pacman_ignore_group_packages}~g" "/etc/pacman.conf"

fi

echo "[info] Showing pacman configuration file '/etc/pacman.conf'..."
cat "/etc/pacman.conf"

# note overwrite required due to bug in missing soname link
# see below for details:-
# https://www.archlinux.org/news/nss3511-1-and-lib32-nss3511-1-updates-require-manual-intervention/
echo "[info] Synchronize pacman database and then upgrade any existing packages using pacman..."

if [[ "${pacman_confirm}" == "yes" ]]; then
	yes|pacman -Syyu --overwrite /usr/lib\*/p11-kit-trust.so
else
	pacman -Syyu --overwrite /usr/lib\*/p11-kit-trust.so --noconfirm
fi

# delme once fixed!!
# force downgrade of coreutils - fixes permission denied issue when building on docker hub
# https://github.com/archlinux/archlinux-docker/issues/32
curl --connect-timeout 5 --max-time 600 --retry 5 --retry-delay 0 --retry-max-time 60 -o /tmp/coreutils.tar.xz -L "https://github.com/binhex/arch-packages/raw/master/compiled/x86-64/coreutils.tar.xz"
pacman -U '/tmp/coreutils.tar.xz' --noconfirm
# /delme once fixed!!
