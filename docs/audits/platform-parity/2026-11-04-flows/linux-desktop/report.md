# linux-desktop: fixed native system-action transactions

Audited SHA: `213d65af24d2aa4845ba47743c9bab6787b61964`.

## Scope and result

Reviewed the fixed native system-action facade, its dispatcher and side-effect/receipt boundary. Window-cycle and generic UI-toggle sources were ancillary comparators; this is not a claim to have qualified every desktop interaction or hardware backend. New actionable entries: 2.

## LDS-001 — Desktop command producer hides both shell acquisition and background child failures

Severity medium; confidence high; G2.

Reproduction: Run actual Gestures.execute_action(mic_mute_toggle,tap_3) with recording os.execute returning nil/exit126 or throwing: no warning/error. Then run its exact command through a real POSIX shell with only a scratch fake pactl that writes a reached marker and exits37: the child failure is discarded, and there is no error diagnostic. Healthy exit control also executes once. No actual audio device or user session is used.

Root cause: linux/modules/gestures/manager.lua run_background wraps os.execute(cmd .. " 2>/dev/null &") in an ignored pcall, so acquisition failure is lost and successful shell background dispatch has no retained child status/error channel. SystemActions fixed commands and multiple direct/handler actions share this producer.

Hidden failure: stderr is redirected to /dev/null and no completion owner exists. execute_action=true only acknowledges a nonempty action name by its documented contract; it is not reinterpreted as a terminal success receipt.

Regression: Exercise the actual public dispatcher and native owned child boundary with construction/launch refusal, nonzero exit, stderr, healthy exit, cancellation and late callbacks. Require observable refusal without blocking the grabbed-keyboard daemon; do not replace asynchronous dispatch with synchronous waits.

## LDS-002 — Overlapping accepted theme toggles lose one update

Severity medium; confidence high; G3. Two distinct accepted bindings launch background shells which both read `default`, both derive `prefer-dark`, and both write it. Two sequential toggles instead return to `default`. Per-invocation gesture admission does not serialize independent public calls; no documented coalescing policy was found.

[Immutable-command probe](toggle-race.py) and [actual public-manager probe](toggle-public.py) execute real POSIX shells with a private fake `gsettings`. The fake returns correctly quoted GVariant values and records completion after atomic fixture-state publication. Its read barrier controls overlap; it changes no actual GNOME settings. [Command receipt](toggle-race.json), [public-manager output](toggle-public.txt) and [independent countercheck](independent-toggle-countercheck.md) retain the controls. This does not establish atomicity or immunity on another OS.

The owner must coordinate accepted read-modify-write operations or use a genuinely atomic native operation. Regression coverage should join independent public bindings to the native read/write boundary, including sequential and refusal controls without blocking the input daemon. The dispatcher return remains name admission, not terminal success.

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

## Initial pass ledger and refutations

- Discovery pass: mapped every fixed facade entry in the named source files and tracked its actual native/async receipt. Findings above are the resulting scope entries; no finding-count target was used.
- First subsequent dry pass: rechecked false/nil/throw, per-target partial results, caller containment, confirmation target capture, native path/argument boundaries and existing test purposes. No additional confirmed finding.
- Second subsequent dry pass: rechecked pause admission, result/cleanup ownership, shared-host refusal, callback generation and alternate caller paths. No additional confirmed finding.
- These initial sweeps did not catch LDS-002. Discovery of that additional root resets this scope’s stopping counter; the post-discovery ledger below supersedes the initial closure.
- Windows post-close false is not an exception and progress messages do not claim completed success. No false-success finding was inferred from that wording.
- Windows delayed display-topology pause preemption and HWND/PID incarnation reuse remain hypotheses/native qualification gaps, not additional entries.
- The macOS degraded async registry was inspected: `shell_entry_owned` includes degraded entries, and `release_shell` removes both registries. A leak was not asserted from the degraded spelling alone.
- Linux `execute_action=true` is explicitly a dispatch-name acknowledgment; the finding concerns absence of any failure observer, not changing that documented return contract.

## Validation, memory and performance

No G4 timing claim is made. Test durations are not native desktop latency. The watch-list includes native process handles, retained callbacks, degraded cleanup debt and original target custody; source/recording checks do not constitute live heap/process-retention measurements.

No user clipboard/config/secret, real microphone, process termination, trash, monitor topology or mounted disk was mutated. Native Windows/macOS and actual Linux desktop execution remain open.

Existing system_actions21 cases passed. `probe.lua` separately records acquisition refusals, throw, healthy launch and genuine POSIX-shell/fake-native child failure.

## Post-discovery closure

The [fresh bounded dry-pass ledger](post-toggle-dry-passes.md) records two consecutive source sweeps after LDS-002: all fixed command state/effect/receipt boundaries, then all handlers and actual shortcut/gesture callers, cleanup and policy. Independent private probe replays corroborated the race. No further confirmed root emerged in those sweeps. `show_desktop` has the same source-level read/modify/write shape and belongs to the same ownership review; it is not independently counted or natively reproduced. This stopping condition is limited to the named facade.
