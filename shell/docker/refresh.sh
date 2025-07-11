#!/bin/bash

# script to refresh the scripts repository
# this script is run by the dockerfile to ensure the scripts repository is up to date

set -e

scripts_dest_path="/usr/local/bin"

# ensure git cli is installed
pacman -S git --noconfirm

# silence warning aobut permissions
git config --global --add safe.directory "${scripts_dest_path}"

# if scripts path is not a git repository then clone
if git -C "${scripts_dest_path}" rev-parse --is-inside-work-tree &>/dev/null; then
	# create directory for scripts repository
	mkdir -p "${scripts_dest_path}"
	# git clone scripts repository
	git clone https://github.com/binhex/scripts --depth 1 "${scripts_dest_path}"
fi

# ensure scripts repository is up to date
cd "${scripts_dest_path}" || exit 1
git pull || true

# add docker scripts to PATH
if ! grep -q "${scripts_dest_path}/shell/docker" '/root/.bashrc' &>/dev/null; then
	echo "export PATH=\"${scripts_dest_path}/shell/docker:\${PATH}\"" >> '/root/.bashrc'
fi

if ! grep -q "${scripts_dest_path}/shell/docker" '/home/nobody/.bashrc' &>/dev/null; then
	echo "export PATH=\"${scripts_dest_path}/shell/docker:\${PATH}\"" >> '/home/nobody/.bashrc'
fi

# ensure scripts are executable and owned by nobody:users
chown -R nobody:users "${scripts_dest_path}"
chmod -R 755 "${scripts_dest_path}"
