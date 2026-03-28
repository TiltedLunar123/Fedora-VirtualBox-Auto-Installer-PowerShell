# Fedora VirtualBox Auto-Installer (PowerShell)

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg?logo=powershell)](https://docs.microsoft.com/en-us/powershell/)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-0078D6.svg?logo=windows)](https://www.microsoft.com/windows)

Fully automatic Fedora GNOME VM provisioning for VirtualBox on Windows. Creates a VM from scratch, feeds the installer a real Kickstart file through an attached `OEMDRV` disk, waits for the install to finish, removes the installer media, and boots the completed VM.

## Why This Script Exists

Most "automatic Fedora VM" scripts either generate a Kickstart file but never actually use it, rely on Fedora Live ISOs that aren't the right path for unattended installs, or depend on brittle VirtualBox unattended behavior that falls apart.

This script takes the cleaner route:

- **Fedora Everything netinstall ISO** (not Workstation Live)
- **Real Kickstart automation** via OEMDRV
- **OEMDRV disk auto-detected** by the Fedora installer natively

## What It Does

1. Detects your system specs (CPU, RAM, disk, GPU)
2. Calculates a sensible VM configuration automatically
3. Finds or downloads the Fedora **Everything netinstall** ISO
4. Creates a VirtualBox VM with optimized defaults
5. Builds a small `OEMDRV` VHD containing `ks.cfg`
6. Boots the Fedora installer — Kickstart handles the rest
7. Waits for the VM to power off when installation completes
8. Detaches the ISO and temporary Kickstart disk
9. Boots the finished Fedora VM
10. Creates helper scripts for starting, stopping, and SSHing into the VM

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

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-VMName` | String | `Fedora-Workstation` | Name for the VM |
| `-FedoraVersion` | String | `43` | Fedora release version |
| `-VMBaseDir` | String | `~/VirtualBox VMs` | Base directory for VMs |
| `-ISOPath` | String | — | Path to a local Fedora Everything netinstall ISO |
| `-GuestUsername` | String | `user` | Guest OS username |
| `-GuestPassword` | String | `fedora` | Guest OS password |
| `-GuestHostname` | String | `fedora-vm` | Guest OS hostname |
| `-GuestTimezone` | String | `America/New_York` | Timezone |
| `-SSHHostPort` | Int | `2222` | Host port for SSH forwarding |
| `-InstallTimeoutMinutes` | Int | `90` | Max wait for install |
| `-SkipDownload` | Switch | — | Skip auto-download; prompts for ISO file |
| `-Force` | Switch | — | Replace existing VM with the same name |
| `-Headless` | Switch | — | Run the VM without a GUI window |

## Files Created

Inside the VM folder, the script creates:

- The VirtualBox VM and main `.vdi` disk
- An `_autoinstall` folder with `ks.cfg` and `OEMDRV.vhd`
- Helper scripts: `Start-VM.bat`, `Stop-VM.bat`, `SSH-Connect.bat`

## Connecting via SSH

After the VM boots:

```bash
ssh -p 2222 user@localhost
```

## License

[MIT](LICENSE)
