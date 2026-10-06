#!/usr/bin/env bash
set -euo pipefail

PREFIX=/usr/local
SSHD_CONFIG=/etc/ssh/sshd_config
SSHD_DROPIN_DIR=/etc/ssh/sshd_config.d
SSHD_DROPIN=$SSHD_DROPIN_DIR/00-root-ide.conf
DATA_BASE=/var/lib/root-ide

die() {
    echo "root-ide-ssh: $*" >&2
    exit 1
}

reload_sshd() {
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; then
        if systemctl is-active --quiet ssh.service; then
            systemctl reload ssh.service
            return
        fi

        if systemctl is-active --quiet sshd.service; then
            systemctl reload sshd.service
            return
        fi

        echo "sshd is not running; reload skipped"
        return
    fi

    if command -v service >/dev/null; then
        if service ssh status >/dev/null 2>&1; then
            service ssh reload
            return
        fi

        if service sshd status >/dev/null 2>&1; then
            service sshd reload
            return
        fi
    fi

    echo "sshd is not running; reload skipped"
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

main() {
    local file config_changed tmp

    [[ $EUID -eq 0 ]] || die "run as root"

    for file in \
        bin/root-ide-add \
        bin/root-ide-remove \
        bin/root-ide-list \
        libexec/root-ide-ssh \
        sshd/00-root-ide.conf
    do
        [[ -f "$SCRIPT_DIR/$file" ]] ||
            die "missing $file (run ./install.sh from a repository checkout)"
    done

    command -v sshd >/dev/null 2>&1 || die "sshd not found"
    command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found"
    command -v unshare >/dev/null 2>&1 ||
        die "unshare not found; util-linux is required"
    command -v mount >/dev/null 2>&1 || die "mount not found"
    command -v realpath >/dev/null 2>&1 || die "realpath not found"
    [[ -x /bin/bash ]] || die "/bin/bash is missing"

    # Fail closed: make-rprivate must run only inside the new namespace.
    if ! unshare --mount -- /bin/bash -c '
        set -euo pipefail
        self=$(readlink -- /proc/self/ns/mnt)
        host=$(readlink -- /proc/1/ns/mnt)
        [[ -n "$self" && "$self" != "$host" ]]
        mount --make-rprivate /
    '
    then
        die "private mount namespaces are not available"
    fi

    install -d -m 0755 "$PREFIX/sbin"
    install -d -m 0755 "$PREFIX/libexec"
    install -d -m 0755 "$SSHD_DROPIN_DIR"
    install -d -m 0700 "$DATA_BASE"
    chmod 0700 "$DATA_BASE"

    install -m 0755 \
        "$SCRIPT_DIR/bin/root-ide-add" \
        "$PREFIX/sbin/root-ide-add"

    install -m 0755 \
        "$SCRIPT_DIR/bin/root-ide-remove" \
        "$PREFIX/sbin/root-ide-remove"

    install -m 0755 \
        "$SCRIPT_DIR/bin/root-ide-list" \
        "$PREFIX/sbin/root-ide-list"

    install -m 0755 \
        "$SCRIPT_DIR/libexec/root-ide-ssh" \
        "$PREFIX/libexec/root-ide-ssh"

    install -m 0644 \
        "$SCRIPT_DIR/sshd/00-root-ide.conf" \
        "$SSHD_DROPIN"

    install -d -m 0700 /root/.ssh

    if [[ -L /root/.ssh/authorized_keys ]]; then
        die "refusing to edit symlink: /root/.ssh/authorized_keys"
    fi

    if [[ ! -e /root/.ssh/authorized_keys ]]; then
        touch -- /root/.ssh/authorized_keys
    fi

    chmod 0600 /root/.ssh/authorized_keys

    # Ensure sshd actually includes drop-ins.
    config_changed=0
    if ! grep -Eq \
        '^[[:space:]]*Include[[:space:]]+(/etc/ssh/)?sshd_config\.d/\*\.conf([[:space:]]|$)' \
        "$SSHD_CONFIG"
    then
        cp -a -- "$SSHD_CONFIG" "${SSHD_CONFIG}.root-ide-ssh.bak"

        tmp=$(mktemp) ||
            die "cannot create a temporary sshd config"
        {
            echo 'Include /etc/ssh/sshd_config.d/*.conf'
            cat -- "$SSHD_CONFIG"
        } > "$tmp"

        cat -- "$tmp" > "$SSHD_CONFIG"
        rm -f -- "$tmp"
        config_changed=1
    fi

    if ! sshd -t; then
        echo "root-ide-ssh: sshd configuration is invalid" >&2

        if [[ "$config_changed" -eq 1 ]]; then
            cp -a -- "${SSHD_CONFIG}.root-ide-ssh.bak" "$SSHD_CONFIG"
        fi

        rm -f -- "$SSHD_DROPIN"
        exit 1
    fi

    reload_sshd

    echo "root-ide-ssh installed"
    echo
    echo "Add a user:"
    echo "  root-ide-add <name> < user.pub"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
