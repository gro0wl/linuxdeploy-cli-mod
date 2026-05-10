#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3

do_install()
{
    msg ":: Installing ${COMPONENT} ... "
    local packages=""
    case "${DISTRIB}:${ARCH}:${SUITE}" in
    debian:*|ubuntu:*|kali:*)
        packages="desktop-base dbus-x11 x11-xserver-utils xfonts-base xfonts-utils gnome-core gnome-terminal gnome-session-flashback metacity gnome-panel adwaita-icon-theme"
        apt_install ${packages}
    ;;
    archlinux:*)
        packages="xorg-xauth xorg-fonts-misc ttf-dejavu gnome gnome-terminal gnome-flashback metacity"
        pacman_install ${packages}
    ;;
    fedora:*)
        packages="xorg-x11-server-utils xorg-x11-fonts-misc dejavu-* @gnome-desktop gnome-flashback metacity"
        dnf_install ${packages}
    ;;
    esac
}

do_configure()
{
    msg ":: Configuring ${COMPONENT} ... "
    local xsession="${CHROOT_DIR}$(user_home ${USER_NAME})/.xsession"
    cat > "${xsession}" <<EOF
#!/bin/sh
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=GNOME-Flashback:GNOME
export GNOME_SHELL_SESSION_MODE=gnome-flashback-metacity
export NO_AT_BRIDGE=1

exec >>"\${HOME}/.xsession-errors" 2>&1
echo "Starting GNOME session: \$(date)"

if command -v gnome-session >/dev/null 2>&1; then
    exec dbus-launch --exit-with-session gnome-session --session=gnome-flashback-metacity
fi

if command -v gnome-panel >/dev/null 2>&1 && command -v metacity >/dev/null 2>&1; then
    metacity --replace &
    exec gnome-panel
fi

if command -v xterm >/dev/null 2>&1; then
    exec xterm
fi

exit 1
EOF
    chmod 755 "${xsession}"
    chroot_exec -u root chown "${USER_NAME}:${USER_NAME}" "$(user_home ${USER_NAME})/.xsession"
    return 0
}
