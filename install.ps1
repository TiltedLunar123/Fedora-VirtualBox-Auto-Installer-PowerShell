<#
.SYNOPSIS
    One-click installer for VirtualBox Auto-Installer.
    Downloads the latest version, self-elevates to admin, and prints usage instructions.
#>

# -- Self-elevate to Administrator if not already ------------------------------
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

# -- Running as Admin from here ------------------------------------------------
Set-ExecutionPolicy Bypass -Scope Process -Force
$ErrorActionPreference = "Stop"
$installDir = Join-Path $env:USERPROFILE "Fedora-VirtualBox-Auto-Installer"
$scriptPath = Join-Path $installDir "New-FedoraVirtualBoxVM.ps1"
$repoBase = "https://raw.githubusercontent.com/TiltedLunar123/Fedora-VirtualBox-Auto-Installer-PowerShell/main"

# SHA256 of the canonical (LF line endings, UTF-8, no BOM) form of
# New-FedoraVirtualBoxVM.ps1. The installer refuses to save or run a download
# whose digest does not match this pin, so a tampered-but-parseable script is
# rejected instead of executed (issue #4). Regenerate with
# tools/Update-InstallerHash.ps1 whenever the provisioner changes;
# tests/install.Tests.ps1 fails CI if this drifts from the committed script.
$expectedProvisionerHash = '1300f3179804ce4a414ed077e22b3bb9186ade17cf3c0422f257dc1e458f04e9'

function Test-ProvisionerScriptContent {
    <#
    .SYNOPSIS
        Returns $true only when $Content looks like the real provisioner script.

    .DESCRIPTION
        The old guard executed anything longer than 500 bytes, so a truncated
        download, an HTML error page, or a captive-portal redirect would have
        been saved and run as-is (issue #4). This checks that the content parses
        as PowerShell with no errors and carries the admin requirement header and
        the New-FedoraVM entry point before it is trusted. It is not a substitute
        for a signature, but it closes the door on the obvious garbage cases.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return $false }
    if ($Content.Length -lt 500) { return $false }
    if ($Content -notmatch '#Requires -RunAsAdministrator') { return $false }
    if ($Content -notmatch 'function\s+New-FedoraVM\b') { return $false }

    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput(
        $Content, [ref]$null, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) { return $false }

    return $true
}

function Get-CanonicalScriptHash {
    <#
    .SYNOPSIS
        SHA256 of script content, computed over a canonical form so that
        line-ending and BOM differences do not change the result.

    .DESCRIPTION
        The provisioner can reach this installer through two paths whose bytes
        are not guaranteed to be identical: the file committed in the repo (which
        Git may check out with CRLF on Windows) and the copy pulled from
        raw.githubusercontent.com over HTTP. Hashing the raw bytes would make a
        correct file fail its own integrity check purely on line endings. So the
        content is normalized to LF and encoded as UTF-8 without a BOM before it
        is hashed, and the pinned value in this installer is generated the same
        way. The output is lowercase hex with no separators.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    $normalized = $Content -replace "`r`n", "`n" -replace "`r", "`n"

    # Drop a leading BOM character if the decode left one in, so a BOM-prefixed
    # copy and a BOM-free copy hash the same.
    if ($normalized.Length -gt 0 -and $normalized[0] -eq [char]0xFEFF) {
        $normalized = $normalized.Substring(1)
    }

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($normalized)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return ([System.BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
}

function Test-ProvisionerScriptHash {
    <#
    .SYNOPSIS
        Returns $true only when $Content hashes to $ExpectedHash.

    .DESCRIPTION
        This is the integrity gate for issue #4. Structural validation
        (Test-ProvisionerScriptContent) rejects truncated or non-PowerShell
        downloads, but it would still accept a tampered script that happens to
        parse and carry the right markers. Pinning the SHA256 closes that gap:
        the installer only trusts the exact provisioner it was published against.
        The comparison is canonical (see Get-CanonicalScriptHash) and
        case-insensitive.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedHash
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedHash)) { return $false }
    $actual = Get-CanonicalScriptHash -Content $Content
    return ($actual -eq $ExpectedHash.Trim().ToLowerInvariant())
}

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

if (-not (Test-ProvisionerScriptContent -Content $scriptContent)) {
    Write-Host "  [-] Downloaded script failed validation (incomplete, corrupt, or not the expected file)." -ForegroundColor Red
    Write-Host "  [i] Nothing was saved or run. Check your connection and try again." -ForegroundColor Gray
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

if (-not (Test-ProvisionerScriptHash -Content $scriptContent -ExpectedHash $expectedProvisionerHash)) {
    Write-Host "  [-] Downloaded script failed the integrity check (SHA256 mismatch)." -ForegroundColor Red
    Write-Host "  [i] The file does not match the version this installer was pinned to. Nothing was saved or run." -ForegroundColor Gray
    Write-Host "  [i] Re-run the latest installer from the project page; if it keeps failing, open an issue." -ForegroundColor Gray
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
