#Requires -Modules Pester

BeforeAll {
    # Dot-source the script functions by extracting them.
    # We parse the script AST to get function definitions without running Main.
    $scriptPath = Join-Path (Join-Path $PSScriptRoot "..") "New-FedoraVirtualBoxVM.ps1"
    $scriptContent = Get-Content $scriptPath -Raw

    # Extract and define individual functions for testing
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($scriptContent, [ref]$null, [ref]$null)
    $functions = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

    foreach ($func in $functions) {
        # Define each function in the current scope
        Invoke-Expression $func.Extent.Text
    }

    # Set up script-scoped variables that functions depend on
    $Script:UseEmoji = $false
    $Script:Icons = @{ Running=">>"; Done="OK"; Warn="!!"; Error="XX"; Info="--" }
    $Script:Colors = @{
        Header  = "Cyan"
        Success = "Green"
        Warning = "Yellow"
        Error   = "Red"
        Info    = "White"
        Accent  = "Magenta"
    }
}

Describe "Get-OptimalVMConfig" {
    Context "Low-end system (4 cores, 8 GB RAM, 40 GB free, 256 MB VRAM)" {
        It "Should return minimum viable config" {
            $specs = [PSCustomObject]@{
                CPUName       = "Test CPU"
                PhysicalCores = 2
                LogicalCores  = 4
                TotalRAMGB    = 8.0
                FreeSpaceGB   = 40.0
                BestDrive     = "C:"
                GPUName       = "Test GPU"
                GPUVRAM_MB    = 256
                VTxEnabled    = $true
            }

            $config = Get-OptimalVMConfig -Specs $specs
            $config.CPUs | Should -Be 2
            $config.RAMMB | Should -BeGreaterOrEqual 4096
            $config.DiskGB | Should -BeLessOrEqual 40
            $config.Enable3D | Should -BeFalse
        }
    }

    Context "Mid-range system (8 cores, 16 GB RAM, 120 GB free, 1024 MB VRAM)" {
        It "Should return balanced config" {
            $specs = [PSCustomObject]@{
                CPUName       = "Test CPU"
                PhysicalCores = 4
                LogicalCores  = 8
                TotalRAMGB    = 16.0
                FreeSpaceGB   = 120.0
                BestDrive     = "C:"
                GPUName       = "Test GPU"
                GPUVRAM_MB    = 1024
                VTxEnabled    = $true
            }

            $config = Get-OptimalVMConfig -Specs $specs
            $config.CPUs | Should -Be 4
            $config.RAMMB | Should -BeGreaterOrEqual 4096
            $config.RAMMB | Should -BeLessOrEqual 16384
            $config.DiskGB | Should -Be 60
            $config.Enable3D | Should -BeTrue
        }
    }

    Context "High-end system (24 cores, 64 GB RAM, 500 GB free, 8192 MB VRAM)" {
        It "Should return capped config" {
            $specs = [PSCustomObject]@{
                CPUName       = "Test CPU"
                PhysicalCores = 12
                LogicalCores  = 24
                TotalRAMGB    = 64.0
                FreeSpaceGB   = 500.0
                BestDrive     = "C:"
                GPUName       = "Test GPU"
                GPUVRAM_MB    = 8192
                VTxEnabled    = $true
            }

            $config = Get-OptimalVMConfig -Specs $specs
            $config.CPUs | Should -Be 8   # capped at 8
            $config.RAMMB | Should -Be 16384  # capped at 16384
            $config.DiskGB | Should -Be 80
            $config.Enable3D | Should -BeTrue
        }
    }

    Context "Config boundaries" {
        It "Should never return less than 2 CPUs even with 2 logical cores" {
            $specs = [PSCustomObject]@{
                CPUName       = "Test CPU"
                PhysicalCores = 1
                LogicalCores  = 2
                TotalRAMGB    = 4.0
                FreeSpaceGB   = 25.0
                BestDrive     = "C:"
                GPUName       = "Test GPU"
                GPUVRAM_MB    = 128
                VTxEnabled    = $false
            }

            $config = Get-OptimalVMConfig -Specs $specs
            $config.CPUs | Should -BeGreaterOrEqual 2
        }

        It "Should always return VRAM as a multiple of 16" {
            $specs = [PSCustomObject]@{
                CPUName       = "Test CPU"
                PhysicalCores = 4
                LogicalCores  = 8
                TotalRAMGB    = 16.0
                FreeSpaceGB   = 100.0
                BestDrive     = "C:"
                GPUName       = "Test GPU"
                GPUVRAM_MB    = 300
                VTxEnabled    = $true
            }

            $config = Get-OptimalVMConfig -Specs $specs
            ($config.VRAMMB % 16) | Should -Be 0
        }

        It "Should always return RAM as a multiple of 256" {
            $specs = [PSCustomObject]@{
                CPUName       = "Test CPU"
                PhysicalCores = 4
                LogicalCores  = 8
                TotalRAMGB    = 12.0
                FreeSpaceGB   = 100.0
                BestDrive     = "C:"
                GPUName       = "Test GPU"
                GPUVRAM_MB    = 512
                VTxEnabled    = $true
            }

            $config = Get-OptimalVMConfig -Specs $specs
            ($config.RAMMB % 256) | Should -Be 0
        }
    }
}

