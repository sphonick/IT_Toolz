# WindowsUpdateGuard

Something on these Windows 11 boxes re-pauses Windows Update on every boot
("Updates paused until <date in the future>"), and it survives the obvious
regedit fixes. This tool does two things:

1. **`wuguard.cmd`** — clears the pause/defer state and re-enables the update
   plumbing, and installs itself as a scheduled task so it runs a few minutes
   after every boot and every 4 hours thereafter.
2. **`Find-UpdateBlocker.ps1`** — read-only forensics to find *why* it keeps
   happening, so you can eventually stop papering over it.

---

## Quick start

Copy the folder to the workstation, open an **elevated** `cmd`, and:

```bat
wuguard.cmd install
```

That copies the script to `%ProgramData%\IT_Toolz\WindowsUpdateGuard\`,
registers the scheduled task, and runs the repair once immediately.

Other actions:

```bat
wuguard.cmd repair        :: apply the fix now
wuguard.cmd repair /gpo   :: also wipe the local Group Policy cache (see below)
wuguard.cmd audit         :: read-only dump of everything holding updates back
wuguard.cmd status        :: task state + current pause state + last log lines
wuguard.cmd uninstall     :: remove the scheduled task
```

Log: `%ProgramData%\IT_Toolz\WindowsUpdateGuard\wuguard.log`

The script self-elevates if you double-click it, so `install` works from
Explorer too.

---

## What `repair` actually does

| Area | Action |
|------|--------|
| `HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings` | Deletes `Pause*` / `Paused*` values — this is the "paused until" window the Settings app shows |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` | Deletes `Defer*`, `Pause*`, `TargetReleaseVersion`, `BranchReadinessLevel`, `SetDisableUXWUAccess`, … |
| `…\WindowsUpdate\AU` | Deletes `NoAutoUpdate` / `AUOptions` so the default (fully automatic) applies |
| Services | Restores start types: `wuauserv`, `UsoSvc`, `WaaSMedicSvc`, `BITS`, `DoSvc`, `cryptsvc`, `TrustedInstaller` |
| Scheduled tasks | Re-enables everything under `\Microsoft\Windows\UpdateOrchestrator\`, `\WindowsUpdate\`, `\InstallService\`, `\WaaSMedic\` |
| Scan | `sc start wuauserv` + `UsoClient StartScan` |

It **reports but never silently removes** WSUS redirection (`WUServer` /
`UseWUServer`) or MDM/Intune policy, because in a managed environment those
are usually intentional and removing them locally either breaks patching or
gets re-pushed within the hour.

---

## The scheduled task (this is Windows' cron)

There is no crontab. The equivalent is **Task Scheduler**, driven from the CLI
by `schtasks.exe`. The install step creates:

```
Name     \IT_Toolz\WindowsUpdateGuard
Trigger  At system startup, delayed 2 minutes, repeating every 240 minutes
Run as   SYSTEM, highest privileges
Action   cmd /c "%ProgramData%\IT_Toolz\WindowsUpdateGuard\wuguard.cmd" repair
```

The raw command, if you'd rather do it by hand:

```bat
schtasks /Create /TN "\IT_Toolz\WindowsUpdateGuard" ^
  /TR "cmd.exe /c C:\ProgramData\IT_Toolz\WindowsUpdateGuard\wuguard.cmd repair" ^
  /SC ONSTART /DELAY 0002:00 /RI 240 /DU 9999:59 ^
  /RU "SYSTEM" /RL HIGHEST /F
