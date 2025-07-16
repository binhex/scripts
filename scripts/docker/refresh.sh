#!/bin/bash

# script to refresh the scripts repository
# this script is run by the dockerfile to ensure the scripts repository is up to date

set -e

scripts_dest_path="/usr/local/bin/system"

mkdir -p "${scripts_dest_path}"

# ensure git cli is installed
if ! command -v git &>/dev/null; then
    echo "[info] Git not found, installing..."
    pacman -S git --noconfirm
else
    echo "[info] Git is already installed"
fi

# silence warning about permissions
git config --global --add safe.directory "${scripts_dest_path}"

# if scripts path is not a git repository then clone
if ! git -C "${scripts_dest_path}" rev-parse --is-inside-work-tree &>/dev/null; then
	# create directory for scripts repository
	mkdir -p "${scripts_dest_path}"
	# git clone scripts repository
	git clone https://github.com/binhex/scripts --depth 1 "${scripts_dest_path}"
fi

# ensure scripts repository is up to date
cd "${scripts_dest_path}" || exit 1
git pull || true
