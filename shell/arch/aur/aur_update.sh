#!/bin/bash

# install ssh client
pacman -S openssh --noconfirm

# generate keypair
# mkdir -p ~/.ssh && ssh-keygen -f ~/.ssh/aur

# copy aur private key
mkdir -p ~/.ssh && cp "/user/Software/Configs/SSH Keys/aur/"aur* ~/.ssh/

# lock down permissions (required)
chmod -R 600 ~/.ssh/

# copy public key to profile in "My Account" on web ui for aur

# create config file for ssh client
echo "Host aur.archlinux.org" > ~/.ssh/config
echo "  IdentityFile ~/.ssh/aur" >> ~/.ssh/config
echo "  User binhex" >> ~/.ssh/config

# download package using git (read only)
package_name="libreoffice-fresh-rpm"
cd /tmp && git clone "ssh://aur@aur.archlinux.org/${package_name}.git"

cd "/tmp/${package_name}"

# make changes - add pkg version, update checksums, and update changelog in PKGBUILD

# set permissions for user nobody to allow for changes to SRCINFO
chmod 777 .

# generate SRCINFO based off PKGBUILD
su nobody -c "makepkg --printsrcinfo > .SRCINFO"

# set credentials
git config --global user.email "megalith01@gmail.com"
git config --global user.name "binhex"

# add changed file, comment and push
git add PKGBUILD .SRCINFO
git commit -m "updated to 6.1.2"
# git push