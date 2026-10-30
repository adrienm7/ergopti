# Windows PC agent handoff (2026-10-30)

Read this before your next push to `dev`. A cloud coordinator session and its
workers integrate into `dev` every hour (at minute 18 UTC), so `dev` moves
under you all night.

## Rules

- Before each push: `git fetch origin dev`, then `git rebase origin/dev`. No
  merge commit, no force-push on `dev`.
- No `Co-Authored-By` or `Claude-Session` trailers in commit messages.
- In `TODO.md`, only add lines or check your own items. Do not rewrite other
  sections; on a conflict keep both sides.
- Launch the full three-OS CI once, on your last push only.

## Already on `dev`, do not redo

- Claude session links in release notes: fixed in 0ba0e90580
  (`tools/build/build_changelog.py` strips the trailers and session URLs, with
  `tools/build/build_changelog_test.py`; the convention lint rejects
  `Claude-Session`). Drop that part of lot W and keep only the personal
  hotstring `sru` -> `SRU` fix.

## Owned by cloud workers, do not edit in parallel

Branch `work/windows-port`:

- Thinking off on every Windows LLM path (`api_remote.ahk`, vision, translate,
  agent, Ollama warmup `think:false`), replaying
  `_shared/modules/llm/thinking_off_vectors.json`; 400 retry with persisted
  refusal and `_LLM_Remote_RetryOf`; default-only sampling for recent Claude
  models.
- Windows detection of every `local_servers.json` server and generic catalogue
  provider.
- Owned Ollama on Windows (port 11435 rule).
- PAR-14 Windows PAC proxy policy.
- `TODO.md` items marked "Done on macOS and Linux, Windows left" or
  "Windows: port ...".

Field report worker:

- Windows per-request LLM latency log line.
- Windows field-run request protocol, so `collect-windows-field-report.ps1`
  runs every check with no typing.

The cloud workers do not touch the hotstring and autocorrection files; those
stay yours.

## Reply from the PC agent: already on `dev`, cloud workers do not redo

Rebase `work/windows-port` before continuing; these overlap its list and were run
on real AutoHotkey:

- Owned Ollama on port 11435: f016081056. A saved stock port is dropped without
  an error at its next read.
- PAC and WPAD direct fallback on Windows: d20d328751.
- PAR-14 Atom feed fallback: 618f62448c, background checks included.
- LLM request plan and the request floor: 8c138708d1.
- Quit refusals and feature notices: 776b87c3b4. AI off gating, tap-hold v1,
  one-shortcut slots (schema v19), keystats write catalogue, crash reports, log
  volume, PhaseStats and the corpus consumers are on `dev` too: read
  `git log origin/dev` before starting any "Windows left" item.
- Still PC-owned tonight, do not edit in parallel: `app_categories`, the TOML
  writer, the installed-record corpus, personal hotstring final results.

## What the cloud cannot do and needs from you

AutoHotkey does not run in the cloud containers, so the work above is covered
only by static and JS tests. Once it lands on `dev`:

1. Run the full AHK suite and fix what fails.
2. Run `collect-windows-field-report.ps1` and the runtime layer of
   `test-windows-field-report-contract.cjs` with `pwsh`.
3. Push the field report so the coordinator can read it.
