#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Fully automatic Fedora GNOME VM provisioner for VirtualBox on Windows.

.DESCRIPTION
    - Detects host specs
    - Downloads Fedora Everything netinstall ISO
    - Creates an optimized VirtualBox VM
    - Creates a tiny OEMDRV VHD containing ks.cfg
    - Boots Fedora installer, which auto-loads ks.cfg
    - Waits for install completion (guest powers off)
    - Detaches install media + OEMDRV disk
    - Boots the finished Fedora Workstation VM

.NOTES
    Honest version:
    - Uses Fedora Everything netinstall, not Workstation Live
    - Uses real Kickstart automation via OEMDRV
    - Avoids pretending VBox unattended magically handles Fedora desktop installs

    Default login:
      user:     user
      password: fedora

    Change those with -GuestUsername / -GuestPassword.
#>

[CmdletBinding()]
param(
    [string]$VMName = "Fedora-Workstation",
    [string]$FedoraVersion = "43",
    [string]$VMBaseDir = "$env:USERPROFILE\VirtualBox VMs",
    [string]$ISOPath,
    [string]$GuestUsername = "user",
    [string]$GuestPassword = "fedora",
    [string]$GuestHostname = "fedora-vm",
    [string]$GuestTimezone = "America/New_York",
    [int]$SSHHostPort = 2222,
    [int]$InstallTimeoutMinutes = 90,
    [switch]$SkipDownload,
    [switch]$Force,
    [switch]$Headless
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

$Script:Colors = @{
    Header  = "Cyan"
    Success = "Green"
    Warning = "Yellow"
    Error   = "Red"
    Info    = "White"
    Accent  = "Magenta"
}

function Write-Banner {
    $banner = @"

    ╔══════════════════════════════════════════════════════════╗
    ║     FEDORA VIRTUALBOX AUTO-PROVISIONER v4.0             ║
    ║     Real Kickstart Automation via OEMDRV                ║
    ╚══════════════════════════════════════════════════════════╝

"@
    Write-Host $banner -ForegroundColor $Script:Colors.Accent
}

function Write-Step {
    param(
        [string]$Message,
        [ValidateSet("RUNNING","DONE","WARN","ERROR","INFO")]
        [string]$Status = "RUNNING"
    )

    $icon = switch ($Status) {
        "RUNNING" { "⚡" }
        "DONE"    { "✅" }
        "WARN"    { "⚠️" }
        "ERROR"   { "❌" }
        "INFO"    { "ℹ️" }
    }

    $color = switch ($Status) {
        "RUNNING" { $Script:Colors.Info }
        "DONE"    { $Script:Colors.Success }
        "WARN"    { $Script:Colors.Warning }
        "ERROR"   { $Script:Colors.Error }
        "INFO"    { $Script:Colors.Header }
    }

    Write-Host "  $icon " -NoNewline -ForegroundColor $color
    Write-Host $Message -ForegroundColor $color
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$NoThrow
    )

    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not $NoThrow) {
        $cmd = "$FilePath $($Arguments -join ' ')"
        $text = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            $text = "Unknown external command error."
        }
        throw "Command failed (exit $exitCode): $cmd`n$text"
    }

    return ($output | Out-String).Trim()
}

function Invoke-VBoxManage {
    param(
        [Parameter(Mandatory)]
        [string]$VBoxManage,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$NoThrow
    )

    return Invoke-ExternalCommand -FilePath $VBoxManage -Arguments $Arguments -NoThrow:$NoThrow
}

function Test-HostVirtualizationWarnings {
    Write-Host "`n  ── Host Checks ──" -ForegroundColor $Script:Colors.Header

    try {
        $hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
        if ($hv.State -eq "Enabled") {
            Write-Step "Hyper-V appears enabled. VirtualBox may run poorly or fail until Hyper-V/VBS is disabled." "WARN"
        } else {
            Write-Step "Hyper-V not enabled." "INFO"
        }
    }
    catch {
        Write-Step "Could not query Hyper-V state. Continuing." "WARN"
    }
}

