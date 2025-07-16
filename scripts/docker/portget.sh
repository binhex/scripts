#!/bin/bash

# Basic download and wrapper script for portset.sh

portset_script_name='portset.sh'
portset_filepath="/usr/local/bin/scripts/docker/${portset_script_name}"
github_url="https://raw.githubusercontent.com/binhex/scripts/refs/heads/master/scripts/docker/${portset_script_name}"

echo "[INFO] Downloading portset.sh from Github to '${portset_filepath}'..."
rm -f "${portset_filepath}"

# Retry download up to 10 times with 1 second delay
download_success=false
for attempt in {1..10}; do
    echo "[INFO] Download attempt ${attempt}/10..."
    if curl -fLs -o "${portset_filepath}" "${github_url}"; then
        if [[ -s "${portset_filepath}" ]]; then
            chmod +x "${portset_filepath}"
            echo "[INFO] Download complete. Executing ${portset_script_name} with arguments provided..."
            download_success=true
            break
        else
            echo "[WARN] Downloaded file is empty, retrying..."
            rm -f "${portset_filepath}"
        fi
    else
        echo "[WARN] Download failed, retrying in 1 second..."
    fi
    sleep 1
done

if [[ "${download_success}" == "true" ]]; then
    exec "${portset_filepath}" "$@"
else
    echo "[ERROR] Failed to download ${portset_script_name} after 10 attempts"
    if [[ $# -gt 0 ]]; then
        echo "[INFO] Executing provided arguments directly: $*"
        exec "$@"
    else
        echo "[ERROR] No arguments provided to execute"
        exit 1
    fi
fi
