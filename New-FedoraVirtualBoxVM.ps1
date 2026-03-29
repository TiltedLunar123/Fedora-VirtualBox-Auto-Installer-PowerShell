#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Fully automatic RHEL-family VM provisioner for VirtualBox on Windows.

.DESCRIPTION
    - Detects host specs
    - Downloads Fedora/CentOS-Stream/AlmaLinux/Rocky Everything netinstall ISO
    - Verifies ISO checksum (SHA256) when downloading
    - Creates an optimized VirtualBox VM
    - Creates a tiny OEMDRV VHD containing ks.cfg (with SHA-512 hashed password)
    - Boots the installer, which auto-loads ks.cfg
    - Waits for install completion (guest powers off)
    - Detaches install media + OEMDRV disk
    - Cleans up sensitive install artifacts
    - Boots the finished VM
    - Supports resume/checkpoint on re-run

.NOTES
    Honest version:
    - Uses Everything netinstall, not Workstation Live
    - Uses real Kickstart automation via OEMDRV
    - Avoids pretending VBox unattended magically handles desktop installs

    Default login:
      user:     user
      password: fedora

    Change those with -GuestUsername / -GuestPassword.

.EXAMPLE
    .\New-FedoraVirtualBoxVM.ps1 -Force
    Provisions a default Fedora Workstation VM, replacing any existing one.

.EXAMPLE
    .\New-FedoraVirtualBoxVM.ps1 -VMName "MyFedora" -GuestUsername "admin" -Force
    Provisions a custom-named VM with a different guest username.

.EXAMPLE
    .\New-FedoraVirtualBoxVM.ps1 -ISOPath "C:\ISOs\Fedora-Everything-netinst-x86_64-43-1.1.iso" -Force
    Uses a local ISO file instead of downloading one.

.EXAMPLE
    .\New-FedoraVirtualBoxVM.ps1 -Distro "AlmaLinux" -Force
    Provisions an AlmaLinux VM instead of Fedora.

.EXAMPLE
    .\New-FedoraVirtualBoxVM.ps1 -Validate
    Runs all pre-flight checks without creating anything.
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
    [switch]$Headless,
    [ValidateSet("Fedora","CentOS-Stream","AlmaLinux","Rocky")]
    [string]$Distro = "Fedora",
    [switch]$Validate,
    [switch]$KeepArtifacts,
    [switch]$NoResume,
    [switch]$SecureSudo,
    [string]$SharedFolder
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

# Emoji fallback for old terminals
$Script:UseEmoji = $null -ne $env:WT_SESSION -or $Host.UI.SupportsVirtualTerminal
$Script:Icons = if ($Script:UseEmoji) {
    @{ Running="⚡"; Done="✅"; Warn="⚠️"; Error="❌"; Info="ℹ️" }
} else {
    @{ Running=">>"; Done="OK"; Warn="!!"; Error="XX"; Info="--" }
}

function Write-Banner {
    $banner = @"

    ╔══════════════════════════════════════════════════════════╗
    ║     VIRTUALBOX AUTO-PROVISIONER v5.0                    ║
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
        "RUNNING" { $Script:Icons.Running }
        "DONE"    { $Script:Icons.Done }
        "WARN"    { $Script:Icons.Warn }
        "ERROR"   { $Script:Icons.Error }
        "INFO"    { $Script:Icons.Info }
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

# --- Distro configuration ---

function Get-DistroConfig {
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$Version
    )

    switch ($Distro) {
        "Fedora" {
            return @{
                ISOIndexUrl     = "https://download.fedoraproject.org/pub/fedora/linux/releases/$Version/Everything/x86_64/iso/"
                ISOPattern      = "Fedora-Everything-netinst-x86_64-$Version-[0-9.]+"
                PackageGroup    = "@^workstation-product-environment"
                DefaultHostname = "fedora-vm"
                OSType          = "Fedora_64"
            }
        }
        "CentOS-Stream" {
            return @{
                ISOIndexUrl     = "https://mirrors.centos.org/mirrorlist?path=/SIGs/$Version-stream/BaseOS/x86_64/iso/&redirect=1&protocol=https"
                ISOPattern      = "CentOS-Stream-$Version-latest-x86_64-dvd1"
                PackageGroup    = "@^server-product-environment"
                DefaultHostname = "centos-vm"
                OSType          = "RedHat_64"
            }
        }
        "AlmaLinux" {
            return @{
                ISOIndexUrl     = "https://repo.almalinux.org/almalinux/$Version/isos/x86_64/"
                ISOPattern      = "AlmaLinux-$Version[0-9.]*-x86_64-dvd"
                PackageGroup    = "@^server-product-environment"
                DefaultHostname = "alma-vm"
                OSType          = "RedHat_64"
            }
        }
        "Rocky" {
            return @{
                ISOIndexUrl     = "https://download.rockylinux.org/pub/rocky/$Version/isos/x86_64/"
                ISOPattern      = "Rocky-$Version[0-9.]*-x86_64-dvd"
                PackageGroup    = "@^server-product-environment"
                DefaultHostname = "rocky-vm"
                OSType          = "RedHat_64"
            }
        }
    }
}

