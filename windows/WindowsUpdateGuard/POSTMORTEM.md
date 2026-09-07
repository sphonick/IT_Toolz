# Post-mortem: Windows 11 workstations re-pausing Windows Update

**Status: CLOSED — 2026-09-06.** Root cause found and removed.

Written to stand alone. The captured evidence files were deleted once the case
closed; every excerpt needed to understand or re-recognise this is quoted below.
The originals remain retrievable from git history:

```bash
git show d5503fa --stat                                    # the evidence commit
git show d5503fa:windows/WindowsUpdateGuard/Scripts/PauseWindowsUpdate.ps1
git show d5503fa:windows/WindowsUpdateGuard/wu-audit.txt   # UTF-16LE
```

---

## Symptom

Several Windows 11 workstations showed "Updates paused until \<date roughly a
week out\>" after every boot. Deleting the pause values in `regedit` worked
until the next restart. Nothing relevant in Add/Remove Programs. The machines
were being patched by hand as a workaround.

## Root cause

A scheduled task named **`\PauseWindowsUpdate`**, at the **root task path** —
not under `\Microsoft\` — installed by the machine's **unattended-install
answer file**.

```xml
<BootTrigger>
  <Repetition>
    <Interval>P1D</Interval>
    <StopAtDurationEnd>false</StopAtDurationEnd>
  </Repetition>
</BootTrigger>
<Principal><UserId>S-1-5-19</UserId><RunLevel>LeastPrivilege</RunLevel></Principal>
<Exec>
  <Command>C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe</Command>
  <Arguments>-Command "Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\PauseWindowsUpdate.ps1' -Raw | Invoke-Expression;"</Arguments>
</Exec>
```

Boot trigger **plus** a 24-hour repetition, running as `S-1-5-19` (LOCAL
SERVICE). The script it executes:

```powershell
$now   = [datetime]::UtcNow;
$start = $now.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ssK");
$end   = $now.AddDays(7).ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ssK");

