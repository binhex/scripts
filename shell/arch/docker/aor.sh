#!/bin/bash

# exit script if return code != 0
set -e

# get latest compiled package from aor (required due to the fact we use archive snapshot)
if [[ ! -z "${aor_packages}" ]]; then
	curl -L -o "/tmp/${aor_packages}.tar.xz" "https://www.archlinux.org/packages/${aor_package_type}/any/${aor_packages}/download/"
	pacman -U "/tmp/${aor_packages}.tar.xz" --noconfirm
fi