# --- SHA-512 password hashing ---

function New-SHA512CryptHash {
    param([string]$Password)

    $openssl = Get-Command openssl -ErrorAction SilentlyContinue
    if ($openssl) {
        $hash = & openssl passwd -6 $Password 2>$null
        if ($LASTEXITCODE -eq 0 -and $hash) { return $hash }
    }

    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
    if ($python) {
        $hash = & $python.Source -c "import crypt; print(crypt.crypt('$Password', crypt.mksalt(crypt.METHOD_SHA512)))" 2>$null
        if ($LASTEXITCODE -eq 0 -and $hash) { return $hash }
    }

    return $null
}

# --- Provision state management ---

function Get-ProvisionState {
    param([Parameter(Mandatory)][string]$StatePath)

    if (Test-Path $StatePath) {
        try {
            return (Get-Content $StatePath -Raw | ConvertFrom-Json)
        }
        catch {
            return $null
        }
    }
    return $null
}

function Save-ProvisionState {
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][hashtable]$State
    )

    $dir = Split-Path -Parent $StatePath
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $State | ConvertTo-Json -Depth 5 | Out-File -FilePath $StatePath -Encoding utf8 -Force
}

function Test-StepCompleted {
    param(
        [object]$State,
        [string]$StepName
    )

    if ($null -eq $State) { return $false }
    $val = $State.PSObject.Properties[$StepName]
    if ($null -eq $val) { return $false }
    return [bool]$val.Value
}

# --- Core utility functions ---

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
    Write-Host "`n  -- Host Checks --" -ForegroundColor $Script:Colors.Header

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
    Write-Host "`n  -- System Detection --" -ForegroundColor $Script:Colors.Header

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

    Write-Host "`n  -- Calculating Optimal VM Config --" -ForegroundColor $Script:Colors.Header

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
    Write-Host "`n  -- Locating VirtualBox --" -ForegroundColor $Script:Colors.Header

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

# --- ISO checksum verification ---

