#!/bin/bash

# A simple bash script to build/install Arch AUR packages using makepkg or an AUR helper.

# script name and version
readonly ourScriptName=$(basename -- "$0")
readonly ourScriptVersion="v1.0.0"

# setup default values
readonly defaultDebug='info'
readonly defaultMakepkgPath='/tmp/makepkg'
readonly defaultSnapshotPath='/tmp/snapshots'
readonly defaultUseMakepkg='false'
readonly defaultInstallPackage='false'

DEBUG="${defaultDebug}"
MAKEPKG_PATH="${defaultMakepkgPath}"
SNAPSHOT_PATH="${defaultSnapshotPath}"
USE_MAKEPKG="${defaultUseMakepkg}"
INSTALL_PACKAGE="${defaultInstallPackage}"

function init() {

	rm -rf \
		"${MAKEPKG_PATH}" \
		"${SNAPSHOT_PATH}"

	mkdir -p \
		"${MAKEPKG_PATH}" \
		"${MAKEPKG_PATH}/build" \
		"${MAKEPKG_PATH}/pkgdest" \
		"${MAKEPKG_PATH}/srcdest" \
		"${MAKEPKG_PATH}/srcpkgdest" \
		"${SNAPSHOT_PATH}"

	# set build directory for makepkg
	sed -i -e "s~#BUILDDIR=/tmp/makepkg~BUILDDIR=${MAKEPKG_PATH}/build~g" "/etc/makepkg.conf"

	# set pkgdest directory for makepkg
	sed -i -e "s~#PKGDEST=/tmp/makepkg~PKGDEST=${MAKEPKG_PATH}/pkgdest~g" "/etc/makepkg.conf"

	# set srcdest directory for makepkg
	sed -i -e "s~#SRCDEST=/tmp/makepkg~SRCDEST=${MAKEPKG_PATH}/srcdest~g" "/etc/makepkg.conf"

	# set srcpkgdest directory for makepkg
	sed -i -e "s~#SRCPKGDEST=/tmp/makepkg~SRCPKGDEST=${MAKEPKG_PATH}/srcpkgdest~g" "/etc/makepkg.conf"

	# strip out restriction to not allow make as user root (docker build uses root)
	sed -i -e 's~exit $E_ROOT~~g' '/usr/bin/makepkg'

	# disable building of debug packages
	sed -i '/^OPTIONS=/s/\bdebug\b/!debug/g' '/etc/makepkg.conf'

	# install required packages to compile
	pacman -S base-devel binutils git sudo --needed --noconfirm

}

function compile_using_makepkg() {

	local install_flag=""
	local package

	# set install flag if required
	if [[ "${INSTALL_PACKAGE}" == "true" ]]; then
		install_flag='--install --noconfirm'
	fi

	# convert comma-separated list to array
	IFS=',' read -ra PACKAGE_ARRAY <<< "${AUR_PACKAGE}"

	# loop through each package
	for package in "${PACKAGE_ARRAY[@]}"; do
		# trim whitespace
		package=$(echo "${package}" | xargs)
		echo "[info] Processing package '${package}'..."

		# download aur package snapshot
		if ! stderr=$(rcurl.sh -o "${SNAPSHOT_PATH}/${package}.tar.gz" -L "https://aur.archlinux.org/cgit/aur.git/snapshot/${package}.tar.gz" && tar -xvf "${SNAPSHOT_PATH}/${package}.tar.gz" -C "${SNAPSHOT_PATH}"); then
			echo "[warn] Failed to download AUR package snapshot '${package}' from AUR, error is '${stderr}', attempting GitHub unofficial mirror download of package snapshot..." >&2
			if ! stderr=$(mkdir -p "${SNAPSHOT_PATH}/${package}" && rcurl.sh -o "${SNAPSHOT_PATH}/${package}/PKGBUILD" -L "https://raw.githubusercontent.com/archlinux/aur/refs/heads/${package}/PKGBUILD"); then
				echo "[warn] Failed to download AUR package snapshot '${package}' from AUR GitHub mirror, error is '${stderr}', skipping package..." >&2
				continue
			fi
		fi

		# navigate to extracted PKGBUILD
		cd "${SNAPSHOT_PATH}/${package}" || { echo "[error] Cannot navigate to ${SNAPSHOT_PATH}/${package}, skipping package..."; continue; }

		# compile package
		echo "[info] Compiling package '${package}'..."
		if ! makepkg --clean --syncdeps --rmdeps ${install_flag}; then
			echo "[error] Failed to compile package '${package}', continuing with next package..." >&2
		else
			echo "[info] Successfully compiled package '${package}'"
		fi
	done
}

