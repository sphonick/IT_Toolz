# IT_Toolz — project context

**Repo:** `git@github.com:sphonick/IT_Toolz.git` · https://github.com/sphonick/IT_Toolz

This file is loaded automatically by Claude Code. It exists so that a fresh
session — including one started on a *target* Windows workstation rather than
the Linux dev box — can pick up the current work without re-deriving it.

If you are a new session: read this, then
`windows/WindowsUpdateGuard/DEBUG-STATE.md` for where the investigation
actually stands.

---

## Who you are working with

Linux/UNIX background, strong on low-level Windows internals but *not* on
Windows tooling conventions. Assume fluency with registry concepts, services,
ACLs and process forensics. Do **not** assume familiarity with Task Scheduler
syntax, PowerShell idiom, Group Policy's two-layer config model, or cmd.exe
parsing rules — those are the parts worth explaining, and analogies to
cron/systemd/journalctl/strace land well.

Prefers batch (`.cmd`) over PowerShell for anything that has to run
unattended on a workstation. Wants the *cause*, not just a workaround, but
also wants the machines patching today.

---

## Active work: WindowsUpdateGuard

**Problem - SOLVED 2026-09-06.** Windows 11 workstations re-paused Windows
Update on every boot ("Updates paused until \<future date\>"). Regedit hunting
and reviewing installed programs had both come up empty.

**Root cause.** A scheduled task `\PauseWindowsUpdate` at the **root task
path**, registered by `Specialize.ps1` from the machine's **unattended-install
answer file** (`C:\Windows\Setup\Scripts\`, dated 2025-06-16 = the image build
date). BootTrigger repeating every 24h, running as LOCAL SERVICE, writing a
rolling 7-day pause window that re-stamps forward and therefore never expires.
A sibling `\MoveActiveHours` slid Active Hours every 4h so installs never ran.
The file set is the signature output of Christoph Schneegans' unattend
generator. Not malware, not an upgrade artifact - baked into the image.

None of the *predicted* causes applied: no `Registry.pol`, no GPO, no MDM, no
debloat utility, services all healthy, not metered. **The original hypothesis
ranking in this file was wrong; unattend leftovers are now check #0 in both
tools.**

Evidence preserved in `windows/WindowsUpdateGuard/Scripts/` (read
`Scripts/README.md`); full timeline and the remaining checklist live in
`windows/WindowsUpdateGuard/DEBUG-STATE.md`. Read those before re-deriving
anything.

**Two detection bugs the real-world output exposed, now fixed in `wuguard.cmd`:**

- The non-Microsoft-task search keyed on `pauseupdate`, which is not a
  substring of `PauseWindowsUpdate` - it printed "(none found)" while the
  culprit sat right there. Now matches on the task *name* against
  update/pause/defer/wsus/wuau.
- "Disabled update-related scheduled tasks" grepped the whole CSV line for
  `Disabled`, which matches half a dozen other columns, so it listed Ready
  tasks as disabled. Now parses column 4 specifically. That bug is the only
  reason the culprit got printed at all - it was luck, not detection.

**Deliverables** (`windows/WindowsUpdateGuard/`):

| File | Purpose |
|------|---------|
| `wuguard.cmd` | The fix. Pure batch. `install` / `uninstall` / `repair [/gpo]` / `audit` / `status` |
| `Find-UpdateBlocker.ps1` | Read-only forensics; `-EnableAuditing` sets a SACL so event 4657 names the culprit process |
| `RUNBOOK.txt` | Step-by-step for use on-site, plain text, Notepad-friendly |
| `DEBUG-STATE.md` | Living record of what has been checked on which machine |
| `README.md` | Full docs incl. a Linux→Windows cheat sheet |
| `Scripts/` | **Evidence.** Verbatim capture of `C:\Windows\Setup\Scripts\` from the affected box. Read `Scripts/README.md`; do not run anything in there |
| `wu-audit.txt` | The real `wuguard.cmd audit` output that cracked it (UTF-16LE, from `Tee-Object`) |

**Design decisions that should not be quietly reversed:**

- WSUS (`WUServer`/`UseWUServer`) and MDM policy are **reported, never
  removed**. In a managed fleet those are usually deliberate; stripping them
  locally either breaks patching or is re-pushed within the hour.
- Clearing the local GPO cache is **opt-in** behind `/gpo`, and backs up
  `Registry.pol` first.
- The scheduled task runs as SYSTEM with a **2-minute boot delay** — firing at
  T+0 risks losing the race against whatever does the pausing — plus a 4-hour
  repeat as a backstop.
- `wuguard.cmd` has **no PowerShell dependency** (except a cosmetic log tail in
  `status`), so it still works on a box where PS is locked down or broken.

---

## Status / confidence

- `wuguard.cmd audit` has now been **run for real** on one Windows 11 box and
  produced correct output. `repair`, `install` and `Find-UpdateBlocker.ps1` are
  still **unexecuted** - do not describe those as tested.
- Known-fixed cmd.exe traps, worth not regressing:
  - **No literal `!` in log message strings** — `EnableDelayedExpansion` eats
    them. Warning prefix is `**`, not `!!`.
  - `:log` writes as `>>"%LOG%" 2>nul echo …` with the redirect *first*,
    because `echo msg>>file` misparses a trailing digit as a stream redirect.
  - findstr: avoid a trailing `\` immediately before the closing quote in
    `/c:"…"`; single backslashes are literal, not escapes.
  - Install path is deliberately space-free (`C:\ProgramData\IT_Toolz\…`) so
    `schtasks /TR` needs no embedded-quote gymnastics.
  - Batch `find`/`findstr` cannot read `Registry.pol` — it is UTF-16. That
    check lives in the PowerShell script only.

## Conventions

- `.gitattributes` forces CRLF on `.cmd` / `.bat` / `.ps1` / `.txt`.
- Each tool is a self-contained directory with its own README and no
  dependencies beyond what ships with the OS.
