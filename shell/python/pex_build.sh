#!/bin/bash

set -e

# ensure we are out of any current venv
deactivate || true

# clear down last pex build history
rm -rf ~/.pex

# platform architecture
arch="64"

# python app name
app_name="MovieGrabber-linux${arch}"

# generate path for virtualenv
venv_path="/tmp/venv"

# pex output path
pex_output_path="/tmp/venv"

# generate path for requirements.txt
requirements_path="/tmp"

# remove previous pex package
rm -rf "${pex_output_path}/${app_name}.pex"

# run virtualenv
virtualenv -p python2 "${venv_path}"

# activate new virtualenv environment (gives you access to pip in virtual env)
source "${venv_path}/bin/activate"

# pip install pex
"${venv_path}/bin/pip" install pex

# create pex requirements package for application
pex -r "${requirements_path}"/requirements.txt -o "${pex_output_path}/${app_name}.pex"

# ensure we are now exit current venv
deactivate || true

echo "Now use the pex package by executing '${pex_output_path}/${app_name}.pex ./${app_name}.py'"