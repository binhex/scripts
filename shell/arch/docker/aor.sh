#!/bin/bash

# exit script if return code != 0
set -e

# download and install package
curl -L -o "/tmp/${aor_packages}.tar.xz" "https://www.archlinux.org/packages/${aor_package_type}/any/${aor_packages}/download/"
pacman -U "/tmp/${aor_packages}.tar.xz" --noconfirm