Describe "Get-FreeDriveLetter" {
    It "Should return a single letter" {
        $letter = Get-FreeDriveLetter
        $letter | Should -Match "^[A-Z]$"
    }

    It "Should not return a letter already in use" {
        $usedLetters = (Get-PSDrive -PSProvider FileSystem).Name
        $letter = Get-FreeDriveLetter
        $usedLetters | Should -Not -Contain $letter
    }
}

Describe "New-KickstartFile" {
    BeforeAll {
        $testDir = Join-Path $env:TEMP "pester-ks-test-$(Get-Random)"
        New-Item -Path $testDir -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context "Default Fedora Kickstart" {
        BeforeAll {
            $ksPath = Join-Path $testDir "ks-default.cfg"
            $null = New-KickstartFile `
                -Path $ksPath `
                -GuestUser "testuser" `
                -GuestPass "testpass" `
                -Hostname "test-vm" `
                -Timezone "UTC" `
                -PackageGroup "@^workstation-product-environment"
            $ksContent = Get-Content $ksPath -Raw
        }

        It "Should create the kickstart file" {
            Test-Path $ksPath | Should -BeTrue
        }

        It "Should contain the correct username" {
            $ksContent | Should -Match "testuser"
        }

        It "Should contain the correct hostname" {
            $ksContent | Should -Match "test-vm"
        }

        It "Should contain the correct timezone" {
            $ksContent | Should -Match "timezone UTC"
        }

        It "Should contain the workstation package group" {
            $ksContent | Should -Match "@\^workstation-product-environment"
        }

        It "Should contain NOPASSWD sudo by default" {
            $ksContent | Should -Match "NOPASSWD"
        }

        It "Should contain essential packages" {
            $ksContent | Should -Match "openssh-server"
            $ksContent | Should -Match "sudo"
            $ksContent | Should -Match "git"
        }

        It "Should use --iscrypted or --plaintext for password" {
            $ksContent | Should -Match "(--iscrypted|--plaintext)"
        }
    }

    Context "Server Kickstart with SecureSudo" {
        BeforeAll {
            $ksPath = Join-Path $testDir "ks-secure.cfg"
            $null = New-KickstartFile `
                -Path $ksPath `
                -GuestUser "admin" `
                -GuestPass "secure123" `
                -Hostname "server-vm" `
                -Timezone "Europe/London" `
                -PackageGroup "@^server-product-environment" `
                -SecureSudoMode
            $ksContent = Get-Content $ksPath -Raw
        }

        It "Should use server package group" {
            $ksContent | Should -Match "@\^server-product-environment"
        }

        It "Should NOT contain NOPASSWD when SecureSudo is set" {
            $ksContent | Should -Not -Match "NOPASSWD"
        }

        It "Should contain ALL=(ALL) ALL for sudo" {
            $ksContent | Should -Match "ALL=\(ALL\) ALL"
        }

        It "Should NOT include gnome-tweaks for server environments" {
            $ksContent | Should -Not -Match "gnome-tweaks"
        }

        It "Should NOT include GDM auto-login for server environments" {
            $ksContent | Should -Not -Match "AutomaticLoginEnable"
            $ksContent | Should -Not -Match "systemctl enable gdm"
        }
    }

    Context "Workstation Kickstart desktop packages" {
        BeforeAll {
            $ksPath = Join-Path $testDir "ks-workstation.cfg"
            $null = New-KickstartFile `
                -Path $ksPath `
                -GuestUser "user" `
                -GuestPass "pass" `
                -Hostname "fedora-vm" `
                -Timezone "UTC" `
                -PackageGroup "@^workstation-product-environment"
            $ksContent = Get-Content $ksPath -Raw
        }

        It "Should include gnome-tweaks for workstation" {
            $ksContent | Should -Match "gnome-tweaks"
        }

        It "Should include GDM auto-login for workstation" {
            $ksContent | Should -Match "AutomaticLoginEnable=True"
        }

        It "Should enable GDM service for workstation" {
            $ksContent | Should -Match "systemctl enable gdm"
        }
    }

    Context "Kickstart with shared folder" {
        BeforeAll {
            $ksPath = Join-Path $testDir "ks-shared.cfg"
            $null = New-KickstartFile `
                -Path $ksPath `
                -GuestUser "user" `
                -GuestPass "pass" `
                -Hostname "vm" `
                -Timezone "UTC" `
                -PackageGroup "@^workstation-product-environment" `
                -SharedFolderName "shared"
            $ksContent = Get-Content $ksPath -Raw
        }

        It "Should contain shared folder mount setup" {
            $ksContent | Should -Match "mount-vbox-shared"
        }

        It "Should contain vboxsf module loading" {
            $ksContent | Should -Match "vboxsf"
        }

        It "Should create /mnt/shared directory" {
            $ksContent | Should -Match "mkdir -p /mnt/shared"
        }
    }
}

Describe "Get-DistroConfig" {
    It "Should return correct config for Fedora" {
        $config = Get-DistroConfig -Distro "Fedora" -Version "43"
        $config.PackageGroup | Should -Be "@^workstation-product-environment"
        $config.OSType | Should -Be "Fedora_64"
        $config.DefaultHostname | Should -Be "fedora-vm"
    }

    It "Should return server package group for CentOS-Stream" {
        $config = Get-DistroConfig -Distro "CentOS-Stream" -Version "9"
        $config.PackageGroup | Should -Be "@^server-product-environment"
        $config.OSType | Should -Be "RedHat_64"
    }

    It "Should return server package group for AlmaLinux" {
        $config = Get-DistroConfig -Distro "AlmaLinux" -Version "9"
        $config.PackageGroup | Should -Be "@^server-product-environment"
        $config.DefaultHostname | Should -Be "alma-vm"
    }

    It "Should return server package group for Rocky" {
        $config = Get-DistroConfig -Distro "Rocky" -Version "9"
        $config.PackageGroup | Should -Be "@^server-product-environment"
        $config.DefaultHostname | Should -Be "rocky-vm"
    }
}

Describe "Provision State Management" {
    BeforeAll {
        $testDir = Join-Path $env:TEMP "pester-state-test-$(Get-Random)"
        New-Item -Path $testDir -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Should return null for nonexistent state file" {
        $state = Get-ProvisionState -StatePath (Join-Path $testDir "nonexistent.json")
        $state | Should -BeNullOrEmpty
    }

    It "Should save and load state correctly" {
        $path = Join-Path $testDir "state.json"
        $testState = @{
            iso_ready         = $true
            kickstart_created = $true
            oemdrv_created    = $false
        }
        Save-ProvisionState -StatePath $path -State $testState
        $loaded = Get-ProvisionState -StatePath $path
        $loaded.iso_ready | Should -BeTrue
        $loaded.kickstart_created | Should -BeTrue
        $loaded.oemdrv_created | Should -BeFalse
    }

    It "Should correctly test step completion" {
        $path = Join-Path $testDir "state2.json"
        $testState = @{
            iso_ready         = $true
            kickstart_created = $false
        }
        Save-ProvisionState -StatePath $path -State $testState
        $loaded = Get-ProvisionState -StatePath $path
        Test-StepCompleted -State $loaded -StepName "iso_ready" | Should -BeTrue
        Test-StepCompleted -State $loaded -StepName "kickstart_created" | Should -BeFalse
        Test-StepCompleted -State $loaded -StepName "nonexistent_step" | Should -BeFalse
    }

    It "Should handle null state in Test-StepCompleted" {
        Test-StepCompleted -State $null -StepName "anything" | Should -BeFalse
    }
}

Describe "Emoji Fallback" {
    It "Should have text fallback icons defined" {
        $textIcons = @{ Running=">>"; Done="OK"; Warn="!!"; Error="XX"; Info="--" }
        $textIcons.Running | Should -Be ">>"
        $textIcons.Done | Should -Be "OK"
        $textIcons.Warn | Should -Be "!!"
        $textIcons.Error | Should -Be "XX"
        $textIcons.Info | Should -Be "--"
    }

    It "Should have emoji icons defined" {
        # Verify the emoji icon set has all required keys
        $emojiIcons = @{ Running="R"; Done="D"; Warn="W"; Error="E"; Info="I" }
        $emojiIcons.Keys.Count | Should -Be 5
        $emojiIcons.ContainsKey("Running") | Should -BeTrue
        $emojiIcons.ContainsKey("Done") | Should -BeTrue
        $emojiIcons.ContainsKey("Info") | Should -BeTrue
    }
}

Describe "New-SHA512CryptHash" {
    It "Should return a valid SHA-512 hash or throw if no tool is available" {
        try {
            $result = New-SHA512CryptHash -Passphrase "test"
            $result | Should -Match '^\$6\$'
            $result.Length | Should -BeGreaterThan 20
        }
        catch {
            $_.Exception.Message | Should -Match "Cannot hash password"
        }
    }

    It "Should throw with a descriptive message when no hashing tool exists" {
        # Mock both Get-Command calls to return nothing
        Mock Get-Command { $null }

        { New-SHA512CryptHash -Passphrase "test" } | Should -Throw "*Cannot hash password*"
    }
}

Describe "Find-VBoxManage" {
    It "Should check standard VirtualBox install paths" {
        # Mock Write-Host/Write-Step to suppress output
        Mock Write-Host {}
        Mock Write-Step {} -ErrorAction SilentlyContinue

        # Mock Test-Path to return false for all candidates
        Mock Test-Path { $false }
        Mock Get-Command { $null }

        # Should throw when VBoxManage is not found anywhere
        # Also mock Start-Process to prevent opening a browser
        Mock Start-Process {}

        { Find-VBoxManage } | Should -Throw "*VBoxManage*"
    }

    It "Should return path when VBoxManage is on PATH" {
        Mock Write-Host {}
        Mock Write-Step {} -ErrorAction SilentlyContinue

        $fakePath = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
        Mock Get-Command { [PSCustomObject]@{ Source = $fakePath } }
        Mock Test-Path { $true } -ParameterFilter { $Path -eq $fakePath }

        $result = Find-VBoxManage
        $result | Should -Be $fakePath
    }
}

Describe "New-HelperScripts" {
    BeforeAll {
        $testDir = Join-Path $env:TEMP "pester-helpers-test-$(Get-Random)"
        New-Item -Path $testDir -ItemType Directory -Force | Out-Null

        # Suppress console output
        Mock Write-Host {}
        Mock Write-Step {} -ErrorAction SilentlyContinue

        New-HelperScripts `
            -VBoxManage "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" `
            -VMName "TestVM" `
            -VMDir $testDir `
            -SSHUser "testuser" `
            -SSHPort 2222
    }

    AfterAll {
        Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Should create Start-VM.ps1" {
        Test-Path (Join-Path $testDir "Start-VM.ps1") | Should -BeTrue
    }

    It "Should create Stop-VM.ps1" {
        Test-Path (Join-Path $testDir "Stop-VM.ps1") | Should -BeTrue
    }

    It "Should create SSH-Connect.ps1" {
        Test-Path (Join-Path $testDir "SSH-Connect.ps1") | Should -BeTrue
    }

    It "Start-VM.ps1 should reference the correct VM name" {
        $content = Get-Content (Join-Path $testDir "Start-VM.ps1") -Raw
        $content | Should -Match "TestVM"
    }

    It "SSH-Connect.ps1 should reference the correct port and user" {
        $content = Get-Content (Join-Path $testDir "SSH-Connect.ps1") -Raw
        $content | Should -Match "2222"
        $content | Should -Match "testuser"
    }
}

Describe "Invoke-ExternalCommand" {
    It "Should return output from a successful command" {
        $result = Invoke-ExternalCommand -FilePath "cmd.exe" -Arguments @("/c", "echo hello")
        $result | Should -Match "hello"
    }

    It "Should throw on non-zero exit code by default" {
        { Invoke-ExternalCommand -FilePath "cmd.exe" -Arguments @("/c", "exit 1") } | Should -Throw "*Command failed*"
    }

    It "Should not throw with -NoThrow on non-zero exit code" {
        { Invoke-ExternalCommand -FilePath "cmd.exe" -Arguments @("/c", "exit 1") -NoThrow } | Should -Not -Throw
    }
}

Describe "GuestHostname default behavior" {
    It "Each distro should have a DefaultHostname in its config" {
        foreach ($distro in @("Fedora", "CentOS-Stream", "AlmaLinux", "Rocky")) {
            $config = Get-DistroConfig -Distro $distro -Version "9"
            $config.DefaultHostname | Should -Not -BeNullOrEmpty -Because "$distro should have a DefaultHostname"
        }
    }

    It "Fedora DefaultHostname should be fedora-vm" {
        $config = Get-DistroConfig -Distro "Fedora" -Version "43"
        $config.DefaultHostname | Should -Be "fedora-vm"
    }

    It "Rocky DefaultHostname should be rocky-vm" {
        $config = Get-DistroConfig -Distro "Rocky" -Version "9"
        $config.DefaultHostname | Should -Be "rocky-vm"
    }
}

Describe "Test-ValidHostname (#20)" {
    It "Accepts simple lowercase hostname" {
        Test-ValidHostname -Hostname "fedora-vm" | Should -BeTrue
    }

    It "Accepts multi-label FQDN" {
        Test-ValidHostname -Hostname "host-1.lab.example" | Should -BeTrue
    }

    It "Accepts digit-leading labels (RFC 1123)" {
        Test-ValidHostname -Hostname "1host" | Should -BeTrue
    }

    It "Rejects empty string" {
        Test-ValidHostname -Hostname "" | Should -BeFalse
    }

    It "Rejects uppercase letters" {
        Test-ValidHostname -Hostname "Fedora-VM" | Should -BeFalse
    }

    It "Rejects underscore" {
        Test-ValidHostname -Hostname "fedora_vm" | Should -BeFalse
    }

    It "Rejects leading hyphen" {
        Test-ValidHostname -Hostname "-fedora" | Should -BeFalse
    }

    It "Rejects trailing hyphen" {
        Test-ValidHostname -Hostname "fedora-" | Should -BeFalse
    }

    It "Rejects label longer than 63 chars" {
        $longLabel = "a" * 64
        Test-ValidHostname -Hostname $longLabel | Should -BeFalse
    }

    It "Accepts label exactly 63 chars" {
        $maxLabel = "a" * 63
        Test-ValidHostname -Hostname $maxLabel | Should -BeTrue
    }

    It "Rejects total length over 253" {
        $hn = (("a" * 63 + ".") * 4).TrimEnd('.')
        Test-ValidHostname -Hostname $hn | Should -BeFalse
    }

    It "Rejects space in hostname" {
        Test-ValidHostname -Hostname "fedora vm" | Should -BeFalse
    }
}

Describe "Find-VBoxManage (#14)" {
    It "Does not invoke Start-Process (no browser side-effect)" {
        $fn = Get-Command Find-VBoxManage
        $fn.Definition | Should -Not -Match 'Start-Process'
    }

    It "References the VirtualBox download URL in its throw message" {
        $fn = Get-Command Find-VBoxManage
        $fn.Definition | Should -Match 'virtualbox\.org/wiki/Downloads'
    }
}

Describe "Test-PortAvailable (#11)" {
    It "Returns true for a port that is free" {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $freePort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        $listener.Stop()

        Test-PortAvailable -Port $freePort | Should -BeTrue
    }

    It "Returns false for a port that is currently bound" {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $busyPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        try {
            Test-PortAvailable -Port $busyPort | Should -BeFalse
        }
        finally {
            $listener.Stop()
        }
    }

    It "Returns false for an out-of-range port" {
        Test-PortAvailable -Port 0 | Should -BeFalse
        Test-PortAvailable -Port 70000 | Should -BeFalse
    }
}

Describe "New-OEMDRVVHD (#8)" {
    It "Wraps diskpart attach in try/finally" {
        $fn = Get-Command New-OEMDRVVHD
        $fn.Definition | Should -Match 'try\s*\{'
        $fn.Definition | Should -Match 'finally\s*\{'
    }

    It "Tracks attached state and only detaches when attached" {
        $fn = Get-Command New-OEMDRVVHD
        $fn.Definition | Should -Match '\$attached\s*=\s*\$false'
        $fn.Definition | Should -Match '\$attached\s*=\s*\$true'
    }
}

Describe "Wait-ForInstallShutdown (#21)" {
    It "Returns an object with Finished and LastState properties" {
        $fn = Get-Command Wait-ForInstallShutdown
        $fn.Definition | Should -Match 'Finished\s*=\s*\$true'
        $fn.Definition | Should -Match 'Finished\s*=\s*\$false'
        $fn.Definition | Should -Match 'LastState'
    }

    It "Logs the last VM state before returning on timeout" {
        $fn = Get-Command Wait-ForInstallShutdown
        $fn.Definition | Should -Match 'Last reported VM state'
    }
}

Describe "Get-DistroConfig version validation (#19)" {
    It "Accepts a plain numeric version" {
        { Get-DistroConfig -Distro "Fedora" -Version "43" } | Should -Not -Throw
    }

    It "Accepts a major.minor version" {
        { Get-DistroConfig -Distro "AlmaLinux" -Version "9.4" } | Should -Not -Throw
    }

    It "Rejects path traversal in the version" {
        { Get-DistroConfig -Distro "Fedora" -Version "../../etc/passwd" } | Should -Throw
    }

    It "Rejects letters in the version" {
        { Get-DistroConfig -Distro "Fedora" -Version "43abc" } | Should -Throw
    }

    It "Rejects URL-injection characters in the version" {
        { Get-DistroConfig -Distro "Fedora" -Version "43?evil=1" } | Should -Throw
    }
}

Describe "New-SHA512CryptHash secret handling (#1, #2)" {
    It "Uses openssl with -stdin instead of a positional password" {
        $fn = Get-Command New-SHA512CryptHash
        $fn.Definition | Should -Match 'openssl passwd -6 -stdin'
        $fn.Definition | Should -Not -Match 'openssl passwd -6 \$Passphrase'
    }

    It "Pipes the passphrase into openssl via stdin" {
        $fn = Get-Command New-SHA512CryptHash
        $fn.Definition | Should -Match '\$Passphrase\s*\|\s*&\s*openssl'
    }

    It "Reads the python fallback password from an env var, not the command line" {
        $fn = Get-Command New-SHA512CryptHash
        $fn.Definition | Should -Match 'VBOX_KS_PASSWD'
        $fn.Definition | Should -Match 'os\.environ'
        $fn.Definition | Should -Not -Match "crypt\.crypt\('\$Passphrase'"
    }

    It "Restores or removes the env var after the python fallback runs" {
        $fn = Get-Command New-SHA512CryptHash
        $fn.Definition | Should -Match 'finally\s*\{'
        $fn.Definition | Should -Match 'Remove-Item Env:VBOX_KS_PASSWD'
    }
}

Describe "Test-SafeDiskpartPath (#18)" {
    It "Accepts a normal Windows VHD path" {
        Test-SafeDiskpartPath -Path 'C:\Users\me\VirtualBox VMs\Fedora\oemdrv.vhd' | Should -BeTrue
    }

    It "Rejects whitespace-only path" {
        Test-SafeDiskpartPath -Path '   ' | Should -BeFalse
    }

    It "Rejects a path containing a double quote" {
        Test-SafeDiskpartPath -Path 'C:\evil".vhd' | Should -BeFalse
    }

    It "Rejects a path containing a newline" {
        Test-SafeDiskpartPath -Path "C:\evil`nattach vdisk" | Should -BeFalse
    }

    It "Rejects a path containing a carriage return" {
        Test-SafeDiskpartPath -Path "C:\evil`rattach vdisk" | Should -BeFalse
    }

    It "Rejects a path containing redirect or pipe characters" {
        Test-SafeDiskpartPath -Path 'C:\evil>out.txt' | Should -BeFalse
        Test-SafeDiskpartPath -Path 'C:\evil|cmd' | Should -BeFalse
        Test-SafeDiskpartPath -Path 'C:\evil&whoami' | Should -BeFalse
    }
}

Describe "New-OEMDRVVHD path guard (#18)" {
    It "Throws before touching diskpart when the VHD path is unsafe" {
        {
            New-OEMDRVVHD -VHDPath "C:\bad`nattach vdisk" -KickstartPath "C:\ks.cfg"
        } | Should -Throw '*unsafe path*'
    }
}

Describe "Find-ChecksumFileName (#7)" {
    It "Finds a Fedora-style CHECKSUM file" {
        $listing = '<a href="Fedora-Everything-43-1.1-x86_64-CHECKSUM">link</a>'
        Find-ChecksumFileName -ListingContent $listing |
            Should -Be 'Fedora-Everything-43-1.1-x86_64-CHECKSUM'
    }

    It "Finds an AlmaLinux/Rocky SHA256SUMS file" {
        $listing = '<a href="SHA256SUMS">SHA256SUMS</a> <a href="AlmaLinux.iso">iso</a>'
        Find-ChecksumFileName -ListingContent $listing | Should -Be 'SHA256SUMS'
    }

    It "Finds a sha256sum.txt file" {
        $listing = 'href="sha256sum.txt" href="boot.iso"'
        Find-ChecksumFileName -ListingContent $listing | Should -Be 'sha256sum.txt'
    }

    It "Is case-insensitive for the checksum keyword" {
        $listing = 'href="checksum"'
        Find-ChecksumFileName -ListingContent $listing | Should -Be 'checksum'
    }

    It "Prefers a CHECKSUM file over a SHA256SUMS file when both exist" {
        $listing = 'href="SHA256SUMS" href="Fedora-CHECKSUM"'
        Find-ChecksumFileName -ListingContent $listing | Should -Be 'Fedora-CHECKSUM'
    }

    It "Skips detached signatures and keeps looking" {
        $listing = 'href="SHA256SUMS.asc" href="SHA256SUMS.sig" href="SHA256SUMS"'
        Find-ChecksumFileName -ListingContent $listing | Should -Be 'SHA256SUMS'
    }

    It "Returns null when no checksum manifest is present" {
        $listing = '<a href="boot.iso">iso</a> <a href="README.txt">readme</a>'
        Find-ChecksumFileName -ListingContent $listing | Should -BeNullOrEmpty
    }

    It "Returns null for empty listing content" {
        Find-ChecksumFileName -ListingContent '' | Should -BeNullOrEmpty
    }
}

Describe "Get-VMState" {
    It "Pulls the state value out of machine-readable output" {
        Mock Invoke-VBoxManage {
            'name="Fedora-Workstation"' + "`n" + 'VMState="running"' + "`n" + 'VMStateChangeTime="2026-07-08T00:00:00.000000000"'
        }
        Get-VMState -VBoxManage "vbox" -VMName "Fedora-Workstation" | Should -Be "running"
    }

    It "Reports poweroff when the guest is off" {
        Mock Invoke-VBoxManage { 'VMState="poweroff"' }
        Get-VMState -VBoxManage "vbox" -VMName "vm" | Should -Be "poweroff"
    }

    It "Strips the surrounding quotes from the value" {
        Mock Invoke-VBoxManage { 'VMState="saved"' }
        Get-VMState -VBoxManage "vbox" -VMName "vm" | Should -Be "saved"
    }

    It "Does not pick up VMStateChangeTime instead of VMState" {
        # VMStateChangeTime shares the VMState prefix, so a loose match would
        # grab the wrong line. Put it first and confirm the real line still wins.
        Mock Invoke-VBoxManage {
            'VMStateChangeTime="2026-07-08T00:00:00.000000000"' + "`n" + 'VMState="running"'
        }
        Get-VMState -VBoxManage "vbox" -VMName "vm" | Should -Be "running"
    }

    It "Returns an empty string when there is no VMState line" {
        Mock Invoke-VBoxManage { 'name="vm"' + "`n" + 'CfgFile="C:\VMs\vm.vbox"' }
        Get-VMState -VBoxManage "vbox" -VMName "vm" | Should -Be ""
    }

    It "Returns an empty string when the command produces no output" {
        Mock Invoke-VBoxManage { "" }
        Get-VMState -VBoxManage "vbox" -VMName "missing" | Should -Be ""
    }
}

Describe "Remove-InstallArtifacts" {
    BeforeEach {
        $workDir = Join-Path $env:TEMP "pester-artifacts-$(Get-Random)"
        New-Item -Path $workDir -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Removes both ks.cfg and the OEMDRV disk" {
        Set-Content -Path (Join-Path $workDir "ks.cfg") -Value "kickstart"
        Set-Content -Path (Join-Path $workDir "OEMDRV.vhd") -Value "disk"

        Remove-InstallArtifacts -WorkDir $workDir

        Test-Path (Join-Path $workDir "ks.cfg")     | Should -BeFalse
        Test-Path (Join-Path $workDir "OEMDRV.vhd") | Should -BeFalse
    }

    It "Leaves the provision state file and anything else in place" {
        Set-Content -Path (Join-Path $workDir "provision-state.json") -Value "{}"
        Set-Content -Path (Join-Path $workDir "keepme.txt") -Value "keep"

        Remove-InstallArtifacts -WorkDir $workDir

        Test-Path (Join-Path $workDir "provision-state.json") | Should -BeTrue
        Test-Path (Join-Path $workDir "keepme.txt")           | Should -BeTrue
    }

    It "Does not throw when the artifacts are already gone" {
        { Remove-InstallArtifacts -WorkDir $workDir } | Should -Not -Throw
    }
}

Describe "Remove-ExistingVM" {
    BeforeAll {
        # Quiet the banner output these tests would otherwise print.
        Mock Write-Host {}
    }

    It "Throws when the VM exists and -Force is not set" {
        $Force = $false
        Mock Invoke-VBoxManage { '"Fedora-Workstation" {12345678-1234-1234-1234-1234567890ab}' }
        { Remove-ExistingVM -VBoxManage "vbox" -VMName "Fedora-Workstation" } |
            Should -Throw "*already exists*"
    }

    It "Returns quietly when the VM is not in the list" {
        $Force = $false
        Mock Invoke-VBoxManage { '"Some-Other-VM" {12345678-1234-1234-1234-1234567890ab}' }
        { Remove-ExistingVM -VBoxManage "vbox" -VMName "Fedora-Workstation" } |
            Should -Not -Throw
    }

    It "Does not treat a name that is only a prefix of another VM as a match" {
        # The check is anchored on the quoted name, so "Fedora-Workstation" must
        # not fire on "Fedora-Workstation-2".
        $Force = $false
        Mock Invoke-VBoxManage { '"Fedora-Workstation-2" {12345678-1234-1234-1234-1234567890ab}' }
        { Remove-ExistingVM -VBoxManage "vbox" -VMName "Fedora-Workstation" } |
            Should -Not -Throw
    }

    It "Escapes regex metacharacters in the VM name" {
        # A dot in the name has to match literally, not as a regex wildcard.
        $Force = $false
        Mock Invoke-VBoxManage { '"my.vm" {12345678-1234-1234-1234-1234567890ab}' }
        { Remove-ExistingVM -VBoxManage "vbox" -VMName "my.vm" } |
            Should -Throw "*already exists*"
    }

    It "Does not let a dot in the name match a different character" {
        $Force = $false
        Mock Invoke-VBoxManage { '"myXvm" {12345678-1234-1234-1234-1234567890ab}' }
        { Remove-ExistingVM -VBoxManage "vbox" -VMName "my.vm" } |
            Should -Not -Throw
    }
}

Describe "ConvertTo-ISOFileFilter" {
    It "Builds a Fedora filter that matches the real ISO name" {
        # The old derivation collapsed [0-9.] but left the + behind, so the
        # filter ended in *+.iso and matched nothing that exists.
        $filter = ConvertTo-ISOFileFilter -ISOPattern "Fedora-Everything-netinst-x86_64-43-[0-9.]+"
        $filter | Should -Be "Fedora-Everything-netinst-x86_64-43-*.iso"
        "Fedora-Everything-netinst-x86_64-43-1.1.iso" | Should -BeLike $filter
    }

    It "Leaves no regex quantifier in the Fedora filter" {
        ConvertTo-ISOFileFilter -ISOPattern "Fedora-Everything-netinst-x86_64-43-[0-9.]+" |
            Should -Not -Match '\+'
    }

    It "Builds an AlmaLinux filter that matches the real ISO name" {
        $filter = ConvertTo-ISOFileFilter -ISOPattern "AlmaLinux-9[0-9.]*-x86_64-dvd"
        "AlmaLinux-9.6-x86_64-dvd.iso" | Should -BeLike $filter
    }

    It "Builds a Rocky filter that matches the real ISO name" {
        $filter = ConvertTo-ISOFileFilter -ISOPattern "Rocky-9[0-9.]*-x86_64-dvd"
        "Rocky-9.6-x86_64-dvd.iso" | Should -BeLike $filter
    }

    It "Passes a CentOS-Stream pattern through untouched apart from the extension" {
        ConvertTo-ISOFileFilter -ISOPattern "CentOS-Stream-9-latest-x86_64-dvd1" |
            Should -Be "CentOS-Stream-9-latest-x86_64-dvd1.iso"
    }

    It "Collapses a shorthand class and its quantifier too" {
        # Nothing ships \d today, but the next distro added might.
        ConvertTo-ISOFileFilter -ISOPattern 'Something-\d+-x86_64' |
            Should -Be "Something-*-x86_64.iso"
    }

    It "Collapses runs of wildcards into one" {
        ConvertTo-ISOFileFilter -ISOPattern "Alma-[0-9]*[0-9]*-dvd" |
            Should -Be "Alma-*-dvd.iso"
    }

    It "Does not match an unrelated distro's ISO" {
        $filter = ConvertTo-ISOFileFilter -ISOPattern "Fedora-Everything-netinst-x86_64-43-[0-9.]+"
        "AlmaLinux-9.6-x86_64-dvd.iso" | Should -Not -BeLike $filter
    }

    It "Does not match a different Fedora release" {
        $filter = ConvertTo-ISOFileFilter -ISOPattern "Fedora-Everything-netinst-x86_64-43-[0-9.]+"
        "Fedora-Everything-netinst-x86_64-42-1.1.iso" | Should -Not -BeLike $filter
    }
}

Describe "Test-ISOChecksum" {
    BeforeAll {
        Mock Write-Host {}
    }

    BeforeEach {
        $script:isoName = "Fedora-Everything-netinst-x86_64-43-1.1.iso"
        $script:isoDir  = Join-Path $env:TEMP "pester-isocheck-$(Get-Random)"
        New-Item -Path $script:isoDir -ItemType Directory -Force | Out-Null
        $script:isoPath = Join-Path $script:isoDir $script:isoName
        Set-Content -Path $script:isoPath -Value "pretend this is an installer image" -NoNewline
        $script:realHash = (Get-FileHash -Path $script:isoPath -Algorithm SHA256).Hash.ToLower()
        $script:listing  = 'href="Fedora-43-1.1-x86_64-CHECKSUM"'
    }

    AfterEach {
        Remove-Item $script:isoDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Accepts a BSD-style manifest whose hash matches" {
        # Fedora ships "SHA256 (file) = hash" inside a clearsigned CHECKSUM file.
        $script:manifest = "# comment line`nSHA256 ($script:isoName) = $script:realHash"
        Mock Invoke-WebRequest {
            if ($Uri -like '*CHECKSUM*') { [PSCustomObject]@{ Content = $script:manifest } }
            else { [PSCustomObject]@{ Content = $script:listing } }
        }
        { Test-ISOChecksum -ISOPath $script:isoPath -IndexUrl "https://mirror.example/iso/" } |
            Should -Not -Throw
    }

    It "Accepts a GNU-style manifest whose hash matches" {
        $script:manifest = "$script:realHash  $script:isoName"
        Mock Invoke-WebRequest {
            if ($Uri -like '*CHECKSUM*') { [PSCustomObject]@{ Content = $script:manifest } }
            else { [PSCustomObject]@{ Content = $script:listing } }
        }
        { Test-ISOChecksum -ISOPath $script:isoPath -IndexUrl "https://mirror.example/iso/" } |
            Should -Not -Throw
    }

    It "Accepts a GNU-style manifest that marks the file as binary" {
        $script:manifest = "$script:realHash *$script:isoName"
        Mock Invoke-WebRequest {
            if ($Uri -like '*CHECKSUM*') { [PSCustomObject]@{ Content = $script:manifest } }
            else { [PSCustomObject]@{ Content = $script:listing } }
        }
        { Test-ISOChecksum -ISOPath $script:isoPath -IndexUrl "https://mirror.example/iso/" } |
            Should -Not -Throw
    }

    It "Throws when the published hash does not match the file" {
        $script:manifest = "SHA256 ($script:isoName) = $('a' * 64)"
        Mock Invoke-WebRequest {
            if ($Uri -like '*CHECKSUM*') { [PSCustomObject]@{ Content = $script:manifest } }
            else { [PSCustomObject]@{ Content = $script:listing } }
        }
        { Test-ISOChecksum -ISOPath $script:isoPath -IndexUrl "https://mirror.example/iso/" } |
            Should -Throw "*checksum mismatch*"
    }

    It "Ignores an entry for a different file in the same manifest" {
        # A manifest lists every image in the directory. Picking the wrong line
        # would fail a good ISO.
        $script:manifest = "SHA256 (Fedora-Server-netinst-x86_64-43-1.1.iso) = $('b' * 64)`nSHA256 ($script:isoName) = $script:realHash"
        Mock Invoke-WebRequest {
            if ($Uri -like '*CHECKSUM*') { [PSCustomObject]@{ Content = $script:manifest } }
            else { [PSCustomObject]@{ Content = $script:listing } }
        }
        { Test-ISOChecksum -ISOPath $script:isoPath -IndexUrl "https://mirror.example/iso/" } |
            Should -Not -Throw
    }

    It "Warns instead of failing when the file is absent from the manifest" {
        $script:manifest = "SHA256 (some-other-image.iso) = $('c' * 64)"
        Mock Invoke-WebRequest {
            if ($Uri -like '*CHECKSUM*') { [PSCustomObject]@{ Content = $script:manifest } }
            else { [PSCustomObject]@{ Content = $script:listing } }
        }
        { Test-ISOChecksum -ISOPath $script:isoPath -IndexUrl "https://mirror.example/iso/" } |
            Should -Not -Throw
    }

    It "Warns instead of failing when the index listing is unreachable" {
        Mock Invoke-WebRequest { throw "network is down" }
        { Test-ISOChecksum -ISOPath $script:isoPath -IndexUrl "https://mirror.example/iso/" } |
            Should -Not -Throw
    }

    It "Warns instead of failing when the manifest download fails" {
        Mock Invoke-WebRequest {
            if ($Uri -like '*CHECKSUM*') { throw "404" }
            [PSCustomObject]@{ Content = $script:listing }
        }
        { Test-ISOChecksum -ISOPath $script:isoPath -IndexUrl "https://mirror.example/iso/" } |
            Should -Not -Throw
    }

    It "Warns instead of failing when the listing has no manifest at all" {
        Mock Invoke-WebRequest { [PSCustomObject]@{ Content = 'href="boot.iso" href="README.txt"' } }
        { Test-ISOChecksum -ISOPath $script:isoPath -IndexUrl "https://mirror.example/iso/" } |
            Should -Not -Throw
    }
}

Describe "Invoke-ISOChecksumGate" {
    BeforeAll {
        Mock Write-Host {}
    }

    BeforeEach {
        $script:gateDir = Join-Path $env:TEMP "pester-isogate-$(Get-Random)"
        New-Item -Path $script:gateDir -ItemType Directory -Force | Out-Null
        $script:gateIso = Join-Path $script:gateDir "Fedora-Everything-netinst-x86_64-43-1.1.iso"
        Set-Content -Path $script:gateIso -Value "image bytes" -NoNewline
    }

    AfterEach {
        Remove-Item $script:gateDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Deletes the ISO when verification fails" {
        # Leaving a bad ISO on disk is what let the next run reuse it and skip
        # verification entirely.
        Mock Test-ISOChecksum { throw "ISO checksum mismatch!" }
        { Invoke-ISOChecksumGate -ISOPath $script:gateIso -IndexUrl "https://mirror.example/iso/" } |
            Should -Throw "*checksum mismatch*"
        Test-Path $script:gateIso | Should -BeFalse
    }

    It "Keeps the ISO when verification passes" {
        Mock Test-ISOChecksum {}
        { Invoke-ISOChecksumGate -ISOPath $script:gateIso -IndexUrl "https://mirror.example/iso/" } |
            Should -Not -Throw
        Test-Path $script:gateIso | Should -BeTrue
    }

    It "Keeps the ISO when the mirror is unreachable and verification is skipped" {
        # Test-ISOChecksum warns and returns on network trouble, so an offline
        # run must not lose the image it already has.
        Mock Test-ISOChecksum {}
        Invoke-ISOChecksumGate -ISOPath $script:gateIso -IndexUrl "https://mirror.example/iso/"
        Test-Path $script:gateIso | Should -BeTrue
    }
}
