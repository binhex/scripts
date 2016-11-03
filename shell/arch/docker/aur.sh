#!/bin/bash

# exit script if return code != 0
set -e

# install aur helper from github and then install app using helper
if [[ ! -z "${aur_packages}" ]]; then
	curl -o "/tmp/${aur_helper}-any.pkg.tar.xz" -L "https://github.com/binhex/arch-packages/raw/master/compiled/${aur_helper}-any.pkg.tar.xz"
	pacman -U "/tmp/${aur_helper}-any.pkg.tar.xz" --noconfirm
	"${aur_helper}" -S "${aur_packages}" --noconfirm || true
fi

# remove base devel excluding useful core packages
pacman -Ru $(pacman -Qgq base-devel | grep -v pacman | grep -v sed | grep -v grep | grep -v gzip) --noconfirm
