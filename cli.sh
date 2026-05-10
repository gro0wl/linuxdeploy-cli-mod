#!/bin/bash
################################################################################
#
# Linux Deploy CLI
# (C) 2012-2019 Anton Skshidlevsky <meefik@gmail.com>, GPLv3
#
################################################################################

VERSION="2.5.1"

################################################################################
# Common
################################################################################

msg()
{
    echo "$@"
}

is_ok()
{
    if [ $? -eq 0 ]; then
        if [ -n "$2" ]; then
            msg "$2"
        fi
        return 0
    else
        if [ -n "$1" ]; then
            msg "$1"
        fi
        return 1
    fi
}

get_platform()
{
    local arch="$1"
    if [ -z "${arch}" ]; then
        arch=$(uname -m)
    fi
    case "${arch}" in
    arm64|aarch64)
        echo "arm_64"
    ;;
    arm*)
        echo "arm"
    ;;
    x86_64|amd64)
        echo "x86_64"
    ;;
    i[3-6]86|x86)
        echo "x86"
    ;;
    *)
        echo "unknown"
    ;;
    esac
}

get_uuid()
{
    cat /proc/sys/kernel/random/uuid
}

multiarch_support()
{
    if [ -d "/proc/sys/fs/binfmt_misc" ]; then
        return 0
    else
        return 1
    fi
}

selinux_inactive()
{
    if [ -e "/sys/fs/selinux/enforce" ]; then
        return $(cat /sys/fs/selinux/enforce)
    else
        return 0
    fi
}

loop_support()
{
    if [ -n "$(losetup -f)" ]; then
        return 0
    else
        return 1
    fi
}

user_home()
{
    [ -e "${CHROOT_DIR}/etc/passwd" ] || return 1
    local user_name="$1"
    [ -n "${user_name}" ] || return 1
    echo $(grep -m1 "^${user_name}:" "${CHROOT_DIR}/etc/passwd" | awk -F: '{print $6}')
}

user_shell()
{
    [ -e "${CHROOT_DIR}/etc/passwd" ] || return 1
    local user_name="$1"
    [ -n "${user_name}" ] || return 1
    echo $(grep -m1 "^${user_name}:" "${CHROOT_DIR}/etc/passwd" | awk -F: '{print $7}')
}

is_mounted()
{
    local mount_point="$1"
    [ -n "${mount_point}" ] || return 1
    if $(grep -q " ${mount_point%/} " /proc/mounts); then
        return 0
    else
        return 1
    fi
}

is_archive()
{
    local src="$1"
    [ -n "${src}" ] || return 1
    if [ -z "${src##*gz}" -o -z "${src##*bz2}" -o -z "${src##*xz}" ]; then
        return 0
    fi
    return 1
}

get_pids()
{
    local pid pidfile pids
    for pid in $*
    do
        pidfile="${CHROOT_DIR}${pid}"
        if [ -e "${pidfile}" ]; then
            pid=$(cat "${pidfile}")
        fi
        if [ -e "/proc/${pid}" ]; then
            pids="${pids} ${pid}"
        fi
    done
    if [ -n "${pids}" ]; then
        echo ${pids}
        return 0
    else
        return 1
    fi
}

is_started()
{
    get_pids $* >/dev/null
}

is_stopped()
{
    is_started $*
    test $? -ne 0
}

kill_pids()
{
    local pids=$(get_pids $*)
    if [ -n "${pids}" ]; then
        kill -9 ${pids}
        return $?
    fi
    return 0
}

remove_files()
{
    local item target
    for item in $*
    do
        target="${CHROOT_DIR}${item}"
        if [ -e "${target}" ]; then
            rm -f "${target}"
        fi
    done
    return 0
}

make_dirs()
{
    local item target
    for item in $*
    do
        target="${CHROOT_DIR}${item}"
        if [ -d "${target%/*}" -a ! -d "${target}" ]; then
            mkdir "${target}"
        fi
    done
    return 0
}

chroot_exec()
{
    unset TMP TEMP TMPDIR LD_PRELOAD LD_DEBUG
    local path="${PATH}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    if [ "$1" = "-u" ]; then
        local username="$2"
        shift 2
    fi
    case "${METHOD}" in
    chroot)
        if [ -n "${username}" ]; then
            if [ $# -gt 0 ]; then
                chroot "${CHROOT_DIR}" /bin/su - ${username} -c "$*"
            else
                chroot "${CHROOT_DIR}" /bin/su - ${username}
            fi
        else
            PATH="${path}" chroot "${CHROOT_DIR}" $*
        fi
    ;;
    proot)
        if [ -z "${PROOT_TMP_DIR}" ]; then
            export PROOT_TMP_DIR="${TEMP_DIR}"
        fi
        local mounts="-b /proc -b /dev -b /sys"
        if [ -n "${MOUNTS}" ]; then
            mounts="${mounts} -b ${MOUNTS// / -b }"
        fi
        local emulator
        if [ -n "${EMULATOR}" ]; then
            emulator="-q ${EMULATOR}"
        fi
        if [ -n "${username}" ]; then
            if [ $# -gt 0 ]; then
                proot -r "${CHROOT_DIR}" -w / ${mounts} ${emulator} -0 -l -e /bin/su - ${username} -c "$*"
            else
                proot -r "${CHROOT_DIR}" -w / ${mounts} ${emulator} -0 -l -e /bin/su - ${username}
            fi
        else
            PATH="${path}" proot -r "${CHROOT_DIR}" -w / ${mounts} ${emulator} -0 -l -e $*
        fi
    ;;
    esac
}

################################################################################
# Params
################################################################################

