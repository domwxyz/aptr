# aptr - APT Rolling Package Manager

A tool for managing mixed Debian systems with stable core packages and selective rolling packages from unstable.

## Description

**aptr** provides granular control over which packages track Debian's unstable branch while maintaining a stable system foundation. Instead of running a full unstable system or manual APT pinning, aptr automates the configuration and management of mixed package sources.

## Features

- Automatic APT preferences configuration with intelligent pinning
- Selective package tracking from unstable repository
- Rolling update management for chosen packages
- Dry-run mode for previewing operations
- Comprehensive logging and status reporting
- Safety checks and validation

## Installation

```bash
curl <location coming soon>
chmod +x aptr.sh
sudo mv aptr.sh /usr/local/bin/aptr
```

## Quick Start

```bash
# Initialize the system
sudo aptr init

# Install a package from unstable
sudo aptr install python3-dev

# Install a package from stable
sudo aptr install --stable nginx

# List rolling packages
aptr list

# Upgrade all rolling packages
sudo aptr upgrade
```

## Usage

### Commands

- `init` - Initialize system for mixed package management
- `install <package>` - Install package from unstable (default) or stable with --stable flag
- `list` - Display all rolling packages with version information
- `upgrade` - Update all rolling packages to latest unstable versions
- `roll <package>` - Convert installed package from stable to rolling (unstable)
- `unroll <package>` - Remove package from rolling status
- `search <query>` - Search packages in both stable and unstable repositories
- `status` - Show system configuration and package statistics

### Options

- `-v, --verbose` - Enable detailed output
- `-n, --dry-run` - Preview actions without execution
- `-f, --force` - Skip confirmation prompts
- `-y, --yes` - Automatic yes to prompts
- `-s, --stable` - Install from stable branch (for install command)
- `-h, --help` - Display help information
- `--version` - Show version information

### Examples

```bash
# Development environment setup
sudo aptr install golang-1.21
sudo aptr install nodejs
sudo aptr install --stable systemd

# Regular maintenance
sudo aptr -y upgrade
sudo aptr --dry-run upgrade  # Preview changes

# Package management
aptr search docker
sudo aptr roll --dry-run prometheus
sudo aptr unroll python3-dev
```

## Configuration

aptr creates and manages the following files:

- `/etc/apt/sources.list.d/aptr-unstable.list` - Unstable repository configuration
- `/etc/apt/preferences.d/aptr-preferences` - APT pinning preferences
- `/var/lib/aptr/rolling-packages` - Rolling package tracking
- `/var/log/aptr.log` - Operation logs

### APT Pinning Strategy

- Stable packages: Priority 990 (highest)
- Unstable packages: Priority 100 (default low)
- Rolling packages: Priority 990 (high for selected packages)

## Requirements

- Debian-based system with APT package manager
- Root/sudo privileges
- Bash 4.0 or later

## Safety Considerations

1. Always maintain system backups
2. Start with non-critical packages
3. Use `--dry-run` to preview changes
4. Monitor `/var/log/aptr.log` for issues
5. Be aware of dependency implications

## License

GNU General Public License v3.0

## Contributing

Contributions welcome via GitHub pull requests. For major changes, please open an issue first to discuss proposed modifications.
