# Windows managed failure callers — scratch proposal

This packet is WIP preparation only and must not be integrated as Windows runtime/UI code in the current merge. The user deferred Windows-dependent work to their Windows PC. Earlier focused portable checks passed on the preserved 29-control reviewed packet; final bounded source corrections and 38 caller controls have not been executed or compiler-qualified. See `WINDOWS-PC-RESUMPTION.md`, `REVIEW-FINDINGS.md` and `validation/RESULTS.md`. Repository sources were read only. The root agent owns composition, registration, review, translations, verification, native CI and TODO status.

## Scope and dependencies

The live Windows updater download failure now has an owned shared-page surface. The legacy `OllamaWV_Show` window has no live callers after winget refactoring and is deliberately untouched. Current Windows model pull opens a terminal against a borrowed Ollama daemon: no registry-side failure receipt or owned completion API exists. This packet does not qualify model enterprise networking and cannot complete TODO 62.

The production cohort requires the already applied shared managed-network policy/AHK interpreter, translated labels, shared download-window `network_failure.js` registration, and review_brew_boundary's final typed staging producer. Versions uses the same adapter from review_archive36's separate packet. The producer must call standalone Presenter only when no native observer already owns the failure UI; the producer author confirmed this behavior in revisions 2/3.

`windows-failure-callers.patch` adds four new files. `presentation-timeout-policy.patch` separately adds only shared `presentation.render_ack_timeout_ms: 5000` against an exact saved root-owned policy preimage. `windows-registration.patch` contains only entry-point/bootstrap and test-runner registration proposals. Do not overwrite the full entry-point or run_all snapshots: other groups own concurrent changes. Review current preimages and apply their exact surgical hunks after the final staging producer is composed. A missing `Updater_ConfigureManagedFailurePresenter` API is not optional and must fail review rather than be hidden behind a compatibility check.

The two existing registration preimages, shared timing preimage and all candidate hashes are recorded in `SHA256SUMS.tsv`. All AHK candidate bytes have a UTF-8 BOM and LF. The source tree preserves repository-relative paths beneath `source/`.

## Common native adapter

`modules/network/failure_host.ahk` exposes:

- `ManagedNetworkFailureWindows_Init(Policy := unset, Ports := 0)`: one explicit root boot owner; duplicate and concurrent initialization rejected.
- `ManagedNetworkFailureWindows_Contract()`: same shared interpreter instance for trusted typed producer parsing.
- `ManagedNetworkFailureWindows_Classify(Receipt, IsCurrentFn, RetryFn := 0, OwnedFolderFn := 0)`: only safe `cause/message_key/evidence/actions` report.
- `ManagedNetworkFailureWindows_CurrentActions(Cause, IsCurrentFn, RetryFn := 0, OwnedFolderFn := 0)`: fresh private native capabilities.
- `ManagedNetworkFailureWindows_PerformAction(Cause, Id, IsCurrentFn, RetryFn := 0, OwnedFolderFn := 0)`: shared action policy, fresh captured request/pause admission and short atomic native opener start.
- `ManagedNetworkFailureWindows_ReportJson(Report)`: safe field projection, dropping upstream URLs, receipts, paths and owner metadata.

Callbacks remain private closures. Settings availability comes from actual Windows URI registration; diagnostics requires a current regular private log and native notepad executable. Folder action requires an explicit trusted owned-folder callback plus a current native directory/opener. The updater staging author claims no owned final download folder, so its standalone surface does not advertise this action. No alternate-backend action is fabricated.

## Exact updater integration

Root boot, after logger/error-dialog initialization:

```ahk
ManagedNetworkFailureWindows_Init()
Updater_ConfigureManagedFailurePresenter(ManagedNetworkFailureWindows_Contract(),
    _Updater_ShowManagedDownloadFailure, _Updater_RetireManagedDownloadFailure)
```

Producer callback takes `Failure(valid, reason, receipt)` and the exact private terminal `Owner`. It admits `download` and `deadline`, preserving the original `verify` flow. Classification reads only the typed receipt; a pure monotonic expiry with an empty receipt remains unknown. It binds `_Updater_ManagedFailureOwnerIsCurrent(Owner)` and `_Updater_RetryManagedFailure(Owner)` from the producer. Invalid envelopes receive an empty receipt, never guessed stderr classification. Delayed retirement closes only a window still bound to the exact retired owner.

## Native window and page boundary

