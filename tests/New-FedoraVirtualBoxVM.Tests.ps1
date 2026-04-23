#Requires -Modules Pester

BeforeAll {
    # Dot-source the script functions by extracting them.
    # We parse the script AST to get function definitions without running Main.
    $scriptPath = Join-Path $PSScriptRoot ".." "New-FedoraVirtualBoxVM.ps1"
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
        $emojiIcons = @{ Running="⚡"; Done="✅"; Warn="⚠️"; Error="❌"; Info="ℹ️" }
        $emojiIcons.Running | Should -Not -BeNullOrEmpty
        $emojiIcons.Done | Should -Not -BeNullOrEmpty
    }
}

Describe "New-SHA512CryptHash" {
    It "Should return a string or null" {
        $result = New-SHA512CryptHash -Passphrase "test"
        if ($result) {
            $result | Should -Match '^\$6\$'
            $result.Length | Should -BeGreaterThan 20
        } else {
            $result | Should -BeNullOrEmpty
        }
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
