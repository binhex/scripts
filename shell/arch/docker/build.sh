#!/bin/bash

# exit script if return code != 0
set -e

export OS_ARCH=$(cat /etc/os-release | grep -P -o -m 1 "(?=^ID\=).*" | grep -P -o -m 1 "[a-z]+$")
if [[ ! -z "${OS_ARCH}" ]]; then
	if [ "${OS_ARCH}" -eq "arch" ]; then
		OS_ARCH="x86-64"
	else
		OS_ARCH="aarch64"
	fi
	echo "[info] OS_ARCH defined as '${OS_ARCH}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[warn] Unable to identify OS_ARCH, defaulting to 'x86-64'" | ts '%Y-%m-%d %H:%M:%.S'
	export OS_ARCH="x86-64"
fi
