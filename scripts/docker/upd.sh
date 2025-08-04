#!/bin/bash

# exit script if return code != 0
set -e

function create_static_amd64_mirrorlist() {

	cat <<'EOF' > /etc/pacman.d/mirrorlist
Server = https://london.mirror.pkgbuild.com/$repo/os/$arch
Server = https://uk.repo.c48.uk/arch/$repo/os/$arch
Server = https://mirror.server.net/archlinux/$repo/os/$arch
Server = https://de.arch.niranjan.co/$repo/os/$arch
Server = https://mirrors.lug.mtu.edu/archlinux/$repo/os/$arch
EOF

}

function create_static_arm64_mirrorlist() {

	cat <<'EOF' > /etc/pacman.d/mirrorlist
Server = https://de3.mirror.archlinuxarm.org/$arch/$repo
Server = https://de4.mirror.archlinuxarm.org/$arch/$repo
Server = https://de5.mirror.archlinuxarm.org/$arch/$repo
Server = https://eu.mirror.archlinuxarm.org/$arch/$repo
Server = https://ca.us.mirror.archlinuxarm.org/$arch/$repo
EOF

}

function run_reflector() {

	pacman -S rsync reflector --noconfirm

	# use reflector to overwriting existing mirrorlist, args explained below
	# --sort age                        = sort by last server synchronized
	# --age 1                           = Only return mirrors that have synchronized in the last 1 hours.
	# --latest 5                        = Limit the list to the 5 most recently synchronized servers.
	# --score 5                         = Limit the list to the n servers with the highest score.
	# --save /etc/pacman.d/mirrorlist   = Save the mirrorlist to the given path.
	# --protocol https                  = Use HTTPS protocol for the mirrorlist.
	# mirrorlist does not always populate, retry if exit code not 0

	echo "[info] Updating mirrorlist for pacman using reflector..."
	retry_count=3
	sleep_period_secs=10
	completion_percent=100

	while true; do

		# required, as this script is sourced in and thus picks up set -e
		set +e
		reflector_stderr=$(reflector --completion-percent="${completion_percent}" --connection-timeout 60 --cache-timeout 60 --sort age --age 1 --latest 5 --score 5 --save /etc/pacman.d/mirrorlist --protocol https 2>&1)
		set -e
		exit_code=$?

		if [[ ! -z "${reflector_stderr}" ]]; then
			echo "[info] reflector stderr is '${reflector_stderr}'"
		fi

		echo "[info] reflector exit code is '${exit_code}'"

		if [[ "${reflector_stderr}" == *"error"* || "${exit_code}" != "0" ]]; then

			retry_count=$((retry_count-1))
			completion_percent=$((completion_percent-1))

			if [ "${retry_count}" -eq "0" ]; then

				echo "[warn] Failed to download mirrorlist, too many retries, falling back to static list"
				create_static_amd64_mirrorlist
				break

			else

				echo "[warn] Failed to download mirrorlist, ${retry_count} retries left"
				echo "[info] Reducing completion percentage to ${completion_percent}%"
				echo "[info] Sleeping for ${sleep_period_secs} seconds..."

			fi

			sleep "${sleep_period_secs}s"

		else

			echo "[info] Successfully downloaded the mirrorlist"
			break

		fi

	done

	echo "[info] Show contents of reflector generated mirrorlist for pacman..."
	cat /etc/pacman.d/mirrorlist

}

echo "[info] Target architecture from Dockerfile arg is '${TARGETARCH}'"

# reflector only supported for amd64, use static mirrorlist for arm64
if [[ "${TARGETARCH}" == "amd64" ]]; then
	run_reflector
else
	create_static_arm64_mirrorlist
fi

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

echo "[info] Synchronize pacman database and then upgrade any existing packages using pacman..."

if [[ "${pacman_confirm}" == "yes" ]]; then
	yes|pacman -Syyu
else
	pacman -Syyu --noconfirm
fi
