#!/bin/bash

# identify if base-devel package installed
if pacman -Qg "base-devel" > /dev/null ; then

	# remove base devel excluding useful core packages
	pacman -Ru $(pacman -Qgq base-devel | grep -v awk | grep -v pacman | grep -v sed | grep -v grep | grep -v gzip | grep -v which | grep -v patch) --noconfirm

fi

# remove any build tools that maybe present from the build
pacman -Ru dotnet-sdk yarn git github-cli yay-bin reflector gcc binutils rust clank go --noconfirm 2> /dev/null || true

# delete cache and build home directories
rm -rf /home/nobody/.cache/paru /home/nobody/.cache/yarn /home/nobody/.cargo /home/nobody/.dotnet /home/nobody/.nuget /home/nobody/.rustup /home/nobody/.yarn

# general cleanup
yes|pacman -Scc
pacman --noconfirm -Rns $(pacman -Qtdq) 2> /dev/null || true
rm -rf /var/cache/* \
/var/empty/.cache/* \
/usr/share/locale/* \
/usr/share/man/* \
/usr/share/gtk-doc/* \
/tmp/*