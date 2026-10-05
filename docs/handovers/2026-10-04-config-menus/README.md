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
The other seven packets remain unapplied. Frozen patch bytes and review receipts
are historical evidence and must not be rewritten to reflect new integration.
Each subdirectory preserves its author's source review, dependency/preimage
metadata and bounded qualification notes. The shared-menu dependency order is
Tap-Hold head, Metrics labels, Tap-Hold delay, Wrap controls, then Tap-Hold
guidance. Lua installed-record preservation and Mac Boolean leaves are separate
source families. They require current-source preimage checks and owner generator
runs; never merge generated bytes by hand or regenerate independent goldens.
Do not blindly apply obsolete TODO hunks: compose only group1 notes.

The Mac Boolean packet is applied in the continuation feature branch; the Linux
follow-up diagnostic remains prepared only.
The latter proves scalar-parent replacement and a persisted-action acknowledgement
gap in the existing Linux Tap-Hold writer; it is not an implementation.
Creation-time native publication/cleanup debt also remains under TODO5:
Mac bulk persistence still needs complete inverse ownership after a published
write whose lock release is refused. A partial preparation must not be reported
as a completed global transaction.

The remaining menus still have 96 Windows, 153 macOS and 97 Linux counted sites
in the integrated source checkpoint. Prepared packets lower counts only when
actually applied and qualified. canonicalHoldOptions is already shared and must
not be cosmetically reimplemented. Broader configuration catalogues, native
acceptance and complete global composition remain in their original TODO blocks.

## Integration coordination

Feature CI may run concurrently on each group's dedicated branch.
Only final dev integration reserves `codex/ci-lock` and `codex/ci-validation`.
Merge without squash, preserve other groups, push immediately and cancel
automatic exact-SHA runs. Final manual validation must test the integrated
sources; do not substitute unrelated unmerged feature sources from an old CI
aggregate. The CI workflow's manual event must keep release publication off.