```

(The install path is deliberately space-free, which keeps `/TR` quoting sane —
`schtasks` handles embedded quotes badly.)

Inspect or remove it with:

```bat
schtasks /Query  /TN "\IT_Toolz\WindowsUpdateGuard" /V /FO LIST
schtasks /Run    /TN "\IT_Toolz\WindowsUpdateGuard"
schtasks /Delete /TN "\IT_Toolz\WindowsUpdateGuard" /F
```

The **2-minute delay matters**. Run at T+0 and you may lose a race against
whatever re-pauses updates; the repeating trigger is the backstop for that.
If the log shows the pause reappearing between runs, tighten `/RI`.

### Why `RU SYSTEM`

`SYSTEM` is the closest thing to root. It runs with no user logged in, needs
no stored password, and has write access to `HKLM` policy keys. `/RL HIGHEST`
skips the UAC prompt that would otherwise block an unattended run.

---

## Finding the actual culprit

Papering over it every 4 hours works, but it's worth 10 minutes to find the
source. Run elevated:

```
powershell -ExecutionPolicy Bypass -File .\Find-UpdateBlocker.ps1
```

It checks, in order of how often each turns out to be the cause:

**1. Local Group Policy cache** — `C:\Windows\System32\GroupPolicy\Machine\Registry.pol`.
This is the #1 reason a registry fix "doesn't stick": Group Policy re-applies
this file at boot and every ~90 minutes, overwriting whatever you set by hand.
There is no uninstaller and nothing shows up in Add/Remove Programs. If the
script flags it, fix it properly in `gpedit.msc` → Computer Configuration →
Administrative Templates → Windows Components → Windows Update → set the
offending policies to **Not Configured**. Or blow the cache away with
`wuguard.cmd repair /gpo` (it backs the file up first).

**2. MDM / Intune** — `HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Update`.
Fix at the MDM console; local edits get re-synced away.

**3. A "debloat" utility** — O&O ShutUp10, Windows Update Blocker, WinUtil,
Sophia Script, W10Privacy, StopUpdates10 and friends. Several of these install
their own scheduled task or service to re-apply settings at boot. The script
looks for them by name in the uninstall registry, on disk, in Run keys,
startup folders, services, and third-party scheduled tasks.

**4. Catch it in the act.** If nothing above is conclusive:

```
powershell -ExecutionPolicy Bypass -File .\Find-UpdateBlocker.ps1 -EnableAuditing
```

That enables `auditpol` registry success auditing and puts a SACL on the two
update keys. Reboot, let it re-pause, then re-run the script without the flag —
section 7 reads **Security event 4657** and names the process that wrote the
value. This is the definitive answer and it's how you avoid a reinstall.

If `Set-Acl` fails there (it needs `SeSecurityPrivilege`), set the audit rule
by hand: `regedit` → right-click the key → Permissions → Advanced → Auditing →
Add → Everyone → Set Value + Create Subkey + Delete → Success.

Other things worth ruling out that aren't software at all:

- **Metered connection.** Ethernet or Wi-Fi marked metered makes Windows hold
  updates back. Settings → Network → adapter → Metered connection.
- **Low disk space** on `C:` — under ~20 GB free, feature updates defer
  themselves and the UI wording looks a lot like a manual pause.
- **`TargetReleaseVersion`** pinning the box to an older build; it reads as
  "up to date" while never moving forward.

---

## Coming from Linux

| Linux | Windows |
|-------|---------|
| `cron` / `systemd.timer` | Task Scheduler (`schtasks.exe`, `taskschd.msc`) |
| `@reboot` crontab entry | `schtasks /SC ONSTART` |
| `/etc/rc.local` | a startup-triggered task |
| `systemctl enable/start/status` | `sc config` / `sc start` / `sc query` |
| `systemctl set-property` start type | `sc config <svc> start= auto\|demand\|disabled` |
| `/etc/sysctl.conf`, `/etc/*` config | the registry (`reg query` / `reg add` / `reg delete`) |
| `journalctl` | Event Viewer (`eventvwr.msc`), `Get-WinEvent` |
| `ps aux` / `lsof` | `tasklist`, `Get-Process`, Sysinternals `handle` |
| `strace` on a mystery writer | Sysinternals **Process Monitor**, or registry SACL auditing |
| `apt-mark hold` | the update deferral policies above |
| running as `root` | running as `SYSTEM` (`/RU SYSTEM`) |

Two Windows-specific gotchas worth internalising:

- **Config has two layers.** The registry is the live value, but Group Policy
  and MDM are *sources of truth* that get re-stamped onto the registry on a
  schedule. Editing the registry when a policy owns the key is like editing a
  file that Ansible re-templates every 90 minutes. Always check for the policy
  layer first.
- **`schtasks` is not `cron`.** Tasks carry an identity, a run level, battery
  and network conditions, and a "start when available" catch-up flag. A task
  that silently never runs is usually blocked by one of those conditions, not
  by the trigger. `schtasks /Query /V /FO LIST` shows the last run result.

If you prefer PowerShell to batch, the same task is:

```powershell
$a = New-ScheduledTaskAction -Execute 'cmd.exe' `
     -Argument '/c "C:\ProgramData\IT_Toolz\WindowsUpdateGuard\wuguard.cmd" repair'
$t = New-ScheduledTaskTrigger -AtStartup
$t.Delay = 'PT2M'
$p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName 'WindowsUpdateGuard' -TaskPath '\IT_Toolz\' `
    -Action $a -Trigger $t -Principal $p -Settings $s -Force
```