params_read()
{
    local conf_file="$1"
    [ -e "${conf_file}" ] || return 1
    local item key val
    while read item
    do
        key=$(echo ${item} | grep -o '^[0-9A-Z_]\{1,32\}')
        val=${item#${key}=}
        if [ -n "${key}" ]; then
            eval ${key}="${val}"
            if [ -n "${OPTLST##* ${key} *}" ]; then
                OPTLST="${OPTLST}${key} "
            fi
        fi
    done < ${conf_file}
}

params_write()
{
    local conf_file="$1"
    [ -n "${conf_file}" ] || return 1
    echo "# ${conf_file##*/} $(date '+%F %R')" > ${conf_file}
    local key val
    for key in ${OPTLST}
    do
        eval "val=\$${key}"
        if [ -n "${key}" -a -n "${val}" ]; then
            echo "${key}=\"${val}\"" >> ${conf_file}
        fi
    done
}

params_parse()
{
    OPTIND=1
    if [ $# -gt 0 ] ; then
        local item key val
        for item in "$@"
        do
            key=$(expr "${item}" : '--\([0-9a-z-]\{1,32\}=\{0,1\}\)' | sed 'y/-abcdefghijklmnopqrstuvwxyz/_ABCDEFGHIJKLMNOPQRSTUVWXYZ/')
            if [ -n "${key##*=*}" ]; then
                val="true"
            else
                key=${key%*=}
                val=$(expr "${item}" : '--[0-9a-z-]\{1,32\}=\(.*\)')
            fi
            if [ -n "${key}" ]; then
                eval ${key}=\"${val}\"
                let OPTIND=OPTIND+1
                if [ -n "${OPTLST##* ${key} *}" ]; then
                    OPTLST="${OPTLST}${key} "
                fi
            fi
        done
    fi
    #echo ${OPTLST} | tr ' ' '\n' | awk '!x[$0]++'
}

params_check()
{
    local params_list="$@"
    local key val params_lost
    for key in ${params_list}
    do
        eval "val=\$${key}"
        if [ -z "${val}" ]; then
            params_lost="${params_lost} ${key}"
        fi
    done
    if [ -n "${params_lost}" ]; then
        msg "Missing parameters:${params_lost}"
        return 1
    fi
    return 0
}


################################################################################
# Configs
################################################################################

config_which()
{
    local conf_file="$1"
    if [ -n "${conf_file}" ]; then
        if [ -n "${conf_file##*/*}" ]; then
            conf_file="${CONFIG_DIR}/${conf_file}.conf"
        fi
        echo "${conf_file}"
    fi
}

config_update()
{
    local source_conf="$1"; shift
    local target_conf="$1"; shift
    params_read "${source_conf}"
    params_parse "$@"
    params_write "${target_conf}"
}

config_list()
{
    local conf_file="$1"
    local conf
    for conf in $(ls "${CONFIG_DIR}/")
    do
        (
            unset DISTRIB ARCH SUITE INCLUDE
            . "${CONFIG_DIR}/${conf}"
            formated_desc=$(printf "%-15s %-10s %-10s %-10s %.30s\n" "${conf%.conf}" "${DISTRIB}" "${ARCH}" "${SUITE}" "${INCLUDE}")
            msg "${formated_desc}"
        )
    done
}

config_remove()
{
    local conf_file="$1"
    if [ -e "${conf_file}" ]; then
        rm -f "${conf_file}"
    else
        return 1
    fi
}

################################################################################
# Components
################################################################################

component_is_compatible()
{
    local target="$@"
    [ -n "${target}" ] || return 0
    local item
    for item in ${target}
    do
        case "${DISTRIB}:${ARCH}:${SUITE}" in
        ${item})
            return 0
        ;;
        esac
    done
    return 1
}

component_is_exclude()
{
    local component="$1"
    [ -n "${component}" ] || return 1
    for item in ${EXCLUDE_COMPONENTS}
    do
        case "${component}" in
        ${item}*)
            return 0
        ;;
        esac
    done
    return 1
}

component_depends()
{
    local components="$@"
    [ -n "${components}" ] || return 0
    local component conf_file TARGET DEPENDS
    for component in ${components}
    do
        component="${component%/}"
        # check deadlocks
        [ -z "${IGNORE_DEPENDS##* ${component} *}" ] && continue
        IGNORE_DEPENDS="${IGNORE_DEPENDS}${component} "
        # check component exist
        conf_file="${INCLUDE_DIR}/${component}/deploy.conf"
        [ -e "${conf_file}" ] || continue
        # read component variables
        eval $(grep -e '^TARGET=' -e '^DEPENDS=' "${conf_file}")
        # check compatibility
        if [ "${WITHOUT_CHECK}" != "true" ]; then
            component_is_compatible ${TARGET} || continue
        fi
        if [ "${REVERSE_DEPENDS}" = "true" ]; then
            # output
            echo ${component}
            # process depends
            component_depends ${DEPENDS}
        else
            # process depends
            component_depends ${DEPENDS}
            # output
            echo ${component}
        fi
    done
}

component_exec()
{
    local components="$@"
    if [ "${WITHOUT_DEPENDS}" != "true" ]; then
        components=$(IGNORE_DEPENDS=" " component_depends ${components})
    fi
    [ -n "${components}" ] || return 1
    (set -e
        for COMPONENT in ${components}
        do
            COMPONENT_DIR="${INCLUDE_DIR}/${COMPONENT}"
            [ -d "${COMPONENT_DIR}" ] || continue
            unset NAME DESC TARGET PARAMS DEPENDS EXTENDS
            TARGET='*:*:*'
            # read config
            . "${COMPONENT_DIR}/deploy.conf"
            # default functions
            do_install() { return 0; }
            do_configure() { return 0; }
            do_start() { return 0; }
            do_stop() { return 0; }
            do_status() { return 0; }
            do_help() { return 0; }
            # load extends
            for component in ${EXTENDS} ${COMPONENT}
            do
                if [ -e "${INCLUDE_DIR}/${component}/deploy.sh" ]; then
                    . "${INCLUDE_DIR}/${component}/deploy.sh"
                fi
            done
            # exclude components
            component_is_exclude ${COMPONENT} && continue
            # check parameters
            [ "${WITHOUT_CHECK}" != "true" ] && params_check ${PARAMS}
            # exec action
            [ "${DEBUG_MODE}" = "true" ] && msg "## ${COMPONENT} : ${DO_ACTION}"
            set +e
            eval ${DO_ACTION} || exit 1
            set -e
        done
    exit 0)
    is_ok || return 1
}

component_list()
{
    local components="$@"
    local component output DESC
    if [ -z "${components}" ]; then
        components=$(cd "${INCLUDE_DIR}" && find . -type f -name "deploy.conf" | while read f
            do
                component="${f%/*}"
                component="${component#*/}"
                echo "${component}"
            done)
    fi
    components=$(IGNORE_DEPENDS=" " component_depends ${components} | sort)
    for component in $components
    do
        # output
        DESC=''
        eval $(grep '^DESC=' "${INCLUDE_DIR}/${component}/deploy.conf")
        output=$(printf "%-30s %.49s\n" "${component}" "${DESC}")
        msg "${output}"
    done
}

