# Known Bugs

## [Severity: High] Shell injection via GuestUsername in kickstart sudoers line
- **File:** New-FedoraVirtualBoxVM.ps1:629, 631, 704
- **Issue:** `$GuestUsername` is interpolated directly into shell/sudoers commands in the kickstart `%post`; unvalidated input lets an attacker run arbitrary shell during install.
- **Repro:** `.\New-FedoraVirtualBoxVM.ps1 -GuestUsername 'user; whoami #' -Force` — kickstart runs the injected command as root.
- **Fix:** Add `[ValidatePattern('^[a-zA-Z0-9._-]+$')]` to `$GuestUsername` (and `$GuestPassword`).

## [Severity: High] Shell injection via SharedFolderName in mount command
- **File:** New-FedoraVirtualBoxVM.ps1:651
- **Issue:** `$SharedFolderName` is embedded unquoted into `/bin/mount -t vboxsf $SharedFolderName /mnt/shared`, allowing injection via spaces or `;`.
- **Repro:** `.\New-FedoraVirtualBoxVM.ps1 -SharedFolder "C:\Users\test" -SharedFolderName 'shared; id #' -Force`.
- **Fix:** Validate with `[ValidatePattern('^[a-zA-Z0-9._-]+$')]` and/or quote the value in the mount string.

## [Severity: Medium] Guest password printed in plaintext at completion
- **File:** New-FedoraVirtualBoxVM.ps1:1505
- **Issue:** Final summary writes `Password: $GuestPassword` to the console; session transcripts, terminal recordings, and screen-shares capture it.
- **Repro:** Run the script to completion — password is visible in the summary block.
- **Fix:** Mask the password (`***`) and reference a secure note, or read the password as `SecureString` up front.
