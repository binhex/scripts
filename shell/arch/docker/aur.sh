#!/bin/bash

# exit script if return code != 0
set -e

# manually download aur helper from binhex repo
curl -o "/tmp/${aur_helper}-any.pkg.tar.xz" -L "https://github.com/binhex/arch-packages/raw/master/compiled/${aur_helper}-any.pkg.tar.xz"
pacman -U "/tmp/${aur_helper}-any.pkg.tar.xz" --noconfirm

# install app using aur helper (as root)
if [[ ! -z "${aur_packages}" ]]; then
	"${aur_helper}" -S "${aur_packages}" --noconfirm || true
	"${aur_helper}" --gendb
fi

# remove base devel excluding useful core packages
pacman -Ru $(pacman -Qgq base-devel | grep -v pacman | grep -v sed | grep -v grep | grep -v gzip) --noconfirm
