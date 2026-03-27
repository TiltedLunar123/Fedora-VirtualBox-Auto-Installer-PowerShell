# Fedora VirtualBox Auto-Installer (PowerShell)

Fully automatic Fedora GNOME VM provisioning for VirtualBox on Windows.

This script creates a Fedora VM from scratch, feeds the installer a real Kickstart file through an attached `OEMDRV` disk, waits for the install to finish, removes the installer media, and boots the completed VM. It is built to do the whole job with as little manual input as possible.

---

## What It Does

- Detects your system specs (CPU, RAM, disk, GPU)
- Calculates a sensible VM configuration automatically
- Finds or downloads the Fedora **Everything netinstall** ISO
- Creates a VirtualBox VM with optimized defaults
- Builds a small `OEMDRV` VHD containing `ks.cfg`
- Boots the Fedora installer and lets Kickstart handle the install automatically
- Waits for the VM to power off when installation is done
- Detaches the ISO and temporary Kickstart disk
- Boots the finished Fedora VM
- Creates helper scripts for starting, stopping, and SSHing into the VM

---

## Why This Script Exists

Most "automatic Fedora VM" scripts are half real and half fake. They either generate a Kickstart file but never actually use it, rely on Fedora Live ISOs that are not the right path for a real unattended install, or depend on brittle VirtualBox unattended behavior and then fall apart.

This script takes the cleaner route:

- **Fedora Everything netinstall ISO** (not Workstation Live)
- **Real Kickstart automation** via OEMDRV
- **OEMDRV disk auto-detected** by the Fedora installer natively

---

## Requirements

- **Windows** (10 or 11)
- **PowerShell** running **as Administrator**
- **Oracle VirtualBox** installed ([download](https://www.virtualbox.org/wiki/Downloads))
- Hardware virtualization enabled in BIOS/UEFI (VT-x or AMD-V)
- Hyper-V / VBS not interfering with VirtualBox
- Working internet connection (Fedora netinstall needs to download packages)
- Enough disk space for the Fedora ISO, VM disk, and temporary OEMDRV VHD

---

## Default Behavior

| Setting      | Default Value                           |
| ------------ | --------------------------------------- |
| VM Name      | `Fedora-Workstation`                    |
| Fedora       | `43`                                    |
| VM Location  | `C:\Users\<you>\VirtualBox VMs`         |
| Username     | `user`                                  |
| Password     | `fedora`                                |
| Hostname     | `fedora-vm`                             |
| SSH Forward  | `localhost:2222` -> `guest:22`          |

---

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

### All Parameters

| Parameter               | Type     | Description                                    |
| ----------------------- | -------- | ---------------------------------------------- |
| `-VMName`               | String   | Name for the VM (default: `Fedora-Workstation`) |
| `-FedoraVersion`        | String   | Fedora release version (default: `43`)          |
| `-VMBaseDir`            | String   | Base directory for VMs                          |
| `-ISOPath`              | String   | Path to a local Fedora Everything netinstall ISO |
| `-GuestUsername`        | String   | Guest OS username (default: `user`)              |
| `-GuestPassword`        | String   | Guest OS password (default: `fedora`)            |
| `-GuestHostname`        | String   | Guest OS hostname (default: `fedora-vm`)         |
| `-GuestTimezone`        | String   | Timezone (default: `America/New_York`)           |
| `-SSHHostPort`          | Int      | Host port for SSH forwarding (default: `2222`)   |
| `-InstallTimeoutMinutes`| Int      | Max wait for install (default: `90`)             |
| `-SkipDownload`         | Switch   | Skip auto-download; prompts for ISO file         |
| `-Force`                | Switch   | Replace existing VM with the same name           |
| `-Headless`             | Switch   | Run the VM without a GUI window                  |

---

## Files Created

Inside the VM folder, the script creates:

- The VirtualBox VM and main `.vdi` disk
- An `_autoinstall` folder with `ks.cfg` and `OEMDRV.vhd`
- Helper scripts: `Start-VM.bat`, `Stop-VM.bat`, `SSH-Connect.bat`

---

## Connecting via SSH

After the VM boots, connect with:

```bash
ssh -p 2222 user@localhost
```

---

## License

This project is licensed under the [MIT License](LICENSE).
