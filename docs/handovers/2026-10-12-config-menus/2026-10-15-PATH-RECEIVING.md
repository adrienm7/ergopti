<!-- docs/handovers/2026-10-12-config-menus/2026-10-15-PATH-RECEIVING.md -->

# Personal watcher and paths-editor receiving

This checkpoint follows freshly fetched Dev
`0ba71fa72c09f012c13545c9d9c5236ebf92358c`. Root is qualifying a separate
release candidate and queues new feature integration. No new Dev or Main push
is claimed here. Preserve every published feature commit and Root's current
workflow, runner, registration and proof-helper ownership.

## Published Linux watcher fix

Feature commit `b666a22f72cf3b27e55bef08720f7064348d1d40` changes only
`linux/infra/file_watchers.lua` and its existing unit-test module. The old
recursive visited key lowercased Linux paths and removed trailing backslashes.
Distinct real `Foo`/`foo` and `plain`/`plain\` directories therefore lost one
watch. A configured root ending in a literal backslash armed no watch. The
correction removes trailing forward slashes only and retains the filesystem
root. Existing depth, backend and symlink policies remain unchanged.

All 39 original tests remain an exact 32,904-byte prefix. Ten additional
subjects use real files, directory inode checks and native luv/inotify, then
repeat with the polling backend. Both Lua 5.4 and LuaJIT report original
39/zero, unchanged producer with new tests 43/six, and corrected 49/zero.
The six causal failures are missed reloads; ordinary trailing slashes and
the existing depth boundary remain positive controls. Both runtimes execute
every new subject here. Missing native dependencies produce explicit
non-execution messages elsewhere; they cannot establish this receiving.

Selected `verify-change` completes successfully: 13,768 unit tests across
521 modules, zero failures, and 193/193 E2E cases. E2E uses scripted keyboard
ports; it does not qualify physical input or an installed personal profile.
The first ordinary-sandbox invocation could not create its private `/var/tmp`
fixtures; its 13 environmental failures are retained separately. The original
39 tests pass under supported escalation before the causal producer change.
All observed owned watcher fixtures retire. The new test helper can mask a
secondary cleanup diagnostic after a primary failure; no cleanup success is
inferred merely from its failed assertion.

[The sealed packet](2026-10-15-LINUX-PATH-IDENTITY.tar.gz) has 26 regular
members, SHA-256
`6ed91f3c16f33c91dc4deb59a37cd87e91de3d8753311c5afe70d0da5cb4bd9c`.
It retains original/candidate sources, unchanged-test prefix, exact logs,
patch, focused receipt and subsequent full-gate receipt. The focused receipt's
historical `not_run` list precedes the full gate; `publication.json` records
the later results. Extract into an owned directory and verify `SHA256SUMS`.

Linux-only manual [38704117453](https://github.com/adrienm7/ergopti/actions/runs/38704117453)
tests append-only CI commit `b12fc635dc7e014054ec9e287a959c7d311d2d5c`.
Its tree `559f5e4069659cb0d47206c489adf1353366d728` exactly equals the
published feature code. At this packet's seal the run is still in progress;
no terminal hosted success is borrowed. Prior Group 1 runs are terminal.
Both exact-SHA automatic workflow censuses are zero after the feature/CI
pushes; other manual runs are untouched. The manual selection is `linux` and
the current Release job remains push-only. Receive terminal counts, package,
installation and launch separately before integration qualification.

Windows has no corresponding recursive personal-directory walk; macOS uses
one recursive native watcher. This Linux fix does not qualify either native
host or change case-sensitive filtering on a macOS volume.

## Inactive shared paths-editor proposal

Native ready/navigation deliveries can both call the same document's
`initData`. The current shared page replaces both folder fields every time,
overwriting typed, cleared, picked or Reset intent. The proposed page retains
each edited field independently while refreshing translated labels, defaults,
tags and pristine companion fields. A new document starts afresh.

[The source proposal](paths-editor-inactive-proposal.tar.gz) has 26 regular
members and SHA-256
`149ebadf2abeeee18e586e336ea9adcc1ab9a6ccdd464f65f236f4c1532e0868`.
It contains exact preimages, final sources, lossless patch and independent
Node causal controls. Only shared `ui/paths_editor/{script.js,index.html}`
and new `tools/test/test-paths-editor-page.cjs` are proposed. The HTML versions
the changed script as `script.js?v=1`; native inline loaders already handle
asset queries. No locale dictionary or native producer is changed.

The same test runs the real HTML/script/host bridge through three native-port
shapes and all 21 locale dictionaries: literal six cases passed/103 failed,
candidate 109/zero, literal six/103, restored 109/zero. Cases contain multiple
assertions; this is not a count of assertion calls. Source seals reconcile
all 25 captured files in every phase. Repository-configured formatting and
Node syntax checks pass. DOM/native-port doubles do not establish WebView2,
Cocoa or GTK acceptance.

Separate [genuine GTK receiving](2026-10-15-PATHS-EDITOR-GTK.tar.gz) contains
194 regular members, SHA-256
`a8cca0a0bd6c9769588d3c635658aa44d930865e4c453fe3d18d524e8f48e108`.
The production Linux Manager, WebKit host/bridge and path writer receive the
same two-asset overlay: candidate 174 assertions passed/zero failed, literal
71/five, restored 174/zero. The five failures identify lost user intent after
the real duplicate-ready response. Their later assertions are unexecuted.
All six candidate/restored cases execute actual Save, bootstrap persistence
and fresh-process reopen; the untouched literal control also does so. All
2,361 captured sources reconcile and cleanup has zero errors in each phase.
Actual native Browse, installed GUI, physical input, Cocoa, WebView2 and an
already-running installed logger sink remain unqualified.

The page proposal remains inactive. Root must compose one direct CHECKS entry
in `tools/test/run-js-suite.cjs` and
`package.json` alias `test:paths-editor-page` pointing to
`node ./tools/test/test-paths-editor-page.cjs` in the same integration.
An orphan test or missing mechanical alias fails existing guards. Group 1
does not edit those owned enrollment paths or hide cases in another module.
Run the full selected gates on the actual composition, then affected-OS
manual CI on all three hosts; preserve every original assertion and exact
source identity. The [ready-source handoff](https://github.com/adrienm7/ergopti/issues/86#issuecomment-6187614338)
provides byte-exact API blobs for both packets and requests enrollment after
Root's frozen candidate, without interrupting its gates.

## Remaining acceptance

None of TODO 5/7/33/42/54/81 or transversal 16/38 is complete. The Personal
proposal remains inactive and its four constructors still need current shared
composition and genuine Windows receiving. Current public Windows Snapshot
refusal is distinct from Root's newer private receiving; do not copy results
between their SHAs or silently update source pins.

A source audit also establishes an unfenced Windows onboarding folder-picker
continuation: close/reopen during its unowned modal can publish an old result
into a successor session. The paths-editor picker has the same shape. No
Windows fix or native execution is included in this checkpoint. Receive a
captured-session fence through the genuine picker port, with same-session
success/cancel and retired-session controls, then unchanged full native gates.

Installed acceptance still needs fresh/existing/moved-folder profiles,
refusal and explicit repair, edits and cancellations in both folder fields,
late replies, configuration reloads, real trigger effects and installed
restart on the affected OS. Native-port tests and virtual displays do not
replace those checks. The full additional-diagnostics attachment
`Texte collé.txt` remains unavailable; no instructions are inferred from its
preview. Item 22 stays withdrawn and the website is outside this work.