The new `ManagedDownloadFailureWindow extends WebViewHost` uses existing `download_window` manifest geometry and the shared `app_update` page kind. It does not edit the generic WebView host or manifest. A unique native virtual-host origin belongs to each window session. Navigation is asynchronous: the admitted actual document URL is captured from a native Source only after it matches the private expected origin/path/cache-buster, then retained exactly. COM sender native pointer, exact Source, window epoch, operation session and failure epoch fence callbacks and deferred scripts.

The private session retains the receipt, owner, callbacks and canonical report. A successor failure advances its same-session epoch. Retry consumes the exact old intent before native retry may synchronously publish a successor; old completion never closes that successor. Native capability probes can reenter, so publication and action admission recheck exact private intent afterwards. Singleton reservation and registry registration use short atomic sections. Teardown preserves foreign registry/singleton replacements.

Only the canonical safe report reaches the page. Native paths/URLs are never read from page payloads. Actual locale bytes are validated and injected before the shared renderer; no language fallback is invented. The page sends a separate `failure_rendered` acknowledgement fenced by session and failure epoch. Queued/native script success alone is not rendered-page proof. Known script failure or explicit negative application acknowledgement surfaces only the current translated cause in a native notice; it invents no action.

## Independent controls, unexecuted

The final new unit file registers 38 actual production adapter/session/window callback controls, with controlled native probes/timers/WebView promises. Receipts and expected causes are manually authored, not generated from the new interpreter. It covers typed TLS versus generic TLS/origin ambiguity, actual unavailable capabilities, private log targets, removed files, pause, replaced request owner, same-session stale Retry, single-use intent, reentrant native probes/publication, strict page protocol, COM sender/document proof, queued script ownership, synchronous retry successors, close/reopen tokens, late native outcome, safe report projection, foreign registry teardown and reentrant singleton reservation. Eight additional timeout controls cover truthful unknown notice/consent retirement, late acknowledgement, admitted acknowledgement cancellation, same-session successors, close/reopen, native-owner replacement, strict integer bounds and actual timer-registration failure.

None of these controls have been executed. Controlled ports do not establish Windows settings, real WebView2 rendering, corporate PAC/SSPI, TLS trust, actual downloads, installation, packaging or physical networking. Do not report them as passed or qualify TODO 62 from this proposal. No original assertions were removed or weakened, and no full/JS/native suite was run concurrently with root verification.

## Remaining qualification

Compose the final producer/Versions packets first. The focused scratch checks are recorded in `validation/RESULTS.md`. Run proportional verify-change on final composed sources and execute the relevant Windows parser/unit controls on a Windows runner; inspect all actual outcomes. Then qualify the live updater path on a Windows runner using the exact candidate SHA, including current owner retry, stale UI after replacement/cancellation, translated rendering acknowledgement, native settings/diagnostics launch, typed certificate/CONNECT evidence, deadline and malformed envelope unknown fallback. No manual release is authorized by this packet.

## Render acknowledgement lifetime and physical cleanup

The native adapter rejects missing presentation timing, numeric strings, floats, zero, negative or values above SetTimer's signed 32-bit positive bound. The native clock port supplies validated nonnegative GetTickCount64-domain integer ticks; each exact failure retains its original start/duration, and a late ACK cannot restart or bypass that budget. The sole timeout value comes from the shared presentation policy. The window arms a retained callback before starting each actual script attempt. Exact positive acknowledgement cancels only that captured attempt; supersession and native teardown cancel the retained physical callback and invalidate its private ownership. A queued timer that survives physical cancellation is inert because its exact work/session/window/failure owner is rechecked.

Expiry preserves the current canonical cause message, retires only the presentation and its action consent, and leaves the producer's terminal request untouched. It does not cancel, retry or infer a new network cause. A late acknowledgement cannot revive the retired presentation or borrow another native operation. Known native timer registration failure retires presentation immediately rather than starting an unbounded script. The final native notice does not hold Critical while its modal is displayed, preserving other operations.

Physical cancellation is attempted with the exact retained SetTimer callback. Cancellation failure is logged after private ownership has already been invalidated; the one-shot callback may remain physically registered until the runtime dispatches it, but it cannot act. Timer scheduling, OS delivery latency and physical resource release are not proved by controlled ports or static checks and require Windows execution. The original non-timeout frozen source files are retained separately under `causal-preimages/`, and the independently reviewed relative-timeout packet under `reviewed-timeout-preimages/`. All 38 actual-caller controls and original-source causal replay remain unexecuted because AHK is unavailable. Private consent/work/singleton/registry are retired atomically before native cancellation or teardown, including during pause; only the captured producer admission controls whether the truthful terminal notice is shown.

Model registry completion, borrowed daemon environment and corporate network matrix remain outside this packet and unresolved. Root keeps TODO 62 open.
