#!/bin/bash

# A simple bash script to build/install Arch AUR packages using makepkg or an AUR helper.
set -x
# script name and version
readonly ourScriptName=$(basename -- "$0")
readonly ourScriptVersion="v1.0.0"

# setup default values
readonly defaultDebug='info'
readonly defaultPackagePath='/tmp/makepkg'
readonly defaultUseMakepkg='false'
readonly defaultInstallPackage='false'

DEBUG="${defaultDebug}"
PACKAGE_PATH="${defaultPackagePath}"
USE_MAKEPKG="${defaultUseMakepkg}"
INSTALL_PACKAGE="${defaultInstallPackage}"

function init() {

	rm -rf \
		"${PACKAGE_PATH}/build" \
		"${PACKAGE_PATH}/pkgdest" \
		"${PACKAGE_PATH}/srcdest" \
		"${PACKAGE_PATH}/srcpkgdest" \
		"${PACKAGE_PATH}/snapshots"

	mkdir -p \
		"${PACKAGE_PATH}" \
		"${PACKAGE_PATH}/build" \
		"${PACKAGE_PATH}/pkgdest" \
		"${PACKAGE_PATH}/srcdest" \
		"${PACKAGE_PATH}/srcpkgdest" \
		"${PACKAGE_PATH}/snapshots"

	# set build directory for makepkg
	sed -i -e "s~#BUILDDIR=/tmp/makepkg~BUILDDIR=${PACKAGE_PATH}/build~g" "/etc/makepkg.conf"

	# set pkgdest directory for makepkg
	sed -i -e "s~#PKGDEST=/tmp/makepkg~PKGDEST=${PACKAGE_PATH}/pkgdest~g" "/etc/makepkg.conf"

	# set srcdest directory for makepkg
	sed -i -e "s~#SRCDEST=/tmp/makepkg~SRCDEST=${PACKAGE_PATH}/srcdest~g" "/etc/makepkg.conf"

	# set srcpkgdest directory for makepkg
	sed -i -e "s~#SRCPKGDEST=/tmp/makepkg~SRCPKGDEST=${PACKAGE_PATH}/srcpkgdest~g" "/etc/makepkg.conf"

	# strip out restriction to not allow make as user root (docker build uses root)
	sed -i -e 's~exit $E_ROOT~~g' '/usr/bin/makepkg'

	# disable building of debug packages
	sed -i '/^OPTIONS=/s/\bdebug\b/!debug/g' '/etc/makepkg.conf'

	# perform database refresh and update (require for arm as this is not pinned to archive)
	pacman -Syu --noconfirm

	# install required packages to compile
	pacman -S base-devel binutils git sudo --needed --noconfirm

}

