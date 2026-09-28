<!-- docs/handovers/2026-09-28-ergoptiplus/README.md -->

# Cloneable overhaul handoff

Start with [the ordered TODO](../../ERGOPTIPLUS_TODO.md), `AGENTS.md`, then
the relevant repository skills and routed memory. Continue on `dev`.
Do not recreate the old worktrees named in historical specifications.

`PRODUCT_SPECIFICATION.txt` preserves the full original task specification.
Later user decisions recorded below override historical workflow paths and
obsolete task-status claims. `ORIGINAL_MISSION.txt` preserves the initial
delivery authorization and constraints. Neither file is a completion report.
Read only the task section needed for the next checklist item; the specification
also contains repeated historical lane instructions. Later product decisions
override those historical instructions.

## Subsequent user decisions

- Integrate directly on `dev`; preserve atomic history and do not fetch or
  merge additional upstream work unless the user changes that constraint.
- Complex configuration, cleanup and error interfaces use a shared WebView,
  bounded height and scrolling; simple prompts may remain native.
- Unused configuration is actionable cleanup, not a runtime error.
- Translate new interfaces in all 21 languages.
- Window titles must contain the product prefix once on all three OSes.
- Layout emulation sections remain independent: base/Shift, AltGr/ShiftAltGr,
  and number row. Test Ergo-L AltGr-only on an AZERTY Windows base.
- Configured action labels replace the configurable placeholder with the
  configured value; valid gesture action parameters must survive cleanup.
- Consolidate useful work into the real repository and retire temporary
  branches/worktrees after their contents are accounted for.
- Preserve quota for a clean, published handoff. Update the linear TODO after
  each completed step; then advance as far as possible.

## Unapplied proposals

Files under `pending/` are proposals, **not installed features**. Every patch
has path-specific SHA-256 before/after values. Compare every current source
hash with its `before` value and inspect the patch before applying it. Use
`git apply --check <patch>` and exact-path staging; never use a reset or stash
to force an old proposal onto a changed source.

| Proposal | Status and prerequisite | Recorded targeted verification |
| --- | --- | --- |
| `hotstrings-repeat.patch` | Linux sparse repeat preference; independent | 41/41; old code fails 11 cases |
| `hotstrings-engine.patch` | Shared engine detached catalogue publication | 59/59 on LuaJIT and Lua 5.4; five new cases fail before fix |
| `hotstrings-catalogue.patch` | Linux catalogue publication; apply after engine | 53/53 on both runtimes; five causal failures |
| `mac-remap-sparse.patch` | macOS neutral remap persistence; after integrated owned-field preservation | 8/8 targeted, 47/47 broader; four causal failures |

These proofs are recorded from private overlays, not whole-repository release
gates. Integrate each coherently and rerun the gates selected by `verify-change`.
The lane handoffs describe mutation evidence and outstanding limitations.
Paths mentioning `D:/ewt/_scratch` in those immutable notes are historical;
their useful pending patches and design fragments are included here.

## Retired worktree recovery

`original-commits/` preserves eleven exact original commits from the named
branches. `branch-final-audit.md` distinguishes adapted integrations from the
two missing L4 foundations and the dependency update still needing review.

`retired-worktrees/` additionally preserves material found in retired checkouts:

- `actions-D4-staged.patch`: unintegrated model-label changes in 21 locales,
  the macOS formatter and tests. Rebase and verify before applying.
- `diag-integration-unstaged.patch`: unintegrated macOS extension boot loading
  and a Windows historical-binding test. Depends on the preserved L4 commits;
  its old boot snippet conflicts conceptually with newer initialization owners.
- `windows-master-state-unstaged.patch`: historical prerequisite changes,
  substantially superseded but not fully proven equivalent. Do not apply this
  old manifest/generated-output patch wholesale.
- `dev-before.patch`: the original checkout's keyboard-scope changes before
  consolidation. Current canonical keyboard work supersedes this checkpoint;
  retain it as provenance, not a fresh implementation request.
- `actions-D4-history.bundle`: the exact detached D4 history, under 500 KB.
  Its prerequisite `f4d0bfd633ab7af50044199917e1e3db4241d8be` is an ancestor of
  `dev`. `git bundle verify <file>` verifies recoverability without changing
  branches. Its commits have identified counterparts; do not blindly import or
  reapply the entire history.

The retired-worktree audit records the remaining uncertainty and the ignored
fixture/generated files that need not be copied to GitHub. These small recovery
artifacts preserve useful unfinished work; the old 632 MB workspace snapshot is
not needed to read this TODO or resume the identified implementation tasks.

## Incomplete design material

`drafts/` contains **untested, unassembled sketches**, deliberately stored with
`.lua.txt` suffixes. They are not production modules or ready patches. Read
the macOS and Linux final handoffs before reusing any fragment. Missing APIs,
false-value Lua expression bugs and delay recommendation conflicts are called
out there. Never count the complete Hotstrings scope as implemented.

## Verification and environment cautions

- Run JS generation/drift checks separately from driver readers. On the
  maintainer's Windows machine some live generated files are mapped and cannot
  be overwritten. A byte-identical test export can prove generation, but report
  that distinction and retain the full input/hash inventory.
- Never set the main repository's `GIT_DIR` globally for a test suite: fixture
  tests create, commit and reset private Git repositories.
- Isolate `TMPDIR`, `HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME` and
  `XDG_STATE_HOME` for Linux tests. One earlier replay used only private TMPDIR
  and may have written the WSL user's common test settings; no safe preimage
  existed. Do not blindly delete or restore that configuration.
- The macOS Lua and Linux compatibility suites on Windows are software proofs.
  They do not establish physical keyboard, native WebView, desktop-manager or
  Karabiner behavior on real target hardware.
- Do not use AutoHotkey `/validate`: it executes the script. Protect the live
  driver and its UI Automation worker. Use the repository test launchers.

`ARTIFACTS.json` records hashes of the preserved source material. The checklist
and final checkpoint own current state; copied lane notes remain historical.
