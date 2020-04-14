#!/bin/bash

# exit script if return code != 0
set -e

echo "[info] Updating mirrorlist for pacman using reflector..."

# use reflector to overwriting existing mirrorlist, args explained below
# --sort rate                       = sort by download rate
# --age 1                           = Only return mirrors that have synchronized in the last 1 hours.
# --latest 5                        = Limit the list to the 5 most recently synchronized servers.
# --score 5                         = Limit the list to the n servers with the highest score.
# --save /etc/pacman.d/mirrorlist   = Save the mirrorlist to the given path.
pacman -S reflector --noconfirm
reflector --connection-timeout 60 --cache-timeout 60 --sort rate --age 1 --latest 5 --score 5 --save /etc/pacman.d/mirrorlist

echo "[info] Show contents of reflector generated mirrorlist for pacman..."
cat /etc/pacman.d/mirrorlist

echo "[info] Removing reflector and any other packages (python) that are not dependant..."
pacman -Rs reflector --noconfirm

# note overwrite required due to bug in missing soname link
# see below for details:-
# https://www.archlinux.org/news/nss3511-1-and-lib32-nss3511-1-updates-require-manual-intervention/
echo "[info] Synchronize pacman database and then upgrade any existing packages using pacman..."
pacman -Syyu --overwrite /usr/lib\*/p11-kit-trust.so --noconfirm