function Test-ISOChecksum {
    param(
        [Parameter(Mandatory)][string]$ISOPath,
        [Parameter(Mandatory)][string]$IndexUrl
    )

    Write-Host "`n  -- Verifying ISO Checksum --" -ForegroundColor $Script:Colors.Header

    try {
        $listing = Invoke-WebRequest -Uri $IndexUrl -UseBasicParsing
    }
    catch {
        Write-Step "Could not fetch index listing for checksum verification. Skipping." "WARN"
        return
    }

    $checksumMatches = [regex]::Matches($listing.Content, '[^">\s]+CHECKSUM[^"<\s]*') |
        ForEach-Object { $_.Value } |
        Select-Object -Unique

    if (-not $checksumMatches -or $checksumMatches.Count -eq 0) {
        Write-Step "No CHECKSUM file found in index listing. Skipping verification." "WARN"
        return
    }

    $checksumFile = $checksumMatches | Select-Object -First 1
    $checksumUrl = "$IndexUrl$checksumFile"

    Write-Step "Downloading checksum file: $checksumFile" "RUNNING"
    try {
        $checksumContent = (Invoke-WebRequest -Uri $checksumUrl -UseBasicParsing).Content
    }
    catch {
        Write-Step "Could not download checksum file. Skipping verification." "WARN"
        return
    }

    $isoFileName = Split-Path -Leaf $ISOPath
    $expectedHash = $null

    foreach ($line in ($checksumContent -split "`r?`n")) {
        if ($line -match "SHA256\s*\(([^)]+)\)\s*=\s*([a-fA-F0-9]{64})") {
            if ($Matches[1] -eq $isoFileName) {
                $expectedHash = $Matches[2].ToLower()
                break
            }
        }
        elseif ($line -match "^([a-fA-F0-9]{64})\s+\*?(.+)$") {
            if ($Matches[2].Trim() -eq $isoFileName) {
                $expectedHash = $Matches[1].ToLower()
                break
            }
        }
    }

    if (-not $expectedHash) {
        Write-Step "Could not find SHA256 hash for $isoFileName in checksum file. Skipping." "WARN"
        return
    }

    Write-Step "Computing SHA256 hash of ISO (this may take a moment)..." "RUNNING"
    $actualHash = (Get-FileHash -Path $ISOPath -Algorithm SHA256).Hash.ToLower()

    if ($actualHash -ne $expectedHash) {
        throw "ISO checksum mismatch!`n  Expected: $expectedHash`n  Actual:   $actualHash`n  The downloaded ISO may be corrupted. Delete it and retry."
    }

    Write-Step "ISO checksum verified (SHA256 match)" "DONE"
}

function Get-FedoraNetinstISO {
    param(
        [Parameter(Mandatory)][string]$Version,
        [string]$ProvidedISOPath,
        [Parameter(Mandatory)][string]$DistroName
    )

    Write-Host "`n  -- $DistroName Netinstall ISO --" -ForegroundColor $Script:Colors.Header

    $distroConfig = Get-DistroConfig -Distro $DistroName -Version $Version

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

    $isoPattern = $distroConfig.ISOPattern
    $existing = Get-ChildItem -Path $downloadDir -Filter "$($isoPattern -replace '\[.+\]','*').iso" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($existing) {
        Write-Step "Found local ISO: $($existing.FullName)" "DONE"
        return $existing.FullName
    }

    if ($SkipDownload) {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = "Select $DistroName Everything netinstall ISO"
        $dialog.Filter = "ISO files (*.iso)|*.iso"
        $dialog.InitialDirectory = $downloadDir
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Write-Step "Selected ISO: $($dialog.FileName)" "DONE"
            return $dialog.FileName
        }
        throw "No ISO selected."
    }

    $indexUrl = $distroConfig.ISOIndexUrl
    Write-Step "Resolving latest $DistroName ISO..." "RUNNING"

    try {
        $listing = Invoke-WebRequest -Uri $indexUrl -UseBasicParsing
    }
    catch {
        throw "Failed to access release directory: $indexUrl"
    }

    $isoMatches = [regex]::Matches($listing.Content, "$isoPattern\.iso") |
        ForEach-Object { $_.Value } |
        Select-Object -Unique

    $isoName = $isoMatches | Sort-Object -Descending | Select-Object -First 1
    if (-not $isoName) {
        throw "Could not resolve a $DistroName ISO name from $indexUrl"
    }

    $isoUrl = "$indexUrl$isoName"
    $isoPath = Join-Path $downloadDir $isoName

    Write-Step "Downloading $isoName ..." "RUNNING"
    try {
        Start-BitsTransfer -Source $isoUrl -Destination $isoPath -Description "Downloading $DistroName ISO"
    }
    catch {
        Invoke-WebRequest -Uri $isoUrl -OutFile $isoPath -UseBasicParsing
    }

    if (-not (Test-Path $isoPath)) {
        throw "ISO download failed."
    }

    # Verify checksum for downloaded ISOs
    Test-ISOChecksum -ISOPath $isoPath -IndexUrl $indexUrl

    Write-Step "ISO ready: $isoPath" "DONE"
    return $isoPath
}

