#!/bin/bash

# exit on non zero exit code
set -e

# set defaults
defaultLogLevel="info"
defaultCreateVirtualenv="no"
defaultCreatePyEnv="no"
defaultVirtualenvPath="/usr/local/lib/venv"
defaultPyEnvPath="/usr/local/lib/pyenv"
defaultPyEnvVersion="3.12"

log_level="${defaultLogLevel}"
create_virtualenv="${defaultCreateVirtualenv}"
create_pyenv="${defaultCreatePyEnv}"
virtualenv_path="${defaultVirtualenvPath}"
pyenv_path="${defaultPyEnvPath}"
pyenv_version="${defaultPyEnvVersion}"

# source logging functions
if [[ -f "$(pwd)/utils.sh" ]]; then
	# shellcheck disable=SC1091
	source "$(pwd)/utils.sh"
elif [[ -f '/usr/local/bin/utils.sh' ]]; then
	# shellcheck disable=SC1091
	source '/usr/local/bin/utils.sh'
else
	echo "[ERROR] Unable to locate 'utils.sh' script (used for logging function), exiting..." >&2
	exit 1
fi

function create_pyenv() {

	if [[ "${create_pyenv}" == "no" ]]; then
		shlog 1 "-cpe or --create-pyenv set to 'no', skipping..."
		return 0
	fi

	if [[ "${create_pyenv}" == "yes" ]]; then

		# define pacman packages
		pacman_packages="pyenv"

		# install compiled packages using pacman
		if [[ -n "${pacman_packages}" ]]; then
			pacman -S --needed ${pacman_packages} --noconfirm
		fi

		# define path to version of python to be installed via pyenv
		export PYENV_ROOT="${pyenv_path}"

		# install python version using pyenv
		pyenv install "${pyenv_version}"

		# activate pyenv
		eval "$(pyenv init --path)"

		# activate python version
		pyenv global "${pyenv_version}"

	fi

}

function create_virtualenv() {

	if [[ "${create_virtualenv}" == "no" ]]; then
		shlog 1 "-cve or --create-virtualenv set to 'no', skipping..."
		return 0
	fi

	if [[ ! -f "${virtualenv_path}/bin/activate" ]]; then

		shlog 1 "Creating virtualenv at location '${virtualenv_path}'..."

		mkdir -p "${virtualenv_path}"

		# install virtualenv and create virtualenv
		python3 -m pip install --user virtualenv --break-system-packages
		python3 -m venv "${virtualenv_path}"

	else

		shlog 1 "Skipping creation of virtualenv for location '${virtualenv_path}/bin/activate' as it already exists"

	fi

	shlog 1 "Activating virtualenv at location '${virtualenv_path}/bin/activate'"
	# shellcheck disable=SC1091
	source "${virtualenv_path}/bin/activate"

}

function install_requirements() {

	if [[ -z "${requirements_path}" ]]; then
		shlog 1 "-rp or --requirements-path not defined, skipping..."
		return 0
	fi

	if [[ ! -f "${requirements_path}/requirements.txt" ]]; then
		shlog 2 "Path to requirements.txt '${requirements_path}/requirements.txt' does not exist, showing help..."
		show_help
		return 1
	fi

	shlog 1 "Installing Python pre-requisites via requirements.txt file '${requirements_path}/requirements.txt'"

	if [[ -n "${package_constraints}" ]]; then

		shlog 1 "Package constraints defined as '${package_constraints}', writing to file '${requirements_path}/constraints.txt'"
		for package_constraint in ${package_constraints}; do
			echo "${package_constraint}" >> "${requirements_path}/constraints.txt"
		done
		pip install --break-system-packages -r "${requirements_path}/requirements.txt" -c "${requirements_path}/constraints.txt"

	else

		# install python modules as per requirements.txt in virtualenv
		pip install --break-system-packages -r "${requirements_path}/requirements.txt"

	fi

}

function install_pip() {

	if [[ -z "${pip_packages}" ]]; then
		shlog 1 "--pp or --pip-packages not defined, skipping..."
		return 0
	fi

	# define pacman packages
	pacman_packages="python-pip"

	# install compiled packages using pacman
	if [[ -n "${pacman_packages}" ]]; then
		pacman -S --needed ${pacman_packages} --noconfirm
	fi

	if [[ -n "${requirements_path}" ]]; then

		# create install path to store virtualenv and python modules
		mkdir -p "${requirements_path}" && cd "${requirements_path}" || exit 1

	fi

	# ensure we have required tooling for pip, may not always be required
	pip install setuptools --break-system-packages

	shlog 1 "Installing Python package(s) '${pip_packages}'"

	# install python package in virtualenv
	pip install --break-system-packages -U ${pip_packages}

}