$params = @{
    LiteralPath = 'Registry::HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings';
    Type = 'String'; Force = $true;
};
Set-ItemProperty @params -Name 'PauseFeatureUpdatesStartTime' -Value $start;
Set-ItemProperty @params -Name 'PauseFeatureUpdatesEndTime'   -Value $end;
Set-ItemProperty @params -Name 'PauseQualityUpdatesStartTime' -Value $start;
Set-ItemProperty @params -Name 'PauseQualityUpdatesEndTime'   -Value $end;
Set-ItemProperty @params -Name 'PauseUpdatesStartTime'        -Value $start;
Set-ItemProperty @params -Name 'PauseUpdatesExpiryTime'       -Value $end;
```

**A rolling seven-day pause window, re-stamped forward at every boot and every
24 hours. It can therefore never expire.** That is the entire bug.

### The second half of the trick

A sibling task **`\MoveActiveHours`** — boot trigger, repeating every 4 hours —
ran a VBScript that slid Active Hours to follow the clock:

```vbscript
current = Hour(Now)
reg.SetDWORDValue HKLM, key, "ActiveHoursStart",       ( current + 23 ) Mod 24
reg.SetDWORDValue HKLM, key, "ActiveHoursEnd",         ( current + 11 ) Mod 24
reg.SetDWORDValue HKLM, key, "SmartActiveHoursState",  2
```

A 12-hour window that moves with the current hour, so the machine is almost
always "inside active hours" and will not install or reboot on its own. Even
with the pause cleared, this alone would have kept updates from landing.

Both were registered during Windows Setup's specialize pass:

```powershell
Register-ScheduledTask -TaskName 'PauseWindowsUpdate' -Xml (Get-Content ...\PauseWindowsUpdate.xml -Raw);
Register-ScheduledTask -TaskName 'MoveActiveHours'   -Xml (Get-Content ...\MoveActiveHours.xml   -Raw);
```

## Why the manual hunt failed

- **Never an installed program**, so nothing in Add/Remove Programs.
- **Not a policy.** No `Registry.pol`, no GPO, no MDM — the audit confirmed
  `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` absent entirely.
  Every standard "why won't my registry edit stick" answer was a dead end.
- **Root task path.** Not in a vendor folder, and plausibly enough named to
  scroll straight past in Task Scheduler.
- **Nothing appears to be running.** The registry edit *does* work — until the
  next boot. There is no live process to catch, which is what makes a rolling
  window so well hidden: it never looks like anything is acting, just like
  Windows made a choice.

## How it was found

`wuguard.cmd audit` dumped every scheduled task matching update keywords, which
printed the full CSV row for `\PauseWindowsUpdate` including its command line
pointing at `C:\Windows\Setup\Scripts\PauseWindowsUpdate.ps1`. The rest fell out
from reading that directory.

Confirming timeline from the audit — the task was caught mid-cycle:

| Event | Time |
|---|---|
| `\PauseWindowsUpdate` last run | `14:24:39` local |
| `PauseUpdatesStartTime` written | `2026-09-07T00:24:45Z` = `14:24:45` local (UTC−10) |
| Audit captured | `14:32:09` local |

Six seconds after the task fired, seven minutes before anyone looked.

## Attribution

The file set — `Specialize.ps1`, `DefaultUser.ps1`, `FirstLogon.ps1`,
`UserOnce.ps1`, `SetStartPins.ps1`, `RemovePackages/Capabilities/Features.ps1`,
`PauseWindowsUpdate.ps1/.xml`, `MoveActiveHours.vbs/.xml` — is the output of
**[cschneegans/unattend-generator](https://github.com/cschneegans/unattend-generator)**
(https://schneegans.de/windows/unattend-generator/). `PauseWindowsUpdate.xml`
and `MoveActiveHours` are named resources in that project.

> **A web search on these filenames confidently returns "Chris Titus Tech's
> WinUtil". That is wrong.** It matches on what the scripts *do* (near-identical
> debloat effects) rather than how they got there. WinUtil is a post-install
> interactive tool with no concept of `C:\Windows\Setup\Scripts`. The
> discriminator is the mechanism: that directory is populated from an answer
> file and executed by Windows Setup, and the filenames map 1:1 onto the
> generator's documented execution phases — including the asymmetry where
> `UserOnce.ps1` alone logs to `%TEMP%` while every sibling logs to
> `Setup\Scripts`.

## Provenance

Built by the **previous IT admin** as a debloated Windows 11 image. Fleet
inherited around August 2026. Files dated 2025-06-16 (the image build);
`FirstLogon.log` alone dated 2025-11-30, consistent with the image being built
once and deployed to this machine months later.

Clean install, not a Win10→11 upgrade: the content targets Windows 11
specifically (removes Recall, DevHome, Outlook for Windows, MSTeams; uses the
Win11-only Start pins policy; sets `TurnOffWindowsCopilot`). `FirstLogon.ps1`
did contain `rmdir C:\Windows.old` — an upgrade-oriented option — but the log
records it failing with "The system cannot find the file specified".

**Assessed as legitimate but badly configured for business workstations, not
malicious.** No Defender exclusions, no network callouts, no credential
handling, no concealment; Defender's actual AV engine untouched (only
SmartScreen, the reputation layer, was disabled); tasks registered under their
real names with source and logs sitting in plain sight.

## Settings the image applied that OUTLIVE the fix

These are registry state and persist regardless of the scripts being deleted.
Each is a decision now inherited, not a bug:

| Setting | Effect |
|---|---|
| `Explorer\SmartScreenEnabled = "Off"` | SmartScreen disabled |
| `WTDS\Components\ServiceEnabled = 0` + all `Notify*` = 0 | SmartScreen notifications off |
| `Defender Security Center\Systray\HideSystray = 1` | security tray icon hidden |
| `BitLocker\PreventDeviceEncryption = 1` | automatic device encryption blocked |
| `net accounts /maxpwage:UNLIMITED` | passwords never expire |
| `CloudContent\DisableWindowsConsumerFeatures = 1` | consumer app push off |
| `Dsh\AllowNewsAndInterests = 0` | widgets off |
| per-user: `TurnOffWindowsCopilot`, Edge SmartScreen off, GameDVR off, ContentDeliveryManager suggestions off | |

The combination of **SmartScreen off *and* the security systray hidden** is the
one worth a deliberate decision — protection is reduced *and* the channel that
would tell a user is gone.

Also removed at install: Windows Terminal, WordPad, Paint, **Remote Desktop
Connection**, **OpenSSH Client**, PowerShell ISE, Quick Assist, Steps Recorder,
**Windows Hello Face**, MathRecognizer, handwriting/speech, Media Playback,
PowerShell v2, Recall, and a long list of Store apps.

## Remediation applied

The unattend scripts and both scheduled tasks were removed by hand. Issue
resolved. `wuguard.cmd` was **never installed** on any machine — only its
`audit` action was ever run, as a diagnostic.

For reference, the full cleanup is:

```bat
schtasks /Delete /TN "\PauseWindowsUpdate" /F
schtasks /Delete /TN "\MoveActiveHours" /F
rmdir /s /q C:\Windows\Setup\Scripts
```

Deleting the script files alone is **not** enough — the tasks stay registered
and keep running, and failing, on every boot.

## Verification

Confirmed fixed. Scripts and both scheduled tasks removed, the residual pause
window cleared by hand, and automatic updates observed working **across
multiple reboots** — which is the test that matters here, since the task
carried a 24-hour repetition on top of its boot trigger. A single clean boot
would not have proven anything.

## Remaining, for whoever reads this next

- **Active Hours now matter.** With `\MoveActiveHours` gone, Windows can reboot
  unattended again — that behaviour was previously suppressed. Set them
  deliberately per machine (Settings > Windows Update > Advanced options).
- **Feature updates can restore stripped components.** If removed apps or
  features reappear after a build upgrade, that is normal Windows behaviour,
  not the unattend scripts returning.
- **The install media still exists somewhere.** This is the only way the problem
  comes back: whoever re-images the next machine reproduces all of it,
  including the settings listed above that outlive the fix.
  `C:\Windows\Panther\unattend.xml` — the cached copy of the answer file
  actually used — lists every option that was selected, and is the right
  starting point for regenerating corrected media.
- **Any workstation not yet checked**: `dir C:\Windows\Setup\Scripts` and
  `schtasks /Query /TN "\PauseWindowsUpdate"`.

## Takeaway for the tooling

Two bugs in `wuguard.cmd` surfaced only against real output, both since fixed:

- The non-Microsoft task scan keyed on the substring `pauseupdate`, which does
  not occur in `PauseWindowsUpdate`. It reported **"(none found)"** while the
  culprit sat one section above.
- The "disabled tasks" section grepped the whole `schtasks /FO CSV /V` line for
  `Disabled`, which matches several unrelated columns. That bug is the only
  reason the culprit was printed at all — it was luck, not detection.

A scan that says "(none found)" is worse than no scan: it actively argues you
are looking in the wrong place. Match on structured fields, not whole lines,
and check what a scanner *reported* against what was actually *there*.
