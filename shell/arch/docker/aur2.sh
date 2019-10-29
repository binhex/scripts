#!/bin/bash

# exit script if return code != 0
set -e

# path to makepkg
makepkg_path="/usr/bin/makepkg"

# check we have packages to install
if [[ ! -z "${aur_packages}" ]]; then

	# install required packages to compile
	pacman -S base-devel --needed --noconfirm

	# strip out restriction to not allow make as user root
	sed -i -e 's~exit $E_ROOT~~g' "${makepkg_path}"

	# split space separated string of packages into list
	IFS=' ' read -ra aur_packages_list <<< "${aur_packages}"

	# process each package in the list
	for aur_package in "${aur_packages_list[@]}"; do

		# download tarball from aur
		/usr/local/bin/curly.sh -rc 6 -rw 10 -of "/tmp/${aur_package}.tar.gz" -url "https://aur.archlinux.org/cgit/aur.git/snapshot/${aur_package}.tar.gz"

		# extract tarball
		tar -xvf "/tmp/${aur_package}.tar.gz"

		# location of downloaded and extracted tarball from aur (using aur.sh script)
		cd "/tmp/${aur_package}"

		# compile package
		eval "${makepkg_path} ${makepkg_options}"

		# install compiled package using pacman
		pacman -U ${aur_package}*.tar.xz --noconfirm

	done

	# remove base devel excluding useful core packages
	#pacman -Ru $(pacman -Qgq base-devel | grep -v awk | grep -v pacman | grep -v sed | grep -v grep | grep -v gzip | grep -v which) --noconfirm

fi