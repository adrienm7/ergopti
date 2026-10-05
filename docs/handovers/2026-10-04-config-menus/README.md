# Configuration and menus: Windows workstation handoff

The maintainer requested integration of the completed group1 corrections and
explicit TODO steps for Windows work to be resumed on their workstation.
The six assigned items (5, 7, 33, 42, 54, 81) remain partial; none is removed.
Transverse items16/38 retain their validation requirements. No website or
withdrawn differential-update work belongs to this handoff.

## Delivered-source boundary

The feature sources through `38f2add0df777c1d49f04cb3a09e7ea8450c8b0f`
contain fourteen bounded commits, listed exactly in `bounded-commits.json`,
plus merges of current dev. This source checkpoint includes the Windows
semantic cache/feature snapshot and obsolete installed-record preservation.
Their portable checks passed, but their native Windows execution is pending.
The actual integration SHA and final CI result must be recorded by delivery;
a saved patch or portable Lua suite does not prove native integration.

Final-source local qualification passed 356 JS checks, 14,002 portable macOS
unit cases, 6,613 Linux unit cases, macOS/Linux E2E (101 passed plus one
host-specific skip, 188 passed), and BOM/LF checks for 1,821 AHK files.
The AHK unit/parse/E2E gates were not executed on this Linux host.
Individual commit receipts differ where source
selection deliberately omitted an unaffected driver. Actual X11 GTK/WebKit
wizard round-trip, pending-folder, source-race/retry and obsolete-trigger probes
passed. These do not establish physical input, Wayland, a restarted daemon,
Darwin input or a real Windows UI.