component_dir() {
    echo "${INCLUDE_DIR}/$1"
}

################################################################################
# Containers
################################################################################

container_mounted()
{
    if [ "${METHOD}" = "chroot" ]; then
        is_mounted "${CHROOT_DIR}"
    else
        return 0
    fi
}

fs_check()
{
    if is_mounted "${CHROOT_DIR}"; then
        return 1
    fi
    local checkfs=$(which e2fsck)
    if [ -z "${checkfs}" ]; then
        return 1
    fi
    case "${TARGET_TYPE}" in
    file|partition)
        ${checkfs} -p "${TARGET_PATH}" >/dev/null
        return 0
    ;;
    esac
    return 1
}

mount_part()
{
    case "$1" in
    root)
        msg -n "/ ... "
        if ! is_mounted "${CHROOT_DIR}" ; then
            [ -d "${CHROOT_DIR}" ] || mkdir -p "${CHROOT_DIR}"
            local mnt_opts
            [ -d "${TARGET_PATH}" ] && mnt_opts="bind" || mnt_opts="rw,relatime"
            mount -o ${mnt_opts} "${TARGET_PATH}" "${CHROOT_DIR}" &&
            mount -o remount,exec,suid,dev "${CHROOT_DIR}"
            is_ok "fail" "done" || return 1
        else
            msg "skip"
        fi
    ;;
    proc)
        msg -n "/proc ... "
        local target="${CHROOT_DIR}/proc"
        if ! is_mounted "${target}" ; then
            [ -d "${target}" ] || mkdir -p "${target}"
            mount -t proc proc "${target}"
            is_ok "fail" "done"
        else
            msg "skip"
        fi
    ;;
    sys)
        msg -n "/sys ... "
        local target="${CHROOT_DIR}/sys"
        if ! is_mounted "${target}" ; then
            [ -d "${target}" ] || mkdir -p "${target}"
            mount -t sysfs sys "${target}"
            is_ok "fail" "done"
        else
            msg "skip"
        fi
    ;;
    dev)
        msg -n "/dev ... "
        local target="${CHROOT_DIR}/dev"
        if ! is_mounted "${target}" ; then
            [ -d "${target}" ] || mkdir -p "${target}"
            mount -o bind /dev "${target}"
            is_ok "fail" "done"
        else
            msg "skip"
        fi
    ;;
    shm)
        msg -n "/dev/shm ... "
        if ! is_mounted "/dev/shm" ; then
            [ -d "/dev/shm" ] || mkdir -p /dev/shm
            mount -o rw,nosuid,nodev,mode=1777 -t tmpfs tmpfs /dev/shm
        fi
        local target="${CHROOT_DIR}/dev/shm"
        if ! is_mounted "${target}" ; then
            mount -o bind /dev/shm "${target}"
            is_ok "fail" "done"
        else
            msg "skip"
        fi
    ;;
    pts)
        msg -n "/dev/pts ... "
        if ! is_mounted "/dev/pts" ; then
            [ -d "/dev/pts" ] || mkdir -p /dev/pts
            mount -o rw,nosuid,noexec,gid=5,mode=620,ptmxmode=000 -t devpts devpts /dev/pts
        fi
        local target="${CHROOT_DIR}/dev/pts"
        if ! is_mounted "${target}" ; then
            mount -o bind /dev/pts "${target}"
            is_ok "fail" "done"
        else
            msg "skip"
        fi
    ;;
    fd)
        if [ ! -e "/dev/fd" -o ! -e "/dev/stdin" -o ! -e "/dev/stdout" -o ! -e "/dev/stderr" ]; then
            msg -n "/dev/fd ... "
            [ -e "/dev/fd" ] || ln -s /proc/self/fd /dev/
            [ -e "/dev/stdin" ] || ln -s /proc/self/fd/0 /dev/stdin
            [ -e "/dev/stdout" ] || ln -s /proc/self/fd/1 /dev/stdout
            [ -e "/dev/stderr" ] || ln -s /proc/self/fd/2 /dev/stderr
            is_ok "fail" "done"
        fi
    ;;
    tty)
        if [ ! -e "/dev/tty0" ]; then
            msg -n "/dev/tty ... "
            ln -s /dev/null /dev/tty0
            is_ok "fail" "done"
        fi
    ;;
    tun)
        if [ ! -e "/dev/net/tun" ]; then
            msg -n "/dev/net/tun ... "
            [ -d "/dev/net" ] || mkdir -p /dev/net
            mknod /dev/net/tun c 10 200
            is_ok "fail" "done"
        fi
    ;;
    binfmt_misc)
        multiarch_support || return 0
        local binfmt_dir="/proc/sys/fs/binfmt_misc"
        if ! is_mounted "${binfmt_dir}" ; then
            msg -n "${binfmt_dir} ... "
            mount -t binfmt_misc binfmt_misc "${binfmt_dir}"
            is_ok "fail" "done"
        fi
    ;;
    esac

    return 0
}

