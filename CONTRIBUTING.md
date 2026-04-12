# Contributing to VirtualBox Auto-Installer

Thanks for your interest in contributing! Here's how to get started.

## Getting Started

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/Fedora-VirtualBox-Auto-Installer-PowerShell.git
   cd Fedora-VirtualBox-Auto-Installer-PowerShell
   ```
3. Run a dry-run validation (requires Administrator):
   ```powershell
   # Right-click PowerShell > "Run as Administrator"
   .\New-FedoraVirtualBoxVM.ps1 -Validate
   ```

## Development Notes

- **Single-script architecture** — All logic lives in `New-FedoraVirtualBoxVM.ps1`. Functions are extracted for testability but the script is self-contained.
- **No build step** — Edit the `.ps1` file and run it directly.
- **Admin required** — The script creates VMs and disk images, which requires elevation. Use `-Validate` for safe pre-flight checks during development.
- **PowerShell 5.1+** — Must work on the version pre-installed with Windows 10/11. Avoid PS 7-only syntax.
- **VirtualBox required** — Most functions depend on `VBoxManage.exe`. Unit tests use AST extraction to test logic without requiring VirtualBox to be installed.

## Testing

Run tests before submitting a PR:

```powershell
# Install test dependencies (first time only)
Install-Module -Name Pester -MinimumVersion 5.0 -Force -Scope CurrentUser
Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser

# Run linter
Invoke-ScriptAnalyzer -Path ./New-FedoraVirtualBoxVM.ps1 -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Warning,Error

# Run tests
Invoke-Pester ./tests -Output Detailed
```

Tests use Pester 5 with AST-based function extraction so individual functions can be tested without running the full provisioning workflow. When adding new functionality, add corresponding tests in the `tests/` directory.

## What to Work On

Some areas where help is appreciated:

- **Test coverage** — Integration tests for VBoxManage interactions (with mocks)
- **New distributions** — Adding support for other RHEL-family distros
- **Logging** — Optional file logging via a `-LogPath` parameter
- **IPv6 support** — Configuring IPv6 networking in the guest VM
- **Guest Additions** — Automated VirtualBox Guest Additions installation post-install
- **Configuration profiles** — Preset configs for common use cases (dev server, desktop, minimal)

## Pull Request Guidelines

1. **Keep PRs focused** — One feature or fix per PR.
2. **Test manually** — Run with `-Validate` and verify output looks correct.
3. **Run the linter** — `Invoke-ScriptAnalyzer` should report zero issues.
4. **Follow existing style** — Match the code patterns you see in the project.
5. **Update the README** if your change adds or modifies user-facing behavior.

## Reporting Bugs

Open an issue with:

- What you expected to happen
- What actually happened
- Steps to reproduce
- PowerShell version (`$PSVersionTable.PSVersion`)
- Windows version
- VirtualBox version
- Error output (if any)

## Code of Conduct

Be respectful, constructive, and inclusive. We're all here to make a useful tool better.
