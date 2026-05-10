#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3

do_install()
{
    msg ":: Installing ${COMPONENT} ... "
    local packages=""
    case "${DISTRIB}:${ARCH}:${SUITE}" in
    debian:*|ubuntu:*|kali:*)
        packages="desktop-base dbus-x11 x11-xserver-utils xfonts-base xfonts-utils gnome-core gnome-terminal"
        apt_install ${packages}
    ;;
    archlinux:*)
        packages="xorg-xauth xorg-fonts-misc ttf-dejavu gnome gnome-terminal"
        pacman_install ${packages}
    ;;
    fedora:*)
        packages="xorg-x11-server-utils xorg-x11-fonts-misc dejavu-* @gnome-desktop"
        dnf_install ${packages}
    ;;
    esac
}

do_configure()
{
    msg ":: Configuring ${COMPONENT} ... "
    local xsession="${CHROOT_DIR}$(user_home ${USER_NAME})/.xsession"
    echo 'export XDG_SESSION_TYPE=x11' > "${xsession}"
    echo 'export GNOME_SHELL_SESSION_MODE=classic' >> "${xsession}"
    echo 'exec dbus-launch --exit-with-session gnome-session --session=gnome-classic' >> "${xsession}"
    return 0
}
