#!/bin/bash
# This script downloads github source releases in zipped format, it also has basic support for binary assets.

# setup default values
readonly ourScriptName=$(basename -- "$0")
readonly defaultDownloadFilename="github-source.zip"
readonly defaultDownloadPath="/tmp"
readonly defaultExtractPath="/tmp/extracted"
readonly defaultQueryType="releases/latest"
readonly defaultDownloadBranch="master"

download_filename="${defaultDownloadFilename}"
download_path="${defaultDownloadPath}"
extract_path="${defaultExtractPath}"
query_type="${defaultQueryType}"

function identify_github_release_tag_name() {

	echo -e "[info] Running GitHub release/tag name identifier..."

	local github_owner="${1}"
	shift
	local github_repo="${1}"
	shift
	local query_type="${1}"
	shift

	echo -e "[info] Running function to identify name of ${query_type} from GitHub..."
	github_release_url="https://api.github.com/repos/${github_owner}/${github_repo}/${query_type}"

	if [ "${query_type}" == "tags" ]; then
		local json_query=".[0].name"
	elif [ "${query_type}" == "pre-release" ]; then
		local json_query=".[0].tag_name"
		local query_type="releases"
	elif [ "${query_type}" == "releases/latest" ]; then
		local json_query=".tag_name"
	fi

	echo -e "[info] Performing query to find out GitHub ${query_type}..."

	echo -e "[info] rcurl.sh https://api.github.com/repos/${github_owner}/${github_repo}/${query_type} | jq -r ${json_query} 2> /dev/null"
	github_release_tag_name=$(rcurl.sh "https://api.github.com/repos/${github_owner}/${github_repo}/${query_type}" | jq -r "${json_query}" 2> /dev/null)

	if [[ -z "${github_release_tag_name}" ]]; then
		echo "[warn] Unable to identify GitHub ${query_type} name, exiting script..."
		exit 1
	fi

	echo -e "[info] GitHub ${query_type} name is '${github_release_tag_name}'"

}

function github_downloader() {

	echo -e "[info] Running GitHub downloader..."

	local github_release="${1}"
	shift
	local github_owner="${1}"
	shift
	local github_repo="${1}"
	shift
	local query_type="${1}"
	shift
	local download_assets="${1}"
	shift
	local download_branch="${1}"
	shift
	local download_filename="${1}"
	shift

	if [ -n "${download_assets}" ]; then

		echo -e "[info] Finding all GitHub asset names..."

		if [ "${query_type}" == "pre-release" ]; then
			echo -e "[info] curl -s https://api.github.com/repos/${github_owner}/${github_repo}/releases | jq -r '.[0].assets[] | .name' 2> /dev/null"
			github_asset_names=$(curl -s "https://api.github.com/repos/${github_owner}/${github_repo}/releases" | jq -r '.[0].assets[] | .name' 2> /dev/null)
		else
			echo -e "[info] curl -s https://api.github.com/repos/${github_owner}/${github_repo}/${query_type} | jq -r '.assets[] | .name' 2> /dev/null"
			github_asset_names=$(curl -s "https://api.github.com/repos/${github_owner}/${github_repo}/${query_type}" | jq -r '.assets[] | .name' 2> /dev/null)
		fi

		if [[ -z "${github_asset_names}" ]]; then
			echo -e "[info] Unable to identify binary assets available, exiting script..."
			exit 1
		fi

		echo -e "[info] Finding binary asset names that match '${download_assets}'..."

		match_asset_name=$(echo "${github_asset_names}" | grep -P -o -m 1 "${download_assets}")

		if [[ -z "${match_asset_name}" ]]; then

			echo -e "[warn] No binary assets matching pattern available for download, showing all available assets..."
			echo -e "[info] ${github_asset_names}"
			echo -e "[info] Exiting script..." ; exit 1

		else

			echo -e "[info] Asset name matches, downloading binary asset '${match_asset_name}' from GitHub..."

			echo -e "[info] rcurl.sh -o ${download_path}/${match_asset_name} https://github.com/${github_owner}/${github_repo}/releases/download/${github_release}/${match_asset_name}"
			rcurl.sh -o "${download_path}/${match_asset_name}" "https://github.com/${github_owner}/${github_repo}/releases/download/${github_release}/${match_asset_name}"

		fi

		if [ $? -ne 0 ]; then
			echo -e "[info] Unable to download binary asset, exiting script..."
			exit 1
		fi

		filename=$(basename "${match_asset_name}")
		download_ext="${filename##*.}"

	else

		if [[ "${query_type}" == "branch" ]]; then

			echo -e "[info] Downloading latest commit on specific branch '${download_branch}' from GitHub..."
			echo -e "[info] rcurl.sh -o '${download_path}/${download_filename}' 'https://github.com/${github_owner}/${github_repo}/archive/${download_branch}.zip'"
			rcurl.sh -o "${download_path}/${download_filename}" "https://github.com/${github_owner}/${github_repo}/archive/${download_branch}.zip"

		else

			echo -e "[info] Downloading ${query_type} source from GitHub..."
			echo -e "[info] rcurl.sh -o '${download_path}/${download_filename}' 'https://github.com/${github_owner}/${github_repo}/archive/${github_release}.zip'"
			rcurl.sh -o "${download_path}/${download_filename}" "https://github.com/${github_owner}/${github_repo}/archive/${github_release}.zip"

		fi

		if [ $? -ne 0 ]; then
			echo -e "[info] Unable to download source, exiting script..."
			exit 1
		fi

		filename=$(basename "${download_filename}")
		download_ext="${filename##*.}"

	fi

}