function compile_using_makepkg() {

	local package="${1}"
	shift
	local package_type="${1}"
	shift
	local install_flag="${1}"
	shift

	# trim whitespace
	package=$(echo "${package}" | xargs)
	echo "[info] Processing ${package_type} package '${package}'..."

	# set URLs based on package type
	local primary_url
	local package_source_name
	if [[ "${package_type}" == "AOR" ]]; then
		primary_url="https://gitlab.archlinux.org/archlinux/packaging/packages/${package}.git"
		package_source_name="Arch Official Repository (AOR)"
	elif [[ "${package_type}" == "AUR" ]]; then
		primary_url="https://aur.archlinux.org/cgit/aur.git/snapshot/${package}.tar.gz"
		package_source_name="Arch User Repository (AUR)"
	fi

	# download, extract and compile package with retries
	local retries_remaining=12
	local retry_delay=10
	local attempt=1

	while [[ ${retries_remaining} -gt 0 ]]; do
		echo "[info] Attempting to compile package '${package}' using makepkg, (attempt ${attempt})..."

		# clean up any previous attempt
		local snapshots_path="${PACKAGE_PATH}/${package}/snapshots"
		rm -rf "${snapshots_path}"
		mkdir -p "${snapshots_path}"

		# download package snapshot
		if [[ "${package_type}" == "AOR" && -n "${primary_url}" ]]; then
			if stderr=$(git clone "${primary_url}" "${snapshots_path}" 2>&1); then
				break
			else
				echo "[warn] Failed to git clone from URL ${primary_url} for package ${package} from ${package_source_name}, error is '${stderr}'" >&2
			fi
		elif [[ "${package_type}" == "AUR" && -n "${primary_url}" ]]; then
			# note we override the default web browser fake user agent, otherwise bot detection occurs
			if stderr=$(rcurl.sh -o "${snapshots_path}/${package}.tar.gz" -L "${primary_url}" --user-agent 'curl' && tar -xvf "${snapshots_path}/${package}.tar.gz" -C "${snapshots_path}" 2>&1); then
				break
			else
				echo "[warn] Failed to download tarball for package '${package}' from ${package_source_name}, error is '${stderr}'" >&2
			fi
		fi

		# if we get here, something failed
		retries_remaining=$((retries_remaining - 1))
		attempt=$((attempt + 1))
		if [[ ${retries_remaining} -gt 0 ]]; then
			echo "[warn] Failed to download tarball for package '${package}', ${retries_remaining} retries remaining, retrying in ${retry_delay} seconds..."
			sleep ${retry_delay}
		else
			echo "[error] Failed to download tarball for package '${package}' after all retry attempts, displaying incomplete download and then exiting script..."
			cat "${snapshots_path}/${package}.tar.gz"
			exit 1
		fi
	done

	# navigate to extracted PKGBUILD
	if [[ "${package_type}" == "AOR" ]]; then
		extracted_path="${snapshots_path}"
	elif [[ "${package_type}" == "AUR" ]]; then
		extracted_path="${snapshots_path}/${package}"
	fi

	if cd "${extracted_path}"; then
		# edit PKGBUILD if command is specified
		if [[ -n "${PKGBUILD_EDIT}" ]]; then
			echo "[info] Applying PKGBUILD edit command for package '${package}': ${PKGBUILD_EDIT}"
			if ! eval "${PKGBUILD_EDIT}"; then
				echo "[warn] Failed to apply PKGBUILD edit command '${PKGBUILD_EDIT}' for package '${package}'" >&2
				exit 1
			else
				echo "[info] Successfully applied PKGBUILD edit for package '${package}'"
			fi
		fi

		# compile package if download and PKGBUILD edit were successful
		if makepkg --ignorearch --clean --syncdeps --rmdeps --noconfirm --skippgpcheck ${install_flag}; then
			echo "[info] Successfully compiled package '${package}' on attempt ${attempt}"
		else
			echo "[warn] makepkg failed for package '${package}'"
			exit 1
		fi
	else
		echo "[warn] Cannot navigate to extracted path '${extracted_path}'"
		exit 1
	fi

}

function compile_using_helper() {

	# prevent sudo prompt for password when installing compiled package via pacman
	echo 'nobody ALL = NOPASSWD: /usr/sbin/pacman' > /etc/sudoers.d/yay

	# set ownership to user 'nobody' for makepkg build path - required as we are 'su'ing to user nobody (cannot run helper as root)
	chown -R nobody:users \
		"${PACKAGE_PATH}"

	# convert comma-separated list to space-separated for paru
	local package_list="${AUR_PACKAGE//,/ }"
	echo "[info] Processing package list: ${package_list}"

	# switch to user 'nobody' and run aur helper to compile and install package(s) with retries
	local retries_remaining=12
	local retry_delay=10
	local attempt=1

	while [[ ${retries_remaining} -gt 0 ]]; do
		echo "[info] Attempting to compile package '${package_list}' using helper, (attempt ${attempt})..."

		if su nobody -c "paru --sync --norebuild --needed --builddir=${PACKAGE_PATH}/snapshots --mflags '--config /etc/makepkg.conf --skippgpcheck' --noconfirm ${package_list}"; then
			echo "[info] Successfully compiled and installed package(s) '${package_list}' on attempt ${attempt}"
			return 0
		else
			retries_remaining=$((retries_remaining - 1))
			attempt=$((attempt + 1))
			if [[ ${retries_remaining} -gt 0 ]]; then
				echo "[warn] Failed to compile package(s) '${package_list}', ${retries_remaining} retries remaining, retrying in ${retry_delay} seconds..."
				sleep ${retry_delay}
			else
				echo "[error] Failed to compile package(s) '${package_list}' after all retry attempts"
				return 1
			fi
		fi
	done

}