container_mount()
{
    [ "${METHOD}" = "chroot" ] || return 0

    if [ $# -eq 0 ]; then
        container_mount root proc sys dev shm pts fd tty tun binfmt_misc
        return $?
    fi

    params_check TARGET_PATH || return 1

    msg -n "Checking file system ... "
    fs_check
    is_ok "skip" "done"

    msg "Mounting the container: "
    local item
    for item in $*
    do
        mount_part ${item} || return 1
    done

    return 0
}

container_umount()
{
    params_check TARGET_PATH || return 1
    container_mounted || { msg "The container is not mounted." ; return 0; }

    msg -n "Release resources ... "
    local is_release=0
    local lsof_full=$(lsof | awk '{print $1}' | grep -c '^lsof')
    if [ "${lsof_full}" -eq 0 ]; then
        local pids=$(lsof | grep "${CHROOT_DIR%/}" | awk '{print $1}' | uniq)
    else
        local pids=$(lsof | grep "${CHROOT_DIR%/}" | awk '{print $2}' | uniq)
    fi
    kill_pids ${pids}; is_ok "fail" "done"

    msg "Unmounting partitions: "
    local is_mnt=0
    local mask
    for mask in '.*' '*'
    do
        local parts=$(cat /proc/mounts | awk '{print $2}' | grep "^${CHROOT_DIR%/}/${mask}$" | sort -r)
        local part
        for part in ${parts}
        do
            local part_name=$(echo ${part} | sed "s|^${CHROOT_DIR%/}/*|/|g")
            msg -n "${part_name} ... "
            for i in 1 2 3
            do
                umount ${part} && break
                sleep 1
            done
            is_ok "fail" "done"
            is_mnt=1
        done
    done
    [ "${is_mnt}" -eq 1 ]; is_ok " ...nothing mounted"

    local loop=$(losetup -a | grep "${TARGET_PATH%/}" | awk -F: '{print $1}')
    if [ -n "${loop}" ]; then
        msg -n "Disassociating loop device ... "
        losetup -d "${loop}"
        is_ok "fail" "done"
    fi

    return 0
}

container_start()
{
    container_mounted || { msg "The container is not mounted." ; return 1; }

    DO_ACTION='do_start'
    if [ $# -gt 0 ]; then
        component_exec "$@"
    else
        component_exec "${INCLUDE}"
    fi
}

container_stop()
{
    container_mounted || { msg "The container is not mounted." ; return 1; }

    DO_ACTION='do_stop'
    if [ $# -gt 0 ]; then
        component_exec "$@"
    else
        component_exec "${INCLUDE}"
    fi
}

container_shell()
{
    container_mounted || container_mount || return 1

    DO_ACTION='do_start'
    component_exec core

    USER="root"
    SHELL="$(user_shell $USER)"
    HOME="$(user_home $USER)"
    [ -n "${TERM}" ] || TERM="linux"
    [ -n "${PS1}" ] || PS1="\u@\h:\w\\$ "
    export USER SHELL HOME TERM PS1

    if [ -e "${CHROOT_DIR}/etc/motd" ]; then
        msg $(cat "${CHROOT_DIR}/etc/motd")
    fi

    chroot_exec "$@" 2>&1

    return $?
}

rootfs_import()
{
    local rootfs_file="$1"
    [ -n "${rootfs_file}" ] || return 1

    container_mounted || container_mount root || return 1

    case "${rootfs_file}" in
    *tar)
        msg -n "Importing rootfs from tar archive ... "
        if [ -e "${rootfs_file}" ]; then
            tar xf "${rootfs_file}" -C "${CHROOT_DIR}"
        elif [ -z "${rootfs_file##http*}" ]; then
            wget -q -O - "${rootfs_file}" | tar x -C "${CHROOT_DIR}"
        else
            msg "fail"; return 1
        fi
        is_ok "fail" "done" || return 1
    ;;
    *gz)
        msg -n "Importing rootfs from tar.gz archive ... "
        if [ -e "${rootfs_file}" ]; then
            tar xzf "${rootfs_file}" -C "${CHROOT_DIR}"
        elif [ -z "${rootfs_file##http*}" ]; then
            wget -q -O - "${rootfs_file}" | tar xz -C "${CHROOT_DIR}"
        else
            msg "fail"; return 1
        fi
        is_ok "fail" "done" || return 1
    ;;
    *bz2)
        msg -n "Importing rootfs from tar.bz2 archive ... "
        if [ -e "${rootfs_file}" ]; then
            tar xjf "${rootfs_file}" -C "${CHROOT_DIR}"
        elif [ -z "${rootfs_file##http*}" ]; then
            wget -q -O - "${rootfs_file}" | tar xj -C "${CHROOT_DIR}"
        else
            msg "fail"; return 1
        fi
        is_ok "fail" "done" || return 1
    ;;
    *xz)
        msg -n "Importing rootfs from tar.xz archive ... "
        if [ -e "${rootfs_file}" ]; then
            tar xJf "${rootfs_file}" -C "${CHROOT_DIR}"
        elif [ -z "${rootfs_file##http*}" ]; then
            wget -q -O - "${rootfs_file}" | tar xJ -C "${CHROOT_DIR}"
        else
            msg "fail"; return 1
        fi
        is_ok "fail" "done" || return 1
    ;;
    *zst)
        msg -n "Importing rootfs from tar.zst archive ... "
        if [ -e "${rootfs_file}" ]; then
            zstdcat "${rootfs_file}" | tar x -C "${CHROOT_DIR}"
        elif [ -z "${rootfs_file##http*}" ]; then
            wget -q -O - "${rootfs_file}" | zstdcat | tar x -C "${CHROOT_DIR}"
        else
            msg "fail"; return 1
        fi
        is_ok "fail" "done" || return 1
    ;;
    *)
        msg "Incorrect filename, supported only tar, tar.gz, tar.bz2, tar.xz or tar.zst archives."
        return 1
    ;;
    esac
    return 0
}

rootfs_export()
{
    local rootfs_file="$1"
    [ -n "${rootfs_file}" ] || return 1

    container_mounted || container_mount root || return 1

    case "${rootfs_file}" in
    *gz)
        msg -n "Exporting rootfs as tar.gz archive ... "
        tar czvf "${rootfs_file}" --exclude='./dev' --exclude='./sys' --exclude='./proc' -C "${CHROOT_DIR}" . >/dev/null
        is_ok "fail" "done" || return 1
    ;;
    *bz2)
        msg -n "Exporting rootfs as tar.bz2 archive ... "
        tar cjvf "${rootfs_file}" --exclude='./dev' --exclude='./sys' --exclude='./proc' -C "${CHROOT_DIR}" . >/dev/null
        is_ok "fail" "done" || return 1
    ;;
    *xz)
        msg -n "Exporting rootfs as tar.xz archive ... "
        tar cJvf "${rootfs_file}" --exclude='./dev' --exclude='./sys' --exclude='./proc' -C "${CHROOT_DIR}" . >/dev/null
        is_ok "fail" "done" || return 1
    ;;
    *zst)
        msg -n "Exporting rootfs as tar.zst archive ... "
        tar cvf - --exclude='./dev' --exclude='./sys' --exclude='./proc' -C "${CHROOT_DIR}" . 2>/dev/null | zstd -q -19 -T0 -o "${rootfs_file}" -
        is_ok "fail" "done" || return 1
    ;;
    *)
        msg "Incorrect filename, supported only gz, bz2, xz or zst archives."
        return 1
    ;;
    esac
}

