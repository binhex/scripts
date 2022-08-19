#!/bin/bash

# set defaults
defaultLogLevel="WARN"
defaultCreateVirtualenv="yes"

log_level="${defaultLogLevel}"
create_virtualenv="${defaultCreateVirtualenv}"

# logger function
source '/usr/local/bin/utils.sh'

function virtualenv() {

	if [[ "${create_virtualenv}" == "yes" ]]; then

		logger "Activating virtualenv at location '${install_path}/env/bin/activate'" "INFO"

		# install virtualenv, create env and activate
		python3 -m pip install --user virtualenv
		python3 -m venv env
		source "${install_path}/env/bin/activate"

	fi

}

function pip_install() {

	# define pacman packages
	pacman_packages="python"

	# install compiled packages using pacman
	if [[ -n "${pacman_packages}" ]]; then
		pacman -S --needed $pacman_packages --noconfirm
	fi

	# compile pip from source, fixes issue https://github.com/pypa/pip/issues/9348
	curl https://bootstrap.pypa.io/get-pip.py | python

	# force upgrade/install of setuptools
	pip install --upgrade setuptools

	if [[ -n "${install_path}" ]]; then

		 # create install path to store virtualenv and python modules
		mkdir -p "${install_path}" && cd "${install_path}" || exit 1

	fi

	if [[ -z "${pip_packages}" ]]; then

		if [[ ! -f "${install_path}/requirements.txt" ]]; then
			logger "Path to requirements.txt '${install_path}/requirements.txt' does not exist, showing help..." "WARN"
			show_help
			return 1
		fi

		virtualenv

		logger "Installing Python pre-requisites via requirements.txt file '${install_path}/requirements.txt'" "INFO"

		# install python modules as per requirements.txt in virtualenv
		pip install -r "${install_path}/requirements.txt"


	else

		virtualenv

		logger "Installing Python package(s) '${pip_packages}'" "INFO"

		# install python package in virtualenv
		pip install -U ${pip_packages}

	fi

}

function show_help() {
	cat <<ENDHELP
Description:
	A script to install Python pre-requisites via 'requirements.txt' or pip install specific package(s).
Syntax:
	./pip.sh [args]
Where:
	-h or --help
		Displays this text.

	-cv or --create-virtualenv <yes|no>
		Define whether to create and use virtualenv.
		Defaults to '${defaultCreateVirtualenv}'.

	-ip or --install-path <path>
		Define path to 'requirements.txt'.
		No default.

	-pp or --pip-paackages <package names>
		Define specified packages to install via pip.
		No default.

	-ll or --log-level <DEBUG|INFO|WARN|ERROR>
		Define logging level.
		Defaults to '${defaultLogLevel}'.

Examples:
	Install Python modules specified in requirements.txt file (located at --install-path/) to virtualenv (located at --install-path/env/):
		./pip.sh --install-path '/opt/sickchill' --log-level 'WARN'

	Install Python modules specified in requirements.txt file to system:
		./pip.sh --create-virtualenv 'no' --install-path '/opt/sickchill' --log-level 'WARN'

	Install specified Python modules to virtualenv (located at --install-path/env/):
		./pip.sh  --install-path '/opt/sickchill' --pip-packages 'websockify pyxdg numpy' --log-level 'WARN'

	Install specified Python modules to system:
		./pip.sh --create-virtualenv 'no' --pip-packages 'websockify pyxdg numpy' --log-level 'WARN'

Notes:
	Run 'cd <install path>/env && source ./bin/activate' to activate virtualenv.

ENDHELP
}

while [ "$#" != "0" ]
do
	case "$1"
	in
		-cv|--create-virtualenv)
			create_virtualenv=$2
			shift
			;;
		-rq|--install-path)
			install_path=$2
			shift
			;;
		-pp|--pip-packages)
			pip_packages=$2
			shift
			;;
		-ll|--log-level)
			log_level=$2
			shift
			;;
		-h|--help)
			show_help
			exit 0
			;;
		*)
			echo "[WARN] Unrecognised argument '$1', displaying help..." >&2
			echo ""
			show_help
			exit 1
			;;
	esac
	shift
done

# verify required options specified
if [[ -z "${pip_packages}" || "${create_virtualenv}" == "yes" ]]; then

	if [[ -z "${install_path}" ]]; then
		logger "Install path not specified, showing help..." "WARN"
		show_help
		exit 1
	fi

fi

pip_install