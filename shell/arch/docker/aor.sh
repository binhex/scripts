#!/bin/bash

# exit script if return code != 0
set -e

# get repo and arch from aor using api (json format)
aor_package_results=$(curl "https://www.archlinux.org/packages/search/json/?q=${aor_package_name}&arch=any&arch=x86_64" | jq ".results[0] | { repo: .repo, arch: .arch}")
aor_package_repo=$(echo $aor_package_results | jq ".repo")
aor_package_arch=$(echo $aor_package_results | jq ".arch")

# get latest compiled package from aor (required due to the fact we use archive snapshot)
if [[ ! -z "${aor_package_name}" ]]; then
	curl -L -o "/tmp/${aor_package_name}.tar.xz" "https://www.archlinux.org/packages/${aor_package_repo}/${aor_package_arch}/${aor_package_name}/download/"
	pacman -U "/tmp/${aor_package_name}.tar.xz" --noconfirm
fi
