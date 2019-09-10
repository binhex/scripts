#!/bin/bash
# This script downloads github source releases in zipped format, it also has basic support for binary assets.

# exit script if return code != 0
set -e

# setup default values
readonly ourScriptName=$(basename -- "$0")
readonly defaultDownloadFilename="github-source.zip"
readonly defaultDownloadPath="/tmp"
readonly defaultDownloadRelease="true"
readonly defaultExtractPath="/tmp/extracted"
readonly defaultReleaseType="source"
readonly defaultQueryType="releases/latest"

download_filename="${defaultDownloadFilename}"
download_path="${defaultDownloadPath}"
download_release="${defaultDownloadRelease}"
extract_path="${defaultExtractPath}"
release_type="${defaultReleaseType}"
query_type="${defaultQueryType}"

function github_release_version() {

	echo -e "[info] Running function to identify latest release tag from GitHub..."

	# use github rest api to get app release info
	echo -e "[info] github_release_url='https://api.github.com/repos/${github_owner}/${github_repo}/${query_type}'"
	github_release_url="https://api.github.com/repos/${github_owner}/${github_repo}/${query_type}"

	echo -e "[info] Identifying GitHub release..."
	mkdir -p "${download_path}"

	if [ "${query_type}" == "tags" ]; then
		json_query=".[0].name"
	else
		json_query=".tag_name"
	fi

	echo -e "[info] Performing query to find out GitHub release..."
	echo -e "[info] curly.sh -rc 6 -rw 10 -of '${download_path}/github_release' -url '${github_release_url}'"
	curly.sh -rc 6 -rw 10 -of "${download_path}/github_release" -url "${github_release_url}"
	github_release=$(cat "${download_path}/github_release" | jq -r "${json_query}")
	echo -e "[info] GitHub release is '${github_release}'"
	rm -f "${download_path}/github_release"

}

