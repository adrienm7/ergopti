<!-- docs/handovers/2026-10-12-config-menus/2026-10-15-PERSONAL-TOPOLOGY.md -->

# Linux Personal directory coverage

Feature atom `7523f4b192caa06f0cdadda331d4e11a99b9442f` follows the existing identity fix without rewriting
any published commit. Fresh Dev is `e850833c74f3f10c6718eb822fd2aa21f83f13b2`; Root's active release boundary
still queues this feature's integration. No Dev or Main push is claimed.

## Change and ownership

Previously, creating or moving a populated directory into Personal emitted a
directory name that the native TOML filter ignored. Polling could notice the
parent timestamp but never added descendant registrations. The real daemon's
reload consumer reloads configuration without rearming these watchers, so a
reload alone did not repair later edits.

The two-path change reconciles Personal coverage at the existing settled event
boundary. It arms new directories before listing their contents, preserves
case and literal backslashes, and refreshes changed device/inode bindings.
Incomplete enumeration or native activation retains prior coverage. Already
accepted bursts still invoke the existing reload consumer, including main and
base events. A separate bounded retry repairs coverage; failed retries do not
publish reloads, and successful changed coverage queues one fresh settled read
of changes that occurred while unobserved.

Exact entry and session fences reject retired callbacks and obsolete startup
continuations. Personal native handles remain owned until their actual close
acknowledgment; stop/close refusals retain repair debt. The new `stop()` boolean
describes only this Personal ledger. Generic-root shutdown retains its prior
semantics; the result does not acknowledge a whole-driver stop.

New shell operations use unchanged `adapters.shell_runner.exec_checked` and
its sole quoting helper. Native metadata avoids a shell for unrelated events.
The checked fallback enumerates NUL-delimited names, preserving legal newline
bytes. Existing depth, symlink and other-root policies remain unchanged. There
is no recursive idle scan, whole-daemon restart, shared policy, generated
artifact, runner, workflow or registration change.

Windows has no corresponding per-directory recursive walk. macOS already
uses one recursive native Personal watcher. This Linux correction does not
qualify either host or replace their native acceptance.

## Independent receiving

The complete prior 49-test module remains an identical 38,693-byte prefix,
SHA-256 `7538539f52f671d0bf9503fabede610fedfafd45fe85b44cc902898b9369ff38`.
Thirty-four hand-authored subjects add real directory creation, moves,
renaming, inode replacement and later edits under native inotify and explicit
polling. Controlled ports also exercise enumeration/activation refusal,
accepted callback preservation, repaired consumer bytes, asynchronous close
acknowledgment, duplicate names, stale sessions and construction reentry.
These expectations were not generated from the new implementation.

The frozen original receiving uses the same 83-case corpus on Lua 5.4.7 and
LuaJIT 2.1.1737090214:

| Phase                                 | Lua 5.4                 | LuaJIT                  |
| ------------------------------------- | ----------------------- | ----------------------- |
| Prior producer with final corpus      | 55 passed, 28 failed    | 55 passed, 28 failed    |
| Corrected producer                    | 83 passed, zero failed  | 83 passed, zero failed  |
| Eleven focused protection withdrawals | Expected named failures | Expected named failures |
| Restored full producer                | 83 passed, zero failed  | 83 passed, zero failed  |

The 22 withdrawal children terminate with the expected failures, without an
unexpected result. Prior rejected candidates, corrected new fixture premises,
the nonexistent-helper typo and its noncausal failure remain separate in
[the original receiving packet](2026-10-15-PERSONAL-TOPOLOGY.tar.gz).
Its 159 regular members have SHA-256
`ef732a0a888d5f7c5724f9e6b42e3c5b25286b815e60ec28fdd992a3cb2d37a3`;
all 158 manifest entries were independently checked. Extract into an owned
directory and verify `SHA256SUMS`. The packet identifies its dependency Git
baseline and all 2,361 captured files, without duplicating the whole tree.