container_status()
{
    local model=$(which getprop >/dev/null && getprop ro.product.model)
    if [ -n "${model}" ]; then
        msg -n "Device: "
        msg "${model}"
    fi

    local android=$(which getprop >/dev/null && getprop ro.build.version.release)
    if [ -n "${android}" ]; then
        msg -n "Android: "
        msg "${android}"
    fi

    msg -n "Architecture: "
    msg "$(uname -m)"

    msg -n "Kernel: "
    msg "$(uname -r)"

    msg -n "Memory: "
    local mem_total=$(grep ^MemTotal /proc/meminfo | awk '{print $2}')
    let mem_total=${mem_total}/1024
    local mem_free=$(grep ^MemFree /proc/meminfo | awk '{print $2}')
    let mem_free=${mem_free}/1024
    msg "${mem_free}/${mem_total} MB"

    msg -n "Swap: "
    local swap_total=$(grep ^SwapTotal /proc/meminfo | awk '{print $2}')
    let swap_total=${swap_total}/1024
    local swap_free=$(grep ^SwapFree /proc/meminfo | awk '{print $2}')
    let swap_free=${swap_free}/1024
    msg "${swap_free}/${swap_total} MB"

    msg -n "SELinux: "
    selinux_inactive && msg "inactive" || msg "active"

    msg -n "Loop devices: "
    loop_support && msg "yes" || msg "no"

    msg -n "Support binfmt_misc: "
    multiarch_support && msg "yes" || msg "no"

    msg -n "Supported FS: "
    local supported_fs=$(printf '%s ' $(grep -v nodev /proc/filesystems | sort))
    msg "${supported_fs}"

    msg -n "Installed system: "
    local linux_version=$([ -r "${CHROOT_DIR}/etc/os-release" ] && . "${CHROOT_DIR}/etc/os-release"; [ -n "${PRETTY_NAME}" ] && echo "${PRETTY_NAME}" || echo "unknown")
    msg "${linux_version}"

    msg "Status of components: "
    local DO_ACTION='do_status'
    component_exec "${INCLUDE}"

    msg "Mounted parts: "
    local item
    for item in $(grep "${CHROOT_DIR%/}" /proc/mounts | awk '{print $2}' | sed "s|${CHROOT_DIR%/}/*|/|g")
    do
        msg "* ${item}"
    done
}

diagnose_check()
{
    local title="$1"; shift
    msg -n "${title}: "
    "$@" >/dev/null 2>&1
    is_ok "fail" "ok"
}

diagnose_file_tail()
{
    local file="$1"
    local title="$2"
    if [ -s "${file}" ]; then
        msg "${title}:"
        tail -n 40 "${file}" | while read line
        do
            msg "${line}"
        done
    fi
}

diagnose_symlink_dir()
{
    local dir="$1"
    [ -d "${dir}" ] || return 1
    local link="${dir%/}/.linuxdeploy-diag-link"
    local target="${dir%/}/.linuxdeploy-diag-target"
    rm -f "${link}" "${target}"
    touch "${target}" &&
    ln -s ".linuxdeploy-diag-target" "${link}" &&
    rm -f "${link}" "${target}"
}