The first manual three-OS checkpoint is
[37239539127](https://github.com/adrienm7/ergopti/actions/runs/37239539127),
at `68a66ff2069681da0e323a95b29b8613cce8b992`, before the semantic snapshot.
It is not final-source acceptance: Core/js, the Windows AHK suite, the Linux native prerequisite and Swift launcher
tests failed. macOS portable unit/E2E passed; Linux unit/E2E/package/install,
Windows E2E/package/install and macOS installation were not executed. Release
publication was skipped. Windows failures remain workstation handoff work.
The native metrics prerequisite also fails on untouched `689d30293704093feab2e3caa077604e88560eb6`:
its fixture attempts to decode receipt-bearing SQLite stdout as JSON before
production extracts the exit receipt. No assertion may be weakened to fix it.

The final feature-source checkpoint is
[37242713573](https://github.com/adrienm7/ergopti/actions/runs/37242713573),
at `38f2add0df777c1d49f04cb3a09e7ea8450c8b0f`, with Windows explicitly deferred
to the maintainer. JS/properties, Linux units, macOS portable unit/E2E and
macOS packaging passed. Nine of eleven macOS install/launch profiles passed;
`clean` and `karabiner_config` failed their original native AppleEvent probes.
Independent upstream run37239438795 reproduces those same native failures.
`evidence/macos-launch-source-equality.json` records 74 equal probe/launcher/
packaging owners across the upstream and feature checkpoints. The complete
runtime/package is not byte-identical, and the native cause remains unresolved.

Five existing Linux E2E steps failed: disposable-profile SQLite init, release-page
ETag associations, audio locale, AT-SPI interpreter options and literal desktop
notifications. Linux packaging and installation were consequently not executed.
The exact fixtures pass with real native components on both source snapshots in
isolated local sessions (`evidence/linux-native-replays.json`), but their Debian
versions differ from Ubuntu CI. These replays do not erase the hosted failures.
Release publication was skipped. Final integrated-source CI remains mandatory.

## Windows resumption

1. Fetch the current `origin/dev`, inspect local/index state, preserve existing
   work and use a new owned branch from that current ref. Record the exact SHA.
2. Install the pinned Node version and authenticated Windows runtime/compiler
   declared by `_shared/modules/updater/windows_release_toolchain.json`.
   Use the repository RTK launcher and `verify-change`; missing interpreters
   are not passed tests. Follow the PowerShell steps in `ci-windows.yml` for
   native unit/include/E2E and authenticated compilation rather than inventing
   an alternate toolchain.
3. Complete the Windows checkboxes in each of TODO5/7/33/42/54/81. Keep invalid
   stamps strict; preserve retired/scalar/future records until explicit cleanup.
   Record successful, failed, skipped and unexecuted stages separately.
4. For native runner validation, push an owned dedicated CI branch and cancel
   all automatic workflows for that precise pushed SHA. Dispatch `ci.yml`
   manually with `os_lanes=windows` for Windows-only changes; use all affected
   OS lanes after shared changes. Manual runs must finish without release.
5. Use a disposable profile and the supplied qualified artifact for real UI,
   scope and physical acceptance. The manual acceptance document here is a
   draft: exact build, launch instructions and isolation must be verified first.
   No work-machine logs or screenshots need to be exported.

## Prepared work that is not integrated

`prepared/packets.json` records eight frozen patches and exact SHA256 values.
The continuation feature branch applies the macOS Boolean-leaf packet after
matching its exact source preimage; its native qualification remains pending.
The shared Lua installed-record packet is also applied after matching all source
and test preimages. The other six historical payloads remain unapplied. The old
partial-publication packet `19bcc252…` is superseded by the reviewed bulk and
lifecycle continuation; do not apply its old sources over those owners.
Frozen patch bytes and review receipts are historical evidence and must not be
rewritten to reflect new integration.
Each subdirectory preserves its author's source review, dependency/preimage
metadata and bounded qualification notes. The shared-menu dependency order is
Tap-Hold head, Metrics labels, Tap-Hold delay, Wrap controls, then Tap-Hold
guidance. Lua installed-record preservation and Mac Boolean leaves are separate
source families. They require current-source preimage checks and owner generator
runs; never merge generated bytes by hand or regenerate independent goldens.
Do not blindly apply obsolete TODO hunks: compose only group1 notes.

The Mac Boolean packet and the reviewed Linux obsolete-shape successor are
applied in the continuation feature branch; hosted native acceptance remains
pending. The exact bulk publication-recovery packet is applied as described
below. Reviewed scalar/detached setters, activation and startup consumers are
also applied in the lifecycle continuation below. Same-read recommendation
semantic-source admission remains a separate prepared packet. A bounded
implementation must not be reported as a completed global transaction.

The remaining menus still have 96 Windows, 153 macOS and 97 Linux counted sites
in the integrated source checkpoint. Prepared packets lower counts only when
actually applied and qualified. canonicalHoldOptions is already shared and must
not be cosmetically reimplemented. Broader configuration catalogues, native
acceptance and complete global composition remain in their original TODO blocks.

## Continuation: retired integration preference

The continuation feature applies the independently reviewed retired Karabiner
preference correction after checking its exact Boolean-preservation parent.
Ordinary saves and integration-consent changes retain `[karabiner] enabled`
until explicit cleanup, with one precise warning; runtime consent still comes
only from `integration_enabled`. The sole historical deletion expectation is
corrected to exact preservation plus a complete independently specified model,
as required by the maintainer's current policy. All other old assertions remain.
Focused portable checks pass 32 new and 31 existing owner cases. The selected
local gate passes formatting, 357 JS checks, 14,149 portable macOS unit cases
and 101 macOS E2E checks with one host-specific skip. Hosted native,
package/install and physical qualification remain pending; no TODO item is
removed.

## Continuation: installed-layout record updates

Two independently reviewed additive packets apply after the original Lua
installed-record preservation packet. Their exact hashes are
`080142101ff4cf8dc5bda79c07eed31bb75b3179e1841db0d71f5725e7d5efa2`
and `32ba6fc0355f461e517746c955d58e47ce22e1df4a893b15314ea203576e4b3a`.
Verified same-id updates preserve omitted future members without reviving old
owned metadata or obsolete predecessors. Invalid optional extension rows remain
ignored and preserved before native root discovery. All earlier registered
tests retain their byte prefixes; the new complete expected models are
handwritten. Focused checks pass 98 macOS and 88 Linux cases on each available
Lua runtime. Selected executable local gates pass formatting, 357 JS checks,
14,202 portable macOS and 6,758 Linux unit cases, 101 macOS E2E checks with
one host-specific skip, and 188 Linux E2E checks. The selected AHK unit gate
is not executed on this host. Hosted native/package/install qualification
remains pending; these Lua-only corrections do not qualify the separate
Windows record owner.

## Continuation: exact bulk publication recovery

The independently reviewed bulk packet `c9d77463…` applies after the exact
retired-preference Config prerequisite. All fourteen source/test preimages and
postimages match its manifest. Native cleanup capabilities propagate through
the shared writer/layer/scope owners into the actual macOS remap bulk journal;
retry settles them before another inverse, runtime regeneration or backup
release. Its private Config creation inverse verifies current absence without
rewriting a successor or changing the generic scope contract. Every original
assertion remains intact. The explicit-reset fixture follows the conditional
publisher and adds a handwritten exact malformed-source fence; its previous
predicates are unchanged and an independently mutated wrong fence is refused.
Selected local gates pass formatting, 357 JS checks, 14,226 portable macOS and
6,760 Linux unit cases, macOS E2E101 with one host-specific skip, and Linux
E2E188. Hosted native qualification remains pending. The separately reviewed
setter/activation/startup consumer packets are applied in the next continuation;
same-read recommendation admission remains separate. This bounded source does
not establish complete TODO5 acceptance.

## Continuation: lifecycle publication recovery

Three independently reviewed source/test packets apply after the exact bulk
prerequisite:

- Setter/detached V2: `659fe4aac0205d78d95e633ecf3c1327bedd359cfafa250f8464fdc30bf0df78`.
- Enabled transition: `b95d7028579aa912522e5c28b2dc80ce480cd11d40f6377e4d2c73b2f7d57630`.
- Startup V2: `aebc8d547e56318536e81d5f5b1c5ed6aec79db0f6736e95345cc85f72588c88`.

Setter and enabled changes reconstruct exactly on their common init preimage;
conflict-free composition reproduces the independently reviewed `10569b34…`
source before exact startup application produces `35c342ff…`. Existing test
assertions remain intact, including both meaningful Config startup save sites
and all seven false exits. Scalar/detached saves retain the actual native file
effect on refusal; enabled transitions preserve STOPPED/file-inverse/READY
ordering and legacy two-return behavior. Startup records cleanup-only debt
before lease/runtime admission and retries against a fresh source. These private
capabilities do not survive a VM/process exit; existing emergency teardown and
EOF policies do not manufacture an acknowledged cleanup. Independent focused
controls pass 170 setter cases, 13 enabled cases and 211 composed startup cases.
Selected final-source local gates pass formatting, 357 JS checks, 14,253
portable macOS unit cases and 101 macOS E2E checks with one host-specific skip.
Hosted native/package/install and physical/global acceptance remain pending.
No TODO item is removed.

## Continuation: Linux obsolete TapHold shapes

The independently reviewed V3 packet has SHA256
`ac6c1171811d2f21fc138aa26ea03aac20885a73de1b5f0fbb99965ee05b9c89`.
Nine unchanged preimages and their exact postimages match its manifest; the
shared scope transaction is a conflict-free composition with the reviewed bulk
recovery change on their verified common base. Optional canonical receipts
preserve nested empty arrays and unchanged numeric tokens through real writer
and scope owners, including signed64 integers on LuaJIT. Existing corpus and
assertion files remain unchanged. Focused author checks pass 368 cases per Lua
runtime; independent review passes 93 new cases and three Python TOML oracle
operations per runtime. Its separately reviewed codec alias successor is
`b5d89eae194147de2bfd7d926f9da344a4e237381c7fe7ee6dae97d51b1059f1`;
it retains the optional integer-subtype guard while satisfying the unchanged
LuaJIT source rule. The explicit Linux test manifest retains all 362 original
module names and adds the three real new modules. Selected local gates pass
formatting, 357 JS checks, 14,226 portable macOS and 6,853 Linux unit cases,
101 macOS E2E checks with one host-specific skip, and 188 Linux E2E checks.
The first V3 execution ended before a final verdict; the V4 gate exposed the
missing manifest registration before any Linux unit execution. The covering
JS and Linux gates pass after registration; other completed V4 gates remain
unchanged. Hosted native, packaging, installation and physical qualification
remain pending; TODO33 is not complete. Existing source-check/rename
observational limits remain explicit.

## Hosted native checkpoint on the retired-preference source

Manual run [37251013173](https://github.com/adrienm7/ergopti/actions/runs/37251013173)
completed with failure. It tests CI SHA
`eb85009310acf2ae43c9f5a49b610cdabba37635`, tree-identical to source
`ba2f964972bd25ab0d7b27657fce4287e6dcc854`, with `os_lanes=macos+linux`.
It does not qualify later installed-record, publication-recovery or Linux-shape
sources. JS/properties, Linux units, portable macOS unit/E2E and validation pass.
Three Linux E2E steps fail: updater ETag receipts, audio locale receipts and
literal notification text. Native macOS packaging fails in actual Sparkle
archive process-census acceptance and actual Homebrew archive AppleEvent
receiver acceptance. The inspected owner files, including the entire native
launcher subtree, equal the current `02ad69` dev checkpoint; equality alone
is not a native baseline replay or proof of cause. Full failed-step logs were
unavailable with Forbidden, so exact underlying native receipts remain unknown.
Dependent packaging/installation is skipped, Windows is deferred to the
maintainer workstation, and Release / Publish is skipped. Final-source hosted
qualification and the owner follow-ups remain open under items16/38.

## Integration coordination

Feature CI may run concurrently on each group's dedicated branch.
Only final dev integration reserves `codex/ci-lock` and `codex/ci-validation`.
Merge without squash, preserve other groups, push immediately and cancel
automatic exact-SHA runs. Final manual validation must test the integrated
sources; do not substitute unrelated unmerged feature sources from an old CI
aggregate. The CI workflow's manual event must keep release publication off.
