# Debug state — Windows Update re-pausing itself

**Repo:** https://github.com/sphonick/IT_Toolz

Living record of the investigation. **Fill this in on-site and push it** —
that is what lets a later session (or a session running *on* one of the
affected machines) continue instead of starting over.

---

## The symptom

Windows 11 workstations re-pause Windows Update on every boot. Settings shows
"Updates paused until \<date in the future\>". Registry edits do not stick.
Nothing obvious in installed programs.

## Ruled out so far

| Checked | Result | By whom / when |
|---------|--------|----------------|
| regedit spelunking | Values come back after reboot | user, before 2026-09-06 |
| Installed-programs review | Nothing obvious found | user, before 2026-09-06 |

## Not yet checked

- [ ] `C:\Windows\System32\GroupPolicy\Machine\Registry.pol` — **check first**
- [ ] Domain GPO (`gpresult /h gp.html`) if the box is domain-joined
- [ ] MDM/Intune: `HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Update`
- [ ] Debloat utilities + their scheduled-task/Run-key persistence
- [ ] Deny ACEs on the update service keys
- [ ] Metered connection flag on the adapter
- [ ] Free space on `C:` (feature updates self-defer under ~20 GB)
- [ ] `TargetReleaseVersion` build pinning
- [ ] Registry SACL auditing → Security event 4657 (the definitive answer)

---

## Per-machine findings

Copy this block per workstation. `wuguard.cmd audit` and
`Find-UpdateBlocker.ps1` produce everything needed to fill it.

```
### Hostname:
Date checked:
Windows build:                      (winver, or audit header)
Domain-joined:                      yes / no — domain:
Paused until:                       (UX\Settings PauseUpdatesExpiryTime)

Registry.pol present:               yes / no
  ...contains WindowsUpdate policy: yes / no
MDM policy present:                 yes / no
Blocker tool found:                 name / none
Services at Start=4 (disabled):
Disabled update tasks:
Deny ACEs found:
Metered adapter:                    yes / no
Free space on C::
TargetReleaseVersion:

Action taken:                       audit only / repair / repair /gpo / install
Held after reboot:                  yes / no
Notes:
```

---

## Outcome

Once the cause is confirmed on one machine, record it here — including
whether it was fleet-wide. If it turns out to be a single fixable source
(one GPO, one utility), **the boot task is a workaround and should come back
out**: `wuguard.cmd uninstall` on each box.

**Root cause:** _(not yet determined)_

**Fleet-wide fix:** _(TBD)_

**Boot task still needed:** _(TBD)_
