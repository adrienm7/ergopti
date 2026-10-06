<!-- docs/handovers/2026-10-04-parallel-containers/GROUP3-CURRENT-CHECKPOINT.md -->

# Group 3 current source checkpoint and remaining work

The [6 October continuation](GROUP3-2026-10-06-CONTINUATION.md) records the newer
Windows provider source, terminal native CI and inactive preparation archive.
The qualification below remains historical and must not override that newer
source receipt or qualify unexecuted Linux/macOS work.

## Current source checkpoint

Group 3 remains **partial**. All 13 assigned TODO items remain open; zero were
removed. All 46 owned commits are preserved through integration in `dev`
`c551412dcabc85ad94a2a2aa7963e353c6552e93`, source tree
`f1c4c3234e97a18fa87c7e414353df5af96c387a`. Upstream `bb37820c` contains four
commits, including item 112 and native fixture/guard corrections, merged through
`4871f5bc` without losing foreign work.

The latest two owned source commits are:

- `b5478b3f`: separate the exact existing audio packages, translated language packs and locale generation into a bounded prerequisite step. The native audio commands and their two-minute deadline remain unchanged.
- `ba940d13`: provision actual distribution prerequisites (`curl` and Debian `libc6-dev`), change only the two fixture-directory owners and add a fourth ordinary-user write preflight. Preserve the two original preflights plus the unchanged suite (three original sudo calls), native-module source pins and assertions.

