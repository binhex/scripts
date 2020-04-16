#!/bin/bash

# define aur helper
aur_helper="yay"

# check we have aur packages to install
if [[ ! -z "${aur_packages}" ]]; then

	# install required packages to compile
	pacman -S base-devel --needed --noconfirm

	if ! which yay; then

		# exit script if return code != 0, note need it at this location as which
		# yay may return non zero exit code
		set -e

		# install git, used to pull down aur helper from github
		pacman -S git sudo --noconfirm

		# strip out restriction to not allow make as user root, used during make of aur helper
		sed -i -e 's~exit $E_ROOT~~g' "/usr/bin/makepkg"

		# download and install aur helper
		cd /tmp
		git clone https://aur.archlinux.org/yay-bin.git
		cd yay-bin
		makepkg -sri --noconfirm
		cd ..
		rm -fr /tmp/yay-bin

	fi

	# set permissions for /tmp, used to store build and compiled
	# packages
	chmod -R 777 '/tmp'

	# prevent sudo prompt for password when installing compiled
	# package via pacman
	echo 'nobody ALL = NOPASSWD: /usr/sbin/pacman' > /etc/sudoers.d/yay

	# check if aur_options not specified then use common options
	if [[ -z "${aur_options}" ]]; then
		aur_options="--builddir=/tmp --save --noconfirm"
	fi

	# if not defined then assume install package
	if [[ -z "${aur_operations}" ]]; then
		aur_operations="-S"
	fi

	# switch to user 'nobody' and run aur helper to compile package, 'pacman' will
	# also be called after compile via aur helper to install the package
	su nobody -c "export XDG_CONFIG_HOME=/tmp && ${aur_helper} ${aur_operations} ${aur_packages} ${aur_options}"

	# remove base devel excluding useful core packages
	pacman -Ru $(pacman -Qgq base-devel | grep -v awk | grep -v pacman | grep -v sed | grep -v grep | grep -v gzip | grep -v which) --noconfirm

	# remove cached aur packages
	rm -rf "/var/cache/${aur_helper}/" || true

	# remove aur helper
	pacman -Ru yay-bin --noconfirm

else

	echo "[info] No AUR packages defined for installation"

fi