function process_package() {

	local install_flag=""
	local package

	# set install flag if required
	if [[ "${INSTALL_PACKAGE}" == "true" ]]; then
		install_flag='--install'
	fi

	# process AUR packages if defined
	if [[ -n "${AUR_PACKAGE}" ]]; then
		echo "[info] Processing AUR packages..."
		# convert comma-separated list to array
		IFS=',' read -ra AUR_PACKAGE_ARRAY <<< "${AUR_PACKAGE}"

		# loop through each AUR package
		for package in "${AUR_PACKAGE_ARRAY[@]}"; do
			compile_using_makepkg "${package}" "AUR" "${install_flag}"
		done
	fi

	# process AOR packages if defined
	if [[ -n "${AOR_PACKAGE}" ]]; then
		echo "[info] Processing AOR packages..."
		# convert comma-separated list to array
		IFS=',' read -ra AOR_PACKAGE_ARRAY <<< "${AOR_PACKAGE}"

		# loop through each AOR package
		for package in "${AOR_PACKAGE_ARRAY[@]}"; do
			compile_using_makepkg "${package}" "AOR" "${install_flag}"
		done
	fi

}

function install_helper() {

	local install_flag="--install"
	local helper_packages=('paru-bin' 'paru')

	# try each package in order until one succeeds
	for helper_package in "${helper_packages[@]}"; do
		echo "[info] Attempting to install AUR helper package '${helper_package}'..."
		compile_using_makepkg "${helper_package}" "AUR" "${install_flag}"

		if compile_using_helper; then
			return 0
		else
			echo "[warn] Failed to install AUR helper package '${helper_package}', trying next helper if available..."
			pacman -R "${helper_package}" --noconfirm
		fi
	done

	echo "[error] All AUR helper installation attempts failed, exiting script..."
	exit 1

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

	-aop or --aor-package <aor package name>
		Define the AOR package name(s) to build, comma-separated for multiple packages.
		No default.

	-ap or --aur-package <aur package name>
		Define the AUR package name(s) to build, comma-separated for multiple packages.
		No default.

	-uh or --use-makepkg
		Define whether to use makepkg to compile the package.
		Defaults to '${defaultUseMakepkg}'.

	-pp or --package-path <path>
		Define the path to store packages built.
		Defaults to '${defaultPackagePath}'.

	-ip or --install-package
		Define whether to install the package after building (makepkg only).
		Defaults to '${defaultInstallPackage}'.

	-pe or --pkgbuild-edit <command>
		Define a command to edit the PKGBUILD file before compilation.
		Example: "sed -r -i -e 's~-march=native\s?~~g' 'PKGBUILD'"
		No default.

	--debug <yes|no>
		Define whether debug is turned on or not.
		Defaults to '${defaultDebug}'.

Examples:
	Build a single AOR package using makepkg and multiple AUR packages using helper and output packages to /cache:
		./${ourScriptName} --aor-package 'qbittorrent' --aur-package 'boost1.86,libtorrent-rasterbar-1_2-git' --package-path '/cache'

	Build a single AOR package using makepkg and multiple AUR packages using makepkg:
		./${ourScriptName} --aor-package 'qbittorrent' --aur-package 'boost1.86,libtorrent-rasterbar-1_2-git' --use-makepkg

	Build and install single AUR packages using helper:
		./${ourScriptName} --aur-package 'libtorrent-rasterbar-1_2-git'

	Build AUR package with PKGBUILD modification to remove native architecture flags:
		./${ourScriptName} --aur-package 'some-package' --pkgbuild-edit "sed -r -i -e 's~-march=native\s?~~g' 'PKGBUILD'"

Notes:
	makepkg will install AOR dependancies, but it will NOT install AUR dependancies (unlike a helper), so ensure
	all AUR dependancies are installed first in the comma separated AUR package list.

	Due to issues getting hold of the tarball snapshots for ARM64 AOR packages, we are currently using the AMD64
	tarball snapshot and ignoring the architecture specified in the PKGBUILD file, this SEEMS to work but may not
	work for all applications.
ENDHELP
}