function Get-SystemSpecs {
    Write-Host "`n  ── System Detection ──" -ForegroundColor $Script:Colors.Header

    $cpu = Get-CimInstance -ClassName Win32_Processor
    $totalCores = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
    $totalLogical = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    $cpuName = ($cpu | Select-Object -First 1).Name.Trim()

    $totalRAMBytes = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
    $totalRAMGB = [math]::Round($totalRAMBytes / 1GB, 1)

    $bestDrive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" |
        Sort-Object FreeSpace -Descending |
        Select-Object -First 1

    if (-not $bestDrive) {
        throw "No fixed disk found."
    }

    $freeSpaceGB = [math]::Round($bestDrive.FreeSpace / 1GB, 1)
    $driveLetter = $bestDrive.DeviceID

    $gpu = Get-CimInstance -ClassName Win32_VideoController | Select-Object -First 1
    $gpuName = if ($gpu -and $gpu.Name) { $gpu.Name } else { "Unknown GPU" }
    $gpuVRAMMB = if ($gpu -and $gpu.AdapterRAM) {
        [math]::Round($gpu.AdapterRAM / 1MB)
    } else {
        128
    }
    if ($gpuVRAMMB -le 0) { $gpuVRAMMB = 128 }

    $vtxEnabled = $false
    try {
        $vtx = (Get-CimInstance -ClassName Win32_Processor).VirtualizationFirmwareEnabled
        $vtxEnabled = ($vtx -contains $true)
    }
    catch { }

    $specs = [PSCustomObject]@{
        CPUName       = $cpuName
        PhysicalCores = [int]$totalCores
        LogicalCores  = [int]$totalLogical
        TotalRAMGB    = [double]$totalRAMGB
        FreeSpaceGB   = [double]$freeSpaceGB
        BestDrive     = $driveLetter
        GPUName       = $gpuName
        GPUVRAM_MB    = [int]$gpuVRAMMB
        VTxEnabled    = [bool]$vtxEnabled
    }

    Write-Step "CPU: $cpuName ($totalCores cores / $totalLogical threads)" "INFO"
    Write-Step "RAM: $totalRAMGB GB total" "INFO"
    Write-Step "Disk: $driveLetter - $freeSpaceGB GB free" "INFO"
    Write-Step "GPU: $gpuName ($gpuVRAMMB MB VRAM)" "INFO"
    Write-Step "VT-x/AMD-V: $(if ($vtxEnabled) { 'Enabled' } else { 'Not detected (check BIOS)' })" $(if ($vtxEnabled) { "INFO" } else { "WARN" })

    return $specs
}

function Get-OptimalVMConfig {
    param([Parameter(Mandatory)][PSCustomObject]$Specs)

    Write-Host "`n  ── Calculating Optimal VM Config ──" -ForegroundColor $Script:Colors.Header

    $vmCPUs = [math]::Max(2, [math]::Min(8, [math]::Floor($Specs.LogicalCores * 0.5)))
    if ($vmCPUs -lt 2) { $vmCPUs = 2 }

    $ramPercent = if     ($Specs.TotalRAMGB -ge 32) { 0.35 }
                  elseif ($Specs.TotalRAMGB -ge 16) { 0.40 }
                  elseif ($Specs.TotalRAMGB -ge 8)  { 0.50 }
                  else                              { 0.50 }

    $vmRAMMB = [math]::Floor(($Specs.TotalRAMGB * $ramPercent) * 1024 / 256) * 256
    $vmRAMMB = [math]::Max(4096, [math]::Min(16384, [int]$vmRAMMB))

    $vmDiskGB = if     ($Specs.FreeSpaceGB -ge 200) { 80 }
                elseif ($Specs.FreeSpaceGB -ge 100) { 60 }
                elseif ($Specs.FreeSpaceGB -ge 50)  { 40 }
                else                                { 30 }

    $vmVRAMMB = [math]::Floor(([math]::Min(128, [math]::Max(64, ($Specs.GPUVRAM_MB / 4)))) / 16) * 16
    $enable3D = $Specs.GPUVRAM_MB -ge 512

    $config = [PSCustomObject]@{
        CPUs               = [int]$vmCPUs
        RAMMB              = [int]$vmRAMMB
        DiskGB             = [int]$vmDiskGB
        VRAMMB             = [int]$vmVRAMMB
        Enable3D           = [bool]$enable3D
        GraphicsController = "vmsvga"
        Chipset            = "ich9"
        ParavirtProvider   = "kvm"
        Resolution         = "1920x1080"
    }

    Write-Step "CPUs: $($config.CPUs)" "DONE"
    Write-Step "RAM: $([math]::Round($config.RAMMB / 1024, 1)) GB ($($config.RAMMB) MB)" "DONE"
    Write-Step "Disk: $($config.DiskGB) GB dynamic" "DONE"
    Write-Step "Video: $($config.VRAMMB) MB VRAM, 3D=$(if ($config.Enable3D) { 'ON' } else { 'OFF' })" "DONE"

    return $config
}