The topology atom's initial test image is SHA-256
`2340d5e638fbf0660839991d3f96de74d55908e805c53028f5b3e9552d276658`.
The current Linux unit workflow installs luv and filesystem support, but does
not require lua-posix. The original new block returned before its 34 subjects
when that optional library was absent. Its underlying exit was zero; the
independent receiving-count gate correctly rejects the missing subjects.

An explicit fixture scan/stat port backed by real native luv operations now
executes those cases without the optional library. The real POSIX port remains
used when available; explicit no-POSIX subjects still exercise the production
native or checked-shell fallback. The original 49-test prefix and every new
case body, name, expected value and assertion remain unchanged. Only fixture
port selection and two fixture filesystem references change.

Both runtimes receive 83/zero with POSIX and when absence begins at the new
block boundary. With global absence they receive 82/zero: all 34 additions
execute, while one unchanged original installed-POSIX integration is
unavailable. Its absence is not reported as a pass. Each final child has
independent short-lived TMPDIR and TEMP roots with empty cleanup. The
[80-member portability supplement](2026-10-15-PERSONAL-TOPOLOGY-FIXTURE.tar.gz)
has SHA-256
`0bf4806c00308c64bb08be84352ef77e10be3a95b3a10885507c4b619e034a4f`.
The earlier shared-temporary-root matrix is retained as preliminary; no
collision or cause is invented from its mere possibility.

A separate [41-member causal supplement](2026-10-15-PERSONAL-TOPOLOGY-CAUSAL.tar.gz)
uses this exact final test image with both producers and both engines.
The prior producer receives 55 passes/28 failures with POSIX and 54/28 with
global absence; restored receiving is 83/zero and 82/zero respectively.
All 34 new names execute. The 28 literal failed names match the original
frozen corpus, and all available original prefix subjects pass. Its SHA-256
is `780abaa722ba0aebba78c5e5874b3c0be235d5c2aa6b0f7e74e7448438d33cf4`.

The parent and an independent reviewer accepted the final source within this
scope. Their review is separate from execution. Artificial debounce time,
controlled reentry/fault ports and real native filesystem events have distinct
limits; they do not establish that a kernel naturally produced a simulated
failure or that a physical input device was exercised.

## Canonical gate and CI

The final selected canonical `verify-change` gate completed at
2026-10-15 10:02:40 UTC with exit zero: 13,802 units across 521 modules and
193 scripted E2E cases passed, with zero failures. Formatter prerequisites
and strict conventions also passed. Its frozen source images match feature
`7523f4b192caa06f0cdadda331d4e11a99b9442f`, tree
`bbe22ea35474dd86d5d0fe88cb1667980ebde107`; the log SHA-256 is
`38c5f1e31a51958f68bf9fdb0cf837c77c8629bfb526374b99c9b39986cbfdb9`.
The [18-member canonical gate packet](2026-10-15-PERSONAL-TOPOLOGY-LOCAL.tar.gz)
seals both earlier attempts and the publication join; its SHA-256 is
`8dcfb6418b697306bcae068f7a2b4ca62b8dfdc394f9be6dba3d2682b42408d5`.

The preliminary successful gate used an earlier fixture image and potentially
shared temporary root. No collision was established; that receipt remains
preliminary. A later exact-source gate failed at 13,801 units passed/one failed:
the unchanged Unix-socket file-write fixture stopped after 14 of its 24 checks
because its socket pathname was 109 bytes. The remaining ten checks did not
complete. The same original helper and source reproduce that refusal on the
prior baseline, then pass all 24 checks with a 65-byte socket pathname. The
[24-member temporary-directory receipt](2026-10-15-PERSONAL-TOPOLOGY-TMPDIR.tar.gz),
SHA-256 `b19a16751d84bb042e68d097948cded1bef7fbd9026c2a0822d92196845e00bb`,
retains that direct comparison. The final complete gate uses a short unique
TMPDIR and TEMP after the external readers terminate. No helper, original
assertion or production source was changed to obtain that execution result.

