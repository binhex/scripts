#!/bin/bash

# A simple bash script to build/install Arch AUR packages using makepkg or an AUR helper.

# script name and version
ourScriptName=$(basename -- "$0")
readonly ourScriptName
readonly ourScriptVersion="v1.0.0"

# setup default values
readonly defaultPackagePath='/tmp/makepkg'
readonly defaultUseMakepkg='false'
readonly defaultInstallPackage='false'

PACKAGE_PATH="${defaultPackagePath}"
USE_MAKEPKG="${defaultUseMakepkg}"
INSTALL_PACKAGE="${defaultInstallPackage}"

# path to the sudoers rule that lets user 'nobody' install packages without a password,
# overridable so tests do not write to the real /etc
SUDOERS_FILE="${SUDOERS_FILE:-/etc/sudoers.d/yay}"

# pacman/phases that mean the transaction can never succeed on a retry
readonly unresolvable_dependency_pattern='unable to satisfy dependency|target not found|failed to prepare transaction \((could not satisfy|conflicting) dependencies\)'

# escape sed replacement metacharacters so a package path containing ~ or & is written literally
function escape_sed_replacement() {

	printf '%s' "${1}" | sed 's/[\\&~]/\\&/g'

}

# fail loudly when a value-taking flag has no value, instead of silently leaving its
# variable empty (an empty AUR package list exits 0, so a build would carry on having
# installed nothing); a following flag is not a value either
function require_operand() {

	if [[ "$#" -lt 2 ]]; then
		echo "[warn] Parameter '${1}' requires a value, displaying help..." >&2
		echo ""
		show_help
		exit 1
	fi

	# a following flag is a missing value, but a dash-leading value (e.g. a sed
	# expression) is legitimate, so only the known flags are rejected
	case "${2}" in
		-aop|--aor-package|-ap|--aur-package|-uh|--use-makepkg|-pp|--package-path|-ip|--install-package|-pe|--pkgbuild-edit|-h|--help)
			echo "[warn] Parameter '${1}' requires a value, displaying help..." >&2
			echo ""
			show_help
			exit 1
			;;
	esac

}

