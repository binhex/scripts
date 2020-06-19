#!/bin/bash

# exit script if return code != 0
set -e

function compile_tarball {

	aur_package="${1}"

	# download tarball from aur
	/usr/local/bin/curly.sh -of "/tmp/${aur_package}.tar.gz" -url "https://aur.archlinux.org/cgit/aur.git/snapshot/${aur_package}.tar.gz"

	# extract downloaded tarball
	cd '/tmp' && tar -xvf "${aur_package}.tar.gz"

	# change to location of extracted tarball
	cd "./${aur_package}"

	# compile/build package
	eval "${makepkg_path} ${makepkg_options}"

	# install package using pacman
	pacman -U ${aur_package}*.tar.xz --noconfirm

}

function determine_dependencies {

	aur_package="${1}"

	# determine aur dependencies minus optional packages
	aur_package_dependencies=$(curl -s "https://aur.archlinux.org/packages/${aur_package}/" | awk '/"pkgdepslist"/,/<\/ul>/' | grep -Po '\"/packages.*' | grep -v '.*optional.*' | grep -Po '"/packages.*?"' | grep -Po '[^/]+/"$' | grep -Po '[^/"]+' | xargs)

}

# path to makepkg (shell script)
makepkg_path="/usr/bin/makepkg"

# check we have packages to install
if [[ ! -z "${aur_packages}" ]]; then

	# check if build options not specified then use common options
	if [[ -z "${makepkg_options}" ]]; then
		makepkg_options="--install --noconfirm --syncdeps"
	fi

	# install required packages to compile
	pacman -S base-devel --needed --noconfirm

	# strip out restriction to not allow make as user root
	sed -i -e 's~exit $E_ROOT~~g' "${makepkg_path}"

	# split space separated string of packages into list
	IFS=' ' read -ra aur_packages_list <<< "${aur_packages}"

	# process each package in the list
	for aur_package in "${aur_packages_list[@]}"; do

		# determine aur dependencies minus optional packages
		determine_dependencies "${aur_package}"

		if [[ ! -z "${aur_package_dependencies}" ]]; then

			# compile and install aur package dependencies
			compile_tarball "${aur_package_dependencies}"

			# compile and install aur package
			compile_tarball "${aur_package}"

		fi

	done

fi
