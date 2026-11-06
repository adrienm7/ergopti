# Deep parity audit by operating system and module

Audited SHA: `89b0b774c8c960c7ad458ac3cb98d5c97598e518`. Date: 2026-11-04.

Six agents reviewed **18 separate OS × module scopes**, each with two bounded passes or explicitly stated coverage. The source tree was kept unchanged during the examination. Root replayed the available safe probes against the real modules and recording/native-dependency fixtures. This is source/model evidence; actual Windows/macOS desktops, touchpad hardware, live providers and real installation were not certified.

## Scope and actionable entries

| OS/module          | Confirmed actionable IDs                                | Report                                                |
| ------------------ | ------------------------------------------------------- | ----------------------------------------------------- |
| windows-hotstrings | AHK-001                                                 | [Evidence and coverage](windows-hotstrings/report.md) |
| windows-input      | AHK-002, AHK-003                                        | [Evidence and coverage](windows-input/report.md)      |
| windows-llm        | None established; policy candidate separately qualified | [Evidence and coverage](windows-llm/report.md)        |
| windows-metrics    | AHK-004, AHK-005, AHK-006                               | [Evidence and coverage](windows-metrics/report.md)    |
| windows-lifecycle  | None established in reviewed scope                      | [Evidence and coverage](windows-lifecycle/report.md)  |
| windows-gestures   | AHK-007, AHK-008, AHK-009                               | [Evidence and coverage](windows-gestures/report.md)   |
| macos-hotstrings   | HS-001                                                  | [Evidence and coverage](macos-hotstrings/report.md)   |
| macos-input        | HS-002                                                  | [Evidence and coverage](macos-input/report.md)        |
| macos-llm          | HS-003                                                  | [Evidence and coverage](macos-llm/report.md)          |
| macos-metrics      | HS-004, HS-005, HS-006, HS-007                          | [Evidence and coverage](macos-metrics/report.md)      |
| macos-lifecycle    | HS-008, HS-009                                          | [Evidence and coverage](macos-lifecycle/report.md)    |
| macos-gestures     | HS-010, HS-011                                          | [Evidence and coverage](macos-gestures/report.md)     |
| linux-hotstrings   | LIN-001, LIN-002, LIN-003                               | [Evidence and coverage](linux-hotstrings/report.md)   |
| linux-input        | LIN-004                                                 | [Evidence and coverage](linux-input/report.md)        |
| linux-llm          | LIN-005, LIN-006                                        | [Evidence and coverage](linux-llm/report.md)          |
| linux-metrics      | LIN-007                                                 | [Evidence and coverage](linux-metrics/report.md)      |
| linux-lifecycle    | LIN-008                                                 | [Evidence and coverage](linux-lifecycle/report.md)    |
| linux-gestures     | LIN-009, LIN-010                                        | [Evidence and coverage](linux-gestures/report.md)     |

The three OS envelopes contain 30 OS-scoped actionable entries: 9 Windows, 11 macOS and 10 Linux. This includes a guarded unfinished capability and a conditional Windows account-context scenario; it is **not** a claim of 30 hardware-reproduced bugs or 30 unique cross-platform root causes. Restore/restart reporting is shared by macOS and Linux, for example. Severity, confidence and reproduction basis are recorded per entry.

## Intentional differences

See the [cross-OS provenance register](intentional-differences.md), its [machine-readable snapshot](intentional-differences.json), and each module report. Policies with explicit rationale, native constraints, guarded unfinished features and intent not established by source are separate categories.

## Corrections to earlier conclusions

- Physical shortcut editing/delivery is not currently available on any OS at this revision. Windows has no host; macOS/Linux both deliberately return false until native delivery integration is qualified. Real GUI/capture code and admitted test fixtures had been mistaken for end-user readiness. Preserve the safety gate.
- Complex-key expansion-delay widening is present on Windows **and** Linux as well as macOS. The integrated macOS hotstrings row is corrected against `windows/infra/hotstrings/hotstring_dispatch.ahk` and `linux/modules/hotstrings/expansion_delay.lua`; older memory wording is stale.
- Windows inline auto-type inserts a completed continuation; it is not token-by-token document streaming.
- WL-001 is not retained as a confirmed defect: its [self-countercheck](windows-llm/peer-validation.md) proves the unguarded deferred mechanism but not the intended cancellation policy after explicit acceptance.
- The broad macOS stop-hang claim was refuted by independent retirement pumps. Private-window key-content suppression was not inflated into an undocumented universal metadata promise. Raw physical-key replay on pause was not called a defect without evidence of an unwanted transformed action.
- Restore overlays preserve later files; no contract requiring deletion was established. The actionable restart-reporting issue concerns visible reload refusal, not rollback of correctly restored bytes.

## Reproduction and validation

The companion OS manifests are [Windows](windows-envelope/findings.json), [macOS](../../hammerspoon/2026_11_04/findings.json) and [Linux](../../linux/2026_11_04/findings.json). The Hammerspoon envelope uses the existing workflow validator. The Windows envelope lives beside this report because the separate AHK audit pass of the same date owns `docs/audits/ahk/2026_11_04/`. Linux uses the same required-field/enumeration integration check; the shared workflow currently has no Linux scope.

- Real local runtimes: Lua 5.4.8, LuaJIT 2.1, LuaFileSystem 1.8, luv/libuv, Node 22.22.2. A real PowerShell 7.4.6 engine ran extracted Windows worker bodies with fake Windows primitives; this does not certify PowerShell 5.1/PnP on Windows.
- Each report records actual commands and outcomes. Earlier missing `luv`, wrong CWD or Node24 NUL expectations are preserved as provenance and superseded only by explicitly recorded successful reruns. Do not sum overlapping test batches as unique coverage.
- The updater qualification test failed because the npx Node binary had two hard links. The [validation addendum](windows-lifecycle/validation-addendum.md) records the unchanged test passing with a byte-identical independent single-link binary; its safety check was not weakened.
- Probes preserve the exact audit checkout paths and native stubs used for observation. Review and retarget the checkout/toolchain roots before replay elsewhere. Run Windows worker probes only through their fake-native harness, not the extracted PnP bodies. Native AHK reproductions are explicitly unexecuted here.
- Proof logs and scripts are compact audit evidence, not replacements for future regression tests covering the actual production boundaries. Each actionable item states the regression that must be added when implementing its fix.

See [integration validation and intervening dev changes](delivery-validation.md) for delivery-time evidence.

## Coverage and stop condition

All 18 named module scopes finished their bounded passes and documented deliberate differences, refutations and remaining native boundaries. This does not prove absence of every possible bug, native timing race or provider interoperability issue. Performance claims require measurements; none were inferred from source alone. Implementation work and native acceptance remain in the repository TODO.
