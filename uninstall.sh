#!/usr/bin/env bash
set -euo pipefail

PREFIX=/usr/local
AUTHORIZED_KEYS=/root/.ssh/authorized_keys
SSHD_CONFIG=/etc/ssh/sshd_config
SSHD_DROPIN=/etc/ssh/sshd_config.d/00-root-ide.conf
DATA_BASE=/var/lib/root-ide
WRAPPER_COMMAND='command="/usr/local/libexec/root-ide-ssh"'
TMP_FILES=()

die() {
    echo "root-ide-ssh: $*" >&2
    exit 1
}

track_tmp() {
    TMP_FILES+=("$1")
}

cleanup_tmp() {
    if [[ ${#TMP_FILES[@]} -gt 0 ]]; then
        rm -f -- "${TMP_FILES[@]}"
    fi
}

usage() {
    cat <<'EOF'
Usage:
  ./uninstall.sh
  ./uninstall.sh --delete-data
EOF
}

is_plain_key() {
    case "$1" in
        ssh-*|ecdsa-*|sk-*)
            return 0
            ;;
    esac

    return 1
}

is_wrapper_line() {
    if is_plain_key "$1"; then
        return 1
    fi

    [[ "$1" == *"$WRAPPER_COMMAND"* ]]
}

safe_delete_user_data() {
    local name=$1
    local base=$DATA_BASE
    local data="$base/$name"
    local parent child

    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] ||
        die "refusing to delete suspicious user: $name"

    [[ -e "$base" || -L "$base" ]] || return 0

    if [[ -L "$base" || ! -d "$base" ]]; then
        die "refusing to delete through invalid data root: $base"
    fi

    [[ -e "$data" || -L "$data" ]] || return 0

    if [[ -L "$data" || ! -d "$data" ]]; then
        die "refusing to delete invalid data directory: $data"
    fi

    command -v realpath >/dev/null 2>&1 ||
        die "realpath not found"

    parent=$(realpath -e -- "$base") ||
        die "cannot resolve $base"
    child=$(realpath -e -- "$data") ||
        die "cannot resolve $data"

    [[ -n "$parent" && -n "$child" ]] ||
        die "refusing to delete unresolved path: $data"
    [[ "$child" == "$parent/$name" ]] ||
        die "refusing to delete unexpected path: $child"
    [[ "$child" != "$parent" && "$child" != / ]] ||
        die "refusing to delete unexpected path: $child"

    rm -rf -- "$child"
}

delete_managed_data() {
    local path name

    [[ -e "$DATA_BASE" || -L "$DATA_BASE" ]] || return 0

    if [[ -L "$DATA_BASE" || ! -d "$DATA_BASE" ]]; then
        die "refusing to delete through invalid data root: $DATA_BASE"
    fi

    shopt -s nullglob

    for path in "$DATA_BASE"/*; do
        name=${path##*/}

        if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ || -L "$path" || ! -d "$path" ]]; then
            echo "root-ide-ssh: skipping unexpected path: $path" >&2
            continue
        fi

        safe_delete_user_data "$name"
        echo "deleted: $path"
    done
}

list_preserved_data() {
    local path found=0

    [[ -d "$DATA_BASE" && ! -L "$DATA_BASE" ]] || return 0

    shopt -s nullglob

    for path in "$DATA_BASE"/*; do
        [[ -d "$path" && ! -L "$path" ]] || continue

        if [[ "$found" -eq 0 ]]; then
            echo "data preserved:"
            found=1
        fi

        printf '  %s\n' "$path"
    done
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

restore_authorized_keys() {
    local line rest changed tmp

    [[ -e "$AUTHORIZED_KEYS" || -L "$AUTHORIZED_KEYS" ]] || return 0

    if [[ -L "$AUTHORIZED_KEYS" ]]; then
        die "refusing to edit symlink: $AUTHORIZED_KEYS"
    fi

    [[ -f "$AUTHORIZED_KEYS" ]] ||
        die "refusing to edit non-file: $AUTHORIZED_KEYS"

    changed=0
    tmp=$(mktemp "$(dirname -- "$AUTHORIZED_KEYS")/.authorized_keys.XXXXXX") ||
        die "cannot create a temporary authorized_keys file"
    track_tmp "$tmp"

    while IFS= read -r line || [[ -n "$line" ]]; do
        if is_wrapper_line "$line"; then
            changed=1
            rest=${line#* }

            # Drop the forced command so logins do not point at a removed wrapper.
            case "$rest" in
                ssh-*|ecdsa-*|sk-*)
                    printf '%s\n' "$rest"
                    ;;
                *)
                    echo "root-ide-ssh: dropping unrecognized wrapper line" >&2
                    ;;
            esac
            continue
        fi

        printf '%s\n' "$line"
    done < "$AUTHORIZED_KEYS" > "$tmp"

    if [[ "$changed" -eq 1 ]]; then
        chmod 0600 -- "$tmp"
        mv -f -- "$tmp" "$AUTHORIZED_KEYS"
    fi
}

main() {
    local delete_data

    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    [[ $EUID -eq 0 ]] || die "run as root"
    [[ $# -le 1 ]] || {
        usage >&2
        exit 2
    }

    trap cleanup_tmp EXIT

    delete_data=false

    if [[ $# -eq 1 ]]; then
        [[ "$1" == "--delete-data" ]] || {
            usage >&2
            exit 2
        }
        delete_data=true
    fi

    restore_authorized_keys

    rm -f -- \
        "$PREFIX/sbin/root-ide-add" \
        "$PREFIX/sbin/root-ide-remove" \
        "$PREFIX/sbin/root-ide-list" \
        "$PREFIX/libexec/root-ide-ssh" \
        "$SSHD_DROPIN"

    if ! sshd -t; then
        die "sshd configuration became invalid after uninstall"
    fi

    reload_sshd

    if $delete_data; then
        delete_managed_data
    else
        list_preserved_data
    fi

    echo "root-ide-ssh uninstalled"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