function archive_extractor() {

	echo -e "[info] Running archive extractor..."

	local download_ext="${1}"
	shift
	local match_asset_name="${1}"
	shift
	local download_filename="${1}"
	shift
	local extract_path="${1}"
	shift

	if [ -z "${download_ext}" ]; then
		echo -e "[warn] Download extension not found"
		return 1
	fi

	if [ -z "${extract_path}" ]; then
		echo -e "[warn] Extraction path not specified"
		return 1
	fi

	echo -e "[info] Download extension is '${download_ext}'"

	if [ "${download_ext}" == "zip" ]; then

		echo -e "[info] Removing previous extract path..."
		rm -rf "${extract_path}/"
		mkdir -p "${extract_path}"

		echo -e "[info] Extracting zip..."

		if [[ -n "${match_asset_name}" ]]; then
			unzip -o "${download_path}/${match_asset_name}" -d "${extract_path}"
		else
			unzip -o "${download_path}/${download_filename}" -d "${extract_path}"
		fi

	elif [ "${download_ext}" == "gz" ]; then

		echo -e "[info] Removing previous extract path..."
		rm -rf "${extract_path}/"
		mkdir -p "${extract_path}"

		echo -e "[info] Extracting gz..."
		cd "${extract_path}"

		if [[ -n "${match_asset_name}" ]]; then
			tar -xvf "${download_path}/${match_asset_name}"
		else
			tar -xvf "${download_path}/${download_filename}"
		fi

	else

		echo -e "[warn] File extension '${download_ext}' not known as an archive"
		return 1

	fi

}

