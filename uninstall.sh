#!/usr/bin/env bash
set -euo pipefail

PREFIX=/usr/local
AUTHORIZED_KEYS=/root/.ssh/authorized_keys
SSHD_CONFIG=/etc/ssh/sshd_config
SSHD_DROPIN=/etc/ssh/sshd_config.d/00-root-ide.conf

DELETE_HOMES=false

die() {
    echo "root-ide-ssh: $*" >&2
    exit 1
}

usage() {
    echo "Usage:"
    echo "  ./uninstall.sh"
    echo "  ./uninstall.sh --delete-homes"
    exit 2
}

[[ $EUID -eq 0 ]] || die "run as root"

if [[ $# -gt 1 ]]; then
    usage
fi

if [[ $# -eq 1 ]]; then
    [[ "$1" == "--delete-homes" ]] || usage
    DELETE_HOMES=true
fi

homes=()

if [[ -f "$AUTHORIZED_KEYS" ]]; then
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT

    while IFS= read -r line; do
        if [[ "$line" == *'command="/usr/local/libexec/root-ide-ssh"'* ]]; then
            options=${line%% *}

            if [[ "$options" =~ IDE_HOME=([^\",]+) ]]; then
                homes+=("${BASH_REMATCH[1]}")
            fi

            # Strip our authorized_keys options and preserve the key itself.
            printf '%s\n' "${line#* }" >> "$tmp"
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$AUTHORIZED_KEYS"

    cat "$tmp" > "$AUTHORIZED_KEYS"
    chmod 0600 "$AUTHORIZED_KEYS"
fi

rm -f \
    "$PREFIX/sbin/root-ide-add" \
    "$PREFIX/sbin/root-ide-remove" \
    "$PREFIX/sbin/root-ide-list" \
    "$PREFIX/libexec/root-ide-ssh" \
    "$SSHD_DROPIN"

if $DELETE_HOMES; then
    for home in "${homes[@]}"; do
        case "$home" in
            /root/*_ide)
                rm -rf -- "$home"
                echo "deleted: $home"
                ;;
            *)
                echo "refusing to delete suspicious path: $home" >&2
                ;;
        esac
    done
fi

if ! sshd -t; then
    die "sshd configuration became invalid after uninstall"
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

    die "uninstalled, but could not reload sshd automatically"
}

reload_sshd

echo "root-ide-ssh uninstalled"

if ! $DELETE_HOMES && ((${#homes[@]})); then
    echo "IDE homes preserved:"
    printf '  %s\n' "${homes[@]}"
fi