function main() {

	# install pyenv if required
	create_pyenv

	# create virtualenv so we do not conflict with system packages
	create_virtualenv

	# install python modules as per requirements.txt
	install_requirements

	# install python modules
	install_pip

}

function show_help() {
	cat <<ENDHELP
Description:
	A script to perform multiple Python functions:
		- Create and activate specified version of Python using PyEnv.
		- Create and activate a sandbox Python environment using virtualenv.
		- Install Python modules as per requirements.txt file.
		- Install specific Python modules via pip.

Syntax:
	./python.sh [args]

Where:
	-h or --help
		Displays this text.

	-cpe or --create-pyenv <yes|no>
		Define whether to create and use pyenv.
		Defaults to '${defaultCreatePyEnv}'.

	-cve or --create-virtualenv <yes|no>
		Define whether to create and use virtualenv.
		Defaults to '${defaultCreateVirtualenv}'.

	-pev or --pyenv-version <python version>
		Define python version to install using pyenv.
		Defaults to '${defaultPyEnvVersion}'.

	-pep or --pyenv-path <pyenv version path>
		Define path to pyenv version.
		Defaults to '${defaultPyEnvPath}'.

	-vep or --virtualenv-path <path>
		Define path to create for virtualenv.
		Defaults to '${defaultVirtualenvPath}'.

	-rp or --requirements-path <path>
		Define path to 'requirements.txt'.
		No default.

	-pc or --package-constraints <package names and versions>
		Define whether to constraint python packages to a specified version, package constraints can be a space seperated list.
		No default.

	-pp or --pip-paackages <package names>
		Define specified packages to install via pip.
		No default.

	-ll or --log-level <debug|info|warn|error>
		Define logging level.
		Defaults to '${defaultLogLevel}'.

Examples:
	Install Python version 3.12 (latest) using pyenv, create virtual environment and install Python module 'sickchill' using pip:
		./python.sh --create-virtualenv 'yes' --create-pyenv 'yes' --pyenv-version '3.12' --pip-packages 'sickchill' --log-level 'info'

	Install Python version 3.12 (latest) using pyenv, create virtual environment at location /tmp using virtualenv and install Python modules specified in requirements.txt file:
		./python.sh --create-virtualenv 'yes' --create-pyenv 'yes' --pyenv-version '3.12' --pyenv-path '/tmp' --requirements-path '/opt/sickchill' --log-level 'info'

	Install Python version 3.12.7 (specific) using pyenv, create virtual environment at location /tmp using virtualenv, install Python modules specified in requirements.txt file and specify package constraints for cython to less than v3:
		./python.sh --create-virtualenv 'yes' --create-pyenv 'yes' --pyenv-version '3.12.7' --pyenv-path '/tmp' --requirements-path '/opt/sickchill' --package-constraints 'cython<3' --log-level 'info'

	Install Python version 3.12 (latest) using pyenv, create virtual environment at location /tmp using virtualenv, and install Python module 'sickchill' using pip:
		./python.sh --create-virtualenv 'yes' --create-pyenv 'yes' --pyenv-version '3.12' --pyenv-path '/tmp' --pip-packages 'sickchill' --log-level 'info'

	Install Python modules specified in requirements.txt file to Python system:
		./python.sh --create-virtualenv 'no' --requirements-path '/opt/sickchill' --log-level 'info'

	Install specific Python modules to Python system:
		./python.sh --create-virtualenv 'no' --pip-packages 'websockify pyxdg numpy' --log-level 'info'

ENDHELP
}

while [ "$#" != "0" ]
do
	case "$1"
	in
		-cpe|--create-pyenv)
			create_pyenv=$2
			shift
			;;
		-pev|--pyenv-version)
			pyenv_version=$2
			shift
			;;
		-pep|--pyenv-path)
			pyenv_path=$2
			shift
			;;
		-cve|--create-virtualenv)
			create_virtualenv=$2
			shift
			;;
		-vep|--virtualenv-path)
			virtualenv_path=$2
			shift
			;;
		-rp|--requirements-path)
			requirements_path=$2
			shift
			;;
		-pc|--package-constraints)
			package_constraints=$2
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

main