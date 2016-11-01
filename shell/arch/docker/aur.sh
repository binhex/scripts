#!/bin/bash

# exit script if return code != 0
set -e

# create "makepkg-user" user for makepkg
useradd -m -s /bin/bash makepkg-user
echo -e "makepkg-password\nmakepkg-password" | passwd makepkg-user

# prevent prompt for password when running makepkg
echo "makepkg-user ALL=(ALL) NOPASSWD: ALL" | (EDITOR="tee -a" visudo)

# download aur helper tarball
curl -L -o "/home/makepkg-user/${aur_helper}.tar.gz" "https://aur.archlinux.org/cgit/aur.git/snapshot/${aur_helper}.tar.gz"
cd /home/makepkg-user
su -c "tar -xvf ${aur_helper}.tar.gz" - makepkg-user

# compile aur helper using makepkg (as non root)
su -c "cd /home/makepkg-user/${aur_helper} && makepkg -s --noconfirm --needed" - makepkg-user

# install compiled package using pacman (as root)
pacman -U /home/makepkg-user/${aur_helper}/${aur_helper}*.pkg.tar.xz --noconfirm

# install app using aur helper (as root)
"${aur_helper}" -S "${aur_packages}" --noconfirm || true

# remove base devel excluding useful core packages
pacman -Ru $(pacman -Qgq base-devel | grep -v pacman | grep -v sed | grep -v grep | grep -v gzip) --noconfirm

# remove git
pacman -Ru git --noconfirm

# remove makepkg-user account
userdel -r makepkg-user