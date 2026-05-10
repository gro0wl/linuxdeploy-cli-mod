#!/bin/sh
# Linux Deploy Component
# (c) Linux Deploy Mod contributors, GPLv3

do_configure()
{
    msg ":: Configuring ${COMPONENT} ... "
    mkdir -p "${CHROOT_DIR}/run" "${CHROOT_DIR}/run/lock" "${CHROOT_DIR}/tmp"
    chmod 755 "${CHROOT_DIR}/run" "${CHROOT_DIR}/run/lock"
    chmod 1777 "${CHROOT_DIR}/tmp"
    chroot_exec -u root "systemd-machine-id-setup 2>/dev/null || dbus-uuidgen --ensure=/etc/machine-id 2>/dev/null || true"
    is_ok "fail" "done"
}

do_start()
{
    msg -n ":: Starting ${COMPONENT} ... "
    chroot_exec -u root "mkdir -p /run /run/lock /tmp; chmod 1777 /tmp; systemd-tmpfiles --create --boot 2>/dev/null || true; dbus-uuidgen --ensure 2>/dev/null || true; service dbus start 2>/dev/null || /etc/init.d/dbus start 2>/dev/null || true"
    is_ok "fail" "done"
    msg "systemd is not PID 1 in Android chroot; this mode prepares systemd-compatible runtime files and dbus."
    return 0
}

do_stop()
{
    msg -n ":: Stopping ${COMPONENT} ... "
    chroot_exec -u root "service dbus stop 2>/dev/null || /etc/init.d/dbus stop 2>/dev/null || true"
    is_ok "fail" "done"
    return 0
}

do_status()
{
    msg -n ":: ${COMPONENT} ... "
    if [ -e "${CHROOT_DIR}/etc/machine-id" ] && [ -d "${CHROOT_DIR}/run" ]; then
        msg "prepared"
    else
        msg "not prepared"
    fi
}

do_help()
{
cat <<EOF
   systemd compatibility mode prepares /run, machine-id, tmpfiles and dbus.
   Android chroot does not run systemd as PID 1; use a VM/proot namespace layer for real systemd.

EOF
}