function New-KickstartFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$Timezone,
        [Parameter(Mandatory)][string]$PackageGroup,
        [switch]$SecureSudoMode,
        [string]$SharedFolderName
    )

    Write-Host "`n  -- Creating Kickstart --" -ForegroundColor $Script:Colors.Header

    # Attempt to hash the password with SHA-512
    $passwordHash = New-SHA512CryptHash -Password $Password
    if ($passwordHash) {
        $userLine = "user --name=$Username --password=$passwordHash --iscrypted --groups=wheel"
        Write-Step "Password will be stored as SHA-512 hash in Kickstart" "DONE"
    } else {
        $userLine = "user --name=$Username --password=$Password --plaintext --groups=wheel"
        Write-Step "Could not hash password (openssl/python not found). Using plaintext in Kickstart." "WARN"
    }

    # Sudoers line
    $sudoersLine = if ($SecureSudoMode) {
        "echo `"$Username ALL=(ALL) ALL`" > /etc/sudoers.d/90-$Username"
    } else {
        "echo `"$Username ALL=(ALL) NOPASSWD: ALL`" > /etc/sudoers.d/90-$Username"
    }

    # Shared folder post-install block
    $sharedFolderPost = ""
    if ($SharedFolderName) {
        $sharedFolderPost = @"

# Guest Additions and shared folder setup
dnf install -y gcc kernel-devel kernel-headers dkms make bzip2 perl || true
mkdir -p /mnt/shared
echo 'vboxsf' > /etc/modules-load.d/vboxsf.conf
cat > /etc/systemd/system/mount-vbox-shared.service <<'SVCEOF'
[Unit]
Description=Mount VirtualBox Shared Folder
After=vboxadd.service
Requires=vboxadd.service

[Service]
Type=oneshot
ExecStart=/bin/mount -t vboxsf $SharedFolderName /mnt/shared -o uid=1000,gid=1000
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl enable mount-vbox-shared.service || true
"@
    }

    $ks = @"
#version=DEVEL
text

lang en_US.UTF-8
keyboard us
timezone $Timezone --utc

network --bootproto=dhcp --device=link --activate --hostname=$Hostname

rootpw --lock
$userLine

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
$PackageGroup
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
$sudoersLine
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
$sharedFolderPost
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

    Write-Host "`n  -- Creating OEMDRV Disk --" -ForegroundColor $Script:Colors.Header

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
        [Parameter(Mandatory)][string]$VersionLabel,
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$ISOPath,
        [Parameter(Mandatory)][string]$OEMDRVPath,
        [Parameter(Mandatory)][string]$BaseDir,
        [Parameter(Mandatory)][int]$SSHPort,
        [Parameter(Mandatory)][string]$OSType,
        [string]$SharedFolderPath
    )

    Write-Host "`n  -- Creating Virtual Machine --" -ForegroundColor $Script:Colors.Header

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
        "--ostype", $OSType,
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

    # Shared folder configuration
    if ($SharedFolderPath -and (Test-Path $SharedFolderPath)) {
        $shareName = "shared"
        Invoke-VBoxManage -VBoxManage $VBoxManage -Arguments @(
            "sharedfolder", "add", $VMName,
            "--name", $shareName,
            "--hostpath", $SharedFolderPath,
            "--automount"
        ) -NoThrow | Out-Null
        Write-Step "Shared folder configured: $SharedFolderPath -> $shareName" "DONE"
    }

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
$Distro $VersionLabel auto-provisioned
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

    Write-Host "`n  -- Starting Installation --" -ForegroundColor $Script:Colors.Header

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

    Write-Host "`n  -- Waiting For Install To Finish --" -ForegroundColor $Script:Colors.Header

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

    Write-Host "`n  -- Finalizing VM --" -ForegroundColor $Script:Colors.Header

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

