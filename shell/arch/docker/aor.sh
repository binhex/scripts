#!/bin/bash

# exit script if return code != 0
set -e

if [[ ! -z "${aor_packages}" ]]; then

	# split space seperated string of packages into list
	IFS=' ' read -ra aor_package_list <<< "${aor_packages}"

	# process each package in the list
	for aor_package_name in "${aor_package_list[@]}"; do

		echo "[info] attempting download for aor package ${aor_package_name}"
		
		# get repo and arch from aor using api (json format)
		rcurl.sh -o "/tmp/aor_json_${aor_package_name}" "https://www.archlinux.org/packages/search/json/?q=${aor_package_name}&repo=Community&repo=Core&repo=Extra&repo=Multilib&arch=any&arch=x86_64"

		echo "[info] display output of aor json file /tmp/aor_json_${aor_package_name}..."
		cat "/tmp/aor_json_${aor_package_name}"

		# filter based on exact package name to prevent fuzzy matching of wrong packages
		aor_package_json=$(cat "/tmp/aor_json_${aor_package_name}" | jq -c --arg aor_package_name "${aor_package_name}" '.results[] | select(.pkgname | startswith($aor_package_name) and endswith($aor_package_name))')

		if [[ -n "${aor_package_json}" ]]; then

			echo "[info] display aor package json after exact match on package name ${aor_package_name}..."
			echo "${aor_package_json}"

		else

			echo "[info] aor package json empty, assuming failure and exiting..."
			exit 1

		fi

		aor_package_repo=$(echo $aor_package_json | jq -r ".repo")

		if [[ -n "${aor_package_repo}" ]]; then

			echo "[info] aor package repo is ${aor_package_repo}"

		else

			echo "[info] aor package repo is empty, assuming failure and exiting..,"
			exit 1

		fi

		aor_package_arch=$(echo $aor_package_json | jq -r ".arch")

		if [[ -n "${aor_package_arch}" ]]; then

			echo "[info] aor package arch is ${aor_package_arch}"

		else

			echo "[info] aor package arch is empty, assuming failure and exiting..,"
			exit 1

		fi

		# get latest compiled package from aor (required due to the fact we use archive snapshot)
		if [[ ! -z "${aor_package_repo}" && ! -z "${aor_package_arch}" ]]; then

			echo "[info] rcurl.sh -o /tmp/${aor_package_name}.tar.xz https://www.archlinux.org/packages/${aor_package_repo}/${aor_package_arch}/${aor_package_name}/download/"
			rcurl.sh -o "/tmp/${aor_package_name}.tar.xz" "https://www.archlinux.org/packages/${aor_package_repo}/${aor_package_arch}/${aor_package_name}/download/"
			pacman -U "/tmp/${aor_package_name}.tar.xz" --noconfirm

		else

			echo "[warn] unable to determine package repo and/or architecture, skipping package ${aor_package_name}"

		fi

	done

fi