function copy_to_install_path() {

	echo -e "[info] Running copy to install path..."

	local extract_path="${1}"
	shift
	local install_path="${1}"
	shift
	local download_ext="${1}"
	shift
	local download_path="${1}"
	shift
	local match_asset_name="${1}"
	shift

	if [ -z "${install_path}" ]; then
		echo -e "[warn] Install path not specified"
		return 1
	fi

	mkdir -p "${install_path}"

	if [[ "${download_ext}" == "zip" ]] && [[ -z "${match_asset_name}" ]]; then

		if [ -z "${extract_path}" ]; then
			echo -e "[warn] Extraction path not found"
			return 1
		fi

		echo -e "[info] Copying source from extraction path to install path..."
		echo -e "[info] cp -rf ${extract_path}/*/* ${install_path}"
		cp -R "${extract_path}"/*/* "${install_path}"

	elif ( [[ "${download_ext}" == "zip" ]] || [[ "${download_ext}" == "gz" ]] ) && [[ -n "${match_asset_name}" ]]; then

		if [ -z "${extract_path}" ]; then
			echo -e "[warn] Extraction path not found"
			return 1
		fi

		echo -e "[info] Copying binary asset from extraction path to install path..."
		echo -e "[info] cp -rf ${extract_path}/* ${install_path}"
		cp -R "${extract_path}"/* "${install_path}"

	else

		echo -e "[info] Copying binary asset from downloaded path to install path..."
		echo -e "[info] cp -rf ${download_path}/${match_asset_name} ${install_path}"
		cp -R "${download_path}/${match_asset_name}" "${install_path}"

	fi

}

function cleanup() {

	echo -e "[info] Running cleanup..."

	local download_ext="${1}"
	shift
	local match_asset_name="${1}"
	shift
	local download_filename="${1}"
	shift
	local download_path="${1}"
	shift
	local extract_path="${1}"
	shift

	if [[ "${download_ext}" == "zip" ]] || [[ "${download_ext}" == "gz" ]]; then

		if [ -z "${extract_path}" ]; then
			echo -e "[warn] Extraction path not found"
			return 1
		fi

		echo -e "[info] Removing temporary extraction path..."
		echo -e "[info] rm -rf '${extract_path}'"
		rm -rf "${extract_path}"

	fi

	if [[ -n "${match_asset_name}" ]]; then

		echo -e "[info] Removing binary assets..."
		echo -e "[info] rm -f '${download_path}/${match_asset_name}'"
		rm -f "${download_path}/${match_asset_name}"

	else

		echo -e "[info] Removing source archive..."
		echo -e "[info] rm -f '${download_path}/${download_filename}'"
		rm -f "${download_path}/${download_filename}"

	fi

}

function github_compile_src() {

	echo -e "[info] Running compile source..."

	# move to install path
	cd "${install_path}"

	# install compilation tooling
	pacman -S --needed base-devel --noconfirm

	# run commands to compile
	/bin/bash -c "${compile_src}"

}

function show_help() {
	cat <<ENDHELP
Description:
	Script to download GitHub pre-releases/releases/tags/assets.
Syntax:
	${ourScriptName} [args]
Where:
	-h or --help
		Displays this text.

	-df or --download-filename <filename.ext>
		Define name of the downloaded file
		Defaults to '${defaultDownloadFilename}'.

	-da or --download-assets <asset name>
		Define name of the asset file(s) to download, asset name can use regex.
		No default.

	-dp or --download-path <path>
		Define path to download to.
		Defaults to '${defaultDownloadPath}'.

	-db or --download-branch <branch name>
		Define GitHub branch to download.
		Defaults to '${defaultDownloadBranch}'.

	-ep or --extract-path <path>
		Define path to extract the download to.
		Defaults to '${defaultExtractPath}'.

	-ip or --install-path <path>
		Define path to install to.
		No default.

	-go or --github-owner <owner>
		Define GitHub owners name.
		No default.

	-qt or --query-type <release|pre-release|tags|branch>
		Define GitHub api query type for release or tags from GitHub.
		Default to '${defaultQueryType}'.

	-gr or --github-repo <repo>
		Define GitHub repository name.
		No default.

	-grs or --github-release <release name>
		Define GitHub release name.
		If not defined then latest release will be used.

	-cs or --compile-src <commands to execute>
		Define commands to execute to compile source code.
		Default is not defined.

Examples:
	GitHub release source download:
		github.sh --install-path '/opt/binhex/deluge' --github-owner 'binhex' --github-repo 'arch-deluge' --query-type 'release'

	GitHub tags source download:
		github.sh --install-path '/opt/binhex/deluge' --github-owner 'binhex' --github-repo 'arch-deluge' --query-type 'tags'

	GitHub master branch source download:
		github.sh --install-path '/opt/binhex/deluge' --github-owner 'binhex' --github-repo 'arch-deluge' --query-type 'branch' --download-branch 'master'

	GitHub release binary asset download:
		github.sh --install-path '/usr/bin' --github-owner 'yudai' --github-repo 'gotty' --download-assets 'gotty_linux_arm.tar.gz' --query-type 'release'

	GitHub pre-release binary asset download:
		github.sh --install-path '/usr/bin' --github-owner 'yudai' --github-repo 'gotty' --download-assets 'gotty_2.0.0-alpha.3_linux_amd64.tar.gz' --query-type 'pre-release'

ENDHELP
}

while [ "$#" != "0" ]
do
	case "$1"
	in
		-df|--download-filename)
			download_filename=$2
			shift
			;;
		-da|--download-assets)
			download_assets=$2
			shift
			;;
		-dp| --download-path)
			download_path=$2
			shift
			;;
		-db| --download-branch)
			download_branch=$2
			shift
			;;
		-ep|extract-path)
			extract_path=$2
			shift
			;;
		-ip|--install-path)
			install_path=$2
			shift
			;;
		-go|--github-owner)
			github_owner=$2
			shift
			;;
		-gr|--github-repo)
			github_repo=$2
			shift
			;;
		-grs|--github-release)
			github_release=$2
			shift
			;;
		-qt|--query-type)
			query_type=$2
			shift
			;;
		-cs|--compile-src)
			compile_src=$2
			shift
			;;
		-h|--help)
			show_help
			exit 0
			;;
		*)
			echo "[warn] ${ourScriptName}: ERROR: Unrecognised argument '$1'." >&2
			show_help
			 exit 1
			 ;;
	 esac
	 shift
done

echo "[info] Checking we have all required parameters before proceeding..."

if [[ -z "${github_owner}" ]]; then
	echo "[warn] GitHub owner's name not defined via parameter -go or --github-owner, displaying help..."
	echo ""
	show_help
	exit 1
fi

if [[ -z "${github_repo}" ]]; then
	echo "[warn] GitHub repo name not defined via parameter -gr or --github-repo, displaying help..."
	echo ""
	show_help
	exit 1
fi

if [[ -z "${install_path}" ]]; then
	echo "[warn] GitHub installation path not defined via parameter -ip or --install-path, displaying help..."
	echo ""
	show_help
	exit 1
fi

# change friendly name to correct name used in api call
if [ "${query_type}" == "release" ]; then
	query_type="releases/latest"
fi

echo "[info] Running GitHub script..."

# identify release or tag name
if [[ ! "${query_type}" == "branch" ]]; then
	identify_github_release_tag_name "${github_owner}" "${github_repo}" "${query_type}"
	if [ -z "${github_release_tag_name}" ]; then
		echo "[warn] Unable to identify GitHub release or tag name, exiting script..."
		exit 1
	fi
fi

# download source or binary assets
github_downloader "${github_release_tag_name}" "${github_owner}" "${github_repo}" "${query_type}" "${download_assets}" "${download_branch}" "${download_filename}"

# extract any compressed source or binary assets
archive_extractor "${download_ext}" "${match_asset_name}" "${download_filename}" "${extract_path}"

# copy extracted source/binary to specified install path
copy_to_install_path "${extract_path}" "${install_path}" "${download_ext}" "${download_path}" "${match_asset_name}"

# delete any compressed source or binary assets
cleanup "${download_ext}" "${match_asset_name}" "${download_filename}" "${download_path}" "${extract_path}"

# if we need to compile source then install base-devel and run commands to compile
if [[ -n "${compile_src}" ]]; then
	github_compile_src
fi
echo "[info] GitHub script finished"