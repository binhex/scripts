#!/bin/bash

# exit script if return code != 0
set -e

if [[ ! -z "${aor_packages}" ]]; then

	# split space seperated string of packages into list
	IFS=' ' read -ra aor_package_list <<< "${aor_packages}"

	# process each package in the list
	for aor_package_name in "${aor_package_list[@]}"; do

		# get repo and arch from aor using api (json format)
		aor_package_results=$(curl "https://www.archlinux.org/packages/search/json/?q=${aor_package_name}&arch=any&arch=x86_64" | jq ".results[0] | { repo: .repo, arch: .arch}")

		aor_package_repo=$(echo $aor_package_results | jq -r ".repo")
		echo "AOR package repo: ${aor_package_repo}"

		aor_package_arch=$(echo $aor_package_results | jq -r ".arch")
		echo "AOR package arch: ${aor_package_arch}"

		# get latest compiled package from aor (required due to the fact we use archive snapshot)
		if [[ ! -z "${aor_package_repo}" && ! -z "${aor_package_arch}" ]]; then
			echo "curl -L -o "/tmp/${aor_package_name}.tar.xz" "https://www.archlinux.org/packages/${aor_package_repo}/${aor_package_arch}/${aor_package_name}/download/""
			curl -L -o "/tmp/${aor_package_name}.tar.xz" "https://www.archlinux.org/packages/${aor_package_repo}/${aor_package_arch}/${aor_package_name}/download/"
			pacman -U "/tmp/${aor_package_name}.tar.xz" --noconfirm
		else
			echo "Unable to determine package repo and/or architecture, skipping package ${aor_package_name}"
		fi

	done

fi
