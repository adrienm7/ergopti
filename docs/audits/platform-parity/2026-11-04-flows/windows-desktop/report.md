# windows-desktop: fixed native system-action transactions

Audited SHA: `213d65af24d2aa4845ba47743c9bab6787b61964`.

## Scope and result

Reviewed the fixed native system-action facade, its dispatcher and side-effect/receipt boundary. Window-cycle and generic UI-toggle sources were ancillary comparators; this is not a claim to have qualified every desktop interaction or hardware backend. New actionable entries: 2.

## WDS-001 — Ordinary application quit discards failed window-close receipts

Severity medium; confidence high; G2.

Reproduction: Source-derived, native AHK unexecuted: dispatch quit_frontmost_app from an ordinary nonshared application with one or more live windows. Have native PostMessageW(WM_CLOSE) refuse every window (for example a lower-integrity caller targeting an elevated application). Shared-host control must emit LoggerError on the same false receipt; ordinary branch only logs Asked process ... close its 0 windows. No claim that its message says the app actually closed.

Root cause: GestureSysQuitFrontmostApp in windows/modules/gestures/system_actions.ahk accumulates Sys.PostClose(Hwnd) booleans into Closed and unconditionally emits LoggerInfo, without tracking refused/nonempty candidate count. SystemControl.PostClose preserves a false Win32 return without throwing; outer try/catch cannot report this refusal.

Hidden failure: No warning/error is emitted for all-refused ordinary windows, so the errors-only diagnostic channel misses the user action failure. The zero count is INFO, not a positive completed-success assertion.

Regression: Invoke the actual handler with ordinary/shared process fixtures, all/partial/no refused PostClose receipts, zero eligible windows, and pause. Require explicit failure/partial-result diagnostics for refused live targets, while preserving shell/shared-host and exact target protection.

## WDS-002 — Recycle Bin worker failure after successful launch has no completion observer

Severity medium; confidence high; G2.

Reproduction: The exact production Clear-RecycleBin -Force -ErrorAction Stop body ran under real PowerShell 7.4.6 on Linux with a recording replacement native cmdlet: control exits0; refusing cmdlet exits1. Source-derived Windows integration: Sys.Launch starts the hidden worker successfully; the cmdlet later fails, with no handler polling or callback to report its failure. Windows5.1/AHK/Recycling APIs unexecuted.

Root cause: GestureSysEmptyTrash discards the PID returned by SystemControl.Launch, which calls nonwaiting Run. It only logs Emptying the Recycle Bin. No completion monitor is connected to this worker; unrelated ShellRunner/touchpad trackers do not receive it.

Hidden failure: A hidden child can terminate with a native failure after launch admission; neither its stderr nor exit code reaches the action error channel. The progress log is not misrepresented as an explicit completed-success claim.

Regression: Exercise a genuine owned worker lifecycle: native start refusal, child exit0/nonzero, stderr, timeout/cancellation and late terminal delivery. Keep the action asynchronous and confirmation intact, and report worker refusal without claiming completed success from a launch PID.

## Flow coverage

| Entry family                    | Actual path and checks                                                                      | Evidence boundary                                                                                   |
| ------------------------------- | ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| System appearance/audio/display | Dispatcher -> native read -> write/launch -> result logging                                 | Code and recording ports; no live device changes                                                    |
| Quit/force quit                 | Target acquisition/confirmation -> shell/own-process refusal -> native effect -> cleanup    | Windows source lease checks; macOS owned async/bundle identity; Linux generated shell target checks |
| Trash/eject                     | Confirmation where declared -> asynchronous/native command -> result                        | PowerShell body/POSIX shell fixtures; no actual trash or mounted device touched                     |
| File-manager helpers            | Finder/Explorer/native selection -> filesystem path validation -> open/create/chmod/unblock | Source/corpus fixture checks; clipboard-specific defects belong to clipboard reports                |
| Clear/center pointer            | Adapter contract and refusal handling                                                       | Native mutation not executed                                                                        |
| Ancillary UI/cycle              | Shared close/focus/open and window-cycle source contracts                                   | Not complete native timing/focus qualification                                                      |

## Intentional differences and limits

| Behavior                  | Windows                                                                            | macOS                                                                         | Linux                                                                      | Intent classification                                                                                     |
| ------------------------- | ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | -------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Default microphone toggle | Native endpoint mute flag; pins endpoint between read/write                        | Input level zero then restore prior/default level                             | PulseAudio default source mute toggle                                      | Explicit implementation mechanics; native APIs differ, not proof of identical audio semantics             |
| Long work                 | Deferred AHK timer still runs on one script thread; trash uses child process       | Owned asynchronous process with timeout and exact parent scope                | Background shell protects grabbed keyboard runloop                         | Explicit responsiveness policy; loss of failure reporting is a separate gap, not justified by being async |
| Shell/own app protection  | Refuses desktop shell and protects shared hosts; force quit retains process handle | Refuses own bundle/Finder/Dock/loginwindow and validates application identity | Reads X11 window/type/PID before question; rechecks numeric PID            | Native mechanism differs; incarnation-reuse adversarial native cases remain unqualified                   |
| File actions              | Explorer desktop/current tab and Mark-of-the-Web                                   | Finder paths/Terminal and quarantine attribute                                | EWMH/tool/session prerequisites; no generic Explorer/Finder helper assumed | Platform constraints/equivalents, not interchangeable APIs                                                |
| Theme mutation            | Two native registry values plus broadcast                                          | Native AppleScript appearance setting                                         | GNOME color-scheme setting                                                 | Different platform settings; atomic all-or-none theme update contract not established                     |

## Pass ledger and refutations

- Discovery pass: mapped every fixed facade entry in the named source files and tracked its actual native/async receipt. Findings above are the resulting scope entries; no finding-count target was used.
- First subsequent dry pass: rechecked false/nil/throw, per-target partial results, caller containment, confirmation target capture, native path/argument boundaries and existing test purposes. No additional confirmed finding.
- Second subsequent dry pass: rechecked pause admission, result/cleanup ownership, shared-host refusal, callback generation and alternate caller paths. No additional confirmed finding.
- These are two dry sweeps of the listed facade/receipt scope, not proof that all desktop behavior is clean.
- Windows post-close false is not an exception and progress messages do not claim completed success. No false-success finding was inferred from that wording.
- Windows delayed display-topology pause preemption and HWND/PID incarnation reuse remain hypotheses/native qualification gaps, not additional entries.
- The macOS degraded async registry was inspected: `shell_entry_owned` includes degraded entries, and `release_shell` removes both registries. A leak was not asserted from the degraded spelling alone.
- Linux `execute_action=true` is explicitly a dispatch-name acknowledgment; the finding concerns absence of any failure observer, not changing that documented return contract.

## Validation, memory and performance

No G4 timing claim is made. Test durations are not native desktop latency. The watch-list includes native process handles, retained callbacks, degraded cleanup debt and original target custody; source/recording checks do not constitute live heap/process-retention measurements.

No user clipboard/config/secret, real microphone, process termination, trash, monitor topology or mounted disk was mutated. Native Windows/macOS and actual Linux desktop execution remain open.

`source-receipt.json` is source evidence, `worker-proof.json` is real PowerShell7/fake-cmdlet evidence; `independent-countercheck.md` qualifies both. No AHK probe is reported as executed.