function Find-VBoxManage {
    Write-Host "`n  ── Locating VirtualBox ──" -ForegroundColor $Script:Colors.Header

    $candidates = @()

    $cmd = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }

    $candidates += @(
        "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
        "${env:ProgramFiles(x86)}\Oracle\VirtualBox\VBoxManage.exe",
        "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
    ) | Select-Object -Unique

    foreach ($path in $candidates) {
        if ($path -and (Test-Path $path)) {
            Write-Step "Found VBoxManage: $path" "DONE"
            return $path
        }
    }

    Start-Process "https://www.virtualbox.org/wiki/Downloads"
    throw "VBoxManage.exe not found. Install VirtualBox first, then rerun."
}

function Get-FreeDriveLetter {
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    foreach ($letter in @("Z","Y","X","W","V","U","T","S","R","Q","P","O","N","M","L","K","J","I","H","G","F","E","D")) {
        if ($used -notcontains $letter) {
            return $letter
        }
    }
    throw "No free drive letter available."
}

function Get-FedoraNetinstISO {
    param(
        [Parameter(Mandatory)][string]$Version,
        [string]$ProvidedISOPath
    )

    Write-Host "`n  ── Fedora Netinstall ISO ──" -ForegroundColor $Script:Colors.Header

    if ($ProvidedISOPath) {
        if (-not (Test-Path $ProvidedISOPath)) {
            throw "Specified ISO path not found: $ProvidedISOPath"
        }
        $resolved = (Resolve-Path $ProvidedISOPath).Path
        Write-Step "Using provided ISO: $resolved" "DONE"
        return $resolved
    }

    $downloadDir = Join-Path $env:USERPROFILE "Downloads"
    if (-not (Test-Path $downloadDir)) {
        New-Item -Path $downloadDir -ItemType Directory -Force | Out-Null
    }

    $existing = Get-ChildItem -Path $downloadDir -Filter "Fedora-Everything-netinst-x86_64-$Version-*.iso" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($existing) {
        Write-Step "Found local ISO: $($existing.FullName)" "DONE"
        return $existing.FullName
    }

    if ($SkipDownload) {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = "Select Fedora Everything netinstall ISO"
        $dialog.Filter = "ISO files (*.iso)|*.iso"
        $dialog.InitialDirectory = $downloadDir
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Write-Step "Selected ISO: $($dialog.FileName)" "DONE"
            return $dialog.FileName
        }
        throw "No ISO selected."
    }

    $indexUrl = "https://download.fedoraproject.org/pub/fedora/linux/releases/$Version/Everything/x86_64/iso/"
    Write-Step "Resolving latest Fedora Everything netinstall ISO..." "RUNNING"

    try {
        $listing = Invoke-WebRequest -Uri $indexUrl -UseBasicParsing
    }
    catch {
        throw "Failed to access Fedora release directory: $indexUrl"
    }

    $matches = [regex]::Matches($listing.Content, "Fedora-Everything-netinst-x86_64-$Version-[0-9.]+\.iso") |
        ForEach-Object { $_.Value } |
        Select-Object -Unique

    $isoName = $matches | Sort-Object -Descending | Select-Object -First 1
    if (-not $isoName) {
        throw "Could not resolve a Fedora Everything netinstall ISO name from $indexUrl"
    }

    $isoUrl = "$indexUrl$isoName"
    $isoPath = Join-Path $downloadDir $isoName

    Write-Step "Downloading $isoName ..." "RUNNING"
    try {
        Start-BitsTransfer -Source $isoUrl -Destination $isoPath -Description "Downloading Fedora Everything netinstall ISO"
    }
    catch {
        Invoke-WebRequest -Uri $isoUrl -OutFile $isoPath -UseBasicParsing
    }

    if (-not (Test-Path $isoPath)) {
        throw "ISO download failed."
    }

    Write-Step "ISO ready: $isoPath" "DONE"
    return $isoPath
}

