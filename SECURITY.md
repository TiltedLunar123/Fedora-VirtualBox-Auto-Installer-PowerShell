# Security Policy

VirtualBox Auto-Installer is a local provisioning tool that creates VirtualBox VMs from RHEL-family distributions on Windows. This document describes the script's security model and how to report vulnerabilities.

## Permissions

This script requires **Administrator privileges** because creating VHD disk images and mounting them uses `diskpart.exe`, which is a protected system operation.

| Action | Why Admin Is Needed |
|---|---|
| `diskpart.exe` | Create and mount the OEMDRV VHD for Kickstart delivery |
| `VBoxManage.exe` | Create, configure, and manage VirtualBox VMs |
| `Start-BitsTransfer` / `Invoke-WebRequest` | Download the distribution ISO |

**No other elevated operations are performed.** The script does not modify the registry, install services, change firewall rules, or create scheduled tasks.

## What This Tool Does

- Detects system hardware specs (CPU, RAM, disk, GPU) to calculate VM configuration
- Downloads a distribution ISO from official mirrors (with SHA256 checksum verification)
- Creates a VirtualBox VM with optimized settings
- Builds a temporary OEMDRV VHD containing a Kickstart file (with SHA-512 hashed password)
- Boots the VM and waits for the unattended install to complete
- Detaches install media and cleans up sensitive artifacts
- Creates helper scripts for VM management (Start, Stop, SSH)

## What This Tool Does NOT Do

- **No telemetry.** No usage data, analytics, or crash reports are collected or sent anywhere.
- **No network requests** beyond ISO downloads from official distribution mirrors and checksum verification. No HTTP calls to third-party APIs.
- **No persistent system changes** beyond VirtualBox VM registration. No registry edits, no startup entries, no background services.
- **No data exfiltration.** The script only contacts official distribution mirrors listed in the source code.
- **No host OS modification.** All changes are contained within the VirtualBox VM directory.

## Password Handling

- Guest passwords are hashed with **SHA-512** (`$6$` crypt format) before being written to the Kickstart file
- Hashing uses `openssl passwd -6` or Python's `crypt` module
- If no hashing tool is available, the script **terminates with an error** rather than using plaintext
- The Kickstart file (`ks.cfg`) and OEMDRV disk (`OEMDRV.vhd`) are automatically deleted after installation unless `-KeepArtifacts` is specified

## Artifact Cleanup

After installation completes, the script removes:

1. `ks.cfg` — Contains the Kickstart configuration including the hashed password
2. `OEMDRV.vhd` — The temporary disk image that delivered the Kickstart file

These files are stored in `<VM directory>/_autoinstall/` during provisioning. Use `-KeepArtifacts` only for debugging purposes.

## ISO Verification

Downloaded ISOs are verified against the official SHA256 checksum file published by the distribution. User-provided ISOs (via `-ISOPath`) skip this verification — users are responsible for verifying ISOs they supply manually.

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do not** open a public issue.
2. Use GitHub's [private vulnerability reporting](https://github.com/TiltedLunar123/Fedora-VirtualBox-Auto-Installer-PowerShell/security/advisories/new) feature, or email the maintainer at the address listed in the GitHub profile.
3. Include:
   - A description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

I take security issues seriously and will respond as quickly as possible.

## Supported Versions

Only the latest release is actively maintained. Please ensure you're running the most recent version before reporting.
