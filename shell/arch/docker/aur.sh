#!/bin/bash

# define aur helper
aur_helper="yay"

# check we have aur packages to install
if [[ ! -z "${aur_packages}" ]]; then

	# install required packages to compile
	pacman -S base-devel --needed --noconfirm

	# set build directory, used for output for makepkg
	sed -i -e 's~#BUILDDIR=/tmp/makepkg~BUILDDIR=/tmp/makepkg~g' "/etc/makepkg.conf"

	# set permissions for /tmp, used to store build and compiled
	# packages
	chmod -R 777 '/tmp'

	if ! which yay; then

		# exit script if return code != 0, note need it at this location as which
		# yay may return non zero exit code
		set -e

		# install git, used to pull down aur helper from github
		pacman -S git sudo --noconfirm

		aur_helper_package_name="yay-bin.tar.xz"

		# download compiled aur helper
		rcurl.sh -o "/tmp/${aur_helper_package_name}" "https://github.com/binhex/arch-packages/raw/master/compiled/${OS_ARCH}/${aur_helper_package_name}"

		# install aur helper
		pacman -U "/tmp/${aur_helper_package_name}" --noconfirm

		# compile and install aur helper
		# strip out restriction to not allow make as user root, used during make of aur helper
		#sed -i -e 's~exit $E_ROOT~~g' "/usr/bin/makepkg"
		# download and install aur helper
		#cd /tmp
		#git clone https://aur.archlinux.org/yay-bin.git
		#cd yay-bin
		#makepkg -sri --noconfirm
		#cd /tmp

	fi

	if [[ -d /home/nobody/.cache ]]; then
		# ensure we are owner for cache and config folders used by aur_helper
		chown -R nobody:users /home/nobody/.cache
	fi

	if [[ -d /home/nobody/.config ]]; then
		# ensure we are owner for cache and config folders used by aur_helper
		chown -R nobody:users /home/nobody/.config
	fi

	# prevent sudo prompt for password when installing compiled
	# package via pacman
	echo 'nobody ALL = NOPASSWD: /usr/sbin/pacman' > /etc/sudoers.d/yay

	# check if aur_options not specified then use common options
	if [[ -z "${aur_options}" ]]; then
		aur_options="--builddir=/tmp/makepkg --mflags '--config /etc/makepkg.conf' --save --noconfirm"
		echo "[info] No AUR options defined via 'export aur_options=<aur helper options>' using the defaults '${aur_options}'"

	fi

	# if not defined then assume install package
	if [[ -z "${aur_operations}" ]]; then
		aur_operations="-S"
	fi

	# switch to user 'nobody' and run aur helper to compile package
	su nobody -c "cd /tmp && ${aur_helper} ${aur_operations} ${aur_packages} ${aur_options}"
	
	# if custom script defined then run
	if [[ -n "${aur_custom_script}" ]]; then
		eval "${aur_custom_script}"
	fi

else

	echo "[info] No AUR packages defined via 'export aur_packages=<package name>'"

fi
