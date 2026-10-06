# root-ide-ssh

Run Cursor / VS Code Remote SSH as real host `root`, while giving each SSH key its own isolated HOME and IDE state.

This is intended for trusted multi-user servers where all users are allowed full root access, but should not share the same `.cursor-server`, `.cursor`, `.local`, `.config`, etc.

## How it works

All users SSH as the real `root` user.

Each SSH key gets its own `IDE_HOME`, for example:

```text
/root/username1_ide
/root/username2_ide
```

A forced SSH command:

- sets `HOME` to the key-specific `IDE_HOME`;
- keeps the process running as UID `0`;
- preserves normal host-root semantics;
- symlinks shared files from `/root`;
- leaves IDE/application state private.

Example layout:

```text
/root/username_ide/
├── .bashrc        -> /root/.bashrc
├── .profile       -> /root/.profile
├── .ssh           -> /root/.ssh
├── .gitconfig     -> /root/.gitconfig
├── .cursor/
├── .cursor-server/
├── .local/
├── .cache/
└── .config/
```

Commands still execute directly on the host:

```bash
systemctl restart nginx
apt install ...
docker ps
cat /etc/shadow
```

No containers, `sudo`, `nsenter`, chroot, or secondary UID 0 accounts are involved.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Eclipter/root-ide-ssh/main/install.sh | sudo bash
```

The installer configures the shared SSH wrapper and SSH server settings.

## Add a user

```bash
root-ide-add username 'ssh-ed25519 AAAA... username@example.com'
```

This creates:

```text
/root/username_ide
```

and adds a key-specific entry to:

```text
/root/.ssh/authorized_keys
```

Equivalent entry:

```text
environment="IDE_HOME=/root/username_ide",command="/usr/local/libexec/root-ide-ssh" ssh-ed25519 AAAA... user@example.com
```

## Client configuration

Example `~/.ssh/config`:

```sshconfig
Host myhost
    HostName myhost.com
    User root
```

Then connect normally from Cursor / VS Code Remote SSH.

## Verify

```bash
ssh monitor '
echo "HOME=$HOME"
echo "IDE_HOME=$IDE_HOME"
id -u
pwd
'
```

Expected:

```text
HOME=/root/username_ide
IDE_HOME=/root/username_ide
0
/root/username_ide
```

## Shared vs private state

The following directories are private per SSH key:

```text
.cursor
.cursor-server
.local
.cache
.config
```

Other top-level entries from `/root` are exposed through symlinks.

New files added to `/root` are linked automatically on subsequent SSH sessions.

## Requirements

- Linux
- OpenSSH server
- root SSH login via public key
- `PermitUserEnvironment` support
- trusted users

## Security

This project does **not** provide user isolation.

Every configured user runs as the real host UID `0` and therefore has unrestricted root access to the machine and to other users' IDE homes.

Use this only when all configured users are fully trusted.

Password-based root login is intentionally not used because the SSH key identifies which `IDE_HOME` should be selected.

## License

MIT
