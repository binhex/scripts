#!/bin/bash

# script to refresh the scripts repository
# this script is run by the dockerfile to ensure the scripts repository is up to date

set -e

# ensure git cli is installed
pacman -S git --noconfirm

# silence warning aobut permissions
git config --global --add safe.directory '/usr/local/bin'

# if scripts repository does not exist, clone it
if [[ ! -d '/usr/local/bin/shell' ]]; then
	# create directory for scripts repository
	mkdir -p /usr/local/bin/
	# git clone scripts repository
	git clone https://github.com/binhex/scripts --depth 1 '/usr/local/bin'
fi

# ensure scripts repository is up to date
cd /usr/local/bin || exit
git pull || true

# add docker scripts to PATH
if ! grep -q '/usr/local/bin/shell/docker' '/root/.bashrc' &>/dev/null; then
	echo 'export PATH="/usr/local/bin/shell/docker:${PATH}"' >> '/root/.bashrc'
fi

if ! grep -q '/usr/local/bin/shell/docker' '/home/nobody/.bashrc' &>/dev/null; then
	echo 'export PATH="/usr/local/bin/shell/docker:${PATH}"' >> '/home/nobody/.bashrc'
fi

# ensure scripts are executable and owned by nobody:users
chown -R nobody:users '/usr/local/bin'
chmod -R 755 '/usr/local/bin'
