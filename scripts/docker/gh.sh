#!/bin/bash

# setup default values
readonly ourScriptName=$(basename -- "$0")
readonly defaultDownloadPath="$(pwd)"

DOWNLOAD_PATH="${defaultDownloadPath}"

function prereq() {

  echo "[info] Checking we have all required tooling before running..."

  tools="git sed jq"
  for i in ${tools}; do
    if ! command -v "${i}" > /dev/null 2>&1; then
      echo "[warn] Required tool '${i}' is missing, please install and re-run the script"
			pacman -Sy --noconfirm
			pacman -S "${i}" --noconfirm
    fi
  done
  echo "[info] All required tools are available"

	if [[ -z "${DOWNLOAD_TYPE}" ]]; then
		echo "[warn] GitHub download type not defined via parameter -dt or --download-type, displaying help..."
		echo ""
		show_help
		exit 1
	fi

	if [[ "${DOWNLOAD_TYPE}" == 'release' && -z "${RELEASE_TYPE}" ]]; then
		echo "[warn] GitHub release type not defined via parameter -rt or --release-type, displaying help..."
		echo ""
		show_help
		exit 1
	fi

	if [[ "${DOWNLOAD_TYPE}" == 'release' && "${RELEASE_TYPE}" == 'binary' ]]; then
		if [[ -z "${ASSET_REGEX}" ]]; then
			echo "[warn] Asset regex not defined via parameter -ar or --asset-regex, displaying help..."
			echo ""
			show_help
			exit 1
		fi
	fi

	if [[ -z "${GITHUB_OWNER}" ]]; then
		echo "[warn] GitHub owner not defined via parameter -go or --github-owner, displaying help..."
		echo ""
		show_help
		exit 1
	fi

	if [[ -z "${GITHUB_REPO}" ]]; then
		echo "[warn] GitHub repository not defined via parameter -gr or --github-repo, displaying help..."
		echo ""
		show_help
		exit 1
	fi

}

function release_download() {

    mkdir -p "${DOWNLOAD_PATH}"

    # if release name regex is provided, get multiple releases and filter them
    if [[ -n "${RELEASE_NAME_REGEX}" ]]; then
        echo "[info] Searching for releases matching regex: ${RELEASE_NAME_REGEX}"

        # get list of releases with their tag names using GitHub API
        release_list=$(curl -s "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases?per_page=50" | jq '[.[] | {name: .name, tagName: .tag_name, isPrerelease: .prerelease, isLatest: (.tag_name == "latest")}]')

        # filter releases by name regex
        matching_releases=$(jq -r --arg regex "${RELEASE_NAME_REGEX}" '.[] | select(.name | test($regex))' <<< "${release_list}")

        if [[ -z "${matching_releases}" ]]; then
            echo "[warn] No releases found matching regex '${RELEASE_NAME_REGEX}'"
            return 1
        fi

        release_count=$(jq -s 'length' <<< "${matching_releases}")
        echo "[info] Found ${release_count} matching release(s) '${RELEASE_NAME_REGEX}'"

        # process each matching release
        while IFS= read -r release; do
            release_name=$(jq -r '.name' <<< "${release}")
            release_tag=$(jq -r '.tagName' <<< "${release}")

            echo "[info] Processing release: ${release_name} (tag: ${release_tag})"

            if [[ "${RELEASE_TYPE}" == 'binary' ]]; then
                # get assets for this release and download matching ones
                assets=$(curl -s "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tags/${release_tag}" | jq -r --arg pattern "${ASSET_REGEX}" '.assets[] | select(.name | test($pattern)) | .browser_download_url')
                for asset_url in ${assets}; do
                    echo "[info] Downloading asset: $(basename "${asset_url}")"
                    curl -s -L -o "${DOWNLOAD_PATH}/$(basename "${asset_url}")" "${asset_url}"
                done
            elif [[ "${RELEASE_TYPE}" == 'source' ]]; then
                # download source tarball
                echo "[info] Downloading source tarball for ${release_tag}"
                curl -s -L -o "${DOWNLOAD_PATH}/${GITHUB_REPO}-${release_tag}.tar.gz" "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/tarball/${release_tag}"
            fi

        done <<< "$(jq -c '.' <<< "${matching_releases}")"

    else
        # no regex provided, use original behavior (latest release only)
        if [[ "${RELEASE_TYPE}" == 'binary' ]]; then
            # get latest release and download matching assets
            assets=$(curl -s "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest" | jq -r --arg pattern "${ASSET_REGEX}" '.assets[] | select(.name | test($pattern)) | .browser_download_url')
            for asset_url in ${assets}; do
                echo "[info] Downloading asset: $(basename "${asset_url}")"
                curl -s -L -o "${DOWNLOAD_PATH}/$(basename "${asset_url}")" "${asset_url}"
            done
        elif [[ "${RELEASE_TYPE}" == 'source' ]]; then
            # get latest release tag and download source tarball
            latest_tag=$(curl -s "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest" | jq -r '.tag_name')
            echo "[info] Downloading source tarball for ${latest_tag}"
            curl -s -L -o "${DOWNLOAD_PATH}/${GITHUB_REPO}-${latest_tag}.tar.gz" "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/tarball/${latest_tag}"
        fi
    fi

}

