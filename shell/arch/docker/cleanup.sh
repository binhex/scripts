#!/bin/bash

# identify if base-devel package installed
if pacman -Qg "base-devel" > /dev/null ; then

	# remove base devel excluding useful core packages
	pacman -Ru $(pacman -Qgq base-devel | grep -v awk | grep -v pacman | grep -v sed | grep -v grep | grep -v gzip | grep -v which | grep -v patch) --noconfirm

fi

# remove any build tools that maybe present from the build
pacman -Ru dotnet-sdk yarn git yay-bin reflector gcc binutils --noconfirm 2> /dev/null || true

# remove any cached packages that maybe present from the build
rm -rf /home/nobody/.nuget/
 
# general cleanup
yes|pacman -Scc
pacman --noconfirm -Rns $(pacman -Qtdq) 2> /dev/null || true
rm -rf /var/cache/* \
/var/empty/.cache/* \
/usr/share/locale/* \
/usr/share/man/* \
/usr/share/gtk-doc/* \
/tmp/*
