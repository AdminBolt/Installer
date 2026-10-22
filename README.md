# AdminBolt - Powerful and flexible hosting control panel

## Requirements

- **AlmaLinux 9** or **Rocky Linux 9**
- Root access (run with `sudo`)

## Installation

### Option 1: Download and run (one-liner)

Install the latest version:

```bash
curl -fsSL https://raw.githubusercontent.com/AdminBolt/Installer/refs/heads/main/install.sh -o install.sh && sudo bash install.sh
```

Install from staging source:

```bash
curl -fsSL https://raw.githubusercontent.com/AdminBolt/Installer/refs/heads/main/install.sh -o install.sh && sudo bash install.sh --source=staging
```

### Option 2: Clone repository and run

```bash
git clone https://github.com/AdminBolt/Installer.git
cd Installer
sudo ./install.sh
```

Use a specific repository source:

```bash
sudo ./install.sh --source=staging
```

### Command reference

| Command | Description |
|---------|-------------|
| `sudo ./install.sh` | Install latest bolt-panel from repo |
| `sudo ./install.sh --source=<stable\|staging\|testing>` | Install from a specific repository source |
| `sudo ./install.sh --ssh-key="<public key>"` | Add an SSH key for root and turn SSH password login for root off once a sign-in with that key is seen (also `--ssh-key=https://...` for a URL that serves keys) |
| `sudo ./install.sh --help` | Show usage information |

### SSH key and password login

`--ssh-key` takes one public key (`ssh-ed25519 AAAA... comment`) or an `https://` URL that returns one key per line.
The key is checked before anything is installed and added to `/root/.ssh/authorized_keys`; keys already there stay.

At the end of the install, SSH password login for root is turned off only when all of these hold (other users, such as hosting accounts, keep theirs):

- the key is still in root's `authorized_keys`;
- sshd lets root sign in with a key, for the address the key was used from;
- sshd logs a root sign-in with that key after the installer has set up SSH. The installer asks you to sign in with the key from a new terminal and waits up to 10 minutes (Enter skips). Without a terminal (for example cloud-init) there is no such sign-in, so password login stays on.

Otherwise password login stays on and the installer prints the reason and the command to turn it off later.
Password login for root is turned off by `/etc/ssh/sshd_config.d/00-adminbolt-ssh-key-only.conf`; remove that file and run `systemctl reload sshd` to allow it again.

## Install flow

The installer runs in 3 stages:

1. Check prerequisites (root, supported OS, required commands, port 8443 availability)
2. Prepare system and install prerequisite/Bolt packages
3. Run `bolt-cli` post-install actions and print access details

## Access

After installation, the script prints an admin SSO URL.

If needed, you can generate a new one with:

`bolt-cli admin-sso-generate`