function repo_clone() {

	mkdir -p "${DOWNLOAD_PATH}"
	git clone "https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git" "${DOWNLOAD_PATH}" --depth=1

}

function show_help() {
	cat <<ENDHELP
Description:
	Script to download GitHub assets and clone source code.
Syntax:
	${ourScriptName} [args]
Where:
	-h or --help
		Displays this text.

	-dp or --download-path <path>
		Define path to download assets to.
		Default is '${defaultDownloadPath}'.

	-dt or --download-type <release|clone>
		Define the type of download to perform.
		No default.

	-rt or --release-type <binary|source>
		Define whether to download the release binary or release source.
		No default.

	-ar or --asset-regex <regex pattern>
		Define the asset regex pattern to download (only applies when --release-type is 'binary')
		No default.

	-rn or --release-name-regex <regex>
		Define a regex pattern to match release names.
		No default.

	-go or --github-owner <owner>
		Define GitHub owners name.
		No default.

	-gr or --github-repo <repo>
		Define GitHub repository name.
		No default.

Examples:
	GitHub release binary asset download:
	./${ourScriptName} --github-owner zakkarry --github-repo deluge-ltconfig --download-type release --release-type binary --download-path /home/nobody --asset-regex '.*egg$'

	GitHub release binary asset download (matching specific release name):
	./${ourScriptName} --github-owner Arihany --github-repo WinlatorWCPHub --download-type release --release-type binary --download-path /home/nobody --asset-regex '.*wcp$' --release-name-regex '^WOWBOX64$'

	GitHub release source code asset download:
	./${ourScriptName} --github-owner bitmagnet-io --github-repo bitmagnet --download-type release --release-type source --download-path /home/nobody

		GitHub shallow clone of source code:
	./${ourScriptName} --github-owner bitmagnet-io --github-repo bitmagnet --download-type clone --download-path /home/nobody

ENDHELP
}

while [ "$#" != "0" ]
do
	case "$1"
	in
		-dp| --download-path)
			DOWNLOAD_PATH=$2
			shift
			;;
		-dt| --download-type)
			DOWNLOAD_TYPE=$2
			shift
			;;
		-rt|--release-type)
			RELEASE_TYPE=$2
			shift
			;;
		-ar|--asset-regex)
			ASSET_REGEX=$2
			shift
			;;
		-rn|--release-name-regex)
			RELEASE_NAME_REGEX=$2
			shift
			;;
		-go|--github-owner)
			GITHUB_OWNER=$2
			shift
			;;
		-gr|--github-repo)
			GITHUB_REPO=$2
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

function main() {
	prereq

	if [[ "${DOWNLOAD_TYPE}" == 'release' ]]; then
			release_download
	elif [[ "${DOWNLOAD_TYPE}" == 'clone' ]]; then
			repo_clone
	fi

}

main