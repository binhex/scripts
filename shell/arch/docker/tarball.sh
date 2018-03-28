#!/bin/bash

# bash script to be run either on a linux host or inside an already created arch
# linux docker container (arch-devel).

# fail fast
set -e

# get required tooling to create root tarball
pacman -S wget tar --noconfirm

# define path to extract to
bootstrap_extract_path="/tmp/extract"

# define archlinux download site
archlinux_download_site="https://archive.archlinux.org"

# define date of bootstrap tarball to download (constructed from current '<year>.<month>.01'
bootstrap_date=$(date '+%Y.%m.01')

# define today's date, used for filename for root tarball we create
todays_date=$(date +%Y-%m-%d)

# define input tarball filename
bootstrap_gzip_tarball="archlinux-bootstrap.tar.gz"

# define path to extract to
tarball_output_path="/cache/appdata"

# define output tarball filename
tarball_output_file="arch-root.tar.bz2"

# remove previously created root tarball (if it exists)
rm "${tarball_output_file}" || true

# remove previously created extraction folder (if it exists)
rm "${bootstrap_extract_path}" || true

# create extraction path
mkdir -p "${bootstrap_extract_path}"; cd "${bootstrap_extract_path}"

# download bootstrap gzipped tarball from arch linux using wildcards
wget -r --no-parent -nH --cut-dirs=3 -e robots=off --reject "index.html" "${archlinux_download_site}/iso/${bootstrap_date}/" -A "archlinux-bootstrap*.tar.gz"

# rename gzipped tarball to known filename
mv archlinux-bootstrap*.tar.gz "${bootstrap_gzip_tarball}"

# identify if bootstrap gzipped tarball has top level folder, if so we need to remove it
tar -tf "${bootstrap_gzip_tarball}" | head

# extract gzipped tarball to remove top level folder 'root.x86_64'
tar -xvf "${bootstrap_gzip_tarball}" --strip 1

# remove downloaded tarball to prevent inclusion in new root tarball
rm -rf "${bootstrap_gzip_tarball}"

# remove empty folder from /
rm -rf ./x86_64 || true

# create text file detailing build date
echo "bootstrap tarball creation date: ${bootstrap_date}" >> ./build.txt
echo "root tarball creation date: $(date)" >> ./build.txt

# tar and bz2 compress again, excluding folders we dont require for docker usage
tar -cvpjf "${tarball_output_path}/${tarball_output_file}" --exclude=./ext --exclude=./etc/hosts --exclude=./etc/hostname --exclude=./etc/resolv.conf --exclude=./sys --exclude=./usr/share/man --exclude=./usr/share/gtk-doc --exclude=./usr/share/doc --exclude=./usr/share/locale --one-file-system .

# remove extracted folder to tidy up after tarball creation
rm -rf "${bootstrap_extract_path}"

# remove previously uploaded tarball "asset" from github

# upload new tarball 'asset' to github for use in arch-scratch (ensure tag is 'latest')

echo "bootstrap tarball created at ${tarball_output_path}/${tarball_output_file}"