function github_downloader() {

	github_release="${1}"

	if [ "${release_type}" == "binary" ]; then

		filename=$(basename "${download_assets}")
		download_ext="${filename##*.}"

		echo -e "[infp] Finding all GitHub asset names..."
		echo -e "[info] github_asset_names=\$(curl -s 'https://api.github.com/repos/${github_owner}/${github_repo}/releases/latest' | jq -r '.assets[] | .name' || true)"
		github_asset_names=$(curl -s "https://api.github.com/repos/${github_owner}/${github_repo}/releases/latest" | jq -r '.assets[] | .name' || true)

		if [[ ! -z "${github_asset_names}" ]]; then

			echo -e "[info] Finding asset names that match the download filename we specified..."
			echo -e "[info] match_asset_name=\$(echo '${github_asset_names}' | grep -P -o -m 1 '${download_assets}')"
			match_asset_name=$(echo "${github_asset_names}" | grep -P -o -m 1 "${download_assets}")

			if [[ -z "${match_asset_name}" ]]; then

				echo -e "[warn] No assets matching pattern available for download, showing all available assets..."
				echo -e "[info] ${github_asset_names}"
				echo -e "[info] Exiting script..." ; exit 1

			else

				echo -e "[info] Downloading binary release asset from GitHub..."
				echo -e "[info] curly.sh -rc 6 -rw 10 -of '${download_path}/${match_asset_name}' -url 'https://github.com/${github_owner}/${github_repo}/releases/download/${github_release}/${match_asset_name}'"
				curly.sh -rc 6 -rw 10 -of "${download_path}/${match_asset_name}" -url "https://github.com/${github_owner}/${github_repo}/releases/download/${github_release}/${match_asset_name}"

			fi

		fi

		if [ "${download_ext}" == "zip" ]; then

			echo -e "[info] Removing previous extract path..."
			echo -e "[info] rm -rf '${extract_path}/'"
			rm -rf "${extract_path}/"

			echo -e "[info] Extracting zip..."
			echo -e "[info] unzip -o '${download_path}/${match_asset_name}' -d '${extract_path}'"
			mkdir -p "${extract_path}"
			unzip -o "${download_path}/${match_asset_name}" -d "${extract_path}"

			echo -e "[info] Removing binary archive..."
			echo -e "[info] rm -f '${download_path}/${match_asset_name}'"
			rm -f "${download_path}/${match_asset_name}"

			if [[ ! -z "${install_path}" ]]; then

				echo -e "[info] Copying from extraction path to install path..."
				echo -e "[info] cp -R '${extract_path}/*/*' '${install_path}'"
				mkdir -p "${install_path}"
				cp -R "${extract_path}"/*/* "${install_path}"

				echo -e "[info] Removing extract path..."
				echo -e "[info] rm -rf '${extract_path}/'"
				rm -rf "${extract_path}/"

			fi

		else

			if [[ ! -z "${install_path}" ]]; then

				echo -e "[info] Copying from download path to install path..."
				echo -e "[info] cp -R '${download_path}/${match_asset_name}' '${install_path}/${match_asset_name}'"
				mkdir -p "${install_path}"
				cp -R "${download_path}/${match_asset_name}" "${install_path}/${match_asset_name}"

				echo -e "[info] Removing source archive..."
				echo -e "[info] rm -f '${download_path}/${match_asset_name}'"
				rm -f "${download_path}/${match_asset_name}"

				echo -e "[info] Marking binary asset as executable..."
				echo -e "[info] chmod +x '${install_path}/${match_asset_name}'"
				chmod +x "${install_path}/${match_asset_name}"

			fi

		fi

	else

		filename=$(basename "${download_filename}")
		download_ext="${filename##*.}"

		if [[ ! -z "${download_branch}" ]]; then

			echo -e "[info] Downloading latest commit on specific branch '${download_branch}' from GitHub..."
			echo -e "[info] curly.sh -rc 6 -rw 10 -of '${download_path}/${download_filename}' -url 'https://github.com/${github_owner}/${github_repo}/archive/${download_branch}.zip'"
			curly.sh -rc 6 -rw 10 -of "${download_path}/${download_filename}" -url "https://github.com/${github_owner}/${github_repo}/archive/${download_branch}.zip"

		else

			echo -e "[info] Downloading latest release source from GitHub..."
			echo -e "[info] curly.sh -rc 6 -rw 10 -of '${download_path}/${download_filename}' -url 'https://github.com/${github_owner}/${github_repo}/archive/${github_release}.zip'"
			curly.sh -rc 6 -rw 10 -of "${download_path}/${download_filename}" -url "https://github.com/${github_owner}/${github_repo}/archive/${github_release}.zip"

		fi

		if [ "${download_ext}" == "zip" ]; then

			echo -e "[info] Removing previous extract path..."
			echo -e "[info] rm -rf '${extract_path}/'"
			rm -rf "${extract_path}/"

			echo -e "[info] Extracting zip..."
			echo -e "[info] unzip -o '${download_path}/${download_filename}' -d '${extract_path}'"
			mkdir -p "${extract_path}"
			unzip -o "${download_path}/${download_filename}" -d "${extract_path}"

			echo -e "[info] Removing source archive..."
			echo -e "[info] rm -f '${download_path}/${download_filename}'"
			rm -f "${download_path}/${download_filename}"

			if [[ ! -z "${install_path}" ]]; then

				echo -e "[info] Copying from extraction path to install path..."
				echo -e "[info] cp -R '${extract_path}/*/*' '${install_path}'"
				mkdir -p "${install_path}"
				cp -R "${extract_path}"/*/* "${install_path}"

				echo -e "[info] Removing extract path..."
				echo -e "[info] rm -rf '${extract_path}/'"
				rm -rf "${extract_path}/"

			fi

		else

			if [[ ! -z "${install_path}" ]]; then

				echo -e "[info] Copying from download path to install path..."
				echo -e "[info] cp -R '${download_path}/${download_filename}' '${install_path}/${download_filename}'"
				mkdir -p "${install_path}"
				cp -R "${download_path}/${download_filename}" "${install_path}/${download_filename}"

				echo -e "[info] Removing source archive..."
				echo -e "[info] rm -f '${download_path}/${download_filename}'"
				rm -f "${download_path}/${download_filename}"

			fi

		fi

	fi
	
}

function github_compile_src() {

	# install compilation tooling
	pacman -S --needed base-devel --noconfirm

	# run commands to compile
	/bin/bash -c "${compile_src}"

	# remove base devel excluding useful core packages
	pacman -Ru $(pacman -Qgq base-devel | grep -v awk | grep -v pacman | grep -v sed | grep -v grep | grep -v gzip | grep -v which) --noconfirm

}

function show_help() {
	cat <<ENDHELP
Description:
	Script to download GitHub releases.
Syntax:
	${ourScriptName} [args]
Where:
	-h or --help
		Displays this text.

	-df or --download-filename <filename.ext>
		Define name of the downloaded file
		Defaults to '${defaultDownloadFilename}'.

	-da or --download-assets <filename.ext>
		Define name of the asset file(s) to download
		Defaults to '${defaultDownloadAsset}'.

	-dp or --download-path <path>
		Define path to download to.
		Defaults to '${defaultDownloadPath}'.

	-db or --download-branch <branch name>
		Define GitHub branch to download.
		No default.

	-ep or --extract-path <path>
		Define path to extract the download to.
		No default.

	-ip or --install-path <path>
		Define path to install to.
		No default.

	-go or --github-owner <owner>
		Define GitHub owners name.
		No default.

	-rt or --release-type <binary|source>
		Define whether to download binary assets or source from GitHub.
		Default to '${defaultReleaseType}'.

	-qt or --query-type <release/latest|tags>
		Define GitHub api query type for release or tags from GitHub.
		Default to '${defaultQueryType}'.

	-gr or --github-repo <repo>
		Define GitHub repository name.
		No default.

	-grs or --github-release <release name>
		Define GitHub release name.
		If not defined then latest release will be used.

	-dr or --download-release <true|false>
		Define whether to download the GitHub release artifact.
		Default to '${defaultDownloadRelease}'.

	-cs or --compile-src <commands to execute>
		Define commands to execute to compile source code.
		Default is not defined.

Example:
	./github.sh -df github-download.zip -dp /tmp -ep /tmp/extracted -ip /opt/binhex/deluge -go binhex -rt source -gr arch-deluge
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
		-rt|--release-type)
			release_type=$2
			shift
			;;
		-qt|--query-type)
			query_type=$2
			shift
			;;
		-dr|--download-release)
			download_release=$2
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

if [[ -z "${github_owner}" ]]; then
	echo "[warn] GitHub owner's name not defined via parameter -go or --github-owner, displaying help..."
	show_help
	exit 1
fi

if [[ -z "${github_repo}" ]]; then
	echo "[warn] GitHub repo name not defined via parameter -gr --github-repo, displaying help..."
	show_help
	exit 1
fi

# if we dont specify a branch then we assume release
if [[ -z "${download_branch}" ]]; then
	# if we dont define the tag/release then find out what it is
	if [[ -z "${github_release}" ]]; then
		github_release_version
	fi
fi

# if we dont specify a branch then we assume release
# if branch is specified then download without passing github release version
if [[ -z "${download_branch}" ]]; then
	# if we want to download the release artifact then do so, otherwise return release/tag only
	if [[ "${download_release}" == "true" ]]; then
		github_downloader "${github_release}"
	else
		echo "${github_release}"
	fi
else
	github_downloader
fi

# if we need to compile source then install base-devel and run commands to compile
if [[ -n "${compile_src}" ]]; then
	github_compile_src
fi
