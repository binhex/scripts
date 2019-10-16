#!/bin/bash

if [ -z "${1}" ]; then
	echo "[crit] No parameter supplied for file to convert"
	exit 1
fi

if [ ! -f "${1}" ]; then
	echo "[crit] File '${1}' does not exist"
	exit 1
fi

# create temp files used during the conversion
dos2unix_temp_file=$(mktemp /tmp/dos2unixtemp.XXXXXXXXX)
dos2unix_stdout_file=$(mktemp /tmp/dos2unixstdout.XXXXXXXXX)

# file to convert
dos2unix_source_file="${1}"

# run conversion, creating new temp file
/usr/bin/dos2unix -v -n "${dos2unix_source_file}" "${dos2unix_temp_file}" > "${dos2unix_stdout_file}" 2>&1

# if the file required conversion then overwrite (move with force) source file with converted temp file
if ! cat "${dos2unix_stdout_file}" | grep -q 'Converted 0'; then
	echo "[info] Line ending conversion required, moving '${dos2unix_temp_file}' to '${dos2unix_source_file}'"
	mv -f "${dos2unix_temp_file}" "${dos2unix_source_file}"
fi

# remove temporary files
rm -f "${dos2unix_temp_file}"
rm -f "${dos2unix_stdout_file}"
