#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3

[ -n "${XRDP_PORT}" ] || XRDP_PORT="3389"

do_install()
{
    msg ":: Installing ${COMPONENT} ... "
    local packages=""
    case "${DISTRIB}:${ARCH}:${SUITE}" in
    debian:*|ubuntu:*|kali:*)
        packages="xrdp xorgxrdp"
        apt_install ${packages}
    ;;
    archlinux:*)
        packages="xrdp"
        pacman_install ${packages}
    ;;
    fedora:*)
        packages="xrdp xorgxrdp"
        dnf_install ${packages}
    ;;
    centos:*)
        packages="xrdp"
        yum_install ${packages}
    ;;
    esac
}

do_configure()
{
    msg ":: Configuring ${COMPONENT} ... "
    local xrdp_dir="${CHROOT_DIR}/etc/xrdp"
    [ -d "${xrdp_dir}" ] || mkdir -p "${xrdp_dir}"

    if [ -e "${xrdp_dir}/xrdp.ini" ]; then
        sed -i "s/^port=.*/port=${XRDP_PORT}/" "${xrdp_dir}/xrdp.ini"
    fi

    cat > "${xrdp_dir}/startwm.sh" <<EOF
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec ~/.xsession
EOF
    chmod 755 "${xrdp_dir}/startwm.sh"
    return 0
}

do_start()
{
    msg -n ":: Starting ${COMPONENT} ... "
    is_stopped /var/run/xrdp.pid
    is_ok "skip" || return 0
    remove_files /var/run/xrdp.pid /var/run/xrdp-sesman.pid
    chroot_exec -u root xrdp-sesman
    chroot_exec -u root xrdp
    is_ok "fail" "done"
    return 0
}

do_stop()
{
    msg -n ":: Stopping ${COMPONENT} ... "
    kill_pids /var/run/xrdp.pid /var/run/xrdp-sesman.pid
    is_ok "fail" "done"
    return 0
}

do_status()
{
    msg -n ":: ${COMPONENT} ... "
    is_started /var/run/xrdp.pid
    is_ok "stopped" "started"
    return 0
}

do_help()
{
cat <<EOF
   --xrdp-port="${XRDP_PORT}"
     TCP port of XRDP server, default 3389.

EOF
}
