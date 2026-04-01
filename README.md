# VirtualBox Auto-Installer (PowerShell)

[![CI](https://github.com/TiltedLunar123/Fedora-VirtualBox-Auto-Installer-PowerShell/actions/workflows/ci.yml/badge.svg)](https://github.com/TiltedLunar123/Fedora-VirtualBox-Auto-Installer-PowerShell/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg?logo=powershell)](https://docs.microsoft.com/en-us/powershell/)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-0078D6.svg?logo=windows)](https://www.microsoft.com/windows)

Fully automatic RHEL-family VM provisioning for VirtualBox on Windows. Creates a VM from scratch, feeds the installer a real Kickstart file through an attached `OEMDRV` disk, waits for the install to finish, removes the installer media, and boots the completed VM.

## Supported Distributions

| Distribution | Default Package Group | Default Hostname |
|---|---|---|
| **Fedora** (default) | `@^workstation-product-environment` | `fedora-vm` |
| **CentOS-Stream** | `@^server-product-environment` | `centos-vm` |
| **AlmaLinux** | `@^server-product-environment` | `alma-vm` |
| **Rocky** | `@^server-product-environment` | `rocky-vm` |

All distributions use the same Kickstart-based automation. The script automatically selects the correct ISO download URL, package groups, and OS type for each distro.

## Why This Script Exists

Most "automatic Fedora VM" scripts either generate a Kickstart file but never actually use it, rely on Fedora Live ISOs that aren't the right path for unattended installs, or depend on brittle VirtualBox unattended behavior that falls apart.

This script takes the cleaner route:

- **Everything netinstall ISO** (not Workstation Live)
- **Real Kickstart automation** via OEMDRV
- **OEMDRV disk auto-detected** by the installer natively

## What It Does

1. Detects your system specs (CPU, RAM, disk, GPU)
2. Calculates a sensible VM configuration automatically
3. Finds or downloads the ISO (with SHA256 checksum verification)
4. Creates a VirtualBox VM with optimized defaults
5. Builds a small `OEMDRV` VHD containing `ks.cfg` (password SHA-512 hashed)
6. Boots the installer -- Kickstart handles the rest
7. Waits for the VM to power off when installation completes
8. Detaches the ISO and temporary Kickstart disk
9. Cleans up sensitive install artifacts (`ks.cfg`, `OEMDRV.vhd`)
10. Boots the finished VM
11. Creates PowerShell helper scripts for starting, stopping, and SSHing into the VM
12. Saves provision state for resume on re-run

## Requirements

- **Windows** 10 or 11
- **PowerShell** running **as Administrator**
- **Oracle VirtualBox** installed ([download](https://www.virtualbox.org/wiki/Downloads))
- Hardware virtualization enabled in BIOS/UEFI (VT-x or AMD-V)
- Hyper-V / VBS not interfering with VirtualBox
- Working internet connection (netinstall downloads packages)

## Usage

### Basic Run

```powershell
.\New-FedoraVirtualBoxVM.ps1 -Force
```

### Custom Settings

```powershell
.\New-FedoraVirtualBoxVM.ps1 -VMName "MyFedora" -FedoraVersion "43" -GuestUsername "admin" -GuestPassword "secret" -Force
```

### Use a Local ISO (Skip Download)

```powershell
.\New-FedoraVirtualBoxVM.ps1 -ISOPath "C:\ISOs\Fedora-Everything-netinst-x86_64-43-1.1.iso" -Force
```

### Headless Mode

```powershell
.\New-FedoraVirtualBoxVM.ps1 -Force -Headless
```

### Other Distributions

```powershell
.\New-FedoraVirtualBoxVM.ps1 -Distro "AlmaLinux" -FedoraVersion "9" -Force
.\New-FedoraVirtualBoxVM.ps1 -Distro "Rocky" -FedoraVersion "9" -Force
.\New-FedoraVirtualBoxVM.ps1 -Distro "CentOS-Stream" -FedoraVersion "9" -Force
```

### Pre-Flight Validation (Dry Run)

```powershell
.\New-FedoraVirtualBoxVM.ps1 -Validate
```

Runs all pre-flight checks (VirtualBox installed, VT-x, disk space, ISO availability, port conflicts) without creating anything.

### Shared Folder

```powershell
.\New-FedoraVirtualBoxVM.ps1 -Force -SharedFolder "C:\Users\me\Projects"
```

The shared folder will be available inside the VM at `/mnt/shared`.

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-VMName` | String | `Fedora-Workstation` | Name for the VM |
| `-FedoraVersion` | String | `43` | Release version |
| `-VMBaseDir` | String | `~/VirtualBox VMs` | Base directory for VMs |
| `-ISOPath` | String | -- | Path to a local ISO |
| `-GuestUsername` | String | `user` | Guest OS username |
| `-GuestPassword` | String | `fedora` | Guest OS password |
| `-GuestHostname` | String | `fedora-vm` | Guest OS hostname |
| `-GuestTimezone` | String | `America/New_York` | Timezone |
| `-SSHHostPort` | Int | `2222` | Host port for SSH forwarding |
| `-InstallTimeoutMinutes` | Int | `90` | Max wait for install |
| `-SkipDownload` | Switch | -- | Skip auto-download; prompts for ISO file |
| `-Force` | Switch | -- | Replace existing VM with the same name |
| `-Headless` | Switch | -- | Run the VM without a GUI window |
| `-Distro` | String | `Fedora` | Distribution: `Fedora`, `CentOS-Stream`, `AlmaLinux`, `Rocky` |
| `-Validate` | Switch | -- | Run pre-flight checks only (dry run) |
| `-KeepArtifacts` | Switch | -- | Keep `ks.cfg` and `OEMDRV.vhd` after install |
| `-NoResume` | Switch | -- | Ignore saved state; start provisioning from scratch |
| `-SecureSudo` | Switch | -- | Require password for sudo (no NOPASSWD) |
| `-SharedFolder` | String | -- | Host path to share with the guest VM |

## Security

### Password Hashing

Guest passwords are hashed with SHA-512 before being written to the Kickstart file. The script tries `openssl` first, then falls back to `python`. If neither is available, it warns and uses plaintext as a last resort.

### Artifact Cleanup

After installation completes, the script automatically deletes `ks.cfg` and `OEMDRV.vhd` from the `_autoinstall` directory. These files contain sensitive configuration including password data. Use `-KeepArtifacts` to preserve them if needed for debugging.

### Sudo Configuration

By default, the guest user gets passwordless sudo (`NOPASSWD: ALL`). Use `-SecureSudo` to require password authentication for sudo commands.

### ISO Checksum Verification

Downloaded ISOs are automatically verified against the official SHA256 checksum file from the distribution mirror. User-provided ISOs (via `-ISOPath`) skip this check.

## Files Created

Inside the VM folder, the script creates:

- The VirtualBox VM and main `.vdi` disk
- An `_autoinstall` folder with provision state (artifacts cleaned up after install)
- Helper scripts: `Start-VM.ps1`, `Stop-VM.ps1`, `SSH-Connect.ps1`

## Connecting via SSH

After the VM boots:

```bash
ssh -p 2222 user@localhost
```

## Resume / Checkpoint

If provisioning is interrupted, re-running with `-Force` will resume from the last completed step. The script tracks progress in `_autoinstall/provision-state.json`. Use `-NoResume` to force starting from scratch.

## License

[MIT](LICENSE)
