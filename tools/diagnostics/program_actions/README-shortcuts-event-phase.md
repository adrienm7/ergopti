<!-- tools/diagnostics/program_actions/README-shortcuts-event-phase.md -->

# Bounded readonly Shortcuts endpoint phase diagnostic

The historical run `37565772003`, source `72599cb78fc02d5ae9656d94a8e31d09eb4adbbb`, reached the old JXA checkpoint1 after `Application('com.apple.shortcuts.events')` construction. Checkpoint2 is after `app.shortcuts()` returns. Its missing checkpoint2, stdout0/stderr7, 20-second deadline and exact SIGTERM15 group retirement establish only that the call did not return during that budget. Permission, delivery, receiver activity and the cause remain **not determined**. This diagnostic does not alter or execute any peer-owned probe file.

Apple's public `SBApplication.h` says construction by bundle identifier does not launch the application until an event is necessary. Its timeout is in ticks. `AppleEvents.h` says `AEDeterminePermissionToAutomateTarget` requires an already-running target; `askUserIfNeeded=false` does not prompt, and can return `-1744` (consent would be needed), `-1743` (not permitted), or `-600` (target not running). Those are current-caller API facts, not explanations for the historical JXA wait. JXA `Application` is an OSA API; equivalence to ScriptingBridge internals has not been established. No closed-source implementation cause has been inferred.

The new native comparator is its own executable and code identity, distinct from `/usr/bin/osascript`. Its effective TCC responsible principal remains unproved: distinct executable identity does not prove a distinct effective TCC principal. It verifies the registered target's exact bundle identifier and Apple code signature, then records bounded endpoint/running-target/preflight markers. The preflight is explicitly for `core/getd` in both roles; the opaque SB count event class/ID and its event-specific authorization are not inferred from this getter preflight. Running-instance absence in this observation does not establish that every background service is absent.

Two fixed roles exist:

- `raw-version` constructs only a standard readonly `core/getd` application `pVersion` request. It marks native `AESendMessage` entry and return, uses a 15-second native wait, never-interact/no-record/no-prompt flags, and reads no returned direct-object value. A service-reply verdict requires the actual reply descriptor, matching native return ID, a strictly typed error field, and a read-only sender audit token resolved through Security to Apple-signed `com.apple.shortcuts.events`. Audit-token guest selection binds the sender generation instead of trusting a reusable PID alone. An unavailable audit attribute or exited sender refuses this stronger source verdict. A remote read error can still prove that this endpoint replied; it cannot qualify discovery.
- `sb-count` records ScriptingBridge construction, collection access and count-call entry/return, with the same no-prompt flags and 15-second timeout. Typed native delegate errors remain failures. It never reads names, identifiers or returned catalogue rows. No transport entry is inferred from an SB call marker; internal framework allocation remains unproved.

Each native worker has one **20-second parent deadline**, measured before acquisition and never reset by phases. Native allocation or API calls cannot extend that business budget. Exact inherited-process-group retirement is required before marker bytes are admitted. Unknown/lost reservations retain the process owner and streams without unsafe subsequent signaling or reaping; terminal custody never becomes a fabricated successful timeout. Local worker retirement does not prove cancellation of a remote read, and invocation remains refused by the product. The result keeps the original deadline/preflight/native error codes and the exact retirement receipt. Marker stdout is capped4096 bytes/24 records; arbitrary native stderr is private, with only byte counts retained. No catalogue, user names, identifiers, dictionary dumps or opaque errors are written to evidence.

The wrapper pins its four source files plus the existing native owner to actual committed `GITHUB_SHA`, real hosted CI run/attempt, and the exact historical baseline source hash. It owns a real fixed Clang compilation, signs and verifies that exact product, hashes the signed worker, and rechecks compiler/source/worker bytes. It accepts no caller-asserted compiled helper. Native compilation/signing/API execution is macOS/Python3.13 only. No Sparkle, Brew, product build, privacy grant, TCC modification, dynamic injection or modified native runtime is required. The standalone comparator is observational; it does not relax any picker/program/provider admission.

After Root adopts only these four new paths, an actual macOS CI runner may execute each role separately:

```sh
python3 tools/diagnostics/program_actions/run_shortcuts_event_phase_probe.py \
  --source-root "$PWD" --source-sha "$GITHUB_SHA" \
  --role raw-version --output "$RUNNER_TEMP/shortcuts-event-phase-raw"
python3 tools/diagnostics/program_actions/run_shortcuts_event_phase_probe.py \
  --source-root "$PWD" --source-sha "$GITHUB_SHA" \
  --role sb-count --output "$RUNNER_TEMP/shortcuts-event-phase-sb"
```

`1` means refusal. `2` means partial readonly comparator evidence; it is deliberately non-success. Neither grants product qualification. Run both through independent always-run CI steps and retain their JSON on refusal; do not forgive either status as PASS. A raw-version reply plus an SB-count stall would narrow the problem for this sender/API pair, while leaving the old JXA cause unknown. A native send entry with no return locates the wait inside the called native transport boundary; it does not prove event delivery or receiver execution. A typed preflight/send denial distinguishes this caller's authorization refusal, not historical TCC causation. Receiver presence alone is not readiness.

A separate `native-fixture` role builds with the explicit `ERGOPTI_PHASE_FIXTURE` compile definition and installs a fixed handler in its **own process**. A public self-targeted Apple Event must invoke the handler and return. Its disjoint `FIXTURE` protocol is rejected by the genuine comparator roles. This exercises the actual SDK/native send/handler API without contacting Shortcuts, granting permission or inventing a catalogue:

```sh
python3 tools/diagnostics/program_actions/run_shortcuts_event_phase_probe.py \
  --source-root "$PWD" --source-sha "$GITHUB_SHA" \
  --role native-fixture --output "$RUNNER_TEMP/shortcuts-event-phase-fixture"
```

This fixture also returns2 and proves no service availability. Actual SDK/native fixture, signing, Shortcuts endpoint, TCC and Darwin process ownership are **UNRUN** in the Linux preparation environment. Windows/Linux cannot execute the macOS Apple Event/ScriptingBridge APIs. Portable protocol/custody controls run explicitly through `ProtocolControls` and `CustodyControls`; the three actual local-process controls run on Linux (actual `/proc`/WNOWAIT controls, explicitly not Darwin ABI proof) or actual Darwin/Python3.13. They never silently skip:

```sh
python3 -m unittest discover -s tools/diagnostics/program_actions \
  -p test_shortcuts_event_phase_probe.py -v
```

Source authority: Hammerspoon official pinned1.1.1 `ShortcutsEvents.h`/`libshortcuts.m` establish the exact endpoint and readonly property names. Apple-authored public SDK headers establish `SBApplication`, `AESendMessage`, no-prompt permission semantics, return IDs and audit attributes; these were read through an SDK mirror, not represented as first-party hosting. Official Apple Security `Code.cpp`/`cskernel.cpp` establish audit-token guest selection. Apple documentation endpoints were refused403 by this environment's proxy; no bypass was attempted. The separate private packet freezes exact source URLs and SHA256 values. No actual native outcome or cause follows from those source declarations alone.
