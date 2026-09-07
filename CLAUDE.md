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

**Problem.** Several Windows 11 workstations re-pause Windows Update on every
boot — the Settings app shows "Updates paused until \<future date\>". The user
already tried regedit and hunting for installed programs; the state comes
back. No reinstall wanted.

**Working hypothesis, in order of likelihood:**

1. **Local Group Policy** — `C:\Windows\System32\GroupPolicy\Machine\Registry.pol`
   re-stamps the registry at boot and every ~90 min. This is the single most
   likely explanation for "I deleted the key and it came back", and it has no
   uninstaller and no visible process.
2. MDM/Intune via `HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Update`.
3. A debloat utility (O&O ShutUp10, Windows Update Blocker, StopUpdates10,
   WinUtil, Sophia Script, W10Privacy…) with its own boot persistence.
4. Non-software causes: metered connection, low disk on C:,
   `TargetReleaseVersion` pinning.

**Deliverables** (`windows/WindowsUpdateGuard/`):

| File | Purpose |
|------|---------|
| `wuguard.cmd` | The fix. Pure batch. `install` / `uninstall` / `repair [/gpo]` / `audit` / `status` |
| `Find-UpdateBlocker.ps1` | Read-only forensics; `-EnableAuditing` sets a SACL so event 4657 names the culprit process |
| `RUNBOOK.txt` | Step-by-step for use on-site, plain text, Notepad-friendly |
| `DEBUG-STATE.md` | Living record of what has been checked on which machine |
| `README.md` | Full docs incl. a Linux→Windows cheat sheet |

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

- Scripts are **statically reviewed on Linux, never executed on Windows.**
  Do not describe them as tested. First on-site action is `wuguard.cmd audit`,
  which is read-only.
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