# rewrite the makepkg output directories in the given makepkg.conf
function configure_makepkg_conf() {

	local conf="${1}"

	local key
	local suffix
	local value
	local sed_value
	for key in BUILDDIR PKGDEST SRCDEST SRCPKGDEST; do
		case "${key}" in
			BUILDDIR) suffix="build" ;;
			PKGDEST) suffix="pkgdest" ;;
			SRCDEST) suffix="srcdest" ;;
			SRCPKGDEST) suffix="srcpkgdest" ;;
		esac

		# the conf is sourced as shell by makepkg, so shell-quote the value; sed then
		# needs that quoted value escaped for its own metacharacters (\ & ~)
		value=$(printf '%q' "${PACKAGE_PATH}/${suffix}")
		sed_value=$(escape_sed_replacement "${value}")

		# match the key whether it is commented out or already set, so a change to the
		# shipped default cannot silently no-op; append it when the key is absent entirely
		if grep -qE "^#?${key}=" "${conf}"; then
			sed -i -e "s~^#\?${key}=.*~${key}=${sed_value}~" "${conf}"
		else
			# a conf whose last line has no trailing newline would glue the key onto it
			if [[ -n "$(tail -c1 -- "${conf}")" ]]; then
				printf '\n' >> "${conf}"
			fi
			printf '%s=%s\n' "${key}" "${value}" >> "${conf}"
		fi
	done

}

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

	# set the makepkg output directories
	configure_makepkg_conf "/etc/makepkg.conf"

	# strip out restriction to not allow make as user root (docker build uses root)
	# shellcheck disable=SC2016 # $E_ROOT is makepkg's own variable, not ours to expand
	sed -i -e 's~exit $E_ROOT~~g' '/usr/bin/makepkg'

	# disable building of debug packages, note '!\?debug' keeps this idempotent as
	# some distributions already ship '!debug', which would otherwise become '!!debug'
	sed -i '/^OPTIONS=/s/!\?debug\b/!debug/g' '/etc/makepkg.conf'

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
	local retries_remaining=6
	local retry_delay=10
	local attempt=1

	while [[ ${retries_remaining} -gt 0 ]]; do
		echo "[info] Attempting to compile package '${package}' using makepkg, (attempt ${attempt})..."

		# a failed attempt leaves the shell inside the extracted PKGBUILD directory,
		# which the next attempt deletes, so return to a stable directory first
		cd / || return 1

		# clean up any previous attempt
		local snapshots_path="${PACKAGE_PATH}/${package}/snapshots"
		rm -rf "${snapshots_path}"
		mkdir -p "${snapshots_path}"

		# download package snapshot
		local download_success=false
		if [[ "${package_type}" == "AOR" && -n "${primary_url}" ]]; then
			if stderr=$(git clone "${primary_url}" "${snapshots_path}" 2>&1); then
				download_success=true
			else
				echo "[warn] Failed to git clone from URL ${primary_url} for package ${package} from ${package_source_name}, error is '${stderr}'" >&2
			fi
		elif [[ "${package_type}" == "AUR" && -n "${primary_url}" ]]; then
			# note we override the default web browser fake user agent, otherwise bot detection occurs
			if stderr=$(rcurl.sh -o "${snapshots_path}/${package}.tar.gz" -L "${primary_url}" --user-agent 'curl' && tar -xvf "${snapshots_path}/${package}.tar.gz" -C "${snapshots_path}" 2>&1); then
				download_success=true
			else
				echo "[warn] Failed to download tarball for package '${package}' from ${package_source_name}, error is '${stderr}'" >&2
			fi
		fi

		# if download succeeded, try to compile
		if [[ "${download_success}" == "true" ]]; then
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
						cd / || true
						return 1
					else
						echo "[info] Successfully applied PKGBUILD edit for package '${package}'"
					fi
				fi

				# compile package if download and PKGBUILD edit were successful, the output
				# is teed to a log so a deterministic failure can be recognised and not retried
				local makepkg_status
				local makepkg_log="${PACKAGE_PATH}/${package}/makepkg.log"
				# shellcheck disable=SC2086
				makepkg --ignorearch --clean --syncdeps --rmdeps --noconfirm --skippgpcheck ${install_flag} 2>&1 | tee "${makepkg_log}"
				makepkg_status="${PIPESTATUS[0]}"

				if [[ "${makepkg_status}" -eq 0 ]]; then
					echo "[info] Successfully compiled package '${package}' on attempt ${attempt}"
					cd / || return 1
					return 0
				elif grep -Eq "${unresolvable_dependency_pattern}" "${makepkg_log}"; then
					# a dependency the pinned repositories cannot satisfy will not appear on a
					# retry, so report it and hand control back so the caller can try the next option
					echo "[error] Package '${package}' has unresolvable dependencies, retrying cannot help:" >&2
					grep -E "${unresolvable_dependency_pattern}" "${makepkg_log}" | sed 's/^/  /' >&2
					cd / || true
					return 1
				else
					echo "[warn] makepkg failed for package '${package}' on attempt ${attempt}"
				fi
			else
				echo "[warn] Cannot navigate to extracted path '${extracted_path}'"
			fi
		fi

		# if we get here, something failed (download or compilation)
		retries_remaining=$((retries_remaining - 1))
		attempt=$((attempt + 1))
		if [[ ${retries_remaining} -gt 0 ]]; then
			echo "[warn] Failed to compile package '${package}', ${retries_remaining} retries remaining, retrying in ${retry_delay} seconds..."
			sleep ${retry_delay}
		else
			echo "[error] Failed to compile package '${package}' after all retry attempts"
			cd / || true
			return 1
		fi
	done

}

