<!-- docs/audits/hammerspoon/2026_09_07/handoff/TODO.md -->

# Hammerspoon: implementation and test-maintenance TODO

This is the mutable checklist requested for handoff to the next implementing
model. Developer documentation and identifiers intentionally remain in English.
The immutable evidence snapshot is [report.md](report.md); machine-readable
findings are in [findings.json](findings.json).

Validate this same-day handoff with:

```powershell
node docs/audits/hammerspoon/2026_09_07/handoff/validate-handoff.cjs
```

The standard audit CLI cannot select a second report within one date. Do not
overwrite the original dated report to satisfy its path restriction. See the
snapshot's validation note. IDs HS-267 through HS-273 follow the original
same-day report's HS-254 through HS-266 rather than reusing old identifiers.

**Do not equate the length of this list with an exhaustive bug count.** Seven
bugs are confirmed at the audited commit. Test-maintenance tasks and coverage
gaps are separately labelled and must not be advertised as extra bugs.

## 1. Start here: repository state and ownership

- Audited source: `44e0a8e57659994eb3af293440f44d03d66960a8`.
- Main checkout: `D:/Documents/GitHub/ergopti`, branch `dev`.
- Existing implementation worktree: `D:/Documents/GitHub/ergopti-fix-hs`, branch
  `fix/hammerspoon-audit-2026-09-07`. Resume it; do not replace or clean it.
- Documentation worktree: `D:/Documents/GitHub/ergopti-hs-audit-handoff-2026-09-07`,
  branch `audit/hs-handoff-2026-09-07`. It owns this handoff, not driver changes.
- Another agent owns the Windows worktree. Preserve its changes and commits.
- Main originally had a pre-existing uncommitted file:
  `static/ergopti_plus/windows/modules/keylogger/keylogger_reader_cache.ahk`.
  Its initially preserved SHA256 was
  `D06A506CA9E0AFC6EAA3A505599C2A984CF8C20E4980CBB33A62D1D6685C2AB0`.
- At final documentation integration preflight, main was clean and that file's
  SHA256 was `FD248BF5D68743E98CBC4D0A8AEF2E926AAE680C6CEE45FA0F150D7F1FF09AA3`.
  This changed outside the HS/documentation worktrees. Preserve the newly
  observed state; do not restore an old version based on this historical note.
- No push is authorized. Preserve individual commits; never squash without a
  new explicit instruction. Rebase on current `dev`, then integrate with a
  fast-forward only when the implementation is verified.

### H-00 — reconcile the existing candidate before new work

- [ ] Read `git status`, the current branch and `git worktree list` in both
  main and HS. Do not trust the old SHA after another agent has worked.
- [ ] Inspect the existing HS-273 candidate rather than implementing it twice.
- [ ] Confirm the only expected candidate paths are:
  - `static/ergopti_plus/macos/ui/menu/hotstring_counter.lua`;
  - `static/ergopti_plus/macos/tests/unit/ui/menu/test_hotstring_counter_metadata_boundaries.lua`.
- [ ] Preserve any additional user/agent edits. Never stash/reset/clean them.
- [ ] Read the relevant skills: `ship-fix`, `hammerspoon-driver`,
  `verify-change`, `commit-and-push`, `windows-toolchain`; use `logger` when
  changing diagnostics and `cross-driver-parity` for shared code.

The candidate was implemented before the user switched to audit-only work.
Its six new cases failed on old code and passed on the candidate. The existing
gate process finished with exit 0: **9,198 tests / 1,009 modules**, plus the
selected HS-E2E gate. It was deliberately left **uncommitted** after the pivot.
There is no gate process that the next model needs to wait for.

Recovery artifacts, not instructions to overwrite current files:

- [Production diff](evidence/pending-metadata-counter.patch).
- [Candidate regression module](evidence/pending-test-hotstring-counter-metadata-boundaries.lua).
- Private execution log on this machine:
  `D:/Documents/GitHub/ergopti/.git/worktrees/ergopti-fix-hs/wave26-gates.log`.

The documentation integration may move `dev` ahead of the HS branch. Commit
the reviewed candidate first, then rebase a clean HS worktree; do not attempt
a rebase over dirty source or apply the recovery patch twice.

## 2. Execution protocol for every finding

Use one fix and its causal regression tests per atomic commit. A separate
behavior-preserving refactor should have a separate commit. Check an item only
after recording the commit and verification; writing code is not completion.

- [ ] Reproduce against the current source, using the supplied probe as a lead.
- [ ] Turn the observation into a behavioral test asserting the desired result.
- [ ] Demonstrate red on a safe old source snapshot or an explicit mutation.
- [ ] Check siblings of the same root cause before choosing the scope.
- [ ] Implement the smallest complete correction, not an output-only workaround.
- [ ] Run the focused module alone and alongside neighboring owner tests.
- [ ] Run `node tools/test/find-false-greens.cjs`; never raise its baseline.
- [ ] Run `node tools/test/verify-change.cjs --plan`, then its selected gates.
- [ ] Run strict conventions; inspect any generated artifacts or unrelated edits.
- [ ] Stage exact owned paths; use an English Conventional Commit message file.
- [ ] Record commit, test counts, exit codes and native verification limits here.
- [ ] Rebase current `dev`, inspect intervening paths, revalidate affected scope,
  and perform the requested fast-forward integration without push.

Use the project RTK launcher for terminal output. Invoke commands directly if
stdout feeds a file, parser, hash, generator or test assertion. On this machine
Node 22.16 is below the project's supported floor; use the available supported
Node 22.22.2 runtime or another verified supported version. Git hooks need Git
Bash on PATH, not the WindowsApps WSL shim.

Run a focused module from `static/ergopti_plus/macos`, for example:

```powershell
../../../tools/rtk/rtk.ps1 lua tests/run.lua --only tests.unit.ui.menu.test_hotstring_counter_whitespace
```

Do not use `verify-change --help` as a harmless planning query: use `--plan`.
Do not use AutoHotkey `/validate`; it can execute the live script.

### Evidence probes are not ready-made regression tests

The files in `evidence/` intentionally **assert the old wrong behavior** so a
successful probe means the bug was reproduced. After a fix they should fail.
Do not copy their final assertions unchanged into the production test suite.
Each probe must run in a separate Lua process because some use process-local
module replacements. Convert them into properly isolated test modules.

From the macOS driver directory:

```powershell
lua ../../../docs/audits/hammerspoon/2026_09_07/handoff/evidence/probe-app-picker-out-of-order.lua
lua ../../../docs/audits/hammerspoon/2026_09_07/handoff/evidence/probe-app-picker-partial-cache.lua
lua ../../../docs/audits/hammerspoon/2026_09_07/handoff/evidence/probe-counter-repeated-sections.lua
lua ../../../docs/audits/hammerspoon/2026_09_07/handoff/evidence/probe-counter-parser-siblings.lua
lua ../../../docs/audits/hammerspoon/2026_09_07/handoff/evidence/probe-counter-trailing-metadata.lua
```

