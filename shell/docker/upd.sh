#!/bin/bash

# exit script if return code != 0
set -e

function create_static_mirrorlist() {

if [[ "${TARGETARCH}" == "amd64" ]]; then
cat <<'EOF' > /etc/pacman.d/mirrorlist
Server = https://arch.mirror.constant.com/$repo/os/$arch
Server = https://arch.mirror.square-r00t.net/$repo/os/$arch
Server = http://arch.mirror.square-r00t.net/$repo/os/$arch
Server = rsync://arch.mirror.constant.com/archlinux/$repo/os/$arch
Server = rsync://arch.mirror.square-r00t.net/arch/$repo/os/$arch
EOF
else
cat <<'EOF' > /etc/pacman.d/mirrorlist
Server = http://eu.mirror.archlinuxarm.org/$arch/$repo
EOF
fi

}

function run_reflector() {

	pacman -S rsync reflector --noconfirm

	# use reflector to overwriting existing mirrorlist, args explained below
	# --sort age                        = sort by last server synchronized
	# --age 1                           = Only return mirrors that have synchronized in the last 1 hours.
	# --latest 5                        = Limit the list to the 5 most recently synchronized servers.
	# --score 5                         = Limit the list to the n servers with the highest score.
	# --save /etc/pacman.d/mirrorlist   = Save the mirrorlist to the given path.
	# mirrorlist does not always populate, retry if exit code not 0

	echo "[info] Updating mirrorlist for pacman using reflector..."
	retry_count=3
	sleep_period_secs=10
	completion_percent=100

	while true; do

		# required, as this script is sourced in and thus picks up set -e
		set +e
		reflector_stderr=$(reflector --completion-percent="${completion_percent}" --connection-timeout 60 --cache-timeout 60 --sort age --age 1 --latest 5 --score 5 --save /etc/pacman.d/mirrorlist 2>&1)
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
				create_static_mirrorlist
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
	create_static_mirrorlist
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