function compile_using_helper() {

	local test_package="${1}"
	shift

	# prevent sudo prompt for password when installing compiled package via pacman
	echo 'nobody ALL = NOPASSWD: /usr/sbin/pacman' > "${SUDOERS_FILE}"

	# set ownership to user 'nobody' for makepkg build path - required as we are 'su'ing to user nobody (cannot run helper as root)
	chown -R nobody:users \
		"${PACKAGE_PATH}"

	# convert comma-separated list to space-separated for paru
	if [[ -n "${test_package}" ]]; then
		local package_list="${test_package}"
	else
		local package_list="${AUR_PACKAGE//,/ }"
	fi

	echo "[info] Processing package list: ${package_list}"
	# switch to user 'nobody' and run aur helper to compile and install package(s) with retries
	local retries_remaining=6
	local retry_delay=10
	local attempt=1

	while [[ ${retries_remaining} -gt 0 ]]; do
		echo "[info] Attempting to compile package '${package_list}' using helper, (attempt ${attempt})..."

		# the output is teed to a log so a deterministic failure can be recognised and not retried
		local helper_status
		local helper_log="${PACKAGE_PATH}/helper.log"
		# %q keeps a package path with spaces or quotes intact inside the su command string
		local quoted_builddir
		quoted_builddir=$(printf '%q' "${PACKAGE_PATH}/snapshots")
		su nobody -c "paru --sync --norebuild --needed --builddir=${quoted_builddir} --mflags '--config /etc/makepkg.conf --skippgpcheck' --noconfirm ${package_list}" 2>&1 | tee "${helper_log}"
		helper_status="${PIPESTATUS[0]}"

		if [[ "${helper_status}" -eq 0 ]]; then
			echo "[info] Successfully compiled and installed package(s) '${package_list}' on attempt ${attempt}"
			return 0
		elif grep -Eq "${unresolvable_dependency_pattern}" "${helper_log}"; then
			echo "[error] Package(s) '${package_list}' have unresolvable dependencies, retrying cannot help:" >&2
			grep -E "${unresolvable_dependency_pattern}" "${helper_log}" | sed 's/^/  /' >&2
			return 1
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

function verify_helper_installed() {

	if command -v paru >/dev/null 2>&1; then
		echo "[info] AUR helper paru is installed"
		return 0
	else
		echo "[warn] AUR helper paru is not installed"
		return 1
	fi
}

function verify_helper_working() {

	# use dummy package to excercise paru
	local test_package='texlive-dummy'

	if compile_using_helper "${test_package}"; then
		echo "[info] AUR helper paru is working"
		return 0
	else
		echo "[warn] AUR helper paru is not working"
		return 1
	fi
}

function install_helper_and_compile() {

	if verify_helper_installed; then
		if verify_helper_working; then
			if compile_using_helper; then
				return 0
			else
				return 1
			fi
		else
			# shellcheck disable=SC2046 # the package list must split into separate arguments
			pacman -Rns $(pacman -Qq | grep -E '^paru') --noconfirm 2>/dev/null || true
		fi
	fi

	local install_flag="--install"
	local helper_packages=('paru-bin' 'paru')

	# loop through helper packages to attempt installation
	for helper_package in "${helper_packages[@]}"; do

		echo "[info] Attempting to install AUR helper package '${helper_package}'..."
		compile_using_makepkg "${helper_package}" "AUR" "${install_flag}"

		# if paru already installed try to use it first
		if verify_helper_installed; then
			if verify_helper_working; then
				if compile_using_helper; then
					return 0
				else
					return 1
				fi
			else
				echo "[warn] Failed to install AUR helper package '${helper_package}', trying next helper if available..."
				# shellcheck disable=SC2046 # the package list must split into separate arguments
				pacman -Rns $(pacman -Qq | grep -E '^paru') --noconfirm 2>/dev/null || true
			fi
		fi
	done

	echo "[error] All AUR helper installation attempts failed"
	return 1

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

function parse_args() {
	while [ "$#" != "0" ]
	do
		case "$1"
		in
			-aop|--aor-package)
				require_operand "$@"
				AOR_PACKAGE=$2
				shift
				;;
			-ap|--aur-package)
				require_operand "$@"
				AUR_PACKAGE=$2
				shift
				;;
			-uh|--use-makepkg)
				USE_MAKEPKG=true
				;;
			-pp|--package-path)
				require_operand "$@"
				PACKAGE_PATH=$2
				shift
				;;
			-ip|--install-package)
				INSTALL_PACKAGE=true
				;;
			-pe|--pkgbuild-edit)
				require_operand "$@"
				PKGBUILD_EDIT=$2
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
}

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

	# an empty package path, or one that resolves to / (e.g. '/tmp/..'), would make
	# init() remove /build and friends and chown -R the whole filesystem
	if [[ -z "${PACKAGE_PATH}" ]] || [[ "$(realpath -m -- "${PACKAGE_PATH}" 2>/dev/null)" == "/" ]]; then
		echo "[warn] Package path defined via parameter --package-path is empty or resolves to the filesystem root, exiting script..." >&2
		exit 1
	fi

	# make a relative package path absolute, otherwise the cd to / inside the compile
	# loop would reinterpret it against the filesystem root
	if ! PACKAGE_PATH=$(realpath -m -- "${PACKAGE_PATH}"); then
		echo "[warn] Package path defined via parameter --package-path cannot be resolved, exiting script..." >&2
		exit 1
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
				if ! compile_using_makepkg "${package}" "AUR" "${install_flag}"; then
					echo "[error] Failed to compile AUR package '${package}', exiting script..."
					exit 1
				fi
			done
		else
			echo "[info] '--use-makepkg' is not defined, compiling AUR packages using helper..."
			if ! install_helper_and_compile; then
				echo "[error] Failed to compile AUR packages using helper, exiting script..."
				exit 1
			else
				echo "[info] Successfully compiled AUR packages using helper."
			fi
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
			if ! compile_using_makepkg "${package}" "AOR" "${install_flag}"; then
				echo "[error] Failed to compile AOR package '${package}', exiting script..."
				exit 1
			fi
		done
	fi

}

# allow sourcing for testing without running the script
if [[ -z "${AUR_TEST_MODE}" ]]; then
	parse_args "$@"
	main
fi