All five were replayed against the audited commit. Native OS boundaries are
virtual; the relevant controller, reader, registry or builder is real.

## 3. Confirmed bugs: priority and dependency order

| ID | Priority | Surface | State at handoff |
| --- | --- | --- | --- |
| HS-273 | Finish existing candidate | Metadata boundaries | Implemented/tested locally, not committed |
| HS-267 | P1 | Application-picker request ownership | Proven, not implemented |
| HS-268 | P1 | Partial application discovery cache | Proven, not implemented |
| HS-271 | P2, parser design first | Entry versus section-property semantics | Proven, not implemented |
| HS-269 | P2 | Repeated-section detail aggregation | Proven, not implemented |
| HS-270 | P2 | Initial BOM handling | Proven, not implemented |
| HS-272 | P2, coordinate shared behavior | Escaped manifest names | Proven, not implemented |

P1/P2 are execution priorities within this handoff, not severity inflation.
No critical or high-severity defect was established in this final pass.
HS-271 may motivate a shared parsing API: decide that design before building
several more independent regular-expression parsers.

### HS-267 — stale application discovery replaces the newest picker

- [ ] Reproduce and implement.
- [ ] Add all ownership regressions below.
- [ ] Verify, commit and integrate. Commit: `________________`.

**Severity:** medium. **Confidence:** high. **Guarantee:** G3.

**Owner:** `static/ergopti_plus/macos/infra/app_picker.lua`,
`build_menu()` Add action and its `discover_apps()` continuation.
Relevant real callers include `ui/menu/menu_metrics.lua` and
`ui/menu/menu_llm/trigger_panel.lua`. Search for `AppPicker.build_menu` and the
corresponding imported alias rather than relying on old line numbers.

**Reproduction:** with a cold discovery cache, open picker A for one settings
list, then picker B for another list. Complete discovery B, then discovery A.
The old A completion calls `delete_active_chooser()`, destroys B's chooser and
creates a panel carrying A's old `on_change`. Choosing from it invokes A.

**Observed:** `older scan A deletes newer chooser B and sends selection to
obsolete A settings callback`. This is not merely a duplicated visual panel:
the destination settings callback is wrong for the newest intent.

**Root cause:** `_active_chooser` tracks a native object only after discovery.
It does not identify the user's latest request while discovery is pending.
The native selection callback also continues into `on_change` even when its
chooser is no longer the active one. No exception exposes these stale actions.

**Implementation recipe:**

1. Allocate a monotonically increasing request token or identity object at the
   Add action, before starting discovery. Define one owner for that authority.
2. Recheck it before retiring an old chooser, constructing/publishing a new
   chooser and presenting it. Cache-warm completion may be synchronous.
3. Capture both request identity and native chooser identity in selection.
   A stale or already-settled callback must not call the settings callback.
4. Retire logical authority before external deletion or logging can reenter.
   Retain cleanup debt if native deletion fails; do not let a stale owner
   delete or unpublish its successor.
5. Apply a selection at most once. Cancellation retires the exact owner.
6. Add bounded DEBUG diagnostics for request supersession and stale callback
   rejection; do not log selected private application paths unnecessarily.

**Required tests:**

- [ ] A then B, completion B then A: only B presents and applies.
- [ ] A then B, completion A then B: after B becomes latest, A cannot present.
- [ ] Warm-cache synchronous completion obeys the same ownership protocol.
- [ ] Callback queued from a retired chooser changes no settings.
- [ ] Duplicate callback applies at most once; cancellation applies nothing.
- [ ] Native cleanup exception leaves owned cleanup debt without harming B.
- [ ] Reentrant presentation/logging cannot publish an obsolete candidate.

**Pitfall:** adding a check only inside selection does not stop A from deleting
B's current UI. Adding a check only before `show()` is likewise too late.

### HS-268 — failed discovery publishes an authoritative partial cache

- [ ] Define absence/error outcomes and implement publication rules.
- [ ] Cover recovery and cache semantics.
- [ ] Verify, commit and integrate. Commit: `________________`.

**Severity:** medium. **Confidence:** high. **Guarantees:** G2, G5.

**Owner:** `infra/app_picker.lua`, `discover_apps()` completion and
`build_choices()` cache publication. Do not confuse this module with the
previously fixed bundled-app menu scanner in `ui/menu/menu_apps.lua`.

**Reproduction:** complete the real discovery callback with exit code 1 and
stdout `/Applications/Partial.app\n`; immediately request discovery again.
The first partial list is published and cached, no warning occurs, a completion
message is emitted, and the second request starts no process.

**Root cause:** nonempty stdout is treated as success regardless of the exit
receipt. `build_choices()` updates `_apps_cache` and `_apps_cache_at` before the
caller establishes a successful enumeration. The TTL is 60 seconds.

**Implementation recipe:**

1. Separate parsing choices from publishing a cache. Parsing partial data must
   not by itself establish authoritative success.
2. Inspect the actual ShellRunner receipt contract; require confirmed process
   success before publishing a complete discovery snapshot.
3. Handle optional `~/Applications` explicitly. It is often absent; blindly
   rejecting every nonzero combined `find` result would break normal machines.
4. Prove optional absence with the existing filesystem abstractions. Do not
   parse localized stderr or suppress a real permission/I/O failure.
5. If necessary, scan independently classified roots and combine only complete
   results. Keep subprocess ownership in the existing async adapter.
6. On failure, emit a bounded diagnostic and leave the cache retryable. Decide
   how the picker communicates failure; never present partial data as complete.
7. Treat a successful empty scan as distinct from a failed scan. Do not hide
   failures behind an empty-success return or repeated busy retries.

**Required tests:**

- [ ] Exit 1 with partial stdout does not publish a success cache.
- [ ] Interrupted/non-success process with output has the same guarantee.
- [ ] Next request after failure performs a new scan and can recover.
- [ ] Exit 0 with valid output caches; repeat request reuses exactly that result.
- [ ] Exit 0 with no applications has an explicit, truthful empty outcome.
- [ ] Optional user root absent still permits complete system discovery.
- [ ] User root inaccessible is not misclassified as absent.
- [ ] Start refusal does not double-settle `on_ready` or leave stale owners.

**Pitfall:** changing only `if exit_code ~= 0` without addressing the optional
root is an incomplete fix. Keep HS-267 request authority independent of this
cache-success protocol; they are separate causes and separate commits.

### HS-269 — repeated section declarations duplicate preview rows

- [x] Merge section details by canonical section identity.
- [x] Test real rendered menu output and preserved order.
- [x] Verify, commit and integrate. Source: `84f2755b1`; coverage: `8484ba9`.

**Severity:** low. **Confidence:** high. **Guarantee:** G5.

**Owner:** `ui/menu/hotstring_counter.lua`, `count_toml_hotstrings()`.
Consumer to verify: `ui/menu/builder.lua`, extension section detail rendering.

```toml
[[arrows]]
"a" = { output = "A" }
[[arrows]]
"b" = { output = "B" }
```