function compile_using_helper() {

	# prevent sudo prompt for password when installing compiled package via pacman
	echo 'nobody ALL = NOPASSWD: /usr/sbin/pacman' > /etc/sudoers.d/yay

	# set ownership to user 'nobody' for makepkg build path - required as we are 'su'ing to user nobody (cannot run helper as root)
	chown -R nobody:users \
		"${MAKEPKG_PATH}" \
		"${SNAPSHOT_PATH}"

	# convert comma-separated list to space-separated for paru
	local package_list="${AUR_PACKAGE//,/ }"
	echo "[info] Processing package list: ${package_list}"

	# switch to user 'nobody' and run aur helper to compile and install package(s) with retries
	local retries_remaining=12
	local retry_delay=10
	local attempt=1

	while [[ ${retries_remaining} -gt 0 ]]; do
		echo "[info] Attempting to compile package(s) '${package_list}'..."
		if su nobody -c "paru --sync --norebuild --needed --builddir=${SNAPSHOT_PATH} --mflags '--config /etc/makepkg.conf' --noconfirm ${package_list}"; then
			echo "[info] Successfully compiled and installed package(s) '${package_list}' on attempt ${attempt}"
			break
		else
			retries_remaining=$((retries_remaining - 1))
			attempt=$((attempt + 1))
			if [[ ${retries_remaining} -gt 0 ]]; then
				echo "[warn] Failed to compile package(s) '${package_list}', ${retries_remaining} retries remaining, retrying in ${retry_delay} seconds..."
				sleep ${retry_delay}
			else
				echo "[error] Failed to compile package(s) '${package_list}' after all retry attempts, exiting..."
				exit 1
			fi
		fi
	done

}

function copy_compiled_packages() {

	if [[ -n "${PACKAGE_PATH}" ]]; then
		mkdir -p "${PACKAGE_PATH}"
		echo "[info] Copying compiled package(s) to package path '${PACKAGE_PATH}'..."

		# find all .tar.zst files in SNAPSHOT_PATH and copy to PACKAGE_PATH
		if find "${SNAPSHOT_PATH}" -name "*.tar.zst" -exec cp {} "${PACKAGE_PATH}/" \; -print | grep -q .; then
			echo "[info] Listing compiled package(s) in '${SNAPSHOT_PATH}':"
			ls -al "${SNAPSHOT_PATH}/"*.tar.zst
			echo "[info] Successfully copied compiled package(s) to '${PACKAGE_PATH}'"
			chown -R nobody:users "${PACKAGE_PATH}"
		else
			echo "[warn] No compiled packages (*.tar.zst) found in '${SNAPSHOT_PATH}'"
		fi
	else
		echo "[info] No package path defined, skipping copy of compiled package(s)..."
	fi
}

function install_helper() {

	local aur_package_cli
	local install_package_cli

	if command -v paru >/dev/null 2>&1; then
		echo "[info] AUR helper is already installed"
		return 0
	fi

	# save cli package names
	aur_package_cli="${AUR_PACKAGE}"

	# save cli install flag
	install_package_cli="${INSTALL_PACKAGE}"

	# force install option for helper
	INSTALL_PACKAGE='true'

	# force package name to helper
	AUR_PACKAGE='paru-bin'

	# compile and install helper
	compile_using_makepkg

	# switch package name back to cli specified package
	AUR_PACKAGE="${aur_package_cli}"

	# switch install flag back to cli specified value
	INSTALL_PACKAGE="${install_package_cli}"

}

function show_help() {
	cat <<ENDHELP
Description:
	# A simple bash script to build Arch AUR packages in the cloud
	${ourScriptName} ${ourScriptVersion} - Created by binhex.

Syntax:
	${ourScriptName} [args]

Where:
	-h or --help
		Displays this text.

	-ap or --aur-package <aur package name>
		Define the AUR package name(s) to build, comma-separated for multiple packages.
		No default.

	-uh or --use-makepkg
		Define whether to use makepkg to compile the package.
		Defaults to '${defaultUseMakepkg}'.

	-pp or --package-path <path>
		Define the path to store packages built.
		No default.

	-ip or --install-package
		Define whether to install the package after building (makepkg only).
		Defaults to '${defaultInstallPackage}'.

	--debug <yes|no>
		Define whether debug is turned on or not.
		Defaults to '${defaultDebug}'.

Examples:
	Build multiple AUR packages using makepkg:
		./${ourScriptName} --aur-package 'boost1.86,libtorrent-rasterbar-1_2-git' --use-makepkg

	Build and install single AUR packages using helper:
		./${ourScriptName} --aur-package 'libtorrent-rasterbar-1_2-git'

	Build and install single AUR packages using helper and copy built package to a specified package path:
		./${ourScriptName} --aur-package 'libtorrent-rasterbar-1_2-git' --use-helper --package-path '/cache'

Notes:
	Packages built using AUR helper will be located in '${defaultSnapshotPath}/<package name>/'
	unless specified via -pp or --package-path.

	makepkg will install AOR dependancies, but it will NOT install AUR dependancies, so ensure
	all AUR dependancies are installed first in the comma separated AUR package list.
ENDHELP
}

while [ "$#" != "0" ]
do
    case "$1"
    in
        -ap|--aur-package)
            AUR_PACKAGE=$2
            shift
            ;;
        -uh|--use-makepkg)
            USE_MAKEPKG=true
            ;;
        -pp|--package-path)
            PACKAGE_PATH=$2
            shift
            ;;
        -ip|--install-package)
            INSTALL_PACKAGE=true
            ;;
        --debug)
            DEBUG=$2
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

if [[ -z "${AUR_PACKAGE}" ]]; then
	echo "[warn] Package name(s) not defined via parameter -ap or --aur-package, displaying help..."
	echo ""
	show_help
	exit 1
fi

# display packages to be processed
echo "[info] Package(s) to process: ${AUR_PACKAGE}"
init

if [[ "${USE_MAKEPKG}" == "true" ]]; then
	echo "[info] '-uh|--use-makepkg' is defined, compiling using makepkg..."
	compile_using_makepkg
else
	echo "[info] '-uh|--use-makepkg' is not defined, compiling using helper..."
	install_helper
	compile_using_helper
fi
copy_compiled_packages