function New-KickstartFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$Timezone
    )

    Write-Host "`n  ── Creating Kickstart ──" -ForegroundColor $Script:Colors.Header

    $ks = @"
#version=DEVEL
text

lang en_US.UTF-8
keyboard us
timezone $Timezone --utc

network --bootproto=dhcp --device=link --activate --hostname=$Hostname

rootpw --lock
user --name=$Username --password=$Password --plaintext --groups=wheel

firewall --enabled --service=ssh
selinux --enforcing
services --enabled=NetworkManager,sshd

firstboot --disable
eula --agreed

ignoredisk --only-use=sda
zerombr
clearpart --all --initlabel --drives=sda
autopart --type=lvm

bootloader --location=boot

shutdown

%packages
@^workstation-product-environment
openssh-server
sudo
curl
wget
git
htop
vim-enhanced
gnome-tweaks
%end

%post --erroronfail
echo "$Username ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/90-$Username
chmod 440 /etc/sudoers.d/90-$Username

mkdir -p /etc/gdm
cat > /etc/gdm/custom.conf <<'EOF'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=$Username
WaylandEnable=false
EOF

systemctl enable gdm
systemctl enable sshd
systemctl disable initial-setup.service || true
systemctl disable gnome-initial-setup.service || true
%end
"@

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $ks | Out-File -FilePath $Path -Encoding ascii -Force
    Write-Step "Kickstart created: $Path" "DONE"
    return $Path
}

function New-OEMDRVVHD {
    param(
        [Parameter(Mandatory)][string]$VHDPath,
        [Parameter(Mandatory)][string]$KickstartPath
    )

    Write-Host "`n  ── Creating OEMDRV Disk ──" -ForegroundColor $Script:Colors.Header

    if (Test-Path $VHDPath) {
        Remove-Item $VHDPath -Force
    }

    $driveLetter = Get-FreeDriveLetter
    $diskpartScript = Join-Path $env:TEMP "diskpart-oemdrv-create.txt"

    @"
create vdisk file="$VHDPath" maximum=64 type=expandable
select vdisk file="$VHDPath"
attach vdisk
create partition primary
format fs=fat quick label=OEMDRV
assign letter=$driveLetter
exit
"@ | Out-File -FilePath $diskpartScript -Encoding ascii -Force

    $dpOut = Invoke-ExternalCommand -FilePath "diskpart.exe" -Arguments @("/s", $diskpartScript)
    Remove-Item $diskpartScript -Force -ErrorAction SilentlyContinue

    $dest = "${driveLetter}:\ks.cfg"
    Copy-Item -Path $KickstartPath -Destination $dest -Force
    Write-Step "Copied ks.cfg to ${driveLetter}:\ " "DONE"

    $diskpartDetach = Join-Path $env:TEMP "diskpart-oemdrv-detach.txt"
    @"
select vdisk file="$VHDPath"
detach vdisk
exit
"@ | Out-File -FilePath $diskpartDetach -Encoding ascii -Force

    $null = Invoke-ExternalCommand -FilePath "diskpart.exe" -Arguments @("/s", $diskpartDetach)
    Remove-Item $diskpartDetach -Force -ErrorAction SilentlyContinue

    Write-Step "OEMDRV VHD ready: $VHDPath" "DONE"
    return $VHDPath
}

function Get-VMState {
    param(
        [Parameter(Mandatory)][string]$VBoxManage,
        [Parameter(Mandatory)][string]$VMName
    )

    $info = Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @("showvminfo", $VMName, "--machinereadable") -NoThrow
    if ([string]::IsNullOrWhiteSpace($info)) {
        return ""
    }

    $line = ($info -split "`r?`n" | Where-Object { $_ -like 'VMState=*' } | Select-Object -First 1)
    if (-not $line) {
        return ""
    }

    return ($line.Split("=", 2)[1].Trim('"'))
}

