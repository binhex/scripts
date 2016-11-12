#!/bin/bash

# disable exit if return code != 0 (apacan can return exit code 1 due to minor errors)
set +e

# install aur helper from github and then install app using helper
if [[ ! -z "${aur_packages}" ]]; then
	curl -o "/tmp/${aur_helper}-any.pkg.tar.xz" -L "https://github.com/binhex/arch-packages/raw/master/compiled/${aur_helper}-any.pkg.tar.xz"
	pacman -U "/tmp/${aur_helper}-any.pkg.tar.xz" --noconfirm
	"${aur_helper}" -S ${aur_packages} --noconfirm
fi

# re-enable exit script if return code != 0
set -e

exit_code=$?

if (( ${exit_code} != 0 && ${exit_code} != 1 )); then
	echo "apacman returned exit code ${exit_code} (exit code 1 ignored), showing man for exit codes:-"
	cat << EOM
	0   Success
	1   Miscellaneous errors
	2   Invalid parameters
	3   Fatal errors, not warnings
	4   No package matches found
	5   Package does not exist
	6   No internet connection
	7   No free space in tmpfs
	8   One or more package(s) failed to build, keep going
	9   One package failed to build, do not continue
	10  Permission problem −− fakeroot
	11  Permission problem −− root user
	12  Permission problem −− sudo
	13  Permission problem −− su
EOM

	# set exit code to 1 to denote failure to build env
	exit 1
fi

# remove base devel excluding useful core packages
pacman -Ru $(pacman -Qgq base-devel | grep -v pacman | grep -v sed | grep -v grep | grep -v gzip) --noconfirm

# remove cached apacman packages
rm -rf /var/cache/apacman/