container_diagnose()
{
    msg ":: Linux Deploy Mod diagnostics"
    msg "Profile: ${PROFILE}"
    msg "Version: ${VERSION}"
    msg "Method: ${METHOD}"
    msg "Distribution: ${DISTRIB}/${SUITE}/${ARCH}"
    msg "Target: ${TARGET_TYPE} ${TARGET_PATH}"
    msg "Include: ${INCLUDE}"
    msg "Desktop: ${DESKTOP}"
    msg "Graphics: ${GRAPHICS}"
    if [ -s "${TEMP_DIR}/persistent-start.pid" ]; then
        msg "Persistent boot PID: $(cat "${TEMP_DIR}/persistent-start.pid")"
    else
        msg "Persistent boot PID: not running"
    fi

    msg ":: Device"
    msg "UID: $(id -u 2>/dev/null)"
    msg "Kernel: $(uname -r)"
    msg "Machine: $(uname -m)"
    msg "SELinux: $(selinux_inactive && echo inactive || echo active)"
    msg "Loop devices: $(loop_support && echo yes || echo no)"
    msg "binfmt_misc: $(multiarch_support && echo yes || echo no)"

    msg ":: Tools"
    diagnose_check "busybox" command -v busybox
    diagnose_check "mount" command -v mount
    diagnose_check "losetup" command -v losetup
    diagnose_check "mke2fs" command -v mke2fs
    diagnose_check "e2fsck" command -v e2fsck
    diagnose_check "zstd" command -v zstd
    diagnose_check "zstdcat" command -v zstdcat
    diagnose_check "tar" command -v tar
    diagnose_check "wget" command -v wget
    if command -v mke2fs >/dev/null 2>&1; then
        msg "mke2fs: $(mke2fs -V 2>&1 | head -n 1)"
    fi

    msg ":: Storage"
    local target_dir="${TARGET_PATH%/*}"
    [ -n "${target_dir}" -a "${target_dir}" != "${TARGET_PATH}" ] || target_dir="."
    [ -d "${target_dir}" ] || mkdir -p "${target_dir}" 2>/dev/null
    df -h "${target_dir}" 2>/dev/null | while read line
    do
        msg "${line}"
    done
    case "${TARGET_PATH}" in
    /sdcard/*|/storage/emulated/*|${EXTERNAL_STORAGE}/*)
        msg "Warning: target is on Android shared storage. Use File image on /data/local for modern Ubuntu/Debian."
    ;;
    esac
    if [ "${TARGET_TYPE}" = "directory" ]; then
        msg -n "Target symlinks: "
        diagnose_symlink_dir "${TARGET_PATH}" && msg "ok" || msg "fail"
    fi
    if container_mounted; then
        msg -n "Mounted rootfs symlinks: "
        diagnose_symlink_dir "${CHROOT_DIR}" && msg "ok" || msg "fail"
    fi

    msg ":: Mounts"
    local mounted=$(grep "${CHROOT_DIR%/}" /proc/mounts | awk '{print $2}')
    if [ -n "${mounted}" ]; then
        echo "${mounted}" | while read line
        do
            msg "* ${line}"
        done
    else
        msg "No mounted container parts."
    fi
    local loops=$(losetup -a | grep "${TARGET_PATH%/}")
    [ -n "${loops}" ] && msg "${loops}"

    msg ":: Connection"
    msg "Device IP: $(ip -4 addr show 2>/dev/null | awk '/inet / && $2 !~ /^127\\./ {print $2}' | cut -d/ -f1 | head -n 1)"
    msg "SSH: ${SSH_PORT:-22}"
    msg "XRDP: ${XRDP_PORT:-3389}"
    msg "VNC display: ${VNC_DISPLAY:-0}"

    msg ":: Recent logs"
    diagnose_file_tail "${TEMP_DIR}/mke2fs.log" "mke2fs log"
    diagnose_file_tail "${CHROOT_DIR}/debootstrap/debootstrap.log" "debootstrap log"
    diagnose_file_tail "${CHROOT_DIR}$(user_home ${USER_NAME})/.xrdp-startwm.log" "XRDP startup log"
    diagnose_file_tail "${CHROOT_DIR}$(user_home ${USER_NAME})/.xsession-errors" "X session log"
}

container_repair_desktop()
{
    msg ":: Repairing desktop startup files"
    container_mounted || container_mount || return 1
    local DO_ACTION='do_configure'
    component_exec desktop graphics extra/ssh || return 1
    msg "Desktop startup files were regenerated."
    msg "Restart the container, then connect again."
}

persistent_stop()
{
    local lock="${TEMP_DIR}/persistent-start.pid"
    if [ -s "${lock}" ]; then
        local pid=$(cat "${lock}")
        if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            msg "Stopping persistent boot watchdog (${pid}) ... "
            kill "${pid}" 2>/dev/null
        fi
        rm -f "${lock}"
    fi
    container_mounted && container_stop
    container_mounted && container_umount
}

persistent_start()
{
    local retry_delay=30
    local watchdog=300
    local attempts=0
    local item key val
    for item in "$@"
    do
        key=$(expr "${item}" : '--\([0-9a-z-]\{1,32\}=\{0,1\}\)' | sed 'y/-abcdefghijklmnopqrstuvwxyz/_ABCDEFGHIJKLMNOPQRSTUVWXYZ/')
        val=$(expr "${item}" : '--[0-9a-z-]\{1,32\}=\(.*\)')
        case "${key}" in
        RETRY_DELAY) retry_delay="${val}" ;;
        WATCHDOG) watchdog="${val}" ;;
        ATTEMPTS) attempts="${val}" ;;
        esac
    done
    [ -n "${retry_delay}" ] || retry_delay=30
    [ -n "${watchdog}" ] || watchdog=300
    [ -n "${attempts}" ] || attempts=0

    local lock="${TEMP_DIR}/persistent-start.pid"
    if [ -s "${lock}" ]; then
        local old_pid=$(cat "${lock}")
        if [ -n "${old_pid}" ] && kill -0 "${old_pid}" 2>/dev/null; then
            msg "Persistent boot watchdog is already running (${old_pid})."
            return 0
        fi
    fi
    echo $$ > "${lock}"
    trap "rm -f '${lock}'" EXIT INT TERM

    msg ":: Persistent boot enabled"
    msg "Retry delay: ${retry_delay}s"
    msg "Watchdog interval: ${watchdog}s"
    msg "Attempts: $([ "${attempts}" -le 0 ] && echo forever || echo "${attempts}")"

    local attempt=1
    while true
    do
        msg ":: Persistent boot attempt ${attempt}"
        if container_mounted || container_mount; then
            if container_start; then
                msg "Persistent boot started successfully."
                break
            fi
        fi

        msg "Persistent boot failed; remounting before retry."
        container_mounted && container_stop
        container_mounted && container_umount
        if [ "${attempts}" -gt 0 ] && [ "${attempt}" -ge "${attempts}" ]; then
            msg "Persistent boot attempts exhausted."
            return 1
        fi
        attempt=$(expr "${attempt}" + 1)
        sleep "${retry_delay}"
    done

    [ "${watchdog}" -gt 0 ] || return 0
    while true
    do
        sleep "${watchdog}"
        msg ":: Persistent watchdog check"
        if ! container_mounted; then
            msg "Container is not mounted; mounting again."
            container_mount || {
                msg "Mount failed; retrying later."
                sleep "${retry_delay}"
                continue
            }
        fi
        if ! container_start; then
            msg "Start failed; remounting and retrying."
            container_mounted && container_stop
            container_mounted && container_umount
            sleep "${retry_delay}"
            container_mount && container_start
        fi
    done
}

preset_source_path()
{
    case "${1}:${ARCH}" in
    ubuntu:arm|ubuntu:arm_64) echo "http://ports.ubuntu.com/ubuntu-ports/" ;;
    ubuntu:*) echo "http://archive.ubuntu.com/ubuntu/" ;;
    debian:*) echo "http://ftp.debian.org/debian/" ;;
    alpine:*) echo "http://dl-cdn.alpinelinux.org/alpine/" ;;
    *) echo "${SOURCE_PATH}" ;;
    esac
}

preset_touch()
{
    [ -n "${OPTLST##* $1 *}" ] && OPTLST="${OPTLST}$1 "
}

preset_set()
{
    local key="$1"
    local val="$2"
    eval ${key}=\"${val}\"
    preset_touch "${key}"
}

preset_apply()
{
    local preset="$1"
    [ -n "${preset}" ] || preset="list"
    if [ "${preset}" = "list" ]; then
        msg "Available presets:"
        msg "  ubuntu-noble-gnome-xrdp"
        msg "  ubuntu-noble-xfce-xrdp"
        msg "  debian-trixie-xfce-vnc"
        msg "  alpine-ssh"
        return 0
    fi

    [ -n "${ARCH}" ] || ARCH=$(get_platform)
    [ -n "${USER_NAME}" ] || USER_NAME="android"
    [ -n "${USER_PASSWORD}" ] || USER_PASSWORD="changeme"
    preset_set ARCH "${ARCH}"
    preset_set USER_NAME "${USER_NAME}"
    preset_set USER_PASSWORD "${USER_PASSWORD}"
    preset_set TARGET_TYPE "file"
    preset_set FS_TYPE "ext4"
    preset_set LOCALE "${LOCALE:-en_US.UTF-8}"
    preset_set DNS "${DNS:-8.8.8.8 8.8.4.4}"
    preset_set PRIVILEGED_USERS "${PRIVILEGED_USERS:-android:aid_inet android:aid_sdcard_rw android:aid_graphics}"
    preset_set SSH_PORT "${SSH_PORT:-22}"
    preset_set XRDP_PORT "${XRDP_PORT:-3389}"
    preset_set VNC_DISPLAY "${VNC_DISPLAY:-0}"

    case "${preset}" in
    ubuntu-noble-gnome-xrdp)
        preset_set DISTRIB "ubuntu"
        preset_set SUITE "noble"
        preset_set SOURCE_PATH "$(preset_source_path ubuntu)"
        preset_set TARGET_PATH "/data/local/linux-noble-gnome.img"
        preset_set DISK_SIZE "20480"
        preset_set INIT "systemd"
        preset_set INIT_ASYNC "true"
        preset_set GRAPHICS "xrdp"
        preset_set DESKTOP "gnome"
        preset_set INCLUDE "bootstrap init desktop graphics extra/ssh"
    ;;
    ubuntu-noble-xfce-xrdp)
        preset_set DISTRIB "ubuntu"
        preset_set SUITE "noble"
        preset_set SOURCE_PATH "$(preset_source_path ubuntu)"
        preset_set TARGET_PATH "/data/local/linux-noble-xfce.img"
        preset_set DISK_SIZE "12288"
        preset_set INIT "systemd"
        preset_set INIT_ASYNC "true"
        preset_set GRAPHICS "xrdp"
        preset_set DESKTOP "xfce"
        preset_set INCLUDE "bootstrap init desktop graphics extra/ssh"
    ;;
    debian-trixie-xfce-vnc)
        preset_set DISTRIB "debian"
        preset_set SUITE "trixie"
        preset_set SOURCE_PATH "$(preset_source_path debian)"
        preset_set TARGET_PATH "/data/local/linux-trixie-xfce.img"
        preset_set DISK_SIZE "8192"
        preset_set GRAPHICS "vnc"
        preset_set DESKTOP "xfce"
        preset_set INCLUDE "bootstrap desktop graphics extra/ssh"
    ;;
    alpine-ssh)
        preset_set DISTRIB "alpine"
        preset_set SUITE "latest-stable"
        preset_set SOURCE_PATH "$(preset_source_path alpine)"
        preset_set TARGET_PATH "/data/local/linux-alpine.img"
        preset_set DISK_SIZE "2048"
        preset_set GRAPHICS "vnc"
        preset_set DESKTOP "xterm"
        preset_set INCLUDE "bootstrap extra/ssh"
    ;;
    *)
        msg "Unknown preset: ${preset}"
        preset_apply list
        return 1
    ;;
    esac

    params_write "${CONF_FILE}"
    msg "Preset applied: ${preset}"
    msg "Profile: ${PROFILE}"
    msg "Run Install to deploy it."
}

helper()
{
cat <<EOF
Linux Deploy ${VERSION}
(c) 2012-2019 Anton Skshidlevsky, GPLv3

USAGE:
   ${0##*/} [OPTIONS] COMMAND ...

