#!/bin/bash

# exit script if return code != 0, note need it at this location as which
set -e

# define aur helper
aur_helper="yay"

function install_compiled_yay() {

	if ! which yay || true; then

		# install git, used to pull down aur helper from github
		pacman -S git sudo --noconfirm

		# different compression used for arm and amd
		if [[ "${TARGETARCH}" == "amd64" ]]; then
			yay_compression="zst"
		else
			yay_compression="xz"
		fi
		yay_package_name="yay.tar.${yay_compression}"

		# download compiled aur helper
		rcurl.sh -o "/tmp/${yay_package_name}" "https://github.com/binhex/packages/raw/master/compiled/${TARGETARCH}/${yay_package_name}"

		# install aur helper
		pacman -U "/tmp/${yay_package_name}" --noconfirm
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

function compile_yay() {

	# define build directory
	build_dir='/tmp/makepkg'

	# set build directory for makepkg
	sed -i -e "s~#BUILDDIR=/tmp/makepkg~BUILDDIR=${build_dir}~g" "/etc/makepkg.conf"

	# hack to fix up segmentation errors on arm when building packages using yay
	# see https://archlinuxarm.org/forum/viewtopic.php?f=57&t=16830
	# full line shown below
	#-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer"
	sed -i -e 's~-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer~~g' '/etc/makepkg.conf'

	# strip out restriction to not allow make as user root (docker build uses root)
	sed -i -e 's~exit $E_ROOT~~g' "/usr/bin/makepkg"

	# create build directory and then set permissions for /tmp recursively
	mkdir -p "${build_dir}"
	chmod -R 777 '/tmp'

	# different compression used for arm and amd
	if [[ "${TARGETARCH}" == "amd64" ]]; then
		yay_compression="zst"
	else
		yay_compression="xz"
	fi

	# download and install aur helper
	cd /tmp
	git clone https://aur.archlinux.org/yay-bin.git
	cd yay-bin
	makepkg -sri --noconfirm

}

function install_package_using_yay() {

	# prevent sudo prompt for password when installing compiled package via pacman
	echo 'nobody ALL = NOPASSWD: /usr/sbin/pacman' > /etc/sudoers.d/yay

	# check if prerun_cmd (run command before helper)
	if [[ -n "${aur_precmd}" ]]; then
		echo "[info] Pre-run command defined as '${aur_precmd}', executing..."
		eval "${aur_precmd}"
	fi

	# check if aur_options not specified then use common options
	if [[ -z "${aur_options}" ]]; then
		aur_options="--builddir=${build_dir} --mflags '--config /etc/makepkg.conf' --save --norebuild --needed --noconfirm"
		echo "[info] No AUR options defined via 'export aur_options=aur helper options' using the defaults '${aur_options}'"

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

function prereqs() {

	if command -v yay; then
		echo "[info] yay already installed, exiting script..."
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

}

# check we have aur packages to install
if [[ -n "${aur_packages}" ]]; then
	prereqs
	compile_yay
	install_package_using_yay
else
	echo "[info] No AUR packages defined via 'export aur_packages=<package name>'"
fi
