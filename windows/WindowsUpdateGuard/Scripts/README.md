# EVIDENCE — do not run anything in this directory

Captured from **`C:\Windows\Setup\Scripts\`** on host `MSSEMPLOYEE`, 2026-09-06.
Kept verbatim as the proof of root cause. `PauseWindowsUpdate.ps1` is the file
that caused the original problem — it is here to be read, not executed.

## What this is

Output of an **unattended-install answer file** (`unattend.xml`). The file set —
`Specialize.ps1`, `DefaultUser.ps1`, `FirstLogon.ps1`, `UserOnce.ps1`,
`RemovePackages/Capabilities/Features.ps1`, `SetStartPins.ps1`,
`MoveActiveHours.vbs` — is the signature output of Christoph Schneegans'
unattend generator (schneegans.de/windows/unattend-generator/). Windows Setup
drops these into `C:\Windows\Setup\Scripts\` and runs `Specialize.ps1` during
the specialize pass.

So this was baked into the **image at install time**. It is not malware, not a
user-installed utility, and not an upgrade artifact — which is exactly why
regedit spelunking and reviewing installed programs both came up empty.

## The mechanism

`Specialize.ps1` registers two scheduled tasks at the **root** task path:

```powershell
Register-ScheduledTask -TaskName 'PauseWindowsUpdate' -Xml (Get-Content ...PauseWindowsUpdate.xml -Raw)
Register-ScheduledTask -TaskName 'MoveActiveHours'    -Xml (Get-Content ...MoveActiveHours.xml -Raw)
```

`PauseWindowsUpdate.xml` — `BootTrigger` with `<Repetition><Interval>P1D</Interval>`,
running as `S-1-5-19` (LOCAL SERVICE), which pipes `PauseWindowsUpdate.ps1`
into `Invoke-Expression`. That script writes a **rolling 7-day pause window**:

```powershell
$start = now (UTC);  $end = now + 7 days
PauseFeatureUpdatesStartTime / EndTime
PauseQualityUpdatesStartTime / EndTime
PauseUpdatesStartTime / PauseUpdatesExpiryTime
```

At every boot *and* every 24 hours it re-stamps "paused until now + 7 days".
The window can therefore never expire. That is the whole bug.

`MoveActiveHours.xml` — `BootTrigger` repeating every 4 hours, runs
`MoveActiveHours.vbs`, which sets `ActiveHoursStart = (hour+23) mod 24` and
`ActiveHoursEnd = (hour+11) mod 24` — a rolling 12-hour "active hours" window
that follows the clock, so Windows is nearly always inside it and will not
install or reboot on its own.

## Persistent settings it also applied

These live in the registry and survive deleting these files. Worth an explicit
decision rather than leaving them by default:

| Setting | Effect |
|---|---|
| `SmartScreenEnabled = "Off"` | SmartScreen disabled |
| `WTDS\Components\ServiceEnabled = 0` + all `Notify*` = 0 | Defender SmartScreen notifications off |
| `Windows Defender Security Center\Systray\HideSystray = 1` | Security tray icon hidden |
| `BitLocker\PreventDeviceEncryption = 1` | Automatic device encryption blocked |
| `WindowsUpdate\AU\AUOptions = 4` | (absent as of the audit) |
| `WindowsUpdate\AU\NoAutoRebootWithLoggedOnUsers = 1` | (absent as of the audit) |
| `CloudContent\DisableWindowsConsumerFeatures = 1` | consumer app push off |
| `Dsh\AllowNewsAndInterests = 0` | widgets off |

Also removed at install time: Windows Terminal, WordPad, Paint, OpenSSH client,
PowerShell ISE, Quick Assist, Steps Recorder, MathRecognizer, handwriting and
speech, **Windows Hello Face**, Remote Desktop Connection, Media Playback,
PowerShell v2, Recall, and a long list of Store apps (see
`RemovePackages.ps1` / `RemoveCapabilities.ps1` / `RemoveFeatures.ps1`).

The Defender/SmartScreen/BitLocker items are a real reduction in security
posture and the missing RDP client may matter operationally.

## Cleanup checklist

Deleting `C:\Windows\Setup\Scripts\*` stops the scripts, but the **registered
tasks remain** and will run (and fail) forever. Full cleanup:

```bat
schtasks /Delete /TN "\PauseWindowsUpdate" /F
schtasks /Delete /TN "\MoveActiveHours" /F
rmdir /s /q C:\Windows\Setup\Scripts
wuguard.cmd repair
```

`repair` clears the last pause window it left behind, which would otherwise sit
there until it expires. It does **not** touch Active Hours — reset those by hand
in Settings > Windows Update > Advanced options.