Earlier Linux manual
[38704117453](https://github.com/adrienm7/ergopti/actions/runs/38704117453)
is naturally terminal success on `b12fc635dc7e014054ec9e287a959c7d311d2d5c`,
tree `559f5e4069659cb0d47206c489adf1353366d728`, exactly the prior identity
source. It reports 28 jobs: 25 success, zero failure and three skipped
(macOS, Windows and Release), including all 17 installation/launch variants.
Its [terminal receipt](2026-10-15-LINUX-PATH-CI-RECEIVING.tar.gz) is retained.
That earlier success does not qualify this new topology source.

Topology manual
[38717729588](https://github.com/adrienm7/ergopti/actions/runs/38717729588)
completed naturally with **failure**, attempt 1, on
`d7b8d23bb1f1c80b4b70ce6cf599ba66c31bd01a`, tree
`bbe22ea35474dd86d5d0fe88cb1667980ebde107`, exactly the topology source above.
Its 12 jobs comprise four successes, three failures and five skips. Core JS,
properties, Linux E2E and planning succeed; Linux units and two downstream
verdicts fail. Package/install, Windows, macOS and Release are skipped. The
unit API annotation reports 13,799 passed/two failed; raw assertion logs and
failure artifact contents were not received through the storage proxy.

The two failing new native subjects cover overlapping Hotstrings/base owners
and preservation of accepted main/base bursts during Personal refusal. Local
reproduction with the unchanged producer and default `/tmp` fixture root
observes the missed second reload: the existing anchored `/tmp/` exclusion
intentionally refuses those base Lua events. This is a new fixture defect,
not historical debt or permission to change the production exclusion.

Fixture-only atom `3011ea7ef2ac582374410eb2f721ba405c390d5b` selects `/var/tmp`
for those two base-source sessions. Every existing assertion and the complete
original 49-test prefix remain unchanged. Its full proper Git-worktree Linux
unit run passes 13,802/zero across 521 modules, including all 34 additions and
both failed hosted subjects. The watcher producer is unchanged. The corrected
test module has SHA-256
`892fb1e7937190dcd5d8b754ee8954bd2e38590cadc7385bcee312e11ce24e50`.
An earlier incomplete source capture was interrupted and is unqualified.
That local repair does not rewrite the failed hosted run.

The composition now includes all picker and diagnostic atoms below at feature
`280174ee225a5d28869efec6061e43dd20bfe015`, after feature-only Dev merge
`4b08766a2660c631dd670e37fe9ec321867412ae`. Dev
`e850833c74f3f10c6718eb822fd2aa21f83f13b2` is an ancestor of this feature;
no Dev/Main publication is claimed. A subsequent macOS+Linux validation on
[the owned CI branch](https://github.com/adrienm7/ergopti/actions?query=branch%3Acodex%2Fci-config-menus)
is pending at this dated checkpoint. Its exact candidate tree, actual run SHA
and terminal outcomes must be received separately; this document does not
predict them. Release remains push-only and is not authorized by a manual run.

Raw hosted logs currently redirect to a storage hostname refused by this
container's proxy. Exact job/step metadata can establish their API outcomes;
artifact metadata cannot establish content or assertion counts. The saved
environment draft includes the precise hostname addition and still requires
publication in environment settings. No hosted raw count is inferred.

## Native directory pickers and diagnostic facts

The [103-member combined native receipt](2026-10-15-CONFIG-NATIVE-RECEIVING.tar.gz)
seals all four completed atoms, the diagnostic candidate's received phases and
the failed topology CI metadata. Its SHA-256 is
`a76879593d777b9e4a6c08ae1c8c6025e53fe1e147a2754947bcf8866499a732`;
all 102 manifest entries are independently checked. Its diagnostic full-unit
and future hosted qualifications are explicitly pending, rather than inferred
from the completed neighboring atoms.

Linux picker atom `b6f0cbd86281ec0bed7fc38456806668d898f6fa` requires the
existing checked child-process receipt before accepting Zenity/KDialog output.
Real failed children with stdout no longer select a folder. Focused receiving
changes from 22 passed/four failed with the prior producer to 26/zero on both
Lua engines; all 18 original subjects and their assertions remain. The first full gate exposes
two positive UI-bridge fixtures that supply only the former unchecked port:
13,808 units pass/two fail, with 193/193 E2E. Those two fixtures now expose
the checked success receipt, retaining their assertions. The corrected full
gate passes 13,810 units across 521 modules and 193/193 E2E. Its log SHA-256 is
`e9d95a4da267115ab98516fbf1d22e48eca892e465ea13efae666ed56b23329a`.
The initial red remains evidence of this change's fixture mismatch.

Linux root-selection atom `ab2ca83d2b245ecc44fe4d0f62df05750f486456` preserves
an explicit `/` through selection, bootstrap storage and path resolution rather
than clearing it to the default-folder intent. The two owning modules receive
55/zero on both Lua engines against four literal predecessor failures. The
selected complete gate passes 13,814 units and 193/193 E2E. Empty-folder intent
still selects the published default. These fixture and child-process results
do not qualify an installed physical GTK picker session.

macOS picker atom `5bc47ca57fa858f596a91f69154c2d613013ebb6` checks the actual
Hammerspoon execution success flag before parsing either returned representation.
Failed OSA execution can return diagnostic text as its third result; that text
no longer becomes a folder. All five original cases remain byte-identical;
three additive controls cover compilation failure, execution failure and the
successful raw fallback. The full selected portable gate passes 19,830 units
across 1,604 modules and 101 E2E cases, with one explicitly skipped scenario.
Native Cocoa and installed picker acceptance remain separate requirements.

Shared Lua diagnostic atom `280174ee225a5d28869efec6061e43dd20bfe015` retains
numeric and keyed facts when an input table has holes. Lua table length is
undefined for sparse sequences; actual contiguous keys now determine list
traversal. Existing report format, independent corpus and caller redaction
policies remain unchanged. Focused receiving passes nine cases on Lua 5.4
and LuaJIT; strict conventions and all 426 JS checks pass, as do 101 macOS E2E
cases with one explicit skip. Full macOS units and the selected Linux gate
remain running at this checkpoint and are not claimed passed. Windows uses
its separate producer. This bounded correction does not complete English
report/export, generation binding, daily-log collection, GitHub editability or
installed three-OS flow acceptance in item 138. No automatic upload is added.

## Remaining acceptance

Root disappearance/recreation and parent-anchor admission remain outside this
lot. Generic-root lifecycle repair and a complete installed distribution
qualification are not inferred from Personal retirement or GNU coreutils on
this container. Additional-Personal source selection and activation remain
Group 2's policy boundary; observation is not implicit source authorization.

On a normal installed private Linux profile, record the package commit and
keep its existing Personal root. Create a nested folder, copy a known-valid
TOML into it, and observe a settled reload in the runtime log. Edit that file
in place and require another reload. Repeat with a moved-in populated tree,
renamed/recreated child directory and atomic TOML replacement. Confirm main
and base edits still reload while a controlled Personal permission refusal is
active, then restore permissions and confirm coverage repair and subsequent
edits. Separately verify the supported source selection, actual trigger
effects, persistence and installed restart; those are not proven by the
fixture's byte consumer or scripted keyboard ports.

All six Group 1 items and transversal 16/38 remain partial. Shared paths-editor
intent retention still awaits Root's owned npm alias and CHECKS enrollment;
the prepared Windows picker fence remains inactive with native receiving
unexecuted. The four Personal constructors and current scope transactions
still need their recorded receiving. Preserve the existing proposal archives,
original assertions and complete native warnings. Item 22 remains withdrawn;
the website is unchanged. The historical handover reference to `Texte collé.txt`
remains unavailable, and no instructions are inferred from its preview. It is
not a prerequisite for the maintainer's general request to improve system
diagnostics and issue reports; that work proceeds from the current code and
that explicit request.