function Remove-ExistingVM {
    param(
        [Parameter(Mandatory)][string]$VBoxManage,
        [Parameter(Mandatory)][string]$VMName
    )

    $list = Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @("list", "vms") -NoThrow
    if ($list -notmatch "(?m)^`"$([regex]::Escape($VMName))`"\s+\{.+\}$") {
        return
    }

    if (-not $Force) {
        throw "VM '$VMName' already exists. Rerun with -Force to replace it."
    }

    Write-Step "Removing existing VM '$VMName'..." "WARN"
    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @("controlvm", $VMName, "poweroff") -NoThrow | Out-Null
    Start-Sleep -Seconds 2
    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @("unregistervm", $VMName, "--delete") -NoThrow | Out-Null
    Start-Sleep -Seconds 2
}

function New-FedoraVM {
    param(
        [Parameter(Mandatory)][string]$VBoxManage,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$FedoraVersion,
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$ISOPath,
        [Parameter(Mandatory)][string]$OEMDRVPath,
        [Parameter(Mandatory)][string]$BaseDir,
        [Parameter(Mandatory)][int]$SSHPort
    )

    Write-Host "`n  ── Creating Virtual Machine ──" -ForegroundColor $Script:Colors.Header

    Remove-ExistingVM -VBoxManage $VBoxManage -VMName $VMName

    if (-not (Test-Path $BaseDir)) {
        New-Item -Path $BaseDir -ItemType Directory -Force | Out-Null
    }

    $vmDir = Join-Path $BaseDir $VMName
    $vdiPath = Join-Path $vmDir "$VMName.vdi"

    Write-Step "Creating VM..." "RUNNING"
    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "createvm",
        "--name", $VMName,
        "--basefolder", $BaseDir,
        "--ostype", "Fedora_64",
        "--register"
    ) | Out-Null

    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "modifyvm", $VMName,
        "--cpus", $Config.CPUs.ToString(),
        "--memory", $Config.RAMMB.ToString(),
        "--vram", $Config.VRAMMB.ToString(),
        "--graphicscontroller", $Config.GraphicsController,
        "--chipset", $Config.Chipset,
        "--firmware", "efi",
        "--paravirtprovider", $Config.ParavirtProvider,
        "--ioapic", "on",
        "--acpi", "on",
        "--apic", "on",
        "--pae", "on",
        "--nic1", "nat",
        "--nictype1", "virtio",
        "--cableconnected1", "on",
        "--natpf1", "ssh,tcp,,$SSHPort,,22",
        "--boot1", "disk",
        "--boot2", "dvd",
        "--boot3", "none",
        "--boot4", "none",
        "--mouse", "usbtablet"
    ) | Out-Null

    if ($Config.Enable3D) {
        Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
            "modifyvm", $VMName,
            "--accelerate3d", "on"
        ) -NoThrow | Out-Null
    }

    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "modifyvm", $VMName,
        "--clipboard-mode", "bidirectional"
    ) -NoThrow | Out-Null

    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "modifyvm", $VMName,
        "--draganddrop", "bidirectional"
    ) -NoThrow | Out-Null

    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "createmedium", "disk",
        "--filename", $vdiPath,
        "--size", ($Config.DiskGB * 1024).ToString(),
        "--format", "VDI",
        "--variant", "Standard"
    ) | Out-Null

    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "storagectl", $VMName,
        "--name", "SATA",
        "--add", "sata",
        "--controller", "IntelAhci",
        "--portcount", "4",
        "--hostiocache", "on",
        "--bootable", "on"
    ) | Out-Null

    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "storageattach", $VMName,
        "--storagectl", "SATA",
        "--port", "0",
        "--device", "0",
        "--type", "hdd",
        "--medium", $vdiPath
    ) | Out-Null

    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "storageattach", $VMName,
        "--storagectl", "SATA",
        "--port", "1",
        "--device", "0",
        "--type", "hdd",
        "--medium", $OEMDRVPath
    ) | Out-Null

    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "storagectl", $VMName,
        "--name", "IDE",
        "--add", "ide",
        "--controller", "PIIX4"
    ) | Out-Null

    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "storageattach", $VMName,
        "--storagectl", "IDE",
        "--port", "0",
        "--device", "0",
        "--type", "dvddrive",
        "--medium", $ISOPath
    ) | Out-Null

    $resParts = $Config.Resolution -split "x"
    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "setextradata", $VMName,
        "CustomVideoMode1", "$($Config.Resolution)x32"
    ) -NoThrow | Out-Null

    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "setextradata", $VMName,
        "GUI/LastGuestSizeHint", "$($resParts[0]),$($resParts[1])"
    ) -NoThrow | Out-Null

    $desc = @"
