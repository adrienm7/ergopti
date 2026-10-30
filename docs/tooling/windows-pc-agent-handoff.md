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

## What the cloud cannot do and needs from you

AutoHotkey does not run in the cloud containers, so the work above is covered
only by static and JS tests. Once it lands on `dev`:

1. Run the full AHK suite and fix what fails.
2. Run `collect-windows-field-report.ps1` and the runtime layer of
   `test-windows-field-report-contract.cjs` with `pwsh`.
3. Push the field report so the coordinator can read it.
