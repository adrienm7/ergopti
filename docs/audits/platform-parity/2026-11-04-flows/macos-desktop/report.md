# macos-desktop: fixed native system-action transactions

Audited SHA: `213d65af24d2aa4845ba47743c9bab6787b61964`.

## Scope and result

Reviewed the fixed native system-action facade, its dispatcher and side-effect/receipt boundary. Window-cycle and generic UI-toggle sources were ancillary comparators; this is not a claim to have qualified every desktop interaction or hardware backend. New actionable entries: 0.

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

Existing fresh-interpreter controls: system_actions20 cases, window_toggle5 cases, aux_pause_ownership31 cases, aux_deadline_publication3 cases; all passed. system_actions20 was repeated during the dry recheck and must not be added a second time to unique coverage.
