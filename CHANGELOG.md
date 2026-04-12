# Changelog

All notable changes to VirtualBox Auto-Installer are documented here.

## [1.1.0] — 2026-04-12

### Added
- `CHANGELOG.md` for version history
- `CONTRIBUTING.md` with dev setup, testing, and PR guidelines
- `SECURITY.md` documenting permissions, data handling, and vulnerability reporting
- `install.ps1` one-line installer with self-elevation
- Parameter validation: `[ValidateRange]` on `-SSHHostPort` and `-InstallTimeoutMinutes`, `[ValidateNotNullOrEmpty]` on `-GuestUsername` and `-GuestPassword`
- New tests for `Find-VBoxManage`, `New-HelperScripts`, `Test-ISOChecksum`, and parameter validation
- README badges, one-line install section, and community file links

### Changed
- Password hashing now throws a terminating error when no hashing tool is available instead of falling back to plaintext
- Default `-GuestHostname` is now derived from the selected distro when not explicitly set

### Fixed
- CI workflow now triggers on `master` branch pushes in addition to `main`

## [1.0.0] — 2026-03-01

### Added
- Fully automatic RHEL-family VM provisioning for VirtualBox on Windows
- Support for Fedora, CentOS-Stream, AlmaLinux, and Rocky distributions
- Everything netinstall ISO with real Kickstart automation via OEMDRV
- Automatic system spec detection and VM resource calculation
- SHA256 ISO checksum verification for downloaded ISOs
- SHA-512 password hashing for Kickstart files (via OpenSSL or Python)
- Resumable provisioning with checkpoint state (`provision-state.json`)
- Pre-flight validation mode (`-Validate`) for dry-run checks
- Headless VM mode (`-Headless`)
- Shared folder support (`-SharedFolder`) with vboxsf auto-mount
- Secure sudo mode (`-SecureSudo`) requiring password for sudo commands
- Automatic install artifact cleanup (`ks.cfg`, `OEMDRV.vhd`)
- Helper script generation (`Start-VM.ps1`, `Stop-VM.ps1`, `SSH-Connect.ps1`)
- GitHub Actions CI with PSScriptAnalyzer and Pester tests
- Pester 5 test suite covering VM config, Kickstart generation, distro config, state management, and password hashing
