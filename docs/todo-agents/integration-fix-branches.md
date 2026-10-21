<!-- docs/todo-agents/integration-fix-branches.md -->

# Integration of the Codex fix branches (fix/linux, fix/macos, fix/windows)

## Done (on `tmp/integrate-*`, not on dev)

Every Codex commit of the three branches is on one linear branch on top of `origin/dev`, rebased or
cherry-picked, nothing squashed, no merge commit. This agent never pushes `dev` or `main`: dev is
fast-forwarded from the branch only by the maintainer or on the maintainer's own instruction.

- `fix/linux`: 3 of 3 commits, applied without conflict.
- `fix/macos`: 12 of 12 commits. Two conflicted, both with dev's own fix of the same defect
  (`ac1ad9be6a`):
  - "preserve typing history after transient SQLite errors": `sqlite_reader.lua` keeps dev's code
    (identical completeness flag). `projection.lua` keeps dev's build-aside structure and adds
    Codex's intent: an incomplete extension leaves the accepted entry and watermark in place, and
    `session.range` returns the history receipt that the dashboard uses to refuse saving or
    publishing a partial read.
  - "retire typing history before cancellable merges": `projection.lua` keeps dev's code (the
    accepted entry is never mutated nor retired). The retirement tests are kept and now assert that
    contract (accepted entry stays admitted, unmutated, never double counted). The fixture matches
    the reader frame with either path separator (it never matched on Windows).
- `fix/windows`: 113 of 113 commits, applied without textual conflict.
- Follow-up fixes found by hosted CI, one commit each:
  - `fix(ci): re-read a run census whose job list moved between pages`: the site verdict refused
    healthy dispatched all-lanes runs because the jobs listing grows between page reads.
  - `test(windows): pair each WebView2 Close with its own subscriptions`: the teardown-order guard
    flagged the personal info editor once Codex's last commit closed a local controller earlier in
    the file.
  - `fix(windows): refuse remote completions whose bytes are not UTF-8`: Codex's exposing test
    `test_managed_response_utf8.ahk` had no fix yet (quota stop); the facade now judges raw bytes
    and the remote consumer refuses an invalid managed body.
- No commit was skipped as a duplicate: `git cherry` marked all 128 as new, and the two semantic
  duplicates above were kept with their tests adapted.

## Remaining, with next steps

1. Fast-forward dev to the branch tip (maintainer): `git fetch github` then check
   `git merge-base --is-ancestor github/dev github/tmp/integrate-final`, then push that tip to dev.
   If dev moved, rebase first: `git rebase --onto github/dev <old dev base> tmp/integrate-final`.
2. Verify nothing is left: `git cherry github/dev github/fix/linux`, `git cherry github/dev
github/fix/macos`, `git cherry github/dev github/fix/windows`. Lines starting with `+` are
   commits not yet on dev; after the cherry-picks above they print `+` too until dev contains the
   branch (patch ids of the two adapted macOS commits differ by design).
3. Linux flake to watch: `Linux / Install and launch / Arch Linux` and `openSUSE: installed archive`
   failed once (run 39610248703) in "retires shortcut overrides before persisting the chosen normal
   profile" (Codex's `tests/support/ui/menu/llm/manual_profile_selection.lua` on dev's
   `numeric_configuration_fixture.lua`): the runner's parent `storage.json` appeared during the
   test with exactly the global-scope natives (`locale`, `script.log_level`,
   `script.show_error_dialog`). The same code passed in run 39607861912. Suspect a module loaded by
   an earlier test that kept the parent `adapters.storage` instance (`infra.script_settings`
   captures it at load; `infra.i18n` caches it lazily). If it recurs, unload those owners in the
   fixture alongside `adapters.storage`, and prove it with an earlier test that loads them first.

## Validation

- Cheap local gates green on the tip: module matrix, AHK encoding, suite manifest, test coverage,
  v2 antipatterns, e2e manifest, parse coverage, startup contract, warning gate, not-executed,
  conventions lint, format check, teardown-order guard, macOS tests of every touched module (27
  files, run locally with the luv shim).
- Not validated locally: Linux suite (no Linux LuaJIT on this host), full AHK suite (90 min),
  `npm run test:js` in full. Hosted CI runs are listed in the final report of this integration.

## Open risks

- The macOS dashboard now refuses (instead of showing) a history whose SQLite reads were
  incomplete, which is Codex's design; dev had chosen "shown but not cached". Revisit if users
  should see partial counts during a transient SQLite error.
- Codex's last Windows commit (`retain personal editor source consent`) and its UTF-8 exposing test
  said native AFTER replays were still pending; they now run only as part of the AHK suite.