The canonical reader returns one logical section with two entries. The counter
returns two section details and total 2. The actual builder renders two disabled
`arrows (1)` rows instead of one `arrows (2)` row. No mapping loss or incorrect
grand total was demonstrated; do not overstate severity.

**Recipe:** keep an ordered section array plus a name-to-section index. On a
repeated declaration, make the existing record current rather than appending a
second record. Preserve first appearance order, metadata boundaries and cached
record identity. If HS-271 switches to canonical parsed sections, use its
canonical order and records instead of creating another merge implementation.

**Required tests:**

- [x] Two adjacent declarations: total 2, one section detail of count 2.
- [x] `arrows -> symbols -> arrows`: first-appearance order is preserved.
- [x] Metadata between repeated blocks does not become an entry.
- [x] Real builder: exactly one `arrows (2)`, no `arrows (1)` duplicates.
- [x] Repeated count uses successful cache; no extra read or duplicate records.

### HS-270 — a leading UTF-8 BOM hides loaded extensions

- [x] Reuse canonical initial-BOM handling without rewriting input globally.
- [x] Add reader/preview parity cases.
- [x] Verify, commit and integrate. Source: `84f2755b1`; coverage: `8484ba9`.

**Severity:** low. **Confidence:** high. **Guarantee:** G5.

Prefix a first `[[arrows]]` header and valid entry with bytes `EF BB BF`.
The real reader and registry load one entry; the counter returns zero,
`has_ext` is false and the pack is omitted from details.

**Owner:** `ui/menu/hotstring_counter.lua`.
**Reference:** `_shared/lua/toml_codec/reader.lua` removes the prefix only from
the first raw line using `_shared/lua/toml_codec/bom.lua`.

**Recipe:** preserve the filesystem transaction, then normalize the initial
BOM exactly once before recognizing the first header. Reuse `Bom.strip_prefix`
or the canonical parsing API chosen for HS-271. Do not globally remove those
bytes; a BOM sequence inside a quoted value or trigger is content.

**Required tests:**

- [x] Initial BOM and no-BOM versions both count the real entry.
- [x] LF and CRLF; initial BOM followed by a comment before the header.
- [x] Embedded BOM bytes in a string remain unchanged.
- [x] A genuinely empty file still counts zero.
- [x] A successful second count performs no additional read; closure remains
  mandatory and failed reads never publish cache entries.

This is compatibility with an explicitly supported runtime input, not a claim
that every arbitrary BOM placement is valid TOML.

### HS-271 — quoted section properties are mistaken for entries

- [x] Choose one canonical semantic parsing boundary.
- [x] Replace quoted-line counting with actual entry classification.
- [x] Verify transaction/cache guarantees and all parser siblings.
- [x] Verify, commit and integrate. Commit: `84f2755b1`.

**Severity:** low. **Confidence:** high. **Guarantee:** G5.

```toml
[[arrows]]
"description" = "Arrow shortcuts"
"a" = { output = "A" }
```

The real parser stores a section description and one entry; the registry loads
one mapping in the controlled probe. The counter reports two hotstrings.

**Root cause:** `line:match('^"')` is not an entry parser. Transactional reads
and correct header modes cannot make this lexical shortcut semantically true.

**Design decision before implementation:**

1. Inspect `parse_entry`, `parse_kv_value` and the parse loop in the canonical
   reader. Its distinction between a property and an entry is the authority.
2. Prefer a tested in-memory parser entry point consuming the already validated
   text. The file-reading entry point and menu should share the same semantic
   implementation, not two similar loops.
3. If extracting `parse_text` or an equivalent API is necessary, make the
   extraction behavior-preserving and separately verified before switching the
   counter. Keep filesystem/cache concerns with their existing owners.
4. Avoid parsing by temporarily replacing global `io.open` in production.
   That is a test technique, not a safe runtime adapter.
5. Avoid calling the file parser after `read_extension_file()` and rereading the
   pathname: it introduces a second snapshot and bypasses the validated read's
   identity/close guarantees.
6. Propagate semantic parse failure explicitly; never cache a plausible partial
   count as success. Distinguish valid empty content from rejected content.
7. Any `_shared` change requires the cross-driver skill and JS, HS and Linux
   gates selected by `verify-change`. Coordinate with the other OS agent.

**Required tests:**

- [x] Bare and quoted description keys do not increase the entry count.
- [x] A description-only section has zero entries.
- [x] `"description" = { output = "..." }` remains a real trigger and counts.
- [x] Quoted/escaped trigger characters are interpreted by the real parser.
- [x] Section properties after entries do not alter totals.
- [x] Invalid semantic input fails without publishing aggregate/per-file cache.
- [x] Empty, LF, CRLF and missing-final-newline cases remain covered.
- [x] Open/read/close refusal and file identity changes keep their existing
  failure and retry semantics; do not weaken transaction tests to adopt parsing.

**Do not** add a special `if key == "description" then skip` workaround. It
leaves the false classification in place and would lose a legitimate trigger.

### HS-272 — escaped quotes truncate the extension display name

- [x] Decode the actual manifest field using canonical string semantics.
- [x] Decide and coordinate the shared-scanner sibling correction.
- [x] Verify, commit and integrate. Commit:
  `fix(extensions): decode manifest metadata through the canonical parser`.

**Severity:** low. **Confidence:** high. **Guarantee:** G5.

```toml
[extension]
name = "Demo \"Quoted\" Pack"
```