function Remove-InstallArtifacts {
    param(
        [Parameter(Mandatory)][string]$WorkDir
    )

    Write-Host "`n  -- Cleaning Up Install Artifacts --" -ForegroundColor $Script:Colors.Header

    $ksPath = Join-Path $WorkDir "ks.cfg"
    $oemdrvPath = Join-Path $WorkDir "OEMDRV.vhd"

    if (Test-Path $ksPath) {
        Remove-Item $ksPath -Force -ErrorAction SilentlyContinue
        Write-Step "Removed: ks.cfg" "DONE"
    }
    if (Test-Path $oemdrvPath) {
        Remove-Item $oemdrvPath -Force -ErrorAction SilentlyContinue
        Write-Step "Removed: OEMDRV.vhd" "DONE"
    }

    Write-Step "Sensitive install artifacts cleaned up" "DONE"
}

function New-HelperScripts {
    param(
        [Parameter(Mandatory)][string]$VBoxManage,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$VMDir,
        [Parameter(Mandatory)][string]$SSHUser,
        [Parameter(Mandatory)][int]$SSHPort
    )

    Write-Host "`n  -- Creating Helper Scripts --" -ForegroundColor $Script:Colors.Header

    $startScript = @"
# Start-VM.ps1 - Start the VirtualBox VM
`$VBoxManage = "$VBoxManage"
if (-not (Test-Path `$VBoxManage)) {
    Write-Error "VBoxManage not found at `$VBoxManage"
    exit 1
}
& `$VBoxManage startvm "$VMName" --type gui
if (`$LASTEXITCODE -ne 0) { Write-Error "Failed to start VM"; exit 1 }
Write-Host "VM '$VMName' started successfully." -ForegroundColor Green
"@
    $startScript | Out-File -FilePath (Join-Path $VMDir "Start-VM.ps1") -Encoding utf8
    Write-Step "Created: Start-VM.ps1" "DONE"

    $stopScript = @"
# Stop-VM.ps1 - Gracefully stop the VirtualBox VM
`$VBoxManage = "$VBoxManage"
if (-not (Test-Path `$VBoxManage)) {
    Write-Error "VBoxManage not found at `$VBoxManage"
    exit 1
}
& `$VBoxManage controlvm "$VMName" acpipowerbutton
if (`$LASTEXITCODE -ne 0) { Write-Error "Failed to stop VM"; exit 1 }
Write-Host "Shutdown signal sent to '$VMName'." -ForegroundColor Green
"@
    $stopScript | Out-File -FilePath (Join-Path $VMDir "Stop-VM.ps1") -Encoding utf8
    Write-Step "Created: Stop-VM.ps1" "DONE"

    $sshScript = @"