The sixth manual checkpoint is
[37502849744](https://github.com/adrienm7/ergopti/actions/runs/37502849744),
selecting **Linux only**, on validation commit
`7614ddcb09ccb7833bd90d763d8e8a8b3fa9e7c8`. Its tree matches integrated dev:
`f1c4c3234e97a18fa87c7e414353df5af96c387a`.

**Sixth terminal result: FAILED. Release was skipped.** The Linux E2E job
failed at GTK case 0. This does not complete any of the thirteen partial items.
macOS and Windows were not selected; no sixth-run pass is claimed for either.
Source equivalence preserves the first Windows/shared epoch and all Mac drivers,
native probes and Mac CI sources from the fifth epoch. Their actual component
outcomes remain reusable only at that bounded scope, without a whole-build pass.

| Sixth Linux receipt field           | Observed result                                                                                                             |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Units and E2E                       | Units 9,126 passed/0 failed. E2E failed at GTK case 0.                                                                      |
| GTK portable and genuine operands   | Portable 17 passed/0 failed; genuine case assertions three passed/one failed.                                               |
| Audio setup and native audio        | Prerequisites passed; each of Lua 5.4 and LuaJIT passed six native checks/0 failed.                                         |
| X11/XKB source                      | 53 native checks passed/0 failed.                                                                                           |
| Supervision and window switching    | Five family cases, external recovery one and all 34 window cases passed/0 failed/0 skipped, with physical owner retirement. |
| Modifier hold and ETag              | Hold passed: Apps four and AppsAndTyping five checks per ABI/0 failed. ETag seven checks/0 failed.                          |
| Package and distributions           | Package skipped; all five corrected compiler/ABI/two-directory-write/full-suite recipes unexecuted.                         |
| Install and package-format launches | Nine first-install lanes and three format lanes unexecuted.                                                                 |
| Release                             | Skipped.                                                                                                                    |
| Final doc-only source equivalence   | Passed: every other tracked mode/blob equals source `c551412d` and validation `7614ddcb`.                                   |

GTK case 0's unchanged 100 reads at 20 ms missed its receipt. The fixture worker
exited 1, while the genuine GTK command exited 0 and the exact ordinary-app
identity was observed at native completion and after the worker. No native
stdout/stderr, spawn errno or observer exception was recorded. The first
observer wrapper span was about 2,826 ms, versus about 41–56 ms for the next
three cases. That span runs from before spawn through terminal observation and
includes process creation plus durable start-receipt publication/fsync; it is
not an independently measured GTK-internal duration. The source of the delay
inside application work, scheduling or receipt publication is **undetermined**.

Remaining software follow-up is to isolate this genuine delayed identity
observation while preserving the original assertions, identity oracle, poll
window and deadlines. No specific cold-start cause, native GTK refusal or
budget/retry/warmup repair is established by these facts. The earlier fifth
GTK 4/4 and current sixth 3/4 remain separate outcomes.

On the latest source candidates, before their respective commits, selected
formatting passed 242/242 and JavaScript passed 363/363. The distro candidate's
default selected verification passed. The broader audio candidate verification
could not allocate its native window probe because this container lacks the
required exact kernel child-census path; that gate was not a native pass.

Private distro qualification used genuine UID 1000 and native luv/lfs across
433 unchanged modules. The first full run passed 9,125 checks and failed one
because its owned TMPDIR exceeded the native Unix-socket path limit. With only
a shorter owned TMPDIR, the same suite passed 9,126/0. Three real mode-only
fixture refusals under private directory mode 0555 passed after recovery to 0755. This does not qualify foreign-root chown, installation or all five hosted
distributions; those remained unexecuted in the sixth checkpoint.

Earlier private X11 readiness passed eight genuine readiness observations with
zero application cases; diagnostics passed 17 controls and cleanup passed four.
Portable authentication passed 40 inventory, 19 notification and 33 global
controls. These captured source gates do not replace the sixth terminal receipt
or prove the cause of historical HTTP 403 responses.

## Preserved fifth qualification

The fifth manual checkpoint is
[37494746572](https://github.com/adrienm7/ergopti/actions/runs/37494746572),
selecting Linux/macOS on validation commit
`ad22d30899058661e62e3a7ee2fe37f836c2a6e1`. Its source tree matched fifth-source dev
`4dfbb9a50563ea8680a4e59136e7df1062fef430`:
`47a77762d002422c17212bea65849522bb8ed1e8`.

**Fifth-checkpoint terminal result: FAILED. Release was skipped.** This is
an integrated source checkpoint. The current documentation preserves this
historical epoch; its source-equivalence proof is recorded above.

| Fifth receipt field                              | Observed result                                                                                                                                                                                        |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Linux units and E2E                              | Units 9,126 passed/0 failed; hold passed and ETag seven checks/0 failed. The E2E job failed during audio prerequisite installation.                                                                    |
| Linux genuine GTK                                | Portable 17 passed/0 failed and genuine GTK four passed/0 failed.                                                                                                                                      |
| Linux supervision and 34 window cases            | Five family cases, external-helper one, new X11 preflight, all 34 window cases and the physical-source gate were unexecuted.                                                                           |
| Linux package, distributions and install/startup | Package skipped; five corrected distribution recipes, nine first-install lanes and three format lanes unexecuted.                                                                                      |
| Mac portable units/E2E and Swift                 | Units 15,088 passed/0 failed; E2E 101/101 passed. Swift completed 323 methods: 321 passed, two failed with six failed assertions.                                                                      |
| Mac native inventory and notifications           | Inventory 21 passed; constructor nine passed/0 failed/0 skipped, with native process retirement. No notification delivery or callback invocation was tested.                                           |
| Mac global observations and Shortcuts            | Global prerequisites refused: native switcher, product owner and physical keyboard unqualified; exact refusal reason unobserved. Shortcuts discovery/invocation unqualified, permissions undetermined. |
| Mac native owned-program and tooltip             | Owned-program 14 passed; actual tooltip 12 captures passed.                                                                                                                                            |
| Mac application/package acceptance               | Package job failed; actual app build, smoke, signing and installation skipped.                                                                                                                         |
| Release and source equivalence                   | Release skipped; scoped component reuse preserves exact native sources.                                                                                                                                |

The Linux audio step's unchanged two-minute deadline was consumed downloading
59 prerequisite packages (40.7 MB), before locale generation or native audio
cases. The retained package-manager lock then refused later physical-source
and window prerequisites before native commands. This is an observed setup
failure, not a failed 34-case window execution or evidence of an input defect.
Earlier second/third window qualification remains separate.

Scoped authenticated metadata and anonymous archive acquisition succeeded for
the Mac inventory and notification probes; their genuine cases passed. This
does not establish the cause of earlier HTTP 403 responses or a new global
identity/TCC result. Swift failures remain in the foreign Homebrew/Sparkle
archive acceptance methods; preserve their assertions and ownership coordination.

These fifth-source outcomes remain historical component evidence. The latest
Linux-only source and terminal sixth checkpoint are identified above; no fifth
window or distribution execution is inferred.

## Preserved earlier qualification

The [historical Windows continuation and constructor archive](group3-windows-follow-up/README.md)
retain their original source epochs and immutable archive metadata. Read the
current chapter and TODO first; earlier deferral wording does not define the
current software scope. No archive payload or qualification status changes.

Earlier receipts remain separate from the current source checkpoint. None of
the four failed runs completed the group.

- **First, 37462985994:** Windows units 9,715/0, E2E, packaging, compiled startup/crash and native brightness passed. The separate Group 2 compiled-hotstring check executed 23 cases: 22 passed and one failed before disable at `ProcessExist(Pid)`; these are not installation case counts. Cause unknown. Linux units 9,126/0 and hold passed; GTK passed three with one not observed, and five family controls passed before the external-helper PID-count failure; the 34 window cases were unexecuted and package/install skipped. Mac portable units 15,088/0 and 101 E2E cases passed, as did native owned-program 14, inventory 21, constructors nine and tooltip 12. Swift failed two methods/seven assertions; global native identity was refused despite AX listen/post true, and Shortcuts discovery was refused with permissions undetermined.
- **Second, 37470985920:** Linux units 9,126/0, E2E, package, GTK 4/4, supervision five plus external-helper one, window 34, nine first-install cases and three package formats passed. Each of five distributions recorded 8,803 passes/78 prerequisite failures. Mac portable units 15,088/0, E2E 101/101, native owned-program 14 and tooltip 12 passed; Swift completed 323 methods, 321 passed/two failed/six assertions. Inventory raised `HTTPError` before its 21 native cases; notification/global prerequisites were refused and Shortcuts remained unqualified.
- **Third, 37479728162:** Linux units 9,126/0, hold, ETag, family five, external-helper one and window 34 passed. GTK passed 3/4; the original observer failed although genuine GTK exited 0 and its exact identity arrived late. Package and install matrices were skipped.
- **Fourth, 37484349358:** exact dev `03865321`/validation `0da29570` tree `2495b93c` failed. Linux units 9,126/0, hold/ETag and supervision five plus external-helper one passed; GTK passed 3/4 with native exit 0/late exact identity. Initial owned xmessage visibility setup failed, so all 34 window cases were unexecuted. Integrated distribution repair `41dbb044` had no corrected hosted distribution execution; package/install were skipped. Mac portable units 15,088/0, E2E 101/0, native owned-program 14 and tooltip 12 passed; Swift completed 323 methods, 321 passed/two failed/six assertions. Closed portable diagnostics passed 29/15/29. Release-metadata HTTP 403 blocked inventory, notifications and global before archive/native acquisition: 21/nine cases were unexecuted and no new global identity/TCC result exists. Shortcuts discovery was refused, permissions undetermined. The **Mac Package job failed**; actual app build, smoke, signing and installation were **skipped**, not successful. Release was skipped.

The earlier passing components must remain preserved. Historical brightness
timeouts, GTK failures, the compiled-hotstring failure and HTTP response causes
are not established merely by later passing or refused components.

## Remaining implementation and acceptance

| Item | Software/hosted qualification still required                                                                                                                                                                  | Genuine device/evidence boundary                                                                            |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| 63   | Preserve the native brightness owner; complete installed acceptance and investigate only demonstrated regressions.                                                                                            | Actual luminance; attributable evidence for old timeouts.                                                   |
| 71   | Preserve Metrics retirement/unknown comments; complete full-save, upgrade and package/install/startup acceptance.                                                                                             | No new device-only task established.                                                                        |
| 73   | Preserve translated labels and the 182-entry matrix; historical writer attribution remains unknown.                                                                                                           | Retained historical evidence: one disabled gate/three boot sections do not prove three disabled categories. |
| 91   | Windows workstation continuation: simultaneous chords, delay/copy, hold arbitration and fake-AltGr-LCtrl hook ownership.                                                                                      | Actual key order and AltGr generation.                                                                      |
| 93   | Preserve ordered Linux pairs and historical GTK 4/4; diagnose the current receipt-poll miss, then complete chords, cross-device ownership, remaining actions and physical-host/input/distribution acceptance. | Genuine evdev/device/seat delivery and multi-keyboard acceptance.                                           |
| 96   | Prove picker handoff/layout equivalence, resolve wrap/spacing/shift differences and acknowledge migration before switch retirement.                                                                           | Real precedence, chevron timing and layout/dead-key behavior.                                               |
| 97   | Complete native capture, collisions, joint source/modifier/output custody, Unicode/dead keys and accent migration; qualify actual GUI/bridge.                                                                 | Physical positions/output across layouts and devices.                                                       |
| 98   | Complete the same arbitrary physical key/output or None owner; preserve occupied/unknown records during star migration.                                                                                       | Chosen output, modifiers, layout changes and repeats.                                                       |
| 106  | Preserve native inventory 21 and owned-program 14; record Windows discovery/invocation for the workstation, then complete Linux/macOS providers and real Shortcuts discovery/invocation.                      | Device-dependent automation workflows only.                                                                 |
| 107  | Implement native-HKL and Linux/macOS forced symbol/digit owners with joint provenance; preserve admitted policy/migration.                                                                                    | Actual number-row/repeat/Nav/AltGr/Caps/dead output.                                                        |
| 108  | Complete effective-source retargeting, all-owner collisions and modifier/output transactions; preserve None/overrides and compensation.                                                                       | Actual layout changes and editor-key delivery.                                                              |
| 109  | Preserve native constructor captions/returns; establish supported fresh invisible Variables/KeyHistory capture before separate owned GUI/title qualification, retaining runtime HWND identity.                | Physical history, notification delivery/click or focus outside observable hosted cases.                     |
| 111  | Preserve final Linux supervision 5 + external 1 + window 34; complete Mac broker/wiring and exact retirement qualification.                                                                                   | Genuine dual screens, cursor/focus and moved/closed windows.                                                |

Windows-native continuation is recorded for the maintainer workstation as
requested, including remaining Windows software and native acceptance. Remaining
Linux/macOS software ports and hosted qualification stay explicitly identified,
distinct from genuine physical-device acceptance. Native input/layout/registrar
and hook/source ownership overlaps remain coordinated with Group 5 and Group 7.
Linux/macOS `physical_delivery_available()` remains false until the source,
collision and output owners are jointly qualified; GUI readiness is insufficient.
Keep legacy menus and established logical/None/Delete owners reachable.

The item 109 source audit found no supported invisible fresh capture API:
AHK's ListVars/KeyHistory show/focus its runtime window. Cached Edit text is not
fresh capture, and restoring final focus does not erase a transient native
window. This unfinished Windows software/native ownership contract remains part of
the maintainer-workstation continuation. The audit itself implemented and
qualified no replacement.

Items 16/38 and all foreign TODO blocks remain preserved. New item 112 belongs
outside Group 3. Foreign changes, the seven untracked archive paths and ten
historical archive payloads remain intact. A saved patch, source review or
portable control is not an integrated, natively qualified feature. Remove an
item only after its complete software/native/package/install/device scope is
finished; do not reimplement completed features without demonstrated regression.

## Preserved owned source commits

These 46 preceding non-merge commits remain ancestral to the integrated source.
This documentation commit is additional. The inventory is distinct from native
qualification; the documentation commit must preserve the tested non-document
modes and blobs.

<details>
<summary>All 46 owned commits</summary>

- [4d941187](https://github.com/adrienm7/ergopti/commit/4d941187bfe51a37d27ea12c0b7fde1a7acb6995) — fix(linux): isolate action catalogue dependency fixtures
- [1cea146d](https://github.com/adrienm7/ergopti/commit/1cea146d434fda4793a6c5937763ca812ca56b9a) — docs(actions): correct the French category investigation scope
- [b2e1a02f](https://github.com/adrienm7/ergopti/commit/b2e1a02f4dfb0a01e6bc443216401e7ccd45a412) — docs(actions): distinguish layout characterization from picker behavior
- [d7c8e135](https://github.com/adrienm7/ergopti/commit/d7c8e13514bef49e0a544b1c275cad1ec39d19d9) — fix(ci): provision luv for native shared registry checks
- [1b3f5c18](https://github.com/adrienm7/ergopti/commit/1b3f5c183a71f7ca4fc40f60105acbe5f1b7a462) — feat(actions): centralize native worker retirement ownership
- [50165bb9](https://github.com/adrienm7/ergopti/commit/50165bb976321adabe3e90c53e36dbb8460bfdde) — docs(actions): preserve the native publisher receipt handoff
- [0b4968f0](https://github.com/adrienm7/ergopti/commit/0b4968f0851dbeed8bee4251d520b56f0fef174f) — fix(actions): fence timer retirement to its native close attempt
- [55b15d5c](https://github.com/adrienm7/ergopti/commit/55b15d5cd4ac5b213b9763cd2e2f7b606e90f23d) — docs(actions): preserve Windows PC continuation steps
- [d07eb17c](https://github.com/adrienm7/ergopti/commit/d07eb17c63fe8c8664c0d74def7c0580f544742c) — feat(actions): add owned program and cursor-window actions
- [6b9514fa](https://github.com/adrienm7/ergopti/commit/6b9514fa16e525a043232a16a5c6dfc7efbbc6ba) — fix(actions): provision macOS E2E filesystem identity checks
- [e9c9f240](https://github.com/adrienm7/ergopti/commit/e9c9f240201e13a5022423da4b7487fcbbf351fb) — fix(actions): expose owned program C API to Swift
- [8a4df37a](https://github.com/adrienm7/ergopti/commit/8a4df37a6c67b1074906092fbb5d8362ccb35888) — test(actions): require exact native program receipts
- [1f540e3a](https://github.com/adrienm7/ergopti/commit/1f540e3ab91be5f394b942d825f70fbd9ef3f88c) — fix(actions): qualify owned Linux cursor-window switching
- [e940fc0f](https://github.com/adrienm7/ergopti/commit/e940fc0f470226ec4b50bb904449210a04963840) — feat(actions): discover owned script choices on Linux and macOS
- [5bf40c0a](https://github.com/adrienm7/ergopti/commit/5bf40c0a9a22f28a200d14852b536f1897b02200) — test(actions): observe native Apple Shortcuts discovery in CI
- [ff3a682a](https://github.com/adrienm7/ergopti/commit/ff3a682adb5d033a9f5ee1bba988276441e29441) — fix(actions): unify native application notification captions
- [f5ea6c66](https://github.com/adrienm7/ergopti/commit/f5ea6c66b7305c984aceea5cae9ddde0a9196072) — feat(actions): add owned Linux ordered tap-hold pairs
- [7bfc7bba](https://github.com/adrienm7/ergopti/commit/7bfc7bbaee17720edf98bbf6ca77d48430bc06df) — fix(actions): qualify native provider provenance and retain closed diagnostics
- [31989f94](https://github.com/adrienm7/ergopti/commit/31989f9404017ef23db25be90684ced9221609d2) — test(actions): observe genuine macOS notification constructors in CI
- [7ae2f6e2](https://github.com/adrienm7/ergopti/commit/7ae2f6e251d7cdadbdfc8ca1575c54e2a8f6395f) — test(actions): qualify isolated native macOS application switching
- [6a2aabbc](https://github.com/adrienm7/ergopti/commit/6a2aabbc7adbf4c0c33ac718b039ebf3f98ee8bd) — test(actions): preserve canonical native switcher source identities
- [a3919ddd](https://github.com/adrienm7/ergopti/commit/a3919ddd960d8112501bd2a960c6dee7f007d1da) — feat(actions): configure ordered Linux key combinations
- [bafe2631](https://github.com/adrienm7/ergopti/commit/bafe263165efd3077e13a4203741e9e7683ac39c) — fix(actions): require admission for Linux close callbacks
- [196806a2](https://github.com/adrienm7/ergopti/commit/196806a2bc09458aa3b331fa01549a30f84dc6d2) — test(actions): expose closed native provider diagnostics
- [8da2d430](https://github.com/adrienm7/ergopti/commit/8da2d430503e7b823bf0548ad38e7f63783f29a5) — fix(macos): pass one scalar to native provider JSON decoding
- [6a4ed2d8](https://github.com/adrienm7/ergopti/commit/6a4ed2d87a2c640a43b303a34f9019e83801524e) — feat(shortcuts): add fenced physical editor and source observations
- [8ccb5e06](https://github.com/adrienm7/ergopti/commit/8ccb5e0624734f2273cfd476f0f5ee77dd5fc9d3) — test(linux): retain native token bytes in the raw SQL oracle
- [aa5a3eaf](https://github.com/adrienm7/ergopti/commit/aa5a3eaff4410f560597df1325f557ef47082ea2) — fix(shortcuts): retain the separator before modifier groups
- [ff21724e](https://github.com/adrienm7/ergopti/commit/ff21724e572743138be791220b69fa38d3faa8ab) — fix(windows): claim tree completion before yielding diagnostics
- [da2c5756](https://github.com/adrienm7/ergopti/commit/da2c575646171cd0c104507e99afd459980f24b4) — fix(windows): retain acknowledged program cleanup polling
- [9d88afa7](https://github.com/adrienm7/ergopti/commit/9d88afa75cbc921ce1072c297aeb0d4552ad38ea) — test(linux): load actual typing selectors in native hold fixtures
- [035c604a](https://github.com/adrienm7/ergopti/commit/035c604a50495cdf25639085b8e98d54b651d212) — test(actions): expose closed native parsing and launch stages
- [9fcef640](https://github.com/adrienm7/ergopti/commit/9fcef640b8e55e96d645f6ab756f0e21e8f0448b) — fix(windows): check the program cursor before whitespace lookup
- [ec806129](https://github.com/adrienm7/ergopti/commit/ec8061290a93cca8ea852d7885018e110a737c72) — test(linux): publish native operand receipts atomically
- [089008a1](https://github.com/adrienm7/ergopti/commit/089008a19f1aff8b63e8beb832fbae037f5311c5) — test(windows): preserve exact program fixture source bytes
- [ad32ff97](https://github.com/adrienm7/ergopti/commit/ad32ff97e917401aeceaba63c15b4353bacf86f8) — docs(actions): retain precise software and native follow-up
- [9200e6d0](https://github.com/adrienm7/ergopti/commit/9200e6d050055eaa84f5325ce8253c1fd37e7ee1) — test(linux): distinguish native operand receipt failures
- [384ebc02](https://github.com/adrienm7/ergopti/commit/384ebc02a967622e3b24166c17210841cc3fad8a) — test(windows): observe closed native brightness worker phases
- [26242bcc](https://github.com/adrienm7/ergopti/commit/26242bccb0eef80bd977d646b5a05aba9d863096) — fix(windows): retain ownership of partial program construction
- [0d668abe](https://github.com/adrienm7/ergopti/commit/0d668abe206bdd265d9d5524e30de8d5b9ad2578) — test(linux): preserve native receipts and observe GTK launches
- [41dbb044](https://github.com/adrienm7/ergopti/commit/41dbb0446133f2d39054e5823c69013e271c0f83) — fix(ci): prepare genuine distro LuaJIT unit prerequisites
- [fe4f08ad](https://github.com/adrienm7/ergopti/commit/fe4f08ad448f46b07f3fe98d93018c6ced1671b9) — fix(ci): retain closed native bootstrap refusal facts
- [0244be33](https://github.com/adrienm7/ergopti/commit/0244be337a8781a910dbe70fbcf406be905b106c) — fix(ci): require genuine X11 readiness before GTK trials
- [61367eee](https://github.com/adrienm7/ergopti/commit/61367eeef725fc1bc4e9685b00c72064cb1649c4) — fix(ci): isolate native probe metadata authentication
- [b5478b3f](https://github.com/adrienm7/ergopti/commit/b5478b3fbb2ae6862a07c50c0650c30fd49324f6) — fix(ci): separate audio provisioning from native deadlines
- [ba940d13](https://github.com/adrienm7/ergopti/commit/ba940d131894c94e8e9ea96790ca82e591d9ef29) — fix(ci): admit writable native distribution fixtures

</details>
