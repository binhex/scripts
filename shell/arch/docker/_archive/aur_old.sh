#!/bin/bash

# define aur helper and ver
aur_helper="apacman"

# install aur helper from github and then install app using helper
if [[ ! -z "${aur_packages}" ]]; then

	pacman -S jshon base-devel --needed --noconfirm

	# remove existing aur helper if it exists to prevent curl 416 error
	rm -f "/tmp/${aur_helper}-any.pkg.tar.xz"

	curly.sh -of "/tmp/${aur_helper}-any.pkg.tar.xz" -url "https://github.com/binhex/arch-packages/raw/master/compiled/${OS_ARCH}/${aur_helper}.tar.xz"
	pacman -U "/tmp/${aur_helper}-any.pkg.tar.xz" --noconfirm

	# unset failing build on non zero exit code (required as apacman can have exit code of 1 if systemd ref in install)
	set +e

	# check aur helper is functional and then use
	"${aur_helper}" -V
	helper_check_exit_code=$?

	# reset flag to force failed build on non zero exit code
	set -e

	if (( ${helper_check_exit_code} != 0 )); then
		echo "${aur_helper} check returned exit code ${helper_check_exit_code}, exiting script..."
		return 1
	fi

	# if not defined then assume install package
	if [[ -z "${aur_operations}" ]]; then
		aur_operations="-S"
	fi

	# if not defined then assume no prompts for compile or install
	if [[ -z "${aur_options}" ]]; then
		aur_options="--noconfirm"
	fi

	# change to /tmp prior to compile and install
	cd /tmp

	eval "${aur_helper} ${aur_operations} ${aur_options} ${aur_packages}"

	helper_package_exit_code=$?

	if (( ${helper_package_exit_code} != 0 && ${helper_package_exit_code} != 1 )); then

		echo "${aur_helper} returned exit code ${helper_package_exit_code} (exit code 1 ignored), showing man for exit codes:-"
		echo "0   Success"
		echo "1   Miscellaneous errors"
		echo "2   Invalid parameters"
		echo "3   Fatal errors, not warnings"
		echo "4   No package matches found"
		echo "5   Package does not exist"
		echo "6   No internet connection"
		echo "7   No free space in tmpfs"
		echo "8   One or more package(s) failed to build, keep going"
		echo "9   One package failed to build, do not continue"
		echo "10  Permission problem −− fakeroot"
		echo "11  Permission problem −− root user"
		echo "12  Permission problem −− sudo"
		echo "13  Permission problem −− su"

		# set return code to 1 to denote failure to build env
		return 1
	fi

	# if custom script defined then run
	if [[ -n "${aur_custom_script}" ]]; then
		eval "${aur_custom_script}"
	fi

	# remove cached aur packages
	rm -rf "/var/cache/${aur_helper}/" || true

else

	return 0

fi