# SSH-Connect.ps1 - Connect to the VM via SSH
`$SSHPort = $SSHPort
`$SSHUser = "$SSHUser"
`$sshCmd = Get-Command ssh -ErrorAction SilentlyContinue
if (-not `$sshCmd) {
    Write-Error "SSH client not found. Install OpenSSH or use PuTTY."
    exit 1
}
& ssh -p `$SSHPort `$SSHUser@localhost
if (`$LASTEXITCODE -ne 0) { Write-Error "SSH connection failed"; exit 1 }
"@
    $sshScript | Out-File -FilePath (Join-Path $VMDir "SSH-Connect.ps1") -Encoding utf8
    Write-Step "Created: SSH-Connect.ps1" "DONE"
}

# --- Validate / dry-run mode ---

function Invoke-ValidateMode {
    Write-Host "`n  -- Pre-Flight Validation --" -ForegroundColor $Script:Colors.Header
    $allGood = $true

    # VirtualBox installed?
    $vboxOk = $false
    try {
        $null = Find-VBoxManage
        $vboxOk = $true
    }
    catch {
        Write-Step "VirtualBox: NOT FOUND" "ERROR"
        $allGood = $false
    }

    # VT-x
    try {
        $vtx = (Get-CimInstance -ClassName Win32_Processor).VirtualizationFirmwareEnabled
        if ($vtx -contains $true) {
            Write-Step "VT-x/AMD-V: Enabled" "DONE"
        } else {
            Write-Step "VT-x/AMD-V: Not detected (check BIOS)" "WARN"
            $allGood = $false
        }
    }
    catch {
        Write-Step "VT-x/AMD-V: Could not detect" "WARN"
    }

    # Disk space
    $bestDrive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" |
        Sort-Object FreeSpace -Descending | Select-Object -First 1
    if ($bestDrive) {
        $freeGB = [math]::Round($bestDrive.FreeSpace / 1GB, 1)
        if ($freeGB -ge 30) {
            Write-Step "Disk space: $freeGB GB free on $($bestDrive.DeviceID)" "DONE"
        } else {
            Write-Step "Disk space: Only $freeGB GB free (need at least 30 GB)" "ERROR"
            $allGood = $false
        }
    }

    # ISO availability (check if URL is reachable)
    if (-not $ISOPath) {
        $distroConfig = Get-DistroConfig -Distro $Distro -Version $FedoraVersion
        try {
            $null = Invoke-WebRequest -Uri $distroConfig.ISOIndexUrl -UseBasicParsing -Method Head -TimeoutSec 10
            Write-Step "ISO download URL: Reachable" "DONE"
        }
        catch {
            Write-Step "ISO download URL: Not reachable ($($distroConfig.ISOIndexUrl))" "ERROR"
            $allGood = $false
        }
    } else {
        if (Test-Path $ISOPath) {
            Write-Step "ISO file: Found at $ISOPath" "DONE"
        } else {
            Write-Step "ISO file: Not found at $ISOPath" "ERROR"
            $allGood = $false
        }
    }

    # SSH port conflict
    $portInUse = $false
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $SSHHostPort)
        $listener.Start()
        $listener.Stop()
        Write-Step "SSH port $SSHHostPort: Available" "DONE"
    }
    catch {
        Write-Step "SSH port $SSHHostPort: Already in use" "WARN"
        $portInUse = $true
    }

    # Password hashing
    $hashTest = New-SHA512CryptHash -Password "test"
    if ($hashTest) {
        Write-Step "Password hashing: Available (SHA-512)" "DONE"
    } else {
        Write-Step "Password hashing: Not available (will use plaintext)" "WARN"
    }

    # Hyper-V check
    try {
        $hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
        if ($hv.State -eq "Enabled") {
            Write-Step "Hyper-V: Enabled (may interfere with VirtualBox)" "WARN"
        } else {
            Write-Step "Hyper-V: Disabled" "DONE"
        }
    }
    catch {
        Write-Step "Hyper-V: Could not determine status" "WARN"
    }

    Write-Host ""
    if ($allGood) {
        Write-Host "  RESULT: All pre-flight checks passed. Ready to provision." -ForegroundColor $Script:Colors.Success
    } else {
        Write-Host "  RESULT: Some checks failed. Fix the issues above before provisioning." -ForegroundColor $Script:Colors.Error
    }
    Write-Host ""
}

# --- Main ---

