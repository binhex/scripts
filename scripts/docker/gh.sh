#!/bin/bash

# setup default values
readonly ourScriptName=$(basename -- "$0")
readonly defaultDownloadPath="$(pwd)"

DOWNLOAD_PATH="${defaultDownloadPath}"

function prereq() {

	# check if gh cli tool exists
	if ! command -v gh &> /dev/null; then
		echo "[info] GitHub CLI 'gh' not found, installing..."
		pacman -Sy --noconfirm
		pacman -S github-cli --noconfirm
	else
		echo "[info] GitHub CLI 'gh' already installed"
	fi

	if [[ -z "${RELEASE_TYPE}" ]]; then
		echo "[warn] GitHub release type not defined via parameter -rt or --release-type, displaying help..."
		echo ""
		show_help
		exit 1
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

	if [[ "${RELEASE_TYPE}" == 'asset' ]]; then
		if [[ -z "${ASSET_GLOB}" ]]; then
			echo "[warn] Asset glob not defined via parameter -ag or --asset-glob, displaying help..."
			echo ""
			show_help
			exit 1
		fi
	fi
}

function release_download_asset() {

	if [[ "${RELEASE_TYPE}" == 'asset' ]]; then
		type_flag="--pattern ${ASSET_GLOB}"
	elif [[ "${RELEASE_TYPE}" == 'source' ]]; then
		type_flag="--archive tar.gz"
	fi

	mkdir -p "${DOWNLOAD_PATH}"
	# currently github cli 'gh' requires authentication to download assets from public repositories
	# hoeever there is a hack/workaround for this that this script makes use of.
	# detailed hack here: https://github.com/cli/cli/issues/2680#issuecomment-1345491083
	GH_HOST=foobar gh release download -R "github.com/${GITHUB_OWNER}/${GITHUB_REPO}" --dir "${DOWNLOAD_PATH}" ${type_flag}
}

function repo_clone() {
	mkdir -p "${DOWNLOAD_PATH}"
	GH_HOST=foobar gh repo clone "${GITHUB_OWNER}/${GITHUB_REPO}" "${DOWNLOAD_PATH}" -- --depth=1
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

	-ag or --asset-glob <glob pattern>
		Define the asset glob pattern to download (only applies when --release-type is 'asset')
		No default.

	-dp or --download-path <path>
		Define path to download assets to.
		Default is '${defaultDownloadPath}'.

	-go or --github-owner <owner>
		Define GitHub owners name.
		No default.

	-gr or --github-repo <repo>
		Define GitHub repository name.
		No default.

	-rt or --release-type <asset|source>
		Define whether to download the release asset or release source.
		No default.

Examples:
	GitHub shallow clone of source code:
	./${ourScriptName} --github-owner bitmagnet-io --github-repo bitmagnet --release-type source --download-path /home/nobody

	GitHub release source code asset download:
	./${ourScriptName} --github-owner bitmagnet-io --github-repo bitmagnet --release-type asset --download-path /home/nobody --asset-glob '*.tar.gz'

	GitHub release binary asset download:
	./${ourScriptName} --github-owner zakkarry --github-repo deluge-ltconfig --release-type asset --download-path /home/nobody --asset-glob '*.egg'
ENDHELP
}

while [ "$#" != "0" ]
do
	case "$1"
	in
		-ag|--asset-glob)
			ASSET_GLOB=$2
			shift
			;;
		-dp| --download-path)
			DOWNLOAD_PATH=$2
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
		-rt|--release-type)
			RELEASE_TYPE=$2
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
	if [[ "${RELEASE_TYPE}" == 'asset' ]]; then
		release_download_asset
	elif [[ "${RELEASE_TYPE}" == 'source' ]]; then
		repo_clone
	fi
}

main