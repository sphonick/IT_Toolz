# Debug state — Windows Update re-pausing itself

**Repo:** https://github.com/sphonick/IT_Toolz
**Status: ROOT CAUSE FOUND AND FIXED — 2026-09-06**

---

## Root cause

A scheduled task named **`\PauseWindowsUpdate`**, registered at the *root*
task path, installed by the machine's **unattended-install answer file**.

- Trigger: `BootTrigger` with `<Repetition><Interval>P1D</Interval>` — fires at
  every boot **and** every 24 hours.
- Runs as `S-1-5-19` (LOCAL SERVICE), `LeastPrivilege`.
- Action: pipes `C:\Windows\Setup\Scripts\PauseWindowsUpdate.ps1` into
  `Invoke-Expression`, which writes a **rolling 7-day pause window** into
  `HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings` — start = now,
  end = now + 7 days.

Because the window is re-stamped forward on every run, it can never expire.
That is precisely the reported symptom: "postponed to some date in the future",
forever.

A second task, **`\MoveActiveHours`** (BootTrigger, repeating every 4 hours),
ran `MoveActiveHours.vbs` to slide Active Hours to a rolling
`(hour+23)..(hour+11)` window, so the machine was almost always inside active
hours and would not install or reboot on its own.

Both were registered by `Specialize.ps1` during Windows Setup's specialize
pass. Files dated 2025-06-16 (image build date). The whole file set is the
signature output of Christoph Schneegans' unattend generator
(schneegans.de/windows/unattend-generator/).

**The user's guess that it was a Win10→11 upgrade artifact was close but not
right** — it came from the unattended *install*, not an upgrade.

### Why the earlier manual hunt failed

- Not in Add/Remove Programs — it was never an installed program.
- Not in the registry as a *policy* — no `Registry.pol`, no GPO, no MDM. The
  audit confirmed `Policies\...\WindowsUpdate` absent entirely.
- The task sat at the **root task path**, not in a vendor folder, and was named
  plausibly enough to scroll past.
- Deleting the registry values worked — until the next boot.

### Confirming evidence from the audit

| | |
|---|---|
| `\PauseWindowsUpdate` last run | `9/6/2026 2:24:39 PM` local |
| `PauseUpdatesStartTime` written | `2026-09-07T00:24:45Z` |
| Audit captured at | `9/6/2026 2:32:09 PM` local |

Local time is UTC−10, so `00:24:45Z` = `14:24:45` local — six seconds after the
task started, and 7½ minutes before the audit ran. The task was caught
mid-cycle.

## Fix applied

User located the files from the `wuguard.cmd audit` output and removed them.
Confirmed working.

Evidence preserved verbatim in `Scripts/` — see `Scripts/README.md`.

## Still worth doing

- [ ] Confirm the **scheduled tasks themselves** are deleted, not just the
      script files. Deleting `C:\Windows\Setup\Scripts\*` leaves the tasks
      registered; they will run and fail on every boot forever.
      `schtasks /Query /TN "\PauseWindowsUpdate"` — should report not found.
      Same for `\MoveActiveHours`.
- [ ] `wuguard.cmd repair` once, to clear the final 7-day window the task left
      behind (it would otherwise sit until 2026-09-14).
- [ ] Reset Active Hours **by hand** in Settings > Windows Update > Advanced.
      `repair` deliberately does not touch `ActiveHoursStart/End` or
      `SmartActiveHoursState` — they are comfort settings, not blockers, and
      the correct default value for `SmartActiveHoursState` is not something
      to guess at from a script.
- [ ] Reboot and confirm `wuguard.cmd status` shows no pause values.
- [ ] **Apply to the other workstations** — same image, same problem. Check
      `dir C:\Windows\Setup\Scripts` on each.
- [ ] Decide on the other image customizations — SmartScreen off, Defender
      systray hidden, `PreventDeviceEncryption=1`, and the removed components
      (Windows Terminal, RDP client, Windows Hello Face, OpenSSH client).
      These are a real reduction in security posture and persist independently.
      Listed in `Scripts/README.md`.
- [ ] Once all machines are clean, `wuguard.cmd uninstall` — the boot task was
      a workaround and is no longer needed. Keep it through one reboot cycle
      first as a safety net.
- [ ] Find out where the install media came from, or the next re-image
      reintroduces all of this.

---

## Per-machine findings

Copy this block per workstation.

```
### Hostname:
Date checked:
C:\Windows\Setup\Scripts present:   yes / no
  file dates:
\PauseWindowsUpdate task:           present / removed / never there
\MoveActiveHours task:              present / removed / never there
Paused until (before fix):
Tasks deleted:                      yes / no
repair run:                         yes / no
Held after reboot:                  yes / no
Notes:
```

### MSSEMPLOYEE
```
Date checked:                       2026-09-06
C:\Windows\Setup\Scripts present:   yes — dated 2025-06-16
                                    (FirstLogon.log 2025-11-30)
\PauseWindowsUpdate task:           present, last run 14:24:39 local
\MoveActiveHours task:              present
Paused until (before fix):          2026-09-14T00:24:45Z (rolling)
Registry.pol:                       absent
MDM:                                absent
Services:                           all healthy (wuauserv 3, UsoSvc 2)
Metered:                            no (Ethernet/WiFi = 1)
Files removed:                      yes — issue resolved
Tasks deleted:                      TBD — verify
```
