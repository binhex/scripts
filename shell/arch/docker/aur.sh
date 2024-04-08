#!/bin/bash

# exit script if return code != 0, note need it at this location as which
set -e

# define aur helper, normally 'yay' or 'paru'
# note paru does not currently build on arm64 - 20240407
aur_helper="paru"

function install_binary_helper() {

	# download correct binary for arch
	if [[ "${TARGETARCH}" == "amd64" ]]; then
		github_asset_regex="paru.*x86_64.*"
	elif [[ "${TARGETARCH}" == "arm64" ]]; then
		github_asset_regex="paru.*aarch64.*"
	fi

	# download binary helper
	source utils.sh && download_github_release_asset --download-path '/tmp' --github-owner 'Morganamilo' --github-repo 'paru' --github-asset-regex "${github_asset_regex}"

	tar -xvf /tmp/paru*.tar* -C /tmp
	mv '/tmp/paru' '/usr/local/bin/' && chmod +x '/usr/local/bin/paru'
	paru
	ls -al /tmp

}

function install_precompiled_helper() {

	# ensure we have a clean environment
	cleanup

	if ! which "${aur_helper}" || true; then

		# install git, used to pull down aur helper from github
		pacman -S git sudo --noconfirm

		# different compression used for arm and amd
		if [[ "${TARGETARCH}" == "amd64" ]]; then
			compression="zst"
		else
			compression="xz"
		fi

		package_name="${aur_helper}.tar.${compression}"

		# download compiled aur helper
		rcurl.sh -o "/tmp/${package_name}" "https://github.com/binhex/packages/raw/master/compiled/${TARGETARCH}/${package_name}"

		# install aur helper
		pacman -U "/tmp/${package_name}" --noconfirm

	fi

	if [[ -d /home/nobody/.cache ]]; then
		# ensure we are owner for cache and config folders used by aur_helper
		chown -R nobody:users /home/nobody/.cache
	fi

	if [[ -d /home/nobody/.config ]]; then
		# ensure we are owner for cache and config folders used by aur_helper
		chown -R nobody:users /home/nobody/.config
	fi
}

function compile_and_install_helper() {

	# ensure we have a clean environment
	cleanup

	# set build directory for makepkg
	sed -i -e "s~#BUILDDIR=/tmp/makepkg~BUILDDIR=${build_dir}~g" "/etc/makepkg.conf"

	# strip out restriction to not allow make as user root (docker build uses root)
	sed -i -e 's~exit $E_ROOT~~g' "/usr/bin/makepkg"

	if [[ "${aur_helper}" == 'yay' ]]; then
		# download and install aur helper
		git clone https://aur.archlinux.org/yay-bin.git "${git_dir}"
	elif [[ "${aur_helper}" == 'paru' ]]; then
		# download and install aur helper
		git clone https://aur.archlinux.org/paru.git "${git_dir}"
	else
		echo "[warn] AUR helper '${aur_helper}' not supported, exiting script..."
		exit 1
	fi
	cd "${git_dir}"
	makepkg -sri --noconfirm
}

function install_package_using_helper() {

	# ensure we have a clean environment
	cleanup

	# prevent sudo prompt for password when installing compiled package via pacman
	echo 'nobody ALL = NOPASSWD: /usr/sbin/pacman' > /etc/sudoers.d/yay

	# check if prerun_cmd (run command before helper)
	if [[ -n "${aur_precmd}" ]]; then
		echo "[info] Pre-run command defined as '${aur_precmd}', executing..."
		eval "${aur_precmd}"
	fi

	# check if aur_options not specified then use common options
	# note --debug SEEMS (to be confirmed) to fix segmentation faults
	if [[ -z "${aur_options}" ]]; then

		if [[ "${aur_helper}" == 'yay' ]]; then
			aur_options="--builddir=${build_dir} --mflags '--config /etc/makepkg.conf' --save --norebuild --needed --noconfirm --debug"
			echo "[info] No AUR options defined via 'export aur_options=aur helper options' using the defaults '${aur_options}'"
		elif [[ "${aur_helper}" == 'paru' ]]; then
			aur_options="--builddir=${build_dir} --mflags '--config /etc/makepkg.conf' --norebuild --needed --noconfirm --debug"
			echo "[info] No AUR options defined via 'export aur_options=aur helper options' using the defaults '${aur_options}'"
		fi

	fi

	# if no aur operation defined then assume install package
	if [[ -z "${aur_operations}" ]]; then
		aur_operations="-S"
	fi

	# switch to user 'nobody' and run aur helper to compile package
	su nobody -c "cd /tmp && ${aur_helper} ${aur_operations} ${aur_packages} ${aur_options}"

	# if custom script defined then run
	if [[ -n "${aur_custom_script}" ]]; then
		eval "${aur_custom_script}"
	fi

}

function init() {

	if command -v "${aur_helper}"; then
		echo "[info] AUR helper already installed, exiting script..."
		exit 0
	fi

	# install required packages to compile
	pacman -S base-devel binutils git --needed --noconfirm

	# if we do not have arg TARGETARCH' from Dockerfile (calling this script directly) then work out the arch
	if [[ -z "${TARGETARCH}" ]]; then

		uname=$(uname -m)
		if [[ -z "${uname}" ]]; then
			echo "[warn] Unable to identify architecture, exiting script..."
			exit 1
		elif [[ "${uname}" == "x86_64" ]]; then
			TARGETARCH="amd64"
		elif [[ "${uname}" == "aarch64" ]]; then
			TARGETARCH="arm64"
		else
			echo "[warn] No support for architecture '${uname}', exiting script..."
		fi

	fi

	# define paths for build and clone
	build_dir='/tmp/makepkg'
	git_dir='/tmp/helper'

	# create build and clone paths and then set permissions for /tmp recursively
	mkdir -p "${build_dir}"
	mkdir -p "${git_dir}"
	chmod -R 777 '/tmp'

}

function cleanup() {
	rm -rf "${build_dir:?}"/*
	rm -rf "${git_dir:?}"/*
}

# check we have aur packages to install
if [[ -n "${aur_packages}" ]]; then
	init
	#compile_and_install_helper
	#install_precompiled_helper
	install_binary_helper
	install_package_using_helper
else
	echo "[info] No AUR packages defined via 'export aur_packages=<package name>'"
fi