OPTIONS:
   -p NAME - configuration profile
   -d - enable debug mode
   -t - enable trace mode

COMMANDS:
   config [...] [PARAMETERS] [NAME ...] - configuration management
      - without parameters displays a list of configurations
      -r - remove the current configuration
      -i FILE - import the configuration
      -x - dump of the current configuration
      -l - list of dependencies for the specified or are connected components
      -a - list of all components without check compatibility
   deploy [...] [PARAMETERS] [-n NAME] [NAME ...] - install the distribution and included components
      -m - mount the container before deployment
      -i - install without configure
      -c - configure without install
      -n NAME - skip installation of this component
   import FILE|URL - import a rootfs into the current container from archive (tgz, tbz2 or txz)
   export FILE - export the current container as a rootfs archive (tgz, tbz2 or txz)
   shell [-u USER] [COMMAND] - execute the specified command in the container, by default /bin/bash
      -u USER - switch to the specified user
   mount - mount the container
   umount - unmount the container
   start [-m] [NAME ...] - start all included or only specified components
      -m - mount the container before start
   stop [-u] [NAME ...] - stop all included or only specified components
      -u - unmount the container after stop
   status [NAME ...] - display the status of the container and components
   diagnose - run environment, storage, tool and desktop log diagnostics
   repair-desktop - regenerate desktop, graphics and ssh startup files
   persistent-start [OPTIONS] - boot, remount and watchdog-restart the container
      --retry-delay=N - delay between failed boot attempts, default 30 seconds
      --watchdog=N - watchdog interval, default 300 seconds; 0 disables watchdog
      --attempts=N - number of boot attempts, default 0 means forever
   persistent-stop - stop persistent watchdog, services and mounts
   preset [NAME|list] - apply a deployment preset to the current profile
   help [NAME ...] - show this help or help of components

EOF
}

do_info()
{
cat <<EOF
Name: ${COMPONENT}
Description: ${DESC}
Target: ${TARGET}
Depends: ${DEPENDS}
Help:

EOF
}

################################################################################

umask 0022
unset LANG
if [ -z "${ENV_DIR}" ]; then
    ENV_DIR=$(readlink "$0")
    ENV_DIR="${ENV_DIR%/*}"
    if [ -z "${ENV_DIR}" ]; then
        ENV_DIR=$(realpath "${0%/*}")
    fi
fi
if [ -e "${ENV_DIR}/cli.conf" ]; then
    . "${ENV_DIR}/cli.conf"
fi
if [ -z "${CONFIG_DIR}" ]; then
    CONFIG_DIR="${ENV_DIR}/config"
fi
if [ -z "${INCLUDE_DIR}" ]; then
    INCLUDE_DIR="${ENV_DIR}/include"
fi
if [ -z "${TEMP_DIR}" ]; then
    TEMP_DIR="${ENV_DIR}/tmp"
