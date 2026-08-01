# Contributing

Patches welcome. A few things that will save you time.

**Use `-Validate` while developing.** It runs the whole pre-flight path (parameter
checks, VBoxManage discovery, ISO URL construction, disk space) without creating a VM
or downloading several gigabytes of ISO. Almost everything can be worked on this way.
The full run needs elevation; `-Validate` does not.

**It is one script on purpose.** `New-FedoraVirtualBoxVM.ps1` holds all the logic.
Functions are split out so the tests can reach them, not as a step toward a module
layout. Please keep it that way unless you have a strong reason.

**PowerShell 5.1 is the floor.** That is what Windows 10 and 11 ship with. If you use
PS7-only syntax it will work for you and break for most people who run this.

**VirtualBox is not required to run the tests.** The suite pulls functions out through
the AST, so logic gets exercised without `VBoxManage.exe` being present. That is
deliberate, and it is why CI can run at all. If you add something that shells out to
VirtualBox, keep the decision-making in a function that can be tested on its own.

## Running the tests

```powershell
Install-Module -Name Pester -MinimumVersion 5.0 -Force -Scope CurrentUser
Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser

Invoke-ScriptAnalyzer -Path ./New-FedoraVirtualBoxVM.ps1 -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Warning,Error
Invoke-Pester ./tests -Output Detailed
```

Analyzer should be silent. New behaviour needs a test in `tests/`.

## Sending a change

Keep it to one thing per pull request, run `-Validate` and confirm the output still
looks right, and update the README if you changed something visible to whoever runs it.
Match the style that is already there.

## Filing a bug

Tell me what you ran, what you expected, and what happened. Include the distro and
version you targeted, your VirtualBox version, and your PowerShell version
(`$PSVersionTable.PSVersion`). If provisioning got partway and stopped, the VM's state
in the VirtualBox GUI and anything on the guest console are usually what identify it.
Kickstart failures in particular tend to be silent from the host side.