Expected decoded display: `Demo "Quoted" Pack`. The counter displays only
`Demo \`. The canonical codec in the supplied probe produces the complete name.

**Owners:** `ui/menu/hotstring_counter.lua`, `read_ext_name()`;
shared sibling `_shared/lua/hotstrings/extensions.lua`, `parse_name()`.
The shared scanner uses a similar undecoded regex and is **not** a trustworthy
oracle for escaped strings, even though it was useful for whitespace tests.

**Recipe:** parse the actual `[extension].name` field with the established TOML
string decoder. Bound the field to its section so comments and unrelated keys
cannot supply a fake name. Reuse validated text, not a second file read. Preserve
the established fallback to the extension id only for a genuinely absent name;
do not silently reinterpret a malformed manifest as a successful empty one.

**Required tests:**

- [x] Plain name and whitespace variants retain their current correct result.
- [x] Escaped quote, escaped backslash and Unicode decode completely.
- [x] Comment containing `name = ...` is not a field.
- [x] A same-named field in another section does not win.
- [x] Missing name follows the documented id fallback.
- [x] Malformed/truncated string has explicit failure behavior and no success
  cache; test the chosen contract rather than swallowing parse errors.
- [x] Counter details and every changed discovery consumer agree.

Regression evidence: the focused manifest-metadata module passes 20 cases. The
initial shared/counter implementation failed 13 of the first 15 cases. Injecting
only the old counter from `80bc73163` against the corrected shared scanner fails
14 of the complete 20 cases, separating the two faulty readers. The shared scan
now decodes one manifest once for both name and localized descriptions; tests
cover escaped values, locale keys, malformed metadata, bounded privacy-safe
errors, mandatory read/close and retry without poisoned caches. The Linux entry
point has its own escaped-name/description and refusal coverage. HS e2e, 9283 HS
tests across 1014 modules and all 216 JS checks passed (exit 0). Linux under
Windows passed 2186 tests and failed 35; injecting the original shared scanner
and Linux test from `80bc73163` passed 2184 and failed the same 35. Sorted complete
failure lines are identical; the two added Linux regressions pass. This is
reproduced baseline debt, not a green native Linux gate. The generic audit
commit verifier still rejects the nested handoff manifest location before
inspecting the commit; its `Audit-Finding: HS-272` trailer and exact paths were
checked directly, and the handoff/doc-path validators pass. Native macOS/Linux
validation remains unperformed.

Consumer follow-up: Linux `ui/menu/menu_builder.lua`, extension shortcut scan,
wraps `Extensions.scan()` in `pcall` and silently returns existing rows on
failure. This predates the decoder change but now also catches malformed
metadata. Add a bounded, content-free diagnostic and a regression for failed
scan followed by recovery; do not publish a success message for omitted packs.

If correcting the shared scanner, preserve cross-driver parity and coordinate
the broader gates. Do not ship a macOS-specific decoder fork merely to avoid
those checks. Comment/section cases are required regression coverage; only the
escaped-quote truncation was independently reproduced in this final pass.

### HS-273 — metadata headers fail to end the active entry section

- [x] Reproduce original incorrect total with the real reader/registry.
- [x] Implement candidate before audit-only pivot.
- [x] Demonstrate six failures against old source and six passing regressions.
- [x] Obtain independent review and selected full gate success.
- [ ] Reconcile candidate with current source; review saved artifacts.
- [ ] Commit and integrate when implementation work resumes. Commit: `________`.

**Severity:** low. **Confidence:** high. **Guarantee:** G5.

`[[section]]` with one hotstring, followed by `[_meta.sections]` and a quoted
metadata property, yields counter 2 versus registry logical count 1.

**Candidate recipe already applied locally:** normalize each line, recognize
metadata headers before ordinary table headers, recognize canonical array and
simple hotstring table forms, and clear the active section on other `[` headers.
Restore counting only when a subsequent valid hotstring section begins.

**Six regression cases:** four metadata families, one unknown table and valid
simple tables. The metadata cases also resume in a second hotstring section.
Assertions inspect both the total and section details; the canonical reader is
reloaded under both aliases with a local nil cache provider.

This correction does **not** solve HS-271 quoted properties inside a legitimate
hotstring section, nor HS-269 repeated section aggregation. Keep those open.

## 4. Test architecture: detailed maintenance backlog

These are maintenance tasks, not automatically bugs. No redundant behavioral
test was proved safe to delete in this final pass. A large file is a navigation
problem; an independently failing assertion is still useful coverage.

### T-01 — split LLM activation tests by real transaction responsibility

- [ ] Capture the exact baseline list of 44 executed test names and results.
- [ ] Extract the local fixture with explicit ownership and guaranteed cleanup.
- [ ] Move cases into the four modules below without rewriting assertions.
- [ ] Run each module alone, combined, and in reversed order.
- [ ] Prove restoration after a deliberately raised assertion.
- [ ] Commit separately from a runtime behavior change. Commit: `________`.

Source: `tests/unit/ui/menu/menu_llm/test_llm_activation_save_gate.lua` under
the macOS driver. Detailed review found 998 lines and **44 actual
executed cases**, independently replayed green. The fixture occupies roughly
lines 12–441; line numbers are navigation aids, not stable extraction commands.

| Destination in the same test directory | Current responsibility | Cases |
| --- | --- | ---: |
| `test_llm_factory_identity_transaction.lua` | Backend/model/No Model setter receipts, compensation, reentrant construction; original 465–581 | 14 |
| `test_llm_factory_recovery_wiring.lua` | Exact recovery owners, deferred continuation, recommended profile, restored No Model; 582–701 | 6 |
| `test_llm_activation_save_gate.lua` | Persistence refusals, bootstrap compensation, synchronous/double callbacks and dispatch receipts; 702–866 | 16 |
| `test_llm_activation_pause_transaction.lua` | Real ScriptControl resume/rollback, pause failure replay, Disable All supersession; 867–995 | 8 |

Proposed fixture: `tests/support/llm_activation_fixture.lua`, exposing
`with_activation(backend, save_results, options, callback)`. All actions and
deferred callbacks must execute within that scope. Do not return a live fixture
whose globals have already been restored.

Specific ownership work:

- `package.loaded` injections start near line 83. Inventory every mutated key,
  reload it deliberately and restore the exact old value on all exits.
- Preserve the branch using real ScriptControl near line 305. Do not replace
  it with a permissive stub merely to unify setup across all cases.
- Allocate state, event lists and deferred callback queues per invocation.
- Move `assert_rejected_activation` near lines 444–461 with the persistence
  tests that use it, not into a general-purpose global helper.
- `false`, `nil` and thrown refusal matrices must still generate distinct cases.
  Fourteen/six/sixteen/eight is the measured partition, not a target to reach by
  deleting or merging assertions until the arithmetic works.

### T-02 — partition the largest remap transaction test

- [ ] Read all shared setup and measure executed names before moving code.
- [ ] Extract a fixture local to remap enable/disable transactions.
- [ ] Split along the existing ten describe blocks, grouping related small ones.
- [ ] Independently verify every moved module and order isolation.

Source: `tests/unit/platform/remap/test_set_enabled_lease_transaction.lua`.
Inventory: 2,933 newline-split lines, 116,738 bytes, 66 static `helpers.it`
sites, ten describe blocks. **Executed count not measured in this handoff.**

Suggested subdirectory: `tests/unit/platform/remap/enable_transaction/`.
Use names describing guarantees rather than historical audit numbers:

- `test_ready_commit.lua`: enable becomes committed only after READY (near 702).
- `test_persisted_config.lua`: malformed config/Clear All and unsafe init
  (near 884 and 2185), keeping distinct effects asserted.
- `test_setter_disk_commit.lua`: synchronous setters (near 964).
- `test_bulk_owner.lua`: reversible bulk settings and snapshot owner identity
  (near 1010 and 2064). This block itself may require further division by phase.
- `test_exact_disable.lua`: exact-lease disable and STOPPED receipt
  (near 2224 and 2648).
- `test_first_run_fence.lua`: timer ownership (near 2280).
- `test_pause_resume.lua`: complete transaction boundary (near 2423).

This partition is based on inspected headings, not a claim that all assertions
are semantically interchangeable. Keep READY, disk commit and STOPPED as
different guarantees; do not deduplicate them into one generic success test.

### T-03 — separate MLX download presentation, terminal and cleanup tests

- [ ] Preserve the existing protected `with_fixture` ownership model.
- [ ] Measure dynamically expanded cases before extraction.
- [ ] Split presentation, timer replacement, terminal protocol and detached cleanup.
- [ ] Keep native process identity assertions with cleanup tests.

Source: `tests/unit/ui/menu/menu_llm/test_mlx_download_terminal_contract.lua`.
Inventory: 2,520 lines, 98,890 bytes, 84 static test sites, five describe blocks.
The existing fixture starts near line 51 and already uses protected cleanup.

Suggested `menu_llm/download/` modules:

- `test_presentation_owner.lua` — existing block near 730.
- `test_timer_replacement.lua` — near 817.
- `test_terminal_receipts.lua` — core block near 865; divide its long body by
  actual success/failure/cancel and stale-owner transitions after reading it.
- `test_detached_process_identity.lua` — near 2343.
- `test_repository_identifier_validation.lua` — near 2469.

Do not merge a download operation epoch with native WebView identity or process
identity. They are related but independent authorities, and the tests need to
keep detecting mistakes in each one.

### T-04 — split filesystem tests at real adapter contracts

- [ ] Inventory fixture/native filesystem state and test names.
- [ ] Separate read/classification, atomic publication, symlink paths and locks.
- [ ] Review source-inspection assertions for behavioral replacements.

Source: `tests/unit/adapters/test_file_system_atomic_write.lua`.
Inventory: 2,025 lines, 81,344 bytes, 44 static test sites, five describe blocks.

Proposed `tests/unit/adapters/file_system/` modules:

- `test_classified_read_and_create.lua` — near 210.
- `test_atomic_publication.lua` — near 708.
- `test_observed_symlink_paths.lua` — near 1088.
- `test_cooperative_writer_lock.lua` — near 1520.
- Review the source-shape block near 1982 separately; do not delete it until
  a behavior test proves the same harmful operation is caught.

Keep different failure boundaries: open refusal, read refusal, close refusal,
path replacement, identity change, staging publication and lock cleanup. A
passing write test does not subsume all those transaction guarantees.

### T-05 — split tooltip watcher tests without losing facade integration

- [ ] Preserve the distinction between watcher unit tests and facade tests.
- [ ] Extract a scoped fixture, not a process-global fake tooltip singleton.
- [ ] Replay stale callback and cross-owner transitions after the move.

Source: `tests/unit/ui/test_tooltip_watcher_reuse.lua`.
Inventory: 1,829 lines, 79,016 bytes, 50 static test sites, five describe blocks.
Suggested `tests/unit/ui/tooltip/` modules correspond to headings near:

- 271: watcher reuse;
- 675: atomic rendering commit;
- 1089: dequeue ownership;
- 1498: facade propagation of watcher ownership;
- 1581: cross-owner facade serialization.

The latter two exercise an integration boundary. Do not replace them with calls
directly into a lower-level watcher merely because the setup becomes shorter.

### T-06 — unify only the counter test setup, not its different guarantees

- [ ] Retain `tests/support/hotstring_counter_fixture.lua` as the native I/O owner.
- [ ] Extract one scoped canonical-reader helper if at least two semantic test
  files genuinely need the same module/provider restoration.
- [ ] Consider moving the two older transaction modules into `ui/menu/` beside
  the new semantic tests; keep each filename/slug discoverable during the move.
- [ ] Keep file transactions, listing transactions, attribute transactions,
  whitespace and section semantics as separate focused modules.

Current responsibilities:

| Module suffix | What must remain observable |
| --- | --- |
| `file_transaction` | Required close, read/close refusal, privacy of returned errors, retry/cache |
| `listing_transaction` | Native iterator state, failed enumeration versus authoritative empty |
| `attribute_transaction` | stat versus proven absence, dangling links, recovery |
| `whitespace` | Canonical parsing of indentation and display names |
| `metadata_boundaries` | Active entry mode ends and resumes at the right headers |

A table-driven helper may emit repeated native refusal cases, but every case
must have a stable descriptive name. Do not build a giant configurable fixture
that silently decides what count the production code should return.

### T-07 — inspect remaining oversized suites, in risk order

These are inventory targets, not proven duplicate sets:

| Relative to `macos/tests/unit/` | Lines | Bytes | Static test sites |
| --- | ---: | ---: | ---: |
| `platform/remap/test_lease_controller.lua` | 2,298 | 89,828 | 80 |
| `platform/remap/test_guardian_auto_recovery.lua` | 2,066 | 75,016 | 55 |
| `platform/remap/test_generator_managed_lease.lua` | 2,053 | 78,410 | 40 |
| `adapters/test_log_transport.lua` | 1,794 | 75,198 | 50 |
| `modules/shortcuts/test_actions_system.lua` | 1,712 | 74,660 | 43 |
| `platform/remap/test_activation_layout_barrier.lua` | 1,684 | 63,717 | 29 |
| `modules/shortcuts/test_pause_transaction.lua` | 1,560 | 64,121 | 31 |

Also inspect `tests/meta/test_karabiner_stock_process_isolation.lua`:
1,583 lines, 57,379 bytes, nine static sites. Few static sites can contain a
large generated corpus; the size alone does not imply useless tests.

Inventory method: tracked Lua files under `macos/tests`, UTF-8 byte length,
`split("\n").length`, literal `helpers.it(` / `helpers.describe(` occurrences.
A final newline contributes one empty split element. Counts are not comparable
to runtime totals without expanding loops. The six-case candidate was untracked
and therefore excluded from this baseline inventory.

### T-08 — establish a defensible duplicate-removal protocol

- [ ] For each proposed deletion, record the guarantee and failure phase it tests.
- [ ] Identify a surviving test that executes the same production boundary.
- [ ] Mutate that boundary and show the survivor fails for the intended reason.
- [ ] Check the removed case has no additional cleanup, privacy, order or retry
  assertion. If it does, preserve those assertions in a suitable surviving case.
- [ ] Review the diff as a separate maintenance change, with before/after names.

Never classify these as duplicates merely by visual similarity:

- false return versus nil return versus thrown exception;
- first call versus retry after failure;
- current callback versus queued stale callback;
- successful admission versus successful terminal completion;
- successful cache hit versus failed attempt that must remain uncached;
- unit-owner guarantee versus real facade wiring;
- logical hotstring entry versus physical case-expanded mapping.

The reviewed health-probe fixture uses the real backend panel and HTTP replies;
the activation fixture replaces that panel and tests activation ownership.
Do **not** merge them without retaining those distinct exercised dependencies.

### T-09 — strengthen semantic tests before cosmetic file moves

- [ ] Run the mechanical false-green ratchet, but separately inspect copied
  algorithms, source-grep tests and stubs that implement missing production APIs.
- [ ] For source checks, prove the source body exists and strip comments/strings
  where relevant. Prefer an observable guarantee to a spelling assertion.
- [ ] In callback tests, assert the effect, receipt, cleanup and retry state,
  not only that `pcall` returned successfully.
- [ ] In failure tests, assert the actual intended error outcome so a setup
  exception cannot masquerade as the tested refusal.
- [ ] Keep real controller/parser calls; stub only external boundaries.

Recent examples already corrected, not new tasks to redo: real group-name
classification instead of a copied helper (`63649c6ae`), counter failure-result
assertions (`1972e413b`), and the earlier real LLM count menu callbacks.
The ratchet was zero at handoff; that is not proof all semantic false-greens are
gone. No new redundant/false-green case was established in the activation review.

### T-10 — measure test performance before optimizing it

- [ ] Record per-module wall time with the supported runtime and fixed test order.
- [ ] Separate Lua execution from process startup, filesystem traversal and logs.
- [ ] Identify repeated expensive fixture initialization with measurements.
- [ ] Optimize only after a causal before/after comparison with equal assertions.
- [ ] Preserve integration coverage; do not turn real modules into stubs just
  to make the suite faster.

The long Windows-hosted full-suite runs are not native macOS latency evidence.
Do not label a test split as a performance improvement without measurement.
Do not reduce randomized repetitions or erase refusal matrices for quota savings.

## 5. Logging and fail-fast checklist for the implementer

- [ ] Use the central logger and its shared SPEC; no parallel logger utility.
- [ ] Distinguish accepted work, committed effect, cancellation and failure.
- [ ] Put request/operation identifiers in DEBUG diagnostics where useful.
- [ ] Emit a visible first failure; bound repeats at the owning lifecycle level.
- [ ] Set repeat-suppression/retirement state before a sink can reenter.
- [ ] Never emit success for a partial scan, stale callback or refused write.
- [ ] Pair start/success and trace/done, with a failure terminal on aborted paths.
- [ ] Do not add raw typed text, credentials, clipboard data or full private
  application paths to new logs by default.
- [ ] Keep error signals observable in tests without asserting incidental prose
  unless that fixed sanitized error is part of the contract.

Existing `infra.fs_dir` parent-enumeration diagnostics can contain a path and
native detail. Prior counter fixes sanitize their own messages, not all logs
throughout the adapter stack. A repository-wide privacy claim would be false.

## 6. Remaining audit coverage — not confirmed bugs

- [ ] Input: ignored/private applications, pause/resume and layout transitions,
  selection replacement, exact synthetic provenance and terminator settlement.
- [ ] Clipboard: multi-format snapshot, observed paste dispatch, restoration
  failure debt, caller cancellation and subsequent operation ownership.
- [ ] Native lifecycle: each timer/task/watcher construction, start refusal,
  duplicate callback, stop refusal and retained cleanup owner.
- [ ] All shutdown paths: Hammerspoon shutdown callback and explicit quit routes.
- [ ] WebViews: request epoch versus window epoch, exact bridge recipient,
  callback result versus JS dispatch admission, error visibility.
- [ ] Files: permissions, symlinks, atomic publication, partial reads/writes,
  cache identity changes and optional-path absence classification.
- [ ] Configuration: actual supported schemas, malformed input and old snapshots;
  distinguish invalid input from a valid empty configuration.
- [ ] Menu truthfulness: disabled groups/sections, runtime overrides, preview
  counts and feature-state changes. No new disabled-extension finding was proven.
- [ ] Native macOS profiling: real typing paths, startup, idle CPU, repeated
  open/close cycles and memory growth. Resolve actual config/log paths first.
- [ ] Repeat complete scoped audits until two consecutive passes find no new
  actionable defect; still report native or environmental coverage gaps.

The audit did not establish a new `search_web` clipboard bug. That flow was
briefly read before test-organization work took priority. Do not turn this
coverage gap into an invented defect or a claim of safety.

## 7. Completion record template

Copy this under a finding or maintenance task when working on it:

```text
Task ID:
Current source SHA:
Reproduction command and original observation:
Root cause revalidated:
Changed production paths:
Changed test/fixture paths:
Red evidence (exact failure, not fixture/setup error):
Green focused cases and executed count:
Selected gates and terminal exit codes:
Independent review:
Native macOS checks performed / still missing:
Atomic commit:
Rebase base and intervening scope:
Main integration result (no push):
Remaining limitations:
```

Only then check the corresponding completion box. The goal is stronger verified
behavior and clearer test ownership, not a larger number of checked boxes.

## 8. Follow-up evidence from the parallel implementation review

These are current-code findings, not additions to the immutable seven-item
manifest. Keep separate atomic commits and record completion evidence here.

- [x] **Picker cleanup reentrancy:** `infra/app_picker.lua`,
  `delete_active_chooser()` clears `_active_chooser` after external deletion.
  Reproduce by opening A, then B, and starting C from A's injected `delete()`.
  C appears but its callback applies no settings because outer cleanup clears
  C's ownership. Detach the exact old owner before calling native teardown;
  preserve failed cleanup independently. Test one successful C selection, zero
  stale selections, and no deletion of C by the superseded B request.
  Fixed and integrated in `ca603dd86`; HS e2e and 9222 unit tests passed.
- [x] **Picker cleanup debt release/retry:** `_chooser_cleanup_debt` only gains
  keys. Fail the first delete and succeed the next: the deleted owner remains
  strongly retained. Remove the exact debt on successful settlement and provide
  a bounded retry path for detached failed candidates. Use weak observers plus
  forced collection after fixture references are removed. Replace the current
  source-spelling assertion with observable retention, retry and release tests;
  also prove retries never destroy a successor. Fixed and integrated in
  `ca603dd86`, including stale-candidate retry and reentrant retry coverage.
- [x] **Picker stale cache publication:** complete scan B with `New.app`, then
  A with `Old.app`; a third discovery currently reads Old. Give each cold scan
  publication authority before external calls; only the newest scan may publish
  cache. Preserve each caller's own result. Test newer success and newer failure
  separately: failure must remain retryable, not be hidden by A's late success.
  Candidate focused evidence: both cases failed before the correction; the
  ownership module then passed 9/9. Committed as
  `fix(hs): fence application cache publication by discovery ownership`.
- [x] **Ollama refusal fixture:** in
  `tests/unit/ui/menu/menu_llm/test_llm_activation_save_gate.lua`, the expression
  `mode == "false" and false or "nil"` simulates nil for both cases. Record the
  actual stub return type/value and assert it independently of the requested
  mode, then use explicit branches for false/nil/throw. The strengthened old
  fixture failed 1/44 (expected Boolean, observed nil); the correction passed
  44/44. No production change is needed. Committed as
  `test(hs): exercise boolean refusal in Ollama activation coverage`.
- [x] **Canonical malformed-string rejection:** `toml_codec/reader.lua`
  recognizes a quoted token but several callers treat failed decoding as an
  absent property instead of a semantic failure. Confirmed at `parse_entry`
  (trigger), `parse_kv_string`, `parse_kv_value`, `parse_inline_table` and
  `parse_string_array`. Fourteen malformed-string probes committed successfully;
  malformed entry output already rejects and is a control. Propagate the
  existing `PARSE_ERROR` sentinel at recognized quoted-token boundaries; move
  its declaration before array parsing and reject partial `sections_order`.
  Cover invalid escapes, malformed Unicode, unterminated strings, quoted keys,
  all metadata modes, localized inline values and first/later array elements.
  Preserve valid empty strings. Prove empty result plus false status, one file
  close, no cache store, and counter retry after rejection. Do not expand this
  fix into a new full-TOML grammar or unsupported bare-value policy.
  Regression module `test_toml_reader_string_failures.lua` passes
  41 cases after 37 baseline failures and four valid/already-rejected controls.
  It covers three malformed-string classes across 13 recognized contexts,
  file/cache/preview transactions and valid empty values. Recognized quoted keys
  missing their assignment separator also reject: a truncated key may otherwise
  consume the next value's opening quote and be silently ignored. The counter
  and explicit file reader have independently scoped instances; the fixture
  restores the reader captured with its logger. A Linux shared-entry regression
  preserves the same rejection and empty-value contracts. Committed as
  `fix(toml): reject malformed quoted values throughout the reader`.
  Verification: 9,324 Hammerspoon tests across 1,015 modules, 216 JS checks,
  and 67 Hammerspoon E2E vectors passed (one driver-specific vector skipped).
  Linux on Windows: 2,187 passes and 35 failures versus 2,186 passes and the
  exact same 35 failure lines with the original reader and test injected from
  `1b276bc76`. This proves no additional Linux failure in this environment,
  not a green native Linux run. Native macOS validation remains outstanding.

- [x] **Multiline continuation escape ownership:**
  `toml_codec/codec.lua`, `collapse_multiline_continuations()` examines the
  second byte of an escaped backslash pair as a new continuation introducer.
  Two backslashes followed by LF and `b` can become a backspace instead of a
  literal backslash, LF and `b`. Consume non-continuation escape pairs together;
  recognize spaces/tabs before the required LF and trim following whitespace.
  Keep invalid escapes invalid and literal strings untouched. The focused
  `test_toml_multiline_continuations.lua` passes 13 cases, including CRLF;
  injecting the codec from `ddde4d031` produces six root-cause failures and seven controls.
  Linux shared-entry coverage was added. Committed as
  `fix(toml): preserve escape ownership across multiline continuations`.
  Full gates: 9,337 Hammerspoon tests across 1,016 modules and 216 JS checks
  passed. Linux under Windows: 2,188 passes versus 2,187 with the original codec
  and test injected from `ddde4d031`; all 35 failure lines match exactly.
  Independent review found no blocker. No native macOS/Linux runtime claim.
- [x] **Multiline first-line whitespace loss:** the general codec trims the
  assignment line before seeding `pending.parts`, losing spaces and tabs before
  the first physical LF inside a basic or literal multiline string. Reproduced
  with literal content `a`, backslash, space, LF, space, `b`: the space before LF
  disappears. Preserve the original value fragment once lexical scanning proves
  the string remains open, without retaining comments outside strings. Cover
  both quote types, trailing spaces/tabs, blank first lines and ordinary scalar
  comments. This is separate from continuation escape ownership: that focused
  module starts content on the next physical line to isolate its root cause.
  Read-only proposed patch passed six probes: have `split_kv` return an
  additional original RHS, call it on `strip_comments(line)` rather than the
  trimmed assignment, and seed `pending.parts` with that RHS only when
  `multiline_quote` is non-nil. Document the extra return and remove
  `strip_inline_comment` only if no caller remains. Regress basic/literal values
  both standalone and inside arrays, internal `#`, external array comments and
  a following assignment. Four probes differ from current code.
  Implementation passes 14 focused behavioral cases in
  `test_toml_multiline_first_line.lua`, after 12 failures and two controls with
  unchanged production. A Linux public-entrypoint regression covers the same
  value preservation. Independent review found no blocker. Committed as
  `fix(toml): preserve whitespace inside the first multiline fragment`.
  Full gates passed: 9,351 Hammerspoon tests across 1,017 modules and 216 JS
  checks. Linux under Windows: 2,189 passes versus 2,188 with original codec and
  test injected from `8dafc1729`; the exact same 35 failure lines remain.
  Native macOS/Linux execution is not covered by these results.
- [ ] **Application discovery root completeness:** missing/empty HOME allows
  a cached system-only result; repairing HOME immediately does not retry.
  A user Applications root classified as a file is also accepted as a search
  root. Validate completeness and directory type before authorizing cache
  publication; distinguish proven absence from classification failure. Preserve
  valid directory symlinks according to the filesystem adapter contract.
  Isolated probes measured one spawn and zero classifications for missing/empty
  HOME, including a subsequent repaired HOME served from cache. Regress absent,
  empty, directory, proven missing and file roots plus immediate repair retry.
- [ ] **Application discovery completion receipt:** failed subprocess exit and
  successful empty output both call `on_ready({}, nil)` in current probes.
  Failure is logged and does not cache, but the chooser presents the same
  success-shaped empty UI. Add an explicit completion status, propagate it on
  every terminal branch/cache hit, and retire failed request authority without
  presenting a chooser. Regress classification/start/exit/stdout failures,
  successful empty caching, successful retry, chooser count and zero settings
  writes on failure. Preserve exact-owner cleanup and reentrancy invariants.

- [ ] **General decoder interior quotes:** `toml_codec/codec.lua`,
  `coerce_value()` accepts `name = "bad" garbage "tail"` as one string because
  it checks endpoint quotes while `BasicString.unescape_body()` does not own
  string delimiters. Reject unescaped interior quotes at the canonical string
  token boundary; retain escaped quotes. Add direct codec regression tests,
  not a manifest-specific filter. This is distinct from reader propagation.
  Read-only probes also reproduce the acceptance in literal strings, quoted
  keys, arrays and inline tables. For single-line basic strings, reject raw
  quote bytes in `BasicString.unescape_body()` only when `allow_newlines` is
  false; the escape branch must still accept escaped quotes. Literal string
  bodies must reject interior apostrophes. Multiline strings require source
  delimiter validation before continuation collapsing: retain one/two content
  quotes and valid four/five-quote endings. Do not reject a triple quote formed
  only by removing a valid escaped newline. Extend existing codec edge-case and
  shared Linux decode tests with invalid tokens plus these valid controls.
  Single-line value/key/container cases are fixed in `f3911f02c`; all seven new
  rejection cases failed before the fix and the 59-case focused module passed
  afterward. Multiline delimiter termination remains open as a separate fix.
  A read-only candidate passed 32 real decode probes with codec and record
  scanner loaded in memory: 24 valid basic/literal combinations (3/4/5 closing
  quotes, scalar/array, single/multiple lines and trailing comments), four
  trailing-token refusals, two six-quote refusals, escaped content quotes and
  a triple quote formed only after continuation removal. Proposed owner helper:
  scan from byte four, skip basic-string escape pairs, recognize the first
  unescaped run of three or more delimiter quotes, require a run of at most
  five ending exactly at the token boundary, and retain the preceding one/two
  content quotes. Validate before continuation collapsing. Also consume entire
  closing quote runs in `strip_comments`, `split_top_level_commas` and
  `RecordScanner.advance`; otherwise a fourth quote spuriously opens a new
  string and hides array delimiters/comments. These scanners only delimit;
  the value owner rejects oversized runs. No tracked implementation yet.

- [x] **Delimiter decoding ownership:**
  `modules/hotstrings/hotstrings_config.lua`, `parse_overrides()` claims
  `word_delimiters` before `BasicString.unescape_body()` succeeds. An unknown
  escape or surrogate escape is then dropped by an unrelated category save.
  Claim the record only after successful decoding; otherwise retain the raw
  assignment and emit the existing unsupported-representation warning. Extend
  `test_hotstrings_config_preserves_global.lua` to prove a real category commit,
  exact malformed-record preservation and explicit replacement without duplicate
  keys. Fixed in `610b94168` after reproducing the lost-record failure. All three
  focused tests also pass with the preceding decoder injected, proving this
  commit is independent of the subsequent token-validation change.

- [x] **Personal-info parsed absence is not source absence:**
  `modules/dynamic_hotstrings/personal_info.lua`, `parse_toml_section()` silently
  skips literal strings, trailing comments and failed basic-string decoding.
  `load_config()` substitutes defaults and publishes the original source snapshot
  as if interpretation succeeded. Real `start()` plus an unrelated
  `save_info({ last_name = "Updated" })` then erases the ignored first name.
  Read-only reproduction covered `first_name = 'Alice'`, a double-quoted name
  with a trailing comment, and an unknown escape. Decode the complete document
  through the shared codec and validate declared known fields/section shapes
  before publishing a source snapshot. Distinguish missing fields from invalid
  fields; retain defaults only for genuine absence. Reuse startup rollback and
  external-winner refusal on parse failure; never log personal field content.
  Test valid literal/comment/multiline values surviving an unrelated save,
  malformed/typed-invalid input causing zero writes and no active owner, and
  invalid external content not replacing live runtime state.
  Regression coverage is registered in the focused
  `test_personal_info_config_transaction.lua` module. Its 13 cases pass with the
  fix; injecting the original personal-info module from `7bf7cea1b` gives
  11 expected failures and two valid escaped-quote/empty-value control passes.
  The fixture keeps real schema/default semantics and scopes filesystem/logging
  boundaries, including real manifest/field readers that capture the logger.
  It covers malformed external-winner refusal, repaired-winner adoption and a
  successful retry, preserving live table identity and withholding private data
  from logs. The existing ten-case save-transaction module also passes.
  Fixed in `fix(hs): reject invalid personal-info data before publication`.
  Full validation passed: 9263 HS tests across 1013 modules, HS e2e and all
  216 JS checks (exit 0). The subsequent audit-only evidence update passed the
  handoff and documentation-path validators. Native macOS remains unverified.

The delimiter and single-line-token fixes passed 9250 HS unit tests, HS e2e and
all 216 JS checks. The Linux run under Windows Lua 5.4.6 passed 2184 tests and
failed 35 across 182 modules. A process-local injection of the two original
decoder modules and original Linux test from `4ca236055` passed 2183 and failed
the same 35; sorted complete failure lines are identical. The additional codec
regression passes. The overall planner therefore exits 1 for reproduced Linux
baseline debt, not a claimed green native Linux gate. Handoff/doc-path checks
were rerun after the audit-only evidence update. Native macOS/Linux validation
remains unperformed.

HS-272 implementation preparation: the existing `toml_codec.codec.decode()`
already owns section boundaries, comments, BOM and escaped strings. Prefer
having shared `hotstrings.extensions.parse_name()` project `[extension].name`
from it, and make the counter call that same boundary on its validated text.
Preserve `parse_name(nil)` for absent manifests; distinguish absent names from
malformed/non-string names. Update the counter fixture to a real `[extension]`
manifest. Test comment/other-section decoys, escaped quotes/backslashes/Unicode,
duplicate names and rejection followed by successful retry. The existing Linux
shared-scanner tests and runtime hotstrings-config consumer are also in scope.

Verification note: the shared parser snapshot extraction was independently
compared with commit `2f4a770a8` on all three shipped extension TOMLs and on
iterator/semantic/close failure boundaries, with no observed differences.
`npm run test:linux` under Windows Lua 5.4.6 produced 2183 passes and 35 failures
across 182 modules both before and after the extraction; failed-name multisets
and complete failure lines were identical. This is baseline evidence, not a
claim that Linux-native verification passed.

The three implementation/test commits share a completed `verify-change` run:
JS, HS e2e and 9219 HS unit tests passed (exit 0). HS-271 is committed as
`fix(hs): count extension entries with canonical TOML semantics`. The handoff
validator passes. The generic `workflow.cjs verify-commit` rejects this nested
handoff manifest location before inspecting a commit; its trailer and exact
production/regression paths were inspected directly instead. Native macOS
validation and the additional follow-up findings remain open. The renderer and
registry-parity matrices for HS-269/270 are now verified as recorded below.

The remaining HS-269/270 matrices now have focused regression coverage in
`test_hotstring_counter_semantics.lua`: 15 tests pass, including the real menu
builder and registry loader. Injection of the pre-fix counter from `2f4a770a8`
fails the BOM and repeated-section cases. The source fix is shared with HS-271;
no second merging or BOM-normalization implementation is needed. Coverage is
committed in `8484ba9`; HS e2e and all 9234 unit tests passed (exit 0).
The same snapshot passed all 216 JS checks (exit 0); the subsequent audit-only
evidence update passed the handoff and documentation-path validators.

- [x] **Completed picker native callback root:** selection and cancellation
  retire Lua authority but previously never delete the native chooser. The
  Hammerspoon registry retains the callback, which captures the chooser, so
  ordinary cycle collection cannot release it. Native evidence:
  [chooser registry ownership and cleanup](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/chooser/libchooser.m#L810),
  [selection/cancellation callbacks](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/chooser/HSChooser.m#L344).
  Apply the selected settings before external teardown to preserve ordering,
  then settle the exact owner even if settings application throws. Model a
  separate strong native callback registry in tests; verify cancellation,
  selection, thrown settings, failed native delete and retry, garbage collection,
  duplicate callbacks, and reentrant selection order. Fixed in `c6739a1`; all
  18 focused ownership tests, HS e2e and 9234 full-suite tests passed (exit 0).

- [ ] **Picker native presentation reentry:** a custom Hammerspoon
  `chooser.globalCallback` can start request B from A's `willOpen` callback.
  Native `showWithHints` invokes that callback before showing/focusing A, then
  continues without rechecking ownership. A can therefore resume after B opens,
  steal focus and cancel B. The current test double records visibility before
  its reentry hook, hiding this ordering. No Ergopti installer of this global
  callback was found: this is an extension/configuration boundary, not a proven
  stock-configuration failure. Reproduce with native-order visibility and
  focus-loss cancellation, then consider serializing presentation with a latest
  successor continuation. Check repeated supersession, exact cleanup and failure
  release; do not merely add checks between the non-callback setters.