fi
if [ -z "${CHROOT_DIR}" ]; then
    CHROOT_DIR="${ENV_DIR}/mnt"
fi
if [ -z "${METHOD}" ]; then
    METHOD="chroot"
fi

# parse options
OPTIND=1
while getopts :p:dt FLAG
do
    case "${FLAG}" in
    p)
        PROFILE="${OPTARG}"
    ;;
    d)
        DEBUG_MODE="true"
    ;;
    t)
        TRACE_MODE="true"
    ;;
    *)
        if [ ${OPTIND} -gt 1 ]; then
            let OPTIND=OPTIND-1
        fi
        break
    ;;
    esac
done
shift $((OPTIND-1))

# log level
exec 3>&1
if [ "${DEBUG_MODE}" != "true" -a "${TRACE_MODE}" != "true" ]; then
    exec 2>/dev/null
fi
if [ "${TRACE_MODE}" = "true" ]; then
    set -x
fi

# which config
CONF_FILE=$(config_which "${PROFILE}")
PROFILE=$(basename "${CONF_FILE}" ".conf")

# read config
OPTLST=" " # space is required
params_read "${CONF_FILE}"

# fix params
WITHOUT_CHECK="false"
WITHOUT_DEPENDS="false"
REVERSE_DEPENDS="false"
EXCLUDE_COMPONENTS=""

# make dirs
[ -d "${CONFIG_DIR}" ] || mkdir "${CONFIG_DIR}"
[ -d "${INCLUDE_DIR}" ] || mkdir "${INCLUDE_DIR}"
[ -d "${TEMP_DIR}" ] || mkdir "${TEMP_DIR}"
[ -d "${CHROOT_DIR}" ] || mkdir "${CHROOT_DIR}"

# parse command
OPTCMD="$1"; shift
case "${OPTCMD}" in
config|conf)
    if [ $# -eq 0 ]; then
        config_list "${CONF_FILE}"
        exit $?
    fi
    conf_file="${CONF_FILE}"

    # parse options
    OPTIND=1
    while getopts :i:rxla FLAG
    do
        case "${FLAG}" in
        r)
            config_remove "${CONF_FILE}"
            exit $?
        ;;
        x)
            dump_flag="true"
        ;;
        i)
            conf_file=$(config_which "${OPTARG}")
        ;;
        l)
            list_flag="true"
        ;;
        a)
            WITHOUT_CHECK="true"
        ;;
        *)
            if [ ${OPTIND} -gt 1 ]; then
                let OPTIND=OPTIND-1
            fi
            break
        ;;
        esac
    done
    shift $((OPTIND-1))

    if [ "${dump_flag}" = "true" ]; then
        [ -e "${CONF_FILE}" ] && cat "${CONF_FILE}"
    elif [ "${list_flag}" = "true" ]; then
        if [ $# -eq 0 ]; then
            if [ "${WITHOUT_CHECK}" = "true" ]; then
                component_list
            else
                component_list "${INCLUDE}"
            fi
        else
            component_list "$@"
        fi
    else
        config_update "${conf_file}" "${CONF_FILE}" "$@"
    fi
;;
deploy)
    DO_ACTION='do_install && do_configure'

    # parse options
    OPTIND=1
    while getopts :n:mic FLAG
    do
        case "${FLAG}" in
        m)
            mount_flag="true"
        ;;
        i)
            DO_ACTION='do_install'
        ;;
        c)
            DO_ACTION='do_configure'
        ;;
        n)
            EXCLUDE_COMPONENTS="${EXCLUDE_COMPONENTS} ${OPTARG}"
        ;;
        *)
            if [ ${OPTIND} -gt 1 ]; then
                let OPTIND=OPTIND-1
            fi
            break
        ;;
        esac
    done
    shift $((OPTIND-1))

    # parse parameters
    params_parse "$@"
    shift $((OPTIND-1))

    if [ "${mount_flag}" = "true" ]; then
        container_mount || exit 1
    fi

    if [ $# -gt 0 ]; then
        component_exec "$@"
    else
        component_exec "${INCLUDE}"
    fi
;;
import)
    rootfs_import "$@"
;;
export)
    rootfs_export "$@"
;;
shell)
    container_shell "$@"
;;
mount)
    container_mount
;;
umount)
    container_umount
;;
start)
    # parse options
    OPTIND=1
    while getopts :m FLAG
    do
        case "${FLAG}" in
        m)
            mount_flag="true"
        ;;
        *)
            if [ ${OPTIND} -gt 1 ]; then
                let OPTIND=OPTIND-1
            fi
            break
        ;;
        esac
    done
    shift $((OPTIND-1))

    if [ "${mount_flag}" = "true" ]; then
        container_mount || exit 1
    fi

    container_start "$@"
;;
stop)
    # parse options
    OPTIND=1
    while getopts :u FLAG
    do
        case "${FLAG}" in
        u)
            umount_flag="true"
        ;;
        *)
            if [ ${OPTIND} -gt 1 ]; then
                let OPTIND=OPTIND-1
            fi
            break
        ;;
        esac
    done
    shift $((OPTIND-1))

    container_stop "$@" || exit 1

    if [ "${umount_flag}" = "true" ]; then
        container_umount
    fi
;;
status)
    if [ $# -gt 0 ]; then
        DO_ACTION='do_status'
        component_exec "$@"
    else
        container_status
    fi
;;
diagnose|diag)
    container_diagnose
;;
repair-desktop|repair)
    container_repair_desktop
;;
persistent-start|persist-start)
    persistent_start "$@"
;;
persistent-stop|persist-stop)
    persistent_stop
;;
preset|presets)
    preset_apply "$1"
;;
help)
    if [ $# -eq 0 ]; then
        helper
        if [ -n "${INCLUDE}" ]; then
            msg "PARAMETERS: "
            WITHOUT_CHECK="true"
            REVERSE_DEPENDS="true"
            DO_ACTION='do_help'
            component_exec "${INCLUDE}" ||
            msg -e '   Included components do not have parameters.\n'
        fi
    else
        WITHOUT_CHECK="true"
        WITHOUT_DEPENDS="true"
        DO_ACTION='do_info && do_help'
        component_exec "$@"
    fi
;;
*)
    helper
;;
esac