function Main {
    Clear-Host
    Write-Banner

    # Validate mode: run checks and exit
    if ($Validate) {
        Invoke-ValidateMode
        return
    }

    $startTime = Get-Date

    # Apply distro defaults
    $distroConfig = Get-DistroConfig -Distro $Distro -Version $FedoraVersion

    # Override hostname if user didn't set it and using non-Fedora distro
    if ($GuestHostname -eq "fedora-vm" -and $Distro -ne "Fedora") {
        $GuestHostname = $distroConfig.DefaultHostname
    }

    # Override VMName default if using non-Fedora distro
    if ($VMName -eq "Fedora-Workstation" -and $Distro -ne "Fedora") {
        $VMName = "$Distro-Workstation"
    }

    $vmDir = Join-Path $VMBaseDir $VMName
    $workDir = Join-Path $vmDir "_autoinstall"
    $statePath = Join-Path $workDir "provision-state.json"
    $ksPath = Join-Path $workDir "ks.cfg"
    $oemdrvPath = Join-Path $workDir "OEMDRV.vhd"

    # Load resume state
    $state = $null
    if ($Force -and -not $NoResume) {
        $state = Get-ProvisionState -StatePath $statePath
        if ($state) {
            Write-Step "Resuming from previous provisioning state" "INFO"
        }
    }
    if ($NoResume -and (Test-Path $statePath)) {
        Remove-Item $statePath -Force -ErrorAction SilentlyContinue
        $state = $null
    }

    Test-HostVirtualizationWarnings

    $specs = Get-SystemSpecs
    $vmConfig = Get-OptimalVMConfig -Specs $specs
    $vboxManage = Find-VBoxManage

    # ISO step
    $fedoraISO = $null
    if (-not (Test-StepCompleted -State $state -StepName "iso_ready")) {
        $fedoraISO = Get-FedoraNetinstISO -Version $FedoraVersion -ProvidedISOPath $ISOPath -DistroName $Distro
        $currentState = @{
            iso_ready = $true
            iso_path  = $fedoraISO
        }
        Save-ProvisionState -StatePath $statePath -State $currentState
        $state = Get-ProvisionState -StatePath $statePath
    } else {
        $fedoraISO = $state.iso_path
        if (-not (Test-Path $fedoraISO)) {
            Write-Step "Previously used ISO not found at $fedoraISO. Re-downloading." "WARN"
            $fedoraISO = Get-FedoraNetinstISO -Version $FedoraVersion -ProvidedISOPath $ISOPath -DistroName $Distro
        }
        Write-Step "ISO already ready: $fedoraISO" "DONE"
    }

    # Kickstart step
    if (-not (Test-StepCompleted -State $state -StepName "kickstart_created")) {
        $sharedName = if ($SharedFolder) { "shared" } else { "" }
        $null = New-KickstartFile `
            -Path $ksPath `
            -Username $GuestUsername `
            -Password $GuestPassword `
            -Hostname $GuestHostname `
            -Timezone $GuestTimezone `
            -PackageGroup $distroConfig.PackageGroup `
            -SecureSudoMode:$SecureSudo `
            -SharedFolderName $sharedName

        $currentState = @{
            iso_ready         = $true
            iso_path          = $fedoraISO
            kickstart_created = $true
        }
        Save-ProvisionState -StatePath $statePath -State $currentState
        $state = Get-ProvisionState -StatePath $statePath
    } else {
        Write-Step "Kickstart already created" "DONE"
    }

    # OEMDRV step
    if (-not (Test-StepCompleted -State $state -StepName "oemdrv_created")) {
        $null = New-OEMDRVVHD `
            -VHDPath $oemdrvPath `
            -KickstartPath $ksPath

        $currentState = @{
            iso_ready         = $true
            iso_path          = $fedoraISO
            kickstart_created = $true
            oemdrv_created    = $true
        }
        Save-ProvisionState -StatePath $statePath -State $currentState
        $state = Get-ProvisionState -StatePath $statePath
    } else {
        Write-Step "OEMDRV disk already created" "DONE"
    }

    # VM creation step
    $vmInfo = $null
    if (-not (Test-StepCompleted -State $state -StepName "vm_created")) {
        $vmInfo = New-FedoraVM `
            -VBoxManage $vboxManage `
            -VMName $VMName `
            -VersionLabel $FedoraVersion `
            -Config $vmConfig `
            -ISOPath $fedoraISO `
            -OEMDRVPath $oemdrvPath `
            -BaseDir $VMBaseDir `
            -SSHPort $SSHHostPort `
            -OSType $distroConfig.OSType `
            -SharedFolderPath $SharedFolder

        New-HelperScripts `
            -VBoxManage $vboxManage `
            -VMName $VMName `
            -VMDir $vmInfo.VMDir `
            -SSHUser $GuestUsername `
            -SSHPort $SSHHostPort

        $currentState = @{
            iso_ready         = $true
            iso_path          = $fedoraISO
            kickstart_created = $true
            oemdrv_created    = $true
            vm_created        = $true
        }
        Save-ProvisionState -StatePath $statePath -State $currentState
        $state = Get-ProvisionState -StatePath $statePath
    } else {
        $vmInfo = [PSCustomObject]@{
            VMDir   = $vmDir
            VDIPath = Join-Path $vmDir "$VMName.vdi"
        }
        Write-Step "VM already created" "DONE"
    }

    # Install step
    if (-not (Test-StepCompleted -State $state -StepName "install_completed")) {
        if (-not (Test-StepCompleted -State $state -StepName "install_started")) {
            Start-VMInstall -VBoxManage $vboxManage -VMName $VMName -HeadlessMode:$Headless

            $currentState = @{
                iso_ready         = $true
                iso_path          = $fedoraISO
                kickstart_created = $true
                oemdrv_created    = $true
                vm_created        = $true
                install_started   = $true
            }
            Save-ProvisionState -StatePath $statePath -State $currentState
            $state = Get-ProvisionState -StatePath $statePath
        } else {
            Write-Step "Install was already started, checking VM state..." "INFO"
            $currentVMState = Get-VMState -VBoxManage $vboxManage -VMName $VMName
            if ($currentVMState -ne "poweroff") {
                Write-Step "VM is still running ($currentVMState). Waiting for completion..." "INFO"
            }
        }

        $finished = Wait-ForInstallShutdown `
            -VBoxManage $vboxManage `
            -VMName $VMName `
            -TimeoutMinutes $InstallTimeoutMinutes

        if (-not $finished) {
            throw "Install did not finish within $InstallTimeoutMinutes minutes. Check the VM console. Kickstart: $ksPath"
        }

        $currentState = @{
            iso_ready          = $true
            iso_path           = $fedoraISO
            kickstart_created  = $true
            oemdrv_created     = $true
            vm_created         = $true
            install_started    = $true
            install_completed  = $true
        }
        Save-ProvisionState -StatePath $statePath -State $currentState
        $state = Get-ProvisionState -StatePath $statePath
    } else {
        Write-Step "Install already completed" "DONE"
    }

    # Finalize step
    if (-not (Test-StepCompleted -State $state -StepName "finalized")) {
        Finalize-VMAfterInstall -VBoxManage $vboxManage -VMName $VMName

        # Clean up sensitive artifacts unless -KeepArtifacts is specified
        if (-not $KeepArtifacts) {
            Remove-InstallArtifacts -WorkDir $workDir
        } else {
            Write-Step "Keeping install artifacts as requested (-KeepArtifacts)" "INFO"
        }

        $currentState = @{
            iso_ready          = $true
            iso_path           = $fedoraISO
            kickstart_created  = $true
            oemdrv_created     = $true
            vm_created         = $true
            install_started    = $true
            install_completed  = $true
            finalized          = $true
        }
        Save-ProvisionState -StatePath $statePath -State $currentState
    } else {
        Write-Step "VM already finalized" "DONE"
    }

    Write-Step "Booting finished $Distro VM..." "RUNNING"
    Invoke-VBoxManage -VBoxManage $vboxManage -Arguments @(
        "startvm", $VMName, "--type", $(if ($Headless) { "headless" } else { "gui" })
    ) | Out-Null
    Write-Step "Finished VM started" "DONE"

    $elapsed = ((Get-Date) - $startTime).TotalMinutes

    Write-Host ""
    Write-Host "  ======================================================" -ForegroundColor $Script:Colors.Success
    Write-Host "                FULL AUTO SETUP COMPLETE                 " -ForegroundColor $Script:Colors.Success
    Write-Host "  ======================================================" -ForegroundColor $Script:Colors.Success
    Write-Host ""

    Write-Host "  VM Name:      $VMName" -ForegroundColor White
    Write-Host "  Distro:       $Distro $FedoraVersion" -ForegroundColor White
    Write-Host "  Username:     $GuestUsername" -ForegroundColor White
    Write-Host "  Password:     $GuestPassword" -ForegroundColor White
    Write-Host "  Hostname:     $GuestHostname" -ForegroundColor White
    Write-Host "  SSH:          ssh -p $SSHHostPort $GuestUsername@localhost" -ForegroundColor White
    Write-Host "  VM Folder:    $($vmInfo.VMDir)" -ForegroundColor White
    if ($SharedFolder) {
        Write-Host "  Shared:       $SharedFolder -> /mnt/shared" -ForegroundColor White
    }
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
