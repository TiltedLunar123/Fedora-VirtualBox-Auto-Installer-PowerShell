# Invoke-SmartFedoraVBoxAutoProvision.ps1

Fully automatic Fedora GNOME VM provisioning for VirtualBox on Windows.

This script creates a Fedora VM from scratch, feeds the installer a real Kickstart file through an attached `OEMDRV` disk, waits for the install to finish, removes the installer media, and boots the completed VM.

It is built to do the whole job with as little manual input as possible.

---

## What it does

- Detects your system specs
- Calculates a sensible VM config automatically
- Finds or downloads the Fedora **Everything netinstall** ISO
- Creates a VirtualBox VM with optimized defaults
- Builds a small `OEMDRV` VHD containing `ks.cfg`
- Boots the Fedora installer and lets Kickstart handle the install automatically
- Waits for the VM to power off when installation is done
- Detaches the ISO and temporary Kickstart disk
- Boots the finished Fedora VM
- Creates helper scripts for starting, stopping, and SSHing into the VM

---

## Why this script exists

Most “automatic Fedora VM” scripts are half real and half fake.

They either:

- generate a Kickstart file but never actually use it
- rely on Fedora Live ISOs that are not the right path for a real unattended install
- depend on brittle VirtualBox unattended behavior and then fall apart

This script takes the cleaner route:

- **Fedora Everything netinstall ISO**
- **real Kickstart automation**
- **OEMDRV disk auto-detected by the installer**

That is the point.

---

## Requirements

- Windows
- PowerShell running **as Administrator**
- Oracle VirtualBox installed
- Hardware virtualization enabled in BIOS/UEFI
- Hyper-V / VBS not interfering with VirtualBox
- Working internet connection during Fedora install
- Enough disk space for:
  - Fedora ISO
  - VM disk
  - temporary `OEMDRV` VHD

---

## Default behavior

By default, the script:

- creates a VM named `Fedora-Workstation`
- uses Fedora version `43`
- creates the VM in:

  `C:\Users\<you>\VirtualBox VMs`

- creates a guest user:
  - username: `user`
  - password: `fedora`
  - hostname: `fedora-vm`

- forwards SSH like this:

  `localhost:2222 -> guest:22`

---

## Files it creates

Inside the VM folder, the script creates:

- the VirtualBox VM
- the main `.vdi` disk
- an `_autoinstall` folder with:
  - `ks.cfg`
  - `OEMDRV.vhd`
- helper scripts:
  - `Start-VM.bat`
  - `Stop-VM.bat`
  - `SSH-Connect.bat`

---

## Usage

### Basic run

```powershell
.\Invoke-SmartFedoraVBoxAutoProvision.ps1 -Force
