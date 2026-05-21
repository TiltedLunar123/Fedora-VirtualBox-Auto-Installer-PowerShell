<#
.SYNOPSIS
    One-click installer for VirtualBox Auto-Installer.
    Downloads the latest version, self-elevates to admin, and prints usage instructions.
#>

# ── Self-elevate to Administrator if not already ──────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  Requesting Administrator privileges..." -ForegroundColor Yellow

    # Persist the exact source that is running and elevate against that file,
    # instead of re-fetching the URL in the elevated process. Downloading twice
    # opens a TOCTOU gap where the admin run could execute different bytes than
    # what was first invoked and reviewed (issues #4, #5).
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        $selfSource = Get-Content -Raw -LiteralPath $PSCommandPath
    }
    else {
        $selfSource = $MyInvocation.MyCommand.ScriptBlock.ToString()
    }

    $bootstrapPath = Join-Path $env:TEMP ("fvbai-install-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
    [System.IO.File]::WriteAllText($bootstrapPath, $selfSource, [System.Text.Encoding]::UTF8)

    Start-Process powershell -Verb RunAs -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-File", $bootstrapPath
    exit
}

# ── Running as Admin from here ────────────────────────────────────────────────
Set-ExecutionPolicy Bypass -Scope Process -Force
$ErrorActionPreference = "Stop"
$installDir = Join-Path $env:USERPROFILE "Fedora-VirtualBox-Auto-Installer"
$scriptPath = Join-Path $installDir "New-FedoraVirtualBoxVM.ps1"
$repoBase = "https://raw.githubusercontent.com/TiltedLunar123/Fedora-VirtualBox-Auto-Installer-PowerShell/main"

Write-Host ""
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host "    VirtualBox Auto-Installer - Setup     " -ForegroundColor Cyan
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host ""

# Create install directory
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Write-Host "  [+] Created: $installDir" -ForegroundColor Green
}

# Download script content as string (avoids file encoding issues with Get-Content)
Write-Host "  [*] Downloading latest New-FedoraVirtualBoxVM.ps1..." -ForegroundColor Yellow
try {
    $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $scriptContent = (New-Object System.Net.WebClient).DownloadString("$repoBase/New-FedoraVirtualBoxVM.ps1?cb=$cacheBust")
    Write-Host "  [+] Downloaded ($([math]::Round($scriptContent.Length / 1KB, 1)) KB)" -ForegroundColor Green
}
catch {
    Write-Host "  [-] Download failed: $_" -ForegroundColor Red
    Write-Host "  [i] Check your internet connection and try again." -ForegroundColor Gray
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

if (-not $scriptContent -or $scriptContent.Length -lt 500) {
    Write-Host "  [-] Download appears incomplete or corrupt." -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

# Save to disk
[System.IO.File]::WriteAllText($scriptPath, $scriptContent, [System.Text.Encoding]::UTF8)
Write-Host "  [+] Saved to: $scriptPath" -ForegroundColor Green

Write-Host ""
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host "    Installation Complete                 " -ForegroundColor Cyan
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Script saved to: $scriptPath" -ForegroundColor White
Write-Host ""
Write-Host "  Usage examples:" -ForegroundColor Gray
Write-Host "    .\New-FedoraVirtualBoxVM.ps1 -Force" -ForegroundColor White
Write-Host "    .\New-FedoraVirtualBoxVM.ps1 -Distro AlmaLinux -FedoraVersion 9 -Force" -ForegroundColor White
Write-Host "    .\New-FedoraVirtualBoxVM.ps1 -Validate" -ForegroundColor White
Write-Host ""
Write-Host "  Run again:" -ForegroundColor Gray
Write-Host "    cd '$installDir'" -ForegroundColor White
Write-Host "    powershell -ExecutionPolicy Bypass -File '.\New-FedoraVirtualBoxVM.ps1' -Force" -ForegroundColor White
Write-Host ""
