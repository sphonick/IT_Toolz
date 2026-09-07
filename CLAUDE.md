# IT_Toolz — project context

**Repo:** `git@github.com:sphonick/IT_Toolz.git` · https://github.com/sphonick/IT_Toolz

This file is loaded automatically by Claude Code. It carries the context a
fresh session needs — including one started on a target Windows workstation
rather than the Linux dev box.

---

## Who you are working with

Linux/UNIX background. Strong on low-level Windows internals (registry,
services, ACLs, process forensics) but not on Windows *tooling* conventions —
Task Scheduler syntax, PowerShell idiom, Group Policy's two-layer config model
and cmd.exe parsing rules are the parts worth explaining. Analogies to
cron/systemd/journalctl/strace land well.

Prefers batch (`.cmd`) over PowerShell for anything that must run unattended on
a workstation. Wants the root cause, not only a workaround — but also wants the
machines working today. Deliver both.

Inherited a small fleet of Windows 11 workstations around August 2026. No
domain, no GPO, no MDM — the machines were hand-imaged by a previous admin and
then left alone.

---

## windows/WindowsUpdateGuard — CLOSED

Workstations re-paused Windows Update on every boot. **Root cause found and
removed 2026-09-06:** a `\PauseWindowsUpdate` scheduled task at the root task
path, left by an unattended-install answer file
([cschneegans/unattend-generator](https://github.com/cschneegans/unattend-generator)),
writing a rolling 7-day pause window that re-stamped forward at every boot and
so could never expire.

**Read [`windows/WindowsUpdateGuard/POSTMORTEM.md`](windows/WindowsUpdateGuard/POSTMORTEM.md)
before re-deriving anything.** It is self-contained and covers the mechanism,
why the manual hunt failed, attribution (and the confident-but-wrong "Chris
Titus WinUtil" search result), provenance, the image settings that outlive the
fix, and the remaining loose ends.

The captured evidence was deleted when the case closed. It is still in git
history at commit `d5503fa` — `git show d5503fa --stat`.

### Status of the tools

- **Never installed on any machine.** Only `wuguard.cmd audit` was ever run,
  as a diagnostic; it is what surfaced the culprit. `repair`, `install`,
  `uninstall` and `Find-UpdateBlocker.ps1` are **unexecuted** — do not describe
  them as tested.
- Kept for reuse. Do not delete on tidy-up.

### Design decisions that should not be quietly reversed

- WSUS (`WUServer`/`UseWUServer`) and MDM policy are **reported, never
  removed**. In a managed fleet those are usually deliberate.
- Clearing the local GPO cache is **opt-in** behind `/gpo`, and backs up
  `Registry.pol` first.
- The scheduled task runs as SYSTEM with a **2-minute boot delay** — firing at
  T+0 risks losing the race against whatever does the pausing — plus a 4-hour
  repeat as a backstop.
- `wuguard.cmd` has **no PowerShell dependency** (except a cosmetic log tail in
  `status`), so it works on a box where PS is locked down or broken.

### cmd.exe traps already fixed — do not regress

- **No literal `!` in log message strings** — `EnableDelayedExpansion` eats
  them. Warning prefix is `**`, not `!!`.
- `:log` writes as `>>"%LOG%" 2>nul echo …` with the redirect *first*, because
  `echo msg>>file` misparses a trailing digit as a stream redirect.
- findstr: avoid a trailing `\` immediately before the closing quote in
  `/c:"…"`; single backslashes are literal, not escapes.
- Install path is deliberately space-free (`C:\ProgramData\IT_Toolz\…`) so
  `schtasks /TR` needs no embedded-quote gymnastics.
- Batch `find`/`findstr` cannot read `Registry.pol` — it is UTF-16. That check
  lives in the PowerShell script only.
- Scanner matching: match on structured fields, not whole-line greps. Two bugs
  here (`pauseupdate` not being a substring of `PauseWindowsUpdate`; grepping a
  whole CSV row for `Disabled`) meant the tool printed "(none found)" while the
  culprit sat right there. See the POSTMORTEM takeaway.

## Conventions

- `.gitattributes` forces CRLF on `.cmd` / `.bat` / `.ps1` / `.txt`. When
  copying to a USB stick from this Linux checkout, confirm the working tree
  actually has CRLF (`git ls-files --eol`) — cmd.exe mis-parses multi-line
  blocks in LF-only files.
- Each tool is a self-contained directory with its own README and no
  dependencies beyond what ships with the OS.
