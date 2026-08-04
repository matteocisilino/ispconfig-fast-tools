# ISPConfig Fast Tools

A collection of robust, automated scripts for managing ISPConfig environments.

## `reset_DB_password.sh`

This script provides an automated, bulletproof way to safely rotate and update the core database credentials used by ISPConfig. It works flawlessly across **Standalone**, **Master**, and **Slave** nodes by automatically detecting the server role and executing only the necessary rotation phases.

### Features

- **Automated Role Detection**: Automatically detects whether the server is a Master, Slave, or Standalone node.
- **Three-Phase Rotation**:
  - **Phase A**: Rotates the local `root` database password (used by ISPConfig to manage hosted websites) and updates `mysql_clientdb.conf`.
  - **Phase B**: Rotates the local standard `ispconfig` control user password, meticulously updates `config.inc.php` across both the server and interface directories, and automatically updates external service configurations (Dovecot, Pure-FTPd, Postfix) to prevent service disruption.
  - **Phase C (Slaves Only)**: Connects remotely to the Master DB, rotates the slave user's password on the Master, and updates `dbmaster_password` locally.
- **Fail-safe Backups**:
  - Automatically performs a full `rsync` backup of `/usr/local/ispconfig/` before making any changes.
  - Optionally attempts a non-blocking `mysqldump` of the `mysql` and `dbispconfig` databases.
  - Creates `.bak` copies of specific configuration files right before replacing strings in them.
- **High-Security Passwords**: Generates 32-character, ultra-high entropy alphanumeric passwords (`A-Za-z0-9`) to ensure absolute compatibility with all MySQL and PHP parsers while maintaining top-tier security.
- **Interactive & Dry-Run Modes**: Always asks for confirmation before executing each phase. Supports a `--dry-run` flag to simulate what would happen without altering any data.

### Usage

You must run this script as the `root` user on the system.

```bash
# Clone the repository (if you haven't already)
git clone https://github.com/matteocisilino/ispconfig-fast-tools.git
cd ispconfig-fast-tools

# Make the script executable
chmod +x reset_DB_password.sh

# Run the script
./reset_DB_password.sh
```

#### Flags & Options

- `--dry-run` : Simulates the entire process without modifying databases or files. Highly recommended for the first execution.
- `--skip-local-root` : Explicitly skips Phase A (rotation of the local MySQL root password). Useful if you only want to rotate the ISPConfig panel user passwords.
- `--role=<master|slave>` : Forces the script to run as a specific role instead of relying on auto-detection.

### Workflow Example

When you run the script, it will:
1. Detect the server role.
2. Back up the `/usr/local/ispconfig` directory to `/usr/local/ispconfig_<timestamp>`.
3. Proceed to **Phase A** and ask for confirmation. If approved, it generates a new password, applies it via batch SQL to all local `root` hosts, tests the connection, and updates `mysql_clientdb.conf`.
4. Proceed to **Phase B**. It will intelligently re-use the newly generated root password from Phase A to authenticate, rotate the `ispconfig` user password for all associated hosts, update `config.inc.php`, and apply the new credentials to Dovecot, Pure-FTPd, and Postfix configurations. Afterwards, it will prompt you to automatically restart these services.
5. If the server is a **Slave**, it will proceed to **Phase C**, prompting you for the *Remote Master's* root password to authorize the remote credential update.

### Requirements
- A working ISPConfig 3 installation (`/usr/local/ispconfig/`).
- Standard Linux utilities: `bash`, `sed`, `grep`, `rsync`, `mysql`, `mysqldump`.

### Compatibility
- Tested successfully on **ISPConfig version 3.3.1p1**.

### Disclaimer ⚠️
**USE AT YOUR OWN RISK.**
While this script performs automatic backups of the ISPConfig directory and databases before applying changes, it modifies core system credentials. 
The author is not responsible for any data loss, system downtime, or broken configurations. **Always ensure you have an independent, full system backup (or a VM snapshot) available before running this tool.**

### License & Credits
This script is released as Free Software. You are free to distribute and modify it, provided that you include attribution to the original creator.

**Creator:** Matteo Cisilino  
**Email:** matteocisilino@gmail.com
