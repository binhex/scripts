#!/bin/bash

gluetun_script_name='gluetun.sh'
gluetun_filepath="/usr/local/bin/${gluetun_script_name}"
github_url="https://raw.githubusercontent.com/binhex/scripts/refs/heads/master/shell/arch/docker/${gluetun_script_name}"

echo "[INFO] Downloading gluetun.sh from Github to '${gluetun_filepath}'..."
rm -f "${gluetun_filepath}"
curl -fLs -o "${gluetun_filepath}" "${github_url}"
chmod +x "${gluetun_filepath}"
echo "[INFO] Download complete. Executing ${gluetun_script_name} with arguments provided..."
exec "${gluetun_filepath}" "$@"
