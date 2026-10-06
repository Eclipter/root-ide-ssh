#!/usr/bin/env bash
set -euo pipefail

PREFIX=/usr/local
SSHD_CONFIG=/etc/ssh/sshd_config
SSHD_DROPIN_DIR=/etc/ssh/sshd_config.d
SSHD_DROPIN="$SSHD_DROPIN_DIR/00-root-ide.conf"

die() {
    echo "root-ide-ssh: $*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "run as root"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

for file in \
    bin/root-ide-add \
    bin/root-ide-remove \
    bin/root-ide-list \
    libexec/root-ide-ssh \
    sshd/00-root-ide.conf
do
    [[ -f "$SCRIPT_DIR/$file" ]] || die "missing repository file: $file"
done

command -v sshd >/dev/null 2>&1 || die "sshd not found"

install -d -m 0755 "$PREFIX/sbin"
install -d -m 0755 "$PREFIX/libexec"
install -d -m 0755 "$SSHD_DROPIN_DIR"

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
touch /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys

# Ensure sshd actually includes drop-ins.
if ! grep -Eq \
    '^[[:space:]]*Include[[:space:]]+(/etc/ssh/)?sshd_config\.d/\*\.conf([[:space:]]|$)' \
    "$SSHD_CONFIG"
then
    cp -a "$SSHD_CONFIG" "${SSHD_CONFIG}.root-ide-ssh.bak"

    tmp="$(mktemp)"
    {
        echo 'Include /etc/ssh/sshd_config.d/*.conf'
        cat "$SSHD_CONFIG"
    } > "$tmp"

    cat "$tmp" > "$SSHD_CONFIG"
    rm -f "$tmp"
fi

if ! sshd -t; then
    echo "root-ide-ssh: sshd configuration is invalid" >&2

    if [[ -f "${SSHD_CONFIG}.root-ide-ssh.bak" ]]; then
        cp -a "${SSHD_CONFIG}.root-ide-ssh.bak" "$SSHD_CONFIG"
    fi

    rm -f "$SSHD_DROPIN"
    exit 1
fi

reload_sshd() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet ssh.service 2>/dev/null; then
            systemctl reload ssh.service
            return
        fi

        if systemctl is-active --quiet sshd.service 2>/dev/null; then
            systemctl reload sshd.service
            return
        fi
    fi

    if command -v service >/dev/null 2>&1; then
        service ssh reload 2>/dev/null && return
        service sshd reload 2>/dev/null && return
    fi

    die "installed successfully, but could not reload sshd automatically"
}

reload_sshd

echo "root-ide-ssh installed"
echo
echo "Add a user:"
echo "  root-ide-add <name> < user.pub"