Fedora $FedoraVersion auto-provisioned
Created: $(Get-Date -Format "yyyy-MM-dd HH:mm")
Main disk: $($Config.DiskGB) GB
OEMDRV: attached for install only
SSH: localhost:$SSHPort
"@

    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "modifyvm", $VMName,
        "--description", $desc
    ) -NoThrow | Out-Null

    Write-Step "VM created and configured" "DONE"

    return [PSCustomObject]@{
        VMDir   = $vmDir
        VDIPath = $vdiPath
    }
}

function Start-VMInstall {
    param(
        [Parameter(Mandatory)][string]$VBoxManage,
        [Parameter(Mandatory)][string]$VMName,
        [switch]$HeadlessMode
    )

    Write-Host "`n  ── Starting Installation ──" -ForegroundColor $Script:Colors.Header

    $type = if ($HeadlessMode) { "headless" } else { "gui" }
    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "startvm", $VMName, "--type", $type
    ) | Out-Null

    Write-Step "VM started ($type mode)" "DONE"
}

function Wait-ForInstallShutdown {
    param(
        [Parameter(Mandatory)][string]$VBoxManage,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][int]$TimeoutMinutes
    )

    Write-Host "`n  ── Waiting For Install To Finish ──" -ForegroundColor $Script:Colors.Header

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastState = ""

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        $state = Get-VMState -VBoxManage $VBoxManage -VMName $VMName

        if ($state -ne $lastState -and -not [string]::IsNullOrWhiteSpace($state)) {
            Write-Step "VM state: $state" "INFO"
            $lastState = $state
        }

        if ($state -eq "poweroff") {
            Write-Step "Install appears complete. VM powered off." "DONE"
            return $true
        }
    }

    return $false
}

function Finalize-VMAfterInstall {
    param(
        [Parameter(Mandatory)][string]$VBoxManage,
        [Parameter(Mandatory)][string]$VMName
    )

    Write-Host "`n  ── Finalizing VM ──" -ForegroundColor $Script:Colors.Header

    Write-Step "Detaching installer ISO..." "RUNNING"
    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "storageattach", $VMName,
        "--storagectl", "IDE",
        "--port", "0",
        "--device", "0",
        "--type", "dvddrive",
        "--medium", "none"
    ) -NoThrow | Out-Null

    Write-Step "Detaching OEMDRV disk..." "RUNNING"
    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "storageattach", $VMName,
        "--storagectl", "SATA",
        "--port", "1",
        "--device", "0",
        "--type", "hdd",
        "--medium", "none"
    ) -NoThrow | Out-Null

    Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
        "modifyvm", $VMName,
        "--boot1", "disk",
        "--boot2", "none",
        "--boot3", "none",
        "--boot4", "none"
    ) | Out-Null

    Write-Step "VM cleaned up for normal boots" "DONE"
}

function New-HelperScripts {
    param(
        [Parameter(Mandatory)][string]$VBoxManage,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$VMDir,
        [Parameter(Mandatory)][string]$SSHUser,
        [Parameter(Mandatory)][int]$SSHPort
    )

    Write-Host "`n  ── Creating Helper Scripts ──" -ForegroundColor $Script:Colors.Header

    $startScript = @"
@echo off
"$VBoxManage" startvm "$VMName" --type gui
"@
    $startScript | Out-File -FilePath (Join-Path $VMDir "Start-VM.bat") -Encoding ascii
    Write-Step "Created: Start-VM.bat" "DONE"

    $stopScript = @"
@echo off
"$VBoxManage" controlvm "$VMName" acpipowerbutton
"@
    $stopScript | Out-File -FilePath (Join-Path $VMDir "Stop-VM.bat") -Encoding ascii
    Write-Step "Created: Stop-VM.bat" "DONE"

    $sshScript = @"
@echo off
ssh -p $SSHPort $SSHUser@localhost
"@
    $sshScript | Out-File -FilePath (Join-Path $VMDir "SSH-Connect.bat") -Encoding ascii
    Write-Step "Created: SSH-Connect.bat" "DONE"
}

