#!/bin/bash

# wrapper script to perform check before forcing conversion of line endings
# ${1} should be path to file to convert

# check the file exists
if [ ! -f "${1}" ]; then
    exit 1
fi

# check whether the file is set to CRLF line endings
crlf_line_ending_count=$(cat -e "${1}" | grep -c '\^M\$')

if [ "${crlf_line_ending_count}" != 0 ]; then
	echo "[info] '${1}' contains CRLF (Windows) line endings, converting to LF (Unix)..." | ts '%Y-%m-%d %H:%M:%.S'
	dos2unix "${1}"
	echo "[info] Line ending conversion complete" | ts '%Y-%m-%d %H:%M:%.S'
fi
