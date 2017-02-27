#!/bin/bash

# This file is meant as a metadata store for all docker containers in the binhex repo.
# We use percent to seperate lines, and use tilda to seperate items in the line.

#
# common

common_support_all="\
  http://lime-technology.com/forum/index.php?topic"

common_variable_vpn="\
  VPN_ENABLED~yes|no~Toggle VPN%\
  VPN_USER~vpn_user~VPN provider username%\
  VPN_PASS~vpn_pass~VPN provider password%\
  VPN_REMOTE~nl.privateinternetaccess.com~VPN provider remote endpoint%\
  VPN_PORT~1198~VPN provider remote port%\
  VPN_PROTOCOL~udp|tcp~VPN provider remote protocol%\
  VPN_DEVICE_TYPE~tun|tap~VPN provider device type%\
  VPN_PROV~pia|airvpn|custom~VPN provider selection%\
  STRONG_CERTS~no|yes~VPN provider strong certificate support (PIA only)%\
  VPN_OPTIONS~~OpenVPN additional command line options%\
  ENABLE_PRIVOXY~no|yes~Toggle Privoxy (web proxy)%\
  LAN_NETWORK~192.168.1.0/24~Define LAN network in CIDR format%\
  NAME_SERVERS~8.8.8.8,37.235.1.174,8.8.4.4,37.235.1.177~Name Servers used for name resolution inside the container%\
  DEBUG~no|yes~Toggle additional debugging (useful when having issues)%\
  PUID~99~UID of the user that the container will run as%\
  PGID~100~GID of the user that the container will run as"

common_variable_all="\
  PUID~99~UID of the user that the container will run as%\
  PGID~100~GID of the user that the container will run as"

common_path_downloader="\
  /mnt/cache/appdata/config~/config~rw~Configuration Path%\
  /mnt/cache/appdata/data~/data~rw~Downloads Path"

common_path_player="\
  /mnt/cache/appdata/config~/config~rw~Configuration Path%\
  /mnt/cache/appdata/data~/data~rw~Downloads Path%\
  /mnt/user~/media~rw~Media Path"

#
# define name of container
container="couchpotato"

declare "${container}_name"="\
  ${container}"
declare "${container}_repo"="\
  arch-${container}"
declare "${container}_support"="\
  ${common_support_all}=45837.0"
declare "${container}_project"="\
  https://couchpota.to/"
declare "${container}_category"="\
  Downloaders: HomeAutomation: MediaApp:Video Status:Stable"
declare "${container}_mode"="\
  bridge"
declare "${container}_privileged"="\
  false"
declare "${container}_webui"="\
  http://[IP]:[PORT:5050]/"
declare "${container}_path"="\
  ${common_path_downloader}"
declare "${container}_variable"="\
  ${common_variable_all}"
declare "${container}_port"="\
  5050~tcp~Couchpotato WebUI Port"
declare "${container}_description"="\
  CouchPotato (CP) is an automatic NZB and torrent downloader. You can keep a \
  'movies I want'-list and it will search for NZBs/torrents of these movies \
  every X hours. Once a movie is found, it will send it to SABnzbd or \
  download the torrent to a specified directory."
declare "${container}_params"=""

#
# define name of container
container="couchpotato-git"

declare "${container}_name"="\
  ${container}"
declare "${container}_repo"="\
  arch-${container}"
declare "${container}_support"="\
  ${common_support_all}=45837.0"
declare "${container}_project"="\
  https://couchpota.to/"
declare "${container}_category"="\
  Downloaders: HomeAutomation: MediaApp:Video Status:Stable"
declare "${container}_mode"="\
  bridge"
declare "${container}_privileged"="\
  false"
declare "${container}_webui"="\
  http://[IP]:[PORT:5050]/"
declare "${container}_path"="\
  ${common_path_downloader}"
declare "${container}_variable"="\
  ${common_variable_all}"
declare "${container}_port"="\
  5050~tcp~Couchpotato WebUI Port"
declare "${container}_description"="\
  CouchPotato (CP) is an automatic NZB and torrent downloader. You can keep a \
  'movies I want'-list and it will search for NZBs/torrents of these movies \
  every X hours. Once a movie is found, it will send it to SABnzbd or \
  download the torrent to a specified directory."
declare "${container}_params"=""

#
# define name of container
container="deluge"

declare "${container}_name"="\
  ${container}"
declare "${container}_repo"="\
  arch-${container}"
declare "${container}_support"="\
  ${common_support_all}=45820.0"
declare "${container}_project"="\
  http://deluge-torrent.org/"
declare "${container}_category"="\
  Downloaders: HomeAutomation: MediaApp:Video Status:Stable"
declare "${container}_mode"="\
  bridge"
declare "${container}_privileged"="\
  false"
declare "${container}_webui"="\
  http://[IP]:[PORT:8112]/"
declare "${container}_path"="\
  ${common_path_downloader}"
declare "${container}_variable"="\
  ${common_variable_all}"
declare "${container}_port"="\
  8112~tcp~Deluge WebUI Port%\
  58846~tcp~Deluge Daemon Port%\
  58946~tcp~Deluge Incoming Port"
declare "${container}_description"="\
  Deluge is a full-featured ​BitTorrent client for Linux, OS X, Unix and Windows. It uses \
  ​libtorrent in its backend and features multiple user-interfaces including: GTK+, web and console. It has \
  been designed using the client server model with a daemon process that handles all the bittorrent activity. \
  The Deluge daemon is able to run on headless machines with the user-interfaces being able to connect remotely \
  from any platform. This Docker includes OpenVPN to ensure a secure and private connection to the Internet, \
  including use of iptables to prevent IP leakage when the tunnel is down. It also includes Privoxy to allow \
  unfiltered access to index sites, to use Privoxy please point your application at 'host ip:8118'"
declare "${container}_params"=""

#
# define name of container
container="delugevpn"

declare "${container}_name"="\
  ${container}"
declare "${container}_repo"="\
  arch-${container}"
declare "${container}_support"="\
  ${common_support_all}=45812.0"
declare "${container}_project"="\
  http://deluge-torrent.org/"
declare "${container}_category"="\
  Downloaders: HomeAutomation: MediaApp:Video Status:Stable"
declare "${container}_mode"="\
  bridge"
declare "${container}_privileged"="\
  true"
declare "${container}_webui"="\
  http://[IP]:[PORT:8112]/"
declare "${container}_path"="\
  ${common_path_downloader}"
declare "${container}_variable"="\
  ${common_variable_vpn}"
declare "${container}_port"="\
  8112~tcp~Deluge WebUI Port%\
  58846~tcp~Deluge Daemon Port%\
  58946~tcp~Deluge Incoming Port%\
  8118~tcp~Privoxy Port"
declare "${container}_description"="\
  Deluge is a full-featured ​BitTorrent client for Linux, OS X, Unix and Windows. It uses \
  ​libtorrent in its backend and features multiple user-interfaces including: GTK+, web and console. It has \
  been designed using the client server model with a daemon process that handles all the bittorrent activity. \
  The Deluge daemon is able to run on headless machines with the user-interfaces being able to connect remotely \
  from any platform. This Docker includes OpenVPN to ensure a secure and private connection to the Internet, \
  including use of iptables to prevent IP leakage when the tunnel is down. It also includes Privoxy to allow \
  unfiltered access to index sites, to use Privoxy please point your application at 'host ip:8118'"
declare "${container}_params"=""