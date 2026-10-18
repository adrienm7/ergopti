<!-- tools/diagnostics/apple_shortcuts_probe/README.md -->

# Apple Shortcuts next-provider design and read-only native probe

No part of this preparation is implemented in ErgoptiPlus or native-qualified. Do not advertise Apple Shortcuts availability from the presence of a binary, an empty error-swallowing table, or a fire-and-forget callback.

## Established source contracts

The pinned Hammerspoon 1.1.1 source `extensions/shortcuts/libshortcuts.m` uses ScriptingBridge with bundle identifier `com.apple.shortcuts.events`. Its native `list` loops over `app.shortcuts` and returns separate `name`, `id`, `acceptsInput` and `actionCount` values. The generated `ShortcutsEvents.h` declares `id` as a unique shortcut identifier. Its `run` function searches by NAME, calls `runWithInput:nil`, and returns no completion acknowledgement. Both calls are synchronous on the Hammerspoon runloop. Neither belongs in interactive discovery or the existing acknowledged action execution owner.

The public macOS shortcuts man page documents `shortcuts run shortcut-name-or-identifier` and `list --show-identifiers`, plus input/output path options. The displayed list is human text and does not establish a newline-safe schema. Neither trimming, line splitting nor parsing a presumed identifier suffix repairs ambiguity in user shortcut names. The mirrored man page has no cancellation guarantee. Apple and Hammerspoon documentation domains returned HTTP tunnel403 in this Linux cloud environment; official pinned GitHub source and the macOS man-page mirror were accessible. This network result is not evidence that the API is unsupported on macOS.

Source references:

- https://github.com/Hammerspoon/hammerspoon/blob/1.1.1/extensions/shortcuts/libshortcuts.m
- https://github.com/Hammerspoon/hammerspoon/blob/1.1.1/extensions/shortcuts/ShortcutsEvents.h
- https://github.com/keith/xcode-man-pages/blob/master/docs/shortcuts.1.html (mirror, not a hosted native observation)
- https://support.apple.com/guide/shortcuts-mac/run-shortcuts-from-the-command-line-apd455c82f02/mac (blocked from this cloud session)

## Smallest useful slice

A static owned asynchronous JXA/native discovery role reads structured shortcut identifiers and names from Shortcuts Events. Its output reply must be bounded, validated privately, nonce/source/session-bound and delivered only after exact native process settlement. The attached static `discover.js` is a read-only ABI probe for JXA property/index/count/UTF-8 behavior; those exact native assumptions remain untested. It calls the actual `app.shortcuts()` collection twice, then caps OUTPUT rows64, names4096UTF-8bytes and final JSON65536bytes, rejects duplicate identifiers and a changed count, and emits a closed failure object instead of arbitrary exception text. The native full collection retrieval is not bounded by these output caps. A function `.length` property is never used as a catalogue census. Count equality is an observation, not an atomic catalogue generation lease. Renames or equal-count replacement need exact chosen-ID revalidation at confirm.

Opaque picker keys map privately to the discovered stable identifier. Duplicate names and Unicode/NFD/newline names remain separate structured values; keys are never derived by splitting display text. On confirmation the same provider owner rechecks identifier presence and native CLI identity, then lowers to the existing v1 parameter scalar with `/usr/bin/shortcuts` and literal argv `['run', identifier]`. No name is shell-interpolated. Rename, duplicate names, deletion, same-count substitution, stale session and altered native route require independent tests. Structured ID success must be qualified against an actual safe imported fixture before enabling invocation. Optional parameters are actual Shortcuts CLI input/output options, not arbitrary workflow argv; the existing generic parameter editor cannot claim these semantics automatically.

The current `OwnedProgramRunner` intentionally suppresses all payload output and permits only fixed lifecycle records. It cannot capture discovery JSON without a separate bounded native discovery role. `ShellRunner.applescript` logs arbitrary stderr and generic task exit proves only the leader; it cannot be borrowed unchanged. Preserve generic callers and keep discovery privacy, byte limits, parser and physical retirement in its own owner. Do not add capture to the existing private executable worker protocol merely for convenience.

Cancellation of `/usr/bin/shortcuts` and its inherited process group does not prove retirement of an automation executing in Shortcuts Events or another application/service. CLI exit0 likewise needs actual safe-fixture output/completion evidence. The provider must state this service boundary and refuse any stronger cancellation promise until a native API supplies it. `hs.shortcuts.run` returning nothing is never a completion receipt. Discovery cancellation can discard its result and settle the owned query process; it does not claim to cancel a remote already-delivered read request.

## Actual hosted qualification required

Run the read-only probe with Python3.13 and existing Darwin WNOWAIT/libproc owner on a macOS hosted runner. No database scraping, TCC grants, TCC database changes, sender substitution, Accessibility automation or other permission workaround is permitted. Observe actual CLI help/version/stat/route and structured discovery refusal/success without logging names or identifiers. A zero-shortcut result can qualify empty discovery only; it cannot qualify invocation, Unicode names or lifecycle.

The first `app.shortcuts()` is a real Apple event from the runner's osascript. Without existing Automation consent it raises a consent prompt that nobody answers on a hosted runner, which held the old probe until its twenty-second deadline and orphaned Shortcuts Events. JXA cannot pass an `AEDesc` pointer to `AEDeterminePermissionToAutomateTarget` (observed `bridge_refused`), so the permission preflight is native:

1. `sdk_constants.c`, compiled from the Git-admitted source against the selected SDK, runs with `--permission-preflight`. It builds a `typeApplicationBundleID` descriptor for `com.apple.shortcuts.events` and calls `AEDeterminePermissionToAutomateTarget(desc, kAECoreSuite, kAEGetData, false)`, which never prompts. It prints the closed record `{"mode":"permission_preflight","status":<signed 32-bit OSStatus>,"version":1}`. TCC answers for the responsible process, which the helper shares with the later osascript query.
2. `procNotFound` (-600) means the on-demand Shortcuts Events agent is not running. The probe starts it once through LaunchServices with an owned `/usr/bin/open -g -j -b com.apple.shortcuts.events` (no Automation-gated Apple event, no activation) and repeats the preflight until it is not -600. Every preflight, the start and the catalogue query share the original post-help twenty-second budget.
3. Only status 0 runs `discover.js --native-permission-status 0`, the catalogue query. `discover.js` itself refuses the catalogue without that exact argv or its own JXA preflight returning 0, so a JXA bridge failure never reaches `app.shortcuts()`.
4. -1743 (`errAEEventNotPermitted`) records `permission: "refusal_code_observed"`; -1744 (`errAEEventWouldRequireUserConsent`) records `permission: "consent_required"`. Both are complete observations: the probe exits 0 with `discovery_observed: false`, `catalogue_retrieval_attempted: false` and `reason: "automation_consent_absent"`, and no catalogue Apple event is sent.
5. Any other status, a persistent -600 (`failure: "target_not_running"`), a deadline, a failed start, a refused catalogue or an unretired group exits 1.

Creating an independent safe native fixture is a separate prerequisite. The documented CLI offers run/list/view/sign, not a qualified headless import API. Native Shortcuts Events dictionary creation and the public signed `.shortcut` import/UI path must be inspected on the hosted OS. Do not fabricate a shortcut, scrape/modify its private database, silently grant TCC, run an arbitrary discovered user automation, or count absence of a fixture as a test PASS. If native consent/import cannot be completed on a hosted runner, preserve its exact failure and put that concrete remaining qualification in the device handoff only after the attempt.

## Other installed tool providers

The existing four descriptors already cover `.sh`, `.bash`, `.py` with actually resolved interpreters and executable files. A new tool needs a verified invocation contract, eligible native route and independent fixture, not just a recognizable binary name.

- PowerShell: `pwsh`/Windows PowerShell require native version/edition admission and literal `-NoLogo -NoProfile -NonInteractive -File script arguments` tests, including empty strings, NFD, percent, quotes and exit37. Do not add ExecutionPolicy Bypass. Signed-policy refusals remain visible. Windows PowerShell and PowerShell7 are separate contracts; array/bool/native argument behavior is not interchangeable.
- AutoHotkey: an actual v2 interpreter can admit `.ahk` only after qualified version identity, argv/error-stream/exit and cancellation tests. The application's bundled own AHK interpreter is not proof that a user automation provider exists. Windows-dependent implementation and fixtures remain in the PC continuation scope.
- Batch/cmd: `/c` is shell text with percent/metacharacter expansion; generic executable+literal argv does not establish safe batch forwarding. Do not advertise a literal provider without an independent exact invocation bridge and native evidence.
- AppleScript/JXA user files: owned `/usr/bin/osascript script [args]` needs real native run(argv), exit/refusal/output/privacy tests. AppleEvent actions can outlive the osascript process; qualify service boundaries before offering cancellation.
- Linux xdotool/wmctrl/ydotool: presence alone is not readiness. X11 session/display authority, Wayland protocol/compositor support or ydotool socket permissions and actual effect must be independently qualified. These are tools with argument contracts, not interchangeable script interpreters.
- Application launchers: executable binaries fit existing v1. `.app`, `.desktop`, URI/LaunchServices and Windows shell associations delegate to services; launcher completion is not application lifetime. Native resolved application identity, literal parameter support and scope-specific cancellation must be explicit. Do not reuse unowned AI shell execution.

No shared model version/schema change is essential for ID-based invocation lowered to v1. Shared provider source-type/inventory ports would need an additive automation inventory projector (the current descriptor policy enumerates files and extensions only), while menus, private v1 persistence and existing program transaction owners stay central. Parent ownership/coordination is required before changing shared descriptors, native launcher, labels/locales or CI. Missing honest translated service-boundary/input-option reasons must be reported before any21-language change.

## Prepared qualification commands and receipts

After committing this folder under `tools/diagnostics/apple_shortcuts_probe`, run the independent read-only observer after the21case inventory step in the same macOS job, with an always-run condition:

```sh
python3 tools/diagnostics/apple_shortcuts_probe/run_probe.py \
  --source-root "$PWD" --source-sha "$GITHUB_SHA" \
  --output "$RUNNER_TEMP/group3-apple-shortcuts-probe"
```

Retain `observation.json` even on native refusal. It records CLI help acceptance, every native preflight status, whether the service start and catalogue retrieval were attempted, structured discovery/refusal, exact source hashes, and the registered physical capabilities/retirement acknowledgement for every attempted native operation (compiler lookups, compilation, each preflight, the service start and osascript). The observer, JXA and existing Darwin owner must each byte-match the exact committed SHA before running, and after the query. The wrapper byte/time cap kills only its acquired native group. Names, identifiers, stdout, stderr and arbitrary errors are never stored in the result. After a native preflight of 0, a typed native `errorNumber` exactly -1743 thrown by the catalogue query still maps to a permission-refusal observation and a failure. A probe that refuses before any preflight status leaves permission explicitly `not_determined`. There is no silent grant or inference that empty results mean permission success.

Controlled JavaScript cases execute the actual static JXA source against independent API ports and demonstrate that the native collection function is called even though its JS arity is0, that a permission throw never produces a successful empty inventory, and that every JXA preflight result other than a returned 0, including bridge refusal, and every unadmitted argv sends no catalogue Apple event. Portable Python cases drive the real preflight gate: -1743/-1744 never start osascript, -600 starts the agent once and then observes -1744, a persistent -600 fails inside the shared budget, and 0 runs the admitted discovery and validates its rows. Python tests cover independent Unicode/newline/NFD/duplicate-name packet expectations, refusal/private/malformed/cap behavior and exact registered cleanup receipts on interrupted/failed acquisition. These tests are portable controls, not native qualification:

```sh
node tools/diagnostics/apple_shortcuts_probe/test_probe.cjs
python3 -m unittest discover -s tools/diagnostics/apple_shortcuts_probe -p test_probe.py -v
```
