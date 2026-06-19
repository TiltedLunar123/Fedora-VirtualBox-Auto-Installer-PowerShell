<#
.SYNOPSIS
    Recompute and rewrite the provisioner SHA256 pin in install.ps1.

.DESCRIPTION
    install.ps1 refuses to run any download of New-FedoraVirtualBoxVM.ps1 whose
    canonical SHA256 does not match the $expectedProvisionerHash constant baked
    into it. Run this after changing the provisioner so that pin stays current.

    The canonical hasher is loaded out of install.ps1 itself rather than
    reimplemented here, so the value written can never be computed differently
    than the value the installer checks.

.PARAMETER Check
    Do not write anything. Exit non-zero if the pin is stale. This is what CI
    and the Pester drift guard use.

.EXAMPLE
    pwsh -File tools/Update-InstallerHash.ps1
    Rewrites the pin in install.ps1 if the provisioner changed.

.EXAMPLE
    pwsh -File tools/Update-InstallerHash.ps1 -Check
    Reports whether the pin is current; non-zero exit means it drifted.
#>
[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$provisionerPath = Join-Path $root 'New-FedoraVirtualBoxVM.ps1'
$installerPath = Join-Path $root 'install.ps1'

$installerText = Get-Content -Raw -LiteralPath $installerPath

# Load Get-CanonicalScriptHash from install.ps1 so the tool and the installer
# agree on exactly how the pin is computed.
$ast = [System.Management.Automation.Language.Parser]::ParseInput(
    $installerText, [ref]$null, [ref]$null)
$hasher = $ast.FindAll({
        $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $args[0].Name -eq 'Get-CanonicalScriptHash'
    }, $true)
if (-not $hasher) {
    throw "Get-CanonicalScriptHash was not found in $installerPath"
}
. ([scriptblock]::Create($hasher[0].Extent.Text))

$actualHash = Get-CanonicalScriptHash -Content (Get-Content -Raw -LiteralPath $provisionerPath)

$pattern = "(?m)^(\`$expectedProvisionerHash\s*=\s*')([0-9a-fA-F]{64})(')"
$match = [regex]::Match($installerText, $pattern)
if (-not $match.Success) {
    throw "Could not find the `$expectedProvisionerHash pin in $installerPath"
}
$currentHash = $match.Groups[2].Value.ToLowerInvariant()

if ($currentHash -eq $actualHash) {
    Write-Host "Provisioner pin is current: $actualHash" -ForegroundColor Green
    return
}

if ($Check) {
    Write-Error ("Provisioner pin is stale. install.ps1 pins {0} but the script hashes to {1}. " -f $currentHash, $actualHash +
        "Run tools/Update-InstallerHash.ps1 to fix.")
    exit 1
}

$updated = [regex]::Replace($installerText, $pattern, "`${1}$actualHash`${3}")
[System.IO.File]::WriteAllText($installerPath, $updated, [System.Text.UTF8Encoding]::new($false))
Write-Host "Updated provisioner pin: $currentHash -> $actualHash" -ForegroundColor Yellow
