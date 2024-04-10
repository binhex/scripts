#!/bin/bash

# set defaults
defaultLogLevel="WARN"
defaultCreateVirtualenv="yes"
defaultVirtualenvPath="$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')/venv"

log_level="${defaultLogLevel}"
create_virtualenv="${defaultCreateVirtualenv}"
virtualenv_path="${defaultVirtualenvPath}"

# logger function
source '/usr/local/bin/utils.sh'

function virtualenv() {

	if [[ "${create_virtualenv}" == "yes" ]]; then

		if [[ ! -f "${virtualenv_path}/bin/activate" ]]; then

			logger "Creating virtualenv at location '${virtualenv_path}'" "INFO"

			# install virtualenv and create virtualenv
			python3 -m pip install --user virtualenv
			python3 -m venv "${virtualenv_path}"

		else

			logger "Skipping creation of virtualenv for location '${virtualenv_path}' as it already exists" "INFO"

		fi

		logger "Activating virtualenv at location '${virtualenv_path}/bin/activate'" "INFO"
		source "${virtualenv_path}/bin/activate"

	fi

}

function pip_install() {

	# define pacman packages
	pacman_packages="python curl python-pip"

	# install compiled packages using pacman
	if [[ -n "${pacman_packages}" ]]; then
		pacman -S --needed ${pacman_packages} --noconfirm
	fi

	# # compile pip from source, fixes issue https://github.com/pypa/pip/issues/9348
	# curl -L https://bootstrap.pypa.io/get-pip.py | python --break-system-packages

	# # force upgrade/install of setuptools, fixes issue https://github.com/pypa/packaging-problems/issues/573
	# pip install --upgrade setuptools

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

		if [[ -n "${package_constraints}" ]]; then

			logger "Package constraints defined as '${package_constraints}', writing to file '${install_path}/constraints.txt'" "INFO"
			for package_constraint in ${package_constraints}; do
				echo "${package_constraint}" >> "${install_path}/constraints.txt"
			done
			pip install --break-system-packages -r "${install_path}/requirements.txt" -c "${install_path}/constraints.txt"

		else

			# install python modules as per requirements.txt in virtualenv
			pip install --break-system-packages -r "${install_path}/requirements.txt"

		fi

	else

		virtualenv

		logger "Installing Python package(s) '${pip_packages}'" "INFO"

		# install python package in virtualenv
		pip install --break-system-packages -U ${pip_packages}

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

	-pc or --package-constraints <package names and versions>
		Define whether to constraint python packages to a specified version, package constraints can be a space seperated list.
		No default.

	-vp or --virtualenv-path <path>
		Define path to create for virtualenv.
		Defaults to '${defaultVirtualenvPath}'.

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

	Install Python modules specified in requirements.txt file to virtualenv with specific path:
		./pip.sh --create-virtualenv 'yes' --install-path '/opt/sickchill' --virtualenv-path '/opt/sickchill/env' --log-level 'WARN'

	Install Python modules specified in requirements.txt file with constraints on the cython package to virtualenv with specific path:
		./pip.sh --create-virtualenv 'yes' --install-path '/opt/sickchill' --package-constraints 'cython<3' --virtualenv-path '/opt/sickchill/env' --log-level 'WARN'

	Install specific Python modules to virtualenv with the default path (--install-path/env/):
		./pip.sh --create-virtualenv 'yes' --install-path '/opt/sickchill' --pip-packages 'websockify pyxdg numpy' --log-level 'WARN'

	Install specific Python modules to system:
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
		-pc|--package-constraints)
			package_constraints=$2
			shift
			;;
		-vp|--virtualenv-path)
			virtualenv_path=$2
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
if [[ -z "${pip_packages}" ]]; then

	if [[ -z "${install_path}" ]]; then
		logger "Install path not specified, showing help..." "WARN"
		show_help
		exit 1
	fi

fi

pip_install