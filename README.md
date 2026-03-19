# AdminBolt - Powerful and flexible hosting control panel

## Requirements

- **AlmaLinux 9** (only supported distribution)
- Root access (run with `sudo`)

## Installation

### Option 1: Download and run (one-liner)

Install the latest version:

```bash
curl -fsSL https://raw.githubusercontent.com/AdminBolt/Installer/main/install.sh -o install.sh && sudo bash install.sh
```

Install a specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/AdminBolt/Installer/main/install.sh -o install.sh && sudo bash install.sh --version=1.0.0.beta3-v3
```

### Option 2: Clone repository and run

```bash
git clone https://github.com/AdminBolt/Installer.git
cd Installer
sudo ./install.sh
```

For a specific version:

```bash
sudo ./install.sh --version=1.0.0.beta3-v3
```

### Command reference

| Command | Description |
|---------|-------------|
| `sudo ./install.sh` | Install latest bolt-panel from repo |
| `sudo ./install.sh --version=<VERSION>` | Install specific bolt-panel version |
| `sudo ./install.sh --help` | Show usage information |

## Access

After installation, the admin panel is available at:

**https://your-server-ip:8443**

Or use `bolt-cli admin-sso-generate` to get a one-time SSO login URL.
