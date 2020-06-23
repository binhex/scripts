#!/bin/bash

# A simple bash script to make selected media read only to prevent any possible Ransomware attacks.

read_only="no"

media_shares="E-Books,Podcasts"

include_extensions="*.mkv,*.png"

exclude_extensions="*.mkv,*.png"

exclude_folders="_to sort,temp"

# if read only then set chattr else undo read only
if [[ "${read_only}" == "yes" ]]; then
	chattr_cmd="chattr +i"
else
	chattr_cmd="chattr -i"
fi

# get all disks in the array
all_disks=$(ls -d /mnt/disk* | xargs)

# split space separated disks in the array
IFS=' ' read -ra all_disks_list <<< "${all_disks}"

# split comma separated media user shares
IFS=',' read -ra media_shares_list <<< "${media_shares}"

# split comma separated include file extensions
IFS=',' read -ra include_extensions_list <<< "${include_extensions}"

# split comma separated exclude file extensions
IFS=',' read -ra exclude_extensions_list <<< "${exclude_extensions}"

# split comma separated exclude folders
IFS=',' read -ra exclude_folders_list <<< "${exclude_folders}"

include_extensions_cmd=""

# loop over list of file extensions to process and add required flags
for include_extensions_item in "${include_extensions_list[@]}"; do

	if [[ -z "${include_extensions_cmd}" ]]; then
		include_extensions_cmd+="-name \"${include_extensions_item}\""
	else
		include_extensions_cmd+=" -o -name \"${include_extensions_item}\""
	fi

done

include_extensions_cmd="\( ${include_extensions_cmd} \)"

exclude_extensions_cmd=""

# loop over list of file extensions to process and add required flags
for exclude_extensions_item in "${exclude_extensions_list[@]}"; do

	if [[ -z "${exclude_extensions_cmd}" ]]; then
		exclude_extensions_cmd+="-not -name \"${exclude_extensions_item}\""
	else
		exclude_extensions_cmd+=" -o -not -name \"${exclude_extensions_item}\""
	fi

done

exclude_extensions_cmd="\( ${exclude_extensions_cmd} \)"

exclude_folders_cmd=""

if [[ -n "${exclude_folders}" ]]; then

	# loop over list of folders to exclude
	for exclude_folders_item in "${exclude_folders_list[@]}"; do

		if [[ -z "${exclude_folders_cmd}" ]]; then
			exclude_folders_cmd+="-not -path \"*/${exclude_folders_item}/*\""
		fi

	done

fi

# loop over list of disk shares looking for top level user share matches
for all_disks_item in "${all_disks_list[@]}"; do

	# loop over list of media share names looking for media share names that match what we want
	for media_shares_item in "${media_shares_list[@]}"; do

		echo "[info] Finding share that matches '${media_shares_item}' for disk '${all_disks_item}'..."
		echo "[info] find ${all_disks_item} -maxdepth 1 -type d -name ${media_shares_item}"
		media_shares_match=$(find "${all_disks_item}" -maxdepth 1 -type d -name "${media_shares_item}")

		# if a match then process with chattr
		if [[ -n "${media_shares_match}" ]]; then

			echo "[info] Locking media share '${media_shares_match}' using 'chattr' recursively for all files..."
			echo "[debug] find ${media_shares_match} -type f ${exclude_folders_cmd} ${include_extensions_cmd} ${exclude_extensions_cmd} -exec ${chattr_cmd} {} \;"
			eval "find ${media_shares_match} -type f ${exclude_folders_cmd} ${include_extensions_cmd} ${exclude_extensions_cmd} -exec ${chattr_cmd} {} \;"

		else

			echo "[info] No matching media share for disk '${all_disks_item}'"

		fi

		echo "[info] Processing finished for disk '${all_disks_item}'"
		echo "[info]"

	done

done
