#!/bin/bash

# ensure git cli is installed
pacman -S git --noconfirm

# silence warning aobut permissions
git config --global --add safe.directory /usr/local/bin

if [[ ! -d /usr/local/bin/scripts ]]; then
	# create directory for scripts repository
	mkdir -p /usr/local/bin/
	# git clone scripts repository
	git clone https://github.com/binhex/scripts --depth 1 /usr/local/bin
fi

# ensure scripts repository is up to date
cd /usr/local/bin/ && git pull
