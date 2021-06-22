#!/bin/bash

# logger function
source '/usr/local/bin/utils.sh'

# check path param exists
if [[ -z "${1}" ]]; then
    logger "First parameter for path not defined" "ERROR"
fi

install_path="${1}"

# check path exists
if [[ ! -d "${install_path}" ]]; then
    logger "Path '${install_path}' does not exist" "ERROR"
fi

# define pacman packages
pacman_packages="python python-pip"

# install compiled packages using pacman
if [[ ! -z "${pacman_packages}" ]]; then
    pacman -S --needed $pacman_packages --noconfirm
fi

cd "${install_path}" || logger "Cannot change to path '${install_path}'" "ERROR"

# install virtualenv, create env and activate
python3 -m pip install --user virtualenv
python3 -m venv env
source "${install_path}/env/bin/activate"

# install python modules as per requirements.txt in virtualenv
pip install -r "${install_path}/requirements.txt"

# install required packages
pip install -r requirements.txt

logger "Please specify 'cd ${install_path} && source './env/bin/activate' && python3 ${install_path}/<name of python script> <options...>' as commonad to run" "INFO"
