#!/bin/bash

# wrapper script to fix up NFS mount issues with dos2unix
# ${1} should be path to file to convert

# check the file exists
if [ ! -f "${1}" ]; then
    exit 1
fi

# get the filename without path, used for temp filename
filename=$(basename -- "${1}")

# check whether the file is set to CRLF line endings
exit_code=$(cat -e "${1}" | grep '\^M\$')

# note we use dos2unix -n to prevent issues when file is located on NFS mount
if [ "${exit_code}" == 0 ]; then
    echo "[info] '${1}' contains CRLF (Windows) line endings, converting to LF (Unix)..." | ts '%Y-%m-%d %H:%M:%.S'
    rm -f "/tmp/${filename}-lf.tmp"
    dos2unix -n "${1}" "/tmp/${filename}-lf.tmp" 1> /dev/null
    mv -f "/tmp/${filename}-lf.tmp" "${1}"
    echo "[info] Line ending conversion complete" | ts '%Y-%m-%d %H:%M:%.S'
fi