while [ "$#" != "0" ]
do
    case "$1"
    in
        -aop|--aor-package)
            AOR_PACKAGE=$2
            shift
            ;;
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
        -pe|--pkgbuild-edit)
            PKGBUILD_EDIT=$2
            shift
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

function main() {

	local install_flag

	echo "[info] Running ${ourScriptName} script..."
	echo "[info] Checking we have all required parameters before running..."

	# check if package parameter is not defined (unset)
	if [[ -z "${AUR_PACKAGE+unset}"  && -z "${AOR_PACKAGE+unset}" ]]; then
		echo "[warn] Package name(s) not defined via parameter --aur-package and/or via parameter --aor-package, displaying help..."
		echo ""
		show_help
		exit 1
	fi

	# check if package parameter is defined but has a value of an empty string
	if [[ "${AUR_PACKAGE}" == ''  && "${AOR_PACKAGE}" == '' ]]; then
		echo "[info] Package name(s) is an empty string defined via parameter --aur-package and/or via parameter --aor-package, exiting script"
		exit 0
	fi

	# display packages to be processed
	if [[ -n "${AOR_PACKAGE}" ]]; then
		echo "[info] AOR Package(s) to process: ${AOR_PACKAGE}"
	fi
	if [[ -n "${AUR_PACKAGE}" ]]; then
		echo "[info] AUR Package(s) to process: ${AUR_PACKAGE}"
	fi

	# create paths, remove restrictions and install required tooling
	init

	# Handle AUR packages based on --use-makepkg flag
	if [[ -n "${AUR_PACKAGE}" ]]; then
		if [[ "${USE_MAKEPKG}" == "true" ]]; then
			echo "[info] '--use-makepkg' is defined, compiling AUR packages using makepkg..."
			# Process only AUR packages using makepkg
			echo "[info] Processing AUR packages..."
			# convert comma-separated list to array
			IFS=',' read -ra AUR_PACKAGE_ARRAY <<< "${AUR_PACKAGE}"

			# set install flag for mkepkg if requested
			install_flag=""
			if [[ "${INSTALL_PACKAGE}" == "true" ]]; then
				install_flag='--install'
			fi

			# loop through each AUR package
			for package in "${AUR_PACKAGE_ARRAY[@]}"; do
				compile_using_makepkg "${package}" "AUR" "${install_flag}"
			done
		else
			echo "[info] '--use-makepkg' is not defined, compiling AUR packages using helper..."
			install_helper
			compile_using_helper
		fi
	fi

	# AOR packages always use makepkg, AUR packages use makepkg only if --use-makepkg is specified
	if [[ -n "${AOR_PACKAGE}" ]]; then
		echo "[info] AOR packages defined, compiling AOR packages using makepkg..."
		# Process only AOR packages using makepkg
		echo "[info] Processing AOR packages..."
		# convert comma-separated list to array
		IFS=',' read -ra AOR_PACKAGE_ARRAY <<< "${AOR_PACKAGE}"

		# set install flag for mkepkg if requested
		install_flag=""
		if [[ "${INSTALL_PACKAGE}" == "true" ]]; then
			install_flag='--install'
		fi

		# loop through each AOR package
		for package in "${AOR_PACKAGE_ARRAY[@]}"; do
			compile_using_makepkg "${package}" "AOR" "${install_flag}"
		done
	fi

}

main
