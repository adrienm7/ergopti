---
name: windows-toolchain
description: Apply this Windows checkout's safe shell, Git, encoding, and Node practices. Use before scripting or committing.
---

# Working the toolchain on this box

Every trap below cost real time or real damage in this repo. None of them
announce themselves.

## Commit messages go through a file, always

```bash
git commit -F <path-to-message-file>
```

A PowerShell here-string (`@'…'@`) passed to `git commit -m` **splits mid-message**
and git then reads the remaining words as pathspecs — you get
`error: pathspec 'the' did not match any file(s)` and no commit. Write the message
to a scratch file and use `-F`. It also survives em-dashes and non-ASCII, which
the `-m` path mangles.

The commit-msg hook rejects plan-item references (`REFACTOR_PLAN`, `P11.1`, …).
Keep the rationale, drop the token.

## `Get-Content` decodes as ANSI, and that corrupts files

**This is the one that did real damage.** Windows PowerShell 5.1's `Get-Content`
defaults to the system codepage, not UTF-8. Read a UTF-8 file with it and every
non-ASCII character comes back as mojibake (`—` → `â€"`); write that back and the
corruption is now committed.

- Reading: `Get-Content -Raw -Encoding UTF8`, or read it in Node, which is UTF-8
  by default.
- Writing: `[System.IO.File]::WriteAllText($p, $s, [System.Text.UTF8Encoding]::new($false))`
  — the `$false` means "no BOM". Pass `$true` when the file needs one (all `.ahk`
  files do; see the `ahk-driver` skill).
- `Set-Content` / `Add-Content` default to ANSI too. `>` and `>>` usually emit
  UTF-8 **with BOM**, which is wrong for everything except `.ahk`.

After any scripted rewrite, check before committing:

```bash
grep -c 'â€' <file>     # must be 0
file <file>             # line terminators must be consistent, not "CRLF, CR, LF"
```

## Line endings: the working copy is CRLF, git stores LF

Git converts on checkout, so `git` warning *"LF will be replaced by CRLF"* on add
is normal and not a problem. What **is** a problem is producing a file with mixed
terminators — an `awk`/`sed` pass over a CRLF file emits LF and leaves you with
both. Normalise to `\n` while editing and restore the file's original ending on
write.

A related regex trap, and it fails silently: **in a JS regex `.` does not cross
`\r`**, so `^\[([^\]]+)\].*$` matches nothing on a CRLF line. Strip `\r` before
matching or your script quietly skips every line it was written for.

## Node cannot spawn `npm` without a shell

`npm` is a `.cmd` shim, and Node 20+ refuses to spawn one without `shell: true`
(the CVE-2024-27980 hardening). Without it `spawnSync` reports **status `null`**,
which reads as "the gate failed" when the gate never ran. Treat a null status as
its own outcome — a false red costs as much trust as a false green.

## Missing POSIX tools, and what to use instead

| Not available | Use |
|---|---|
| `grep -P` | `grep -E`, or the Grep tool |
| `python3` / `python` | Node, or `tools/format_toml.py` via the `python` the CI uses |
| `rg` | the Grep tool (the shell wrapper falls back noisily) |
| `sleep` in the foreground | a background command with an `until` loop |

`awk` and `sed` are available (Git Bash). Prefer the Read/Edit/Grep tools over
shell text-mangling on tracked files — they preserve encoding.

## Staging: name the paths

`git add -A` sweeps whatever else the working tree happens to hold, and the JS
gate regenerates `_generated/` artefacts as a side effect of running. Stage the
files you actually changed, by name.

`git commit --amend` after `git rm`/`git mv` pulls those staged operations into
the amended commit, which is how an unrelated deletion ends up inside a fix.
Check `git status --short` before amending.

## Proving a test fails before the fix

The `ship-fix` rule "must fail before, pass after" in practice:

```bash
git stash push -- <only the source files, not the test>
AutoHotkey64.exe tests/run_all.ahk --only "<slug from the test name>"   # expect exit 1
git stash pop
```

Stash the **source**, never the test — stashing both proves nothing.

## Where the driver actually lives at runtime

`<ConfigDir>` is **not** the default folder: it is redirected by
`%APPDATA%\Ergopti\paths.toml`. On the maintainer's box that resolves to
`D:\Documents\GitHub\config\ergopti_plus\`, so the logs are at
`…\config\ergopti_plus\autohotkey\logs\`. Looking in the repo for them finds
nothing and invites the wrong conclusion. The log filename carries the date the
**driver started**, not the date of the entries — always read the timestamp on
the line.

AutoHotkey v2 is at `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`.

## `/validate` never validates — it runs the script

Do not use it, in any shell, in any position. On v2.0.26 the flag is ignored
wherever it sits, so the file is parsed and, if it parses, **executed**. Two
independent mechanisms get you there, so guarding against one is not enough:

- **Git Bash** rewrites `/ErrorStdOut` and `/validate` into Windows paths
  (`C:/Program Files/Git/validate`) — MSYS argument conversion — so AHK receives
  two bogus script arguments and runs the file. This applies to **every** `/flag`
  passed to a Windows exe from Git Bash, `Ahk2Exe`'s `/in` `/out` included.
- **PowerShell** passes the flags correctly and the script still runs.

This entry claimed the opposite until 2026-07-29 ("validates when it precedes the
path"), and that reading came from measuring against a file that already had a
syntax error — which exits 2 immediately and is indistinguishable from a working
validator. **Test a validator against VALID input too**, or you cannot tell
validation from execution. An audit trusted the old note and launched 58 `ui/`
files as live scripts.

Two ways that do work:

```powershell
# 1. Ahk2Exe — the reference, identical to CI. exit 0 = parsed, exit 17 = syntax error.
& "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" /in ErgoptiPlus.ahk /out "$env:TEMP\probe.exe"

# 2. Parse-only harness for a file outside the entry's include graph: AHK parses the
#    whole merged script before executing anything, so ExitApp(0) first is safe.
#    "ExitApp(0)`n#Include <file>" -> probe.ahk, then run probe.ahk with /ErrorStdOut.
```

Before and after either, assert the only running `AutoHotkey64.exe` is the
driver: `Get-CimInstance Win32_Process | ? { $_.Name -eq 'AutoHotkey64.exe' }`.
Never point anything at `ErgoptiPlus.ahk` while the driver is running.
