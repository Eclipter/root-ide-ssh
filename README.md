# root-ide-ssh

Real host-root SSH sessions with per-key private IDE state via mount namespaces.

Everyone logs in as the real host `root`: UID 0 and `HOME=/root`. Each SSH session runs in its own mount namespace, where a short whitelist of IDE directories is bind-mounted from that key's backing store. Every other file under `/root` is the real shared file. New dotfiles such as `.ansible`, `.docker`, `.cargo`, and `.kube` are shared with no extra configuration.

The namespace is not a security boundary. It only makes Cursor / VS Code see per-key state at the usual `/root/.cursor` paths.

## Layout

```text
HOME=/root

/root/.bashrc          real shared /root/.bashrc
/root/.ssh             real shared /root/.ssh
/root/.ansible         real shared /root/.ansible
/root/.docker          real shared /root/.docker
/root/.cargo           real shared /root/.cargo
/root/.kube            real shared /root/.kube

/root/.cursor          bind mount of /var/lib/root-ide/<user>/.cursor
/root/.cursor-server   bind mount of /var/lib/root-ide/<user>/.cursor-server
```

Private whitelist, edited as `PRIVATE_DIRS` in `libexec/root-ide-ssh`:

```text
.cursor
.cursor-server
```

Backing directories are mode `0700`. They are created on the first SSH session. When the last process in that mount namespace exits, the binds disappear and the data stays in `/var/lib/root-ide/<user>/`.

If `/root/.cursor` already exists on the host, the bind hides it for that session only. The host directory is still there afterward. If it did not exist, the session creates an empty mountpoint directory on the host. Console logins and host processes do not see the per-key binds.

## Sessions

The forced command is a mount namespace and then a normal shell. No `sudo`, `nsenter`, `/host`, containers, extra accounts, or CLI wrappers.

```bash
systemctl restart nginx
apt install ...
docker ps
cat /etc/shadow
```

`/proc`, systemd, docker, and the network stay the host's. The installer does not change the PAM stack, and it does not disable `pam_systemd`.

An interactive session runs `/bin/bash -l`. A remote command runs `/bin/bash -c "$SSH_ORIGINAL_COMMAND"`. `HOME` stays `/root`.

## Install

```bash
git clone https://github.com/Eclipter/root-ide-ssh.git
cd root-ide-ssh
sudo ./install.sh
```

This installs:

```text
/usr/local/sbin/root-ide-add
/usr/local/sbin/root-ide-remove
/usr/local/sbin/root-ide-list
/usr/local/libexec/root-ide-ssh
/etc/ssh/sshd_config.d/00-root-ide.conf
/var/lib/root-ide/
```

The drop-in is:

```text
PermitRootLogin prohibit-password
UsePAM yes
PermitUserEnvironment ROOT_IDE_USER
```

`install.sh` checks `sshd -t` and reloads `ssh` or `sshd` when that service is running.

## Add a user

```bash
root-ide-add <user> < ~/.ssh/id_ed25519.pub
```

or:

```bash
root-ide-add <user> 'ssh-ed25519 AAAA... comment'
```

That creates `/var/lib/root-ide/<user>` and one managed line in `/root/.ssh/authorized_keys`:

```text
environment="ROOT_IDE_USER=<user>",command="/usr/local/libexec/root-ide-ssh" ssh-ed25519 AAAA... comment
```

Each name has one key and one data directory. Running add again for the same name or the same key replaces that managed line.

```bash
root-ide-list
root-ide-remove <user>
root-ide-remove <user> --delete-data
```

`root-ide-remove` deletes the managed line. It keeps `/var/lib/root-ide/<user>` unless `--delete-data` is given, and it only deletes that exact directory.

## Client

```sshconfig
Host myhost
    HostName myhost.com
    User root
```

Connect with Cursor / VS Code Remote SSH as usual.

## Verify

```bash
ssh root@myhost 'printf "HOME=%s\nUID=%s\n" "$HOME" "$(id -u)"; findmnt -n --target /root/.cursor'
```

`HOME` is `/root`, UID is `0`, and the mount source for `/root/.cursor` contains `/var/lib/root-ide/<user>/.cursor`.

## Uninstall

From a checkout:

```bash
sudo ./uninstall.sh
sudo ./uninstall.sh --delete-data
```

This removes the binaries and the sshd drop-in, checks `sshd -t`, and reloads sshd when it is running. Managed lines are turned back into ordinary root public keys so a login is not left with a forced command pointing at a missing wrapper. `/var/lib/root-ide/*` is kept unless `--delete-data` is passed. That flag deletes only checked directories directly under `/var/lib/root-ide/`.

## Requirements

- Linux with mount namespaces (`unshare` and `mount` from util-linux)
- OpenSSH server with public-key root login
- `PermitUserEnvironment` accepting a variable name
- trusted users

Alpine/BusyBox is not supported.

## Security

This is not security isolation.

Every configured user is the real host UID 0. They can read and change the machine, other sessions, and other keys' backing directories under `/var/lib/root-ide`. Password root login is disabled because the SSH key selects `ROOT_IDE_USER`.

Use this only when every configured user is fully trusted.

## License

MIT
