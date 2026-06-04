#Requires -Modules Pester

BeforeAll {
    # Pull the functions out of install.ps1 without running its top-level
    # self-elevation block, the same way the main script's tests do.
    $installPath = Join-Path (Join-Path $PSScriptRoot "..") "install.ps1"
    $installContent = Get-Content $installPath -Raw

    $ast = [System.Management.Automation.Language.Parser]::ParseInput($installContent, [ref]$null, [ref]$null)
    $functions = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($func in $functions) {
        Invoke-Expression $func.Extent.Text
    }

    # The real provisioner script is the canonical "good" input.
    $Script:RealScript = Get-Content (Join-Path (Join-Path $PSScriptRoot "..") "New-FedoraVirtualBoxVM.ps1") -Raw

    # A minimal script that still satisfies every gate: header, entry point,
    # parses cleanly, and longer than the 500-byte floor.
    $Script:MinimalGood = @'
#Requires -RunAsAdministrator
function New-FedoraVM {
    param([string]$VMName)
    Write-Output $VMName
}
'@ + ("`n# padding to clear the length floor" * 20)
}

Describe "Test-ProvisionerScriptContent (#4)" {
    It "Accepts the real provisioner script" {
        Test-ProvisionerScriptContent -Content $Script:RealScript | Should -BeTrue
    }

    It "Accepts a minimal but valid provisioner script" {
        Test-ProvisionerScriptContent -Content $Script:MinimalGood | Should -BeTrue
    }

    It "Rejects an empty string" {
        Test-ProvisionerScriptContent -Content "" | Should -BeFalse
    }

    It "Rejects whitespace-only content" {
        Test-ProvisionerScriptContent -Content "   `n`t  " | Should -BeFalse
    }

    It "Rejects content under the length floor even if it has the markers" {
        Test-ProvisionerScriptContent -Content "#Requires -RunAsAdministrator; function New-FedoraVM {}" | Should -BeFalse
    }

    It "Rejects an HTML error page" {
        $html = '<!DOCTYPE html><html><head><title>404</title></head><body>Not Found</body></html>'
        $html = $html + ('<p>padding line to clear the length floor</p>' * 20)
        Test-ProvisionerScriptContent -Content $html | Should -BeFalse
    }

    It "Rejects a download truncated before the entry point" {
        $truncated = $Script:RealScript.Substring(0, 600)
        Test-ProvisionerScriptContent -Content $truncated | Should -BeFalse
    }

    It "Rejects content with the right markers but a syntax error" {
        $broken = "#Requires -RunAsAdministrator`nfunction New-FedoraVM {`n  param("
        $broken = $broken + ("`n# padding to clear the length floor" * 20)
        Test-ProvisionerScriptContent -Content $broken | Should -BeFalse
    }

    It "Rejects content missing the admin requirement header" {
        $noHeader = "function New-FedoraVM { param([string]`$x) }"
        $noHeader = $noHeader + ("`n# padding to clear the length floor" * 20)
        Test-ProvisionerScriptContent -Content $noHeader | Should -BeFalse
    }
}