function Main {
    Clear-Host
    Write-Banner

    $startTime = Get-Date

    Test-HostVirtualizationWarnings

    $specs = Get-SystemSpecs
    $vmConfig = Get-OptimalVMConfig -Specs $specs
    $vboxManage = Find-VBoxManage
    $fedoraISO = Get-FedoraNetinstISO -Version $FedoraVersion -ProvidedISOPath $ISOPath

    $vmDir = Join-Path $VMBaseDir $VMName
    $workDir = Join-Path $vmDir "_autoinstall"
    $ksPath = Join-Path $workDir "ks.cfg"
    $oemdrvPath = Join-Path $workDir "OEMDRV.vhd"

    $null = New-KickstartFile `
        -Path $ksPath `
        -Username $GuestUsername `
        -Password $GuestPassword `
        -Hostname $GuestHostname `
        -Timezone $GuestTimezone

    $null = New-OEMDRVVHD `
        -VHDPath $oemdrvPath `
        -KickstartPath $ksPath

    $vmInfo = New-FedoraVM `
        -VBoxManage $vboxManage `
        -VMName $VMName `
        -FedoraVersion $FedoraVersion `
        -Config $vmConfig `
        -ISOPath $fedoraISO `
        -OEMDRVPath $oemdrvPath `
        -BaseDir $VMBaseDir `
        -SSHPort $SSHHostPort

    New-HelperScripts `
        -VBoxManage $vboxManage `
        -VMName $VMName `
        -VMDir $vmInfo.VMDir `
        -SSHUser $GuestUsername `
        -SSHPort $SSHHostPort

    Start-VMInstall -VBoxManage $vboxManage -VMName $VMName -HeadlessMode:$Headless

    $finished = Wait-ForInstallShutdown `
        -VBoxManage $vboxManage `
        -VMName $VMName `
        -TimeoutMinutes $InstallTimeoutMinutes

    if (-not $finished) {
        throw "Install did not finish within $InstallTimeoutMinutes minutes. Check the VM console. Kickstart: $ksPath"
    }

    Finalize-VMAfterInstall -VBoxManage $vboxManage -VMName $VMName

    Write-Step "Booting finished Fedora VM..." "RUNNING"
    Invoke-VBoxManage -VBoxManage $vboxManage -Arguments @(
        "startvm", $VMName, "--type", $(if ($Headless) { "headless" } else { "gui" })
    ) | Out-Null
    Write-Step "Finished VM started" "DONE"

    $elapsed = ((Get-Date) - $startTime).TotalMinutes

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor $Script:Colors.Success
    Write-Host "  ║                FULL AUTO SETUP COMPLETE                 ║" -ForegroundColor $Script:Colors.Success
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor $Script:Colors.Success
    Write-Host ""

    Write-Host "  VM Name:      $VMName" -ForegroundColor White
    Write-Host "  Fedora:       $FedoraVersion" -ForegroundColor White
    Write-Host "  Username:     $GuestUsername" -ForegroundColor White
    Write-Host "  Password:     $GuestPassword" -ForegroundColor White
    Write-Host "  Hostname:     $GuestHostname" -ForegroundColor White
    Write-Host "  SSH:          ssh -p $SSHHostPort $GuestUsername@localhost" -ForegroundColor White
    Write-Host "  VM Folder:    $($vmInfo.VMDir)" -ForegroundColor White
    Write-Host "  Elapsed:      $([math]::Round($elapsed, 1)) minutes" -ForegroundColor White
    Write-Host ""

    Write-Host "  Done." -ForegroundColor $Script:Colors.Accent
}

try {
    Main
}
catch {
    Write-Host ""
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  At line: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Checks:" -ForegroundColor Yellow
    Write-Host "  - VirtualBox is installed" -ForegroundColor Yellow
    Write-Host "  - Run PowerShell as Administrator" -ForegroundColor Yellow
    Write-Host "  - VT-x / AMD-V enabled in BIOS" -ForegroundColor Yellow
    Write-Host "  - Hyper-V / VBS not interfering" -ForegroundColor Yellow
    Write-Host "  - Internet works from the VM during install" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}