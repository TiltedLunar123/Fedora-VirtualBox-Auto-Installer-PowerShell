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

    # The SHA256 pin baked into install.ps1, read out of the source so the drift
    # guard compares against what actually ships, not a separate copy.
    $hashMatch = [regex]::Match($installContent, "(?m)^\`$expectedProvisionerHash\s*=\s*'([0-9a-fA-F]{64})'")
    $Script:EmbeddedHash = $hashMatch.Groups[1].Value

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

Describe "Get-CanonicalScriptHash (#4)" {
    It "Returns a 64-character lowercase hex digest" {
        Get-CanonicalScriptHash -Content $Script:RealScript | Should -Match '^[0-9a-f]{64}$'
    }

    It "Hashes the LF and CRLF forms of the same content identically" {
        $lf = $Script:RealScript -replace "`r`n", "`n" -replace "`r", "`n"
        $crlf = $lf -replace "`n", "`r`n"
        Get-CanonicalScriptHash -Content $crlf | Should -BeExactly (Get-CanonicalScriptHash -Content $lf)
    }

    It "Ignores a leading byte-order mark" {
        $bom = [char]0xFEFF + $Script:RealScript
        Get-CanonicalScriptHash -Content $bom | Should -BeExactly (Get-CanonicalScriptHash -Content $Script:RealScript)
    }

    It "Changes when a single character changes" {
        $tampered = $Script:RealScript + "`n# tampered"
        Get-CanonicalScriptHash -Content $tampered | Should -Not -BeExactly (Get-CanonicalScriptHash -Content $Script:RealScript)
    }
}

Describe "Test-ProvisionerScriptHash (#4)" {
    It "Accepts the real provisioner against the pin baked into install.ps1" {
        Test-ProvisionerScriptHash -Content $Script:RealScript -ExpectedHash $Script:EmbeddedHash | Should -BeTrue
    }

    It "Matches the pin regardless of line endings" {
        $crlf = ($Script:RealScript -replace "`r`n", "`n" -replace "`r", "`n") -replace "`n", "`r`n"
        Test-ProvisionerScriptHash -Content $crlf -ExpectedHash $Script:EmbeddedHash | Should -BeTrue
    }

    It "Is case-insensitive on the expected hash" {
        Test-ProvisionerScriptHash -Content $Script:RealScript -ExpectedHash $Script:EmbeddedHash.ToUpperInvariant() | Should -BeTrue
    }

    It "Rejects a tampered-but-parseable script" {
        # This is the gap the pin closes: content that passes the structural
        # check but is not the published file.
        $tampered = $Script:RealScript + "`nWrite-Output 'malicious payload'"
        Test-ProvisionerScriptContent -Content $tampered | Should -BeTrue
        Test-ProvisionerScriptHash -Content $tampered -ExpectedHash $Script:EmbeddedHash | Should -BeFalse
    }

    It "Rejects an empty expected hash" {
        Test-ProvisionerScriptHash -Content $Script:RealScript -ExpectedHash "" | Should -BeFalse
    }

    It "Rejects a whitespace expected hash" {
        Test-ProvisionerScriptHash -Content $Script:RealScript -ExpectedHash "   " | Should -BeFalse
    }
}

Describe "Installer hash pin stays in sync (#4)" {
    It "Pins a hash in the expected format" {
        $Script:EmbeddedHash | Should -Match '^[0-9a-f]{64}$'
    }

    It "Pins the hash of the committed provisioner (run tools/Update-InstallerHash.ps1 if this fails)" {
        Get-CanonicalScriptHash -Content $Script:RealScript | Should -BeExactly $Script:EmbeddedHash
    }
}
