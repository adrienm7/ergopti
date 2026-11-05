# Linux WebView and personal editor transaction audit — 5 November 2026

> Canonical integration excludes LVB-002 after the actual logger/error-policy countercheck. See [countercheck report](logs/countercheck-report.md); saved bytes committed and an ERROR/error-window request exists. The original submitted sections below remain provenance, not the confirmed queue.

Audited SHA: `3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a`.
Exclusive source: `/workspace/worktrees/parity-2026-11-05/linux-webview`.
Scope: `linux-webview`. Audit only; no tracked production/test edits or commits.

Two confirmed medium findings: the shortcut hotstring editor's admitted close
command never invokes close, and its save path discards the real reload receipt.
The second has actual Config + hotstring_engine + canonical-writer proof on real
private files. All GTK visibility and JS execution claims remain explicitly
unqualified: this run never opened a live desktop or an offscreen GTK session.

## Architecture and command/feature register

There is no Linux `WEBVIEW` worker/socket command protocol in this SHA. This was
derived from the actual `ergopti_hotstrings.lua`, `ui/webview_manager.lua`,
`ui/webkit_host.lua`, `bin/ergopti-hotstrings`, and driver production source search.
The manager loads LGI and constructs GTK/WebKit2 objects inside the daemon.
`UserContentManager.register_script_message_handler` and its detailed signal ID
are the page input capability. JSCore values are decoded by the shared JSON codec;
`route_message` supplies trusted app/epoch/close capabilities, then calls the
registered bridge in-process. Replies/pushes call `WebView.run_javascript`.
The separate process in routed memory is `ui/native_dialog.lua` → `dialog_host.lua`,
for modal dialogs; it is not this WebView transport. Partial lines, short writes,
socket EOF and worker process exit cannot be attributed to a nonexistent protocol.
Renderer termination is the corresponding actual process boundary and is covered
by the native port cohort. No worker/socket protocol was invented in a fake.

The manager's exact app registry is config_cleanup, action_picker,
physical_shortcuts, changelog, download_window, error_dialog, healthcheck,
hotstring_editor, hotstrings_config_window, layer_editor, metrics_apps,
metrics_typing, model_browser, onboarding, layout_manager, paths_editor,
personal_info_editor, numeric_prompt, prompt_editor, token_prompt and update_check.
Only changelog/download_window/model_browser use the additional document nonce,
generation challenge/ack ledger; ordinary editors use native page epochs.
Business commands for unrelated registered apps were not audited by this cohort.

| Surface / owner                                     | Admitted command / feature                                                                                                                                                                    | Actual consequence and tested boundary                                                                                                                                                                                                                   |
| --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Manager                                             | show, hide, toggle, bring_to_front, current_epoch, page_current, route_message, eval_js, shutdown                                                                                             | Real manager over faithful LGI constructor/signal/view/window/pump ports. Provisional acquisition, failed/debt retention, input release, stale epochs, renderer death, duplicate callbacks, cleanup/refocus reentry, retired-message and push admission. |
| Manager document lane                               | load STARTED/FINISHED, nonce read, initialize/confirm document, document ack / envelope                                                                                                       | Shared real document lease + Linux managed-document callers; generation/timeout/retirement cohort. Actual luv deadline expiry/cancel/close/reentrant successor controls.                                                                                 |
| action_picker / action_picker_bridge                | ready (bare or structured); confirm(id,parameter,providerKey,programArguments); cancel                                                                                                        | Actual bridge + ProgramProviderPicker, callback refusal/throw, session replacement and successor-close controls. Captured provider choices remain session-owned. No process is run by the picker itself.                                                 |
| hotstrings_config_window / hotstrings_config_bridge | bare ready/refresh; set_delay(ms), clear_delay, set_color(hex), clear_color, set_tooltip(show_tooltip), clear_tooltip, set_priority(priority), clear_priority, set_all_grey, reset_all, close | Source-traced actual config set/clear receipt path, milliseconds→seconds, per-field personal source binding, push setData and owned close. Bulk operations are sequential; atomic bulk transaction is not claimed.                                       |
| hotstring_editor / hsEditor                         | ready, save(data.sections_order/sections), save_pref(compact_view/auto_close/default_section), window_focus(focused), close                                                                   | Actual bridge, canonical source reads/parsing/write and actual Config/engine refusal proof; exact opening bytes, path/epoch, owned retry, new-section enable; real input gate is the focus owner. close has LVB-001; reload receipt has LVB-002.         |
| personal_info_editor / hsPersonalInfo               | ready, save(values), cancel                                                                                                                                                                   | Actual dynamic manager capture_info_edit/save_info, TomlWriter CAS, Config.reload, private info file; stale source and unknown field refusal, healthy live value, close/cancel/late-save controls.                                                       |

Generic personal-TOML editing: Linux does not register `personal_toml_editor`;
`test_webkit_host` explicitly expects its absence. The nearest actual dedicated
capabilities are the structured `hotstring_editor` for `personal.toml` and
`personal_info_editor` for the generic `[info]` fields in `personal_info.toml`.
The latter displays each actual source key, preserves opaque capture/source
receipts in Lua, and refuses adding arbitrary fields from a page. Other TOMLs
have their own owners and external editing paths. A Windows API/name being absent
is not a parity defect. Whether a full generic text editor is a product
requirement is unknown; no finding is claimed from that absence.

## Confirmed findings

### LVB-001 — Shortcut hotstring auto-close never closes the Linux page

Medium severity, high confidence, G2. Shared hotstring script lines1290–1293 sends
`toLua('close', {})` when `openMode === 'shortcut' && autoClose`. Linux bridge
lines694–697 simply log "Hotstring editor closed" and return nil. They never
invoke `context.close_owned_window`, which the real manager supplies precisely
to bind native hide/release to the source epoch. Consequently no native hide or
input release is reached through that command. The probe supplies an accepting
close port and records **zero calls**. This proves the native call is absent;
it does not pretend a fake window measures actual desktop visibility.

Healthy control: the 217-case cohort drives actual manager hide/delete and
retirement; the personal-info probe calls its actual close capability on healthy
save and cancel. Refusal/stale controls in the cohort require retained native
debt and protect replacement epochs. macOS's actual handler calls `M.close()`.
The independent shared-page issue of posting close before save acknowledgement
belongs to the macOS/shared-page review and is not duplicated here.

Regression: join actual shared auto-close to the actual Linux bridge/manager and
assert exact epoch native retirement/input release; reject stale commands and
retain refusal debt. Do not merely assert the close string exists.

### LVB-002 — A real reload refusal still returns saved success

Medium severity, high confidence, G2/G5. `save_all` commits canonical bytes and
then uses only `local ok_reload = pcall(config.reload)` (lines469–475), discarding
the actual return values. It returns true even for refused or throwing reload.
`Config.reload` already returns `count, committed, cause` from actual `load_all`.

`probes/editor.lua` displays the real editable source, creates a **new** malformed
second TOML (so no healthy cached snapshot can mask it), and saves the valid
personal source with actual Config, hotstring_engine and canonical writer.
The real reload returns false, the physical personal source contains the edit,
and the engine generation stays unchanged. The bridge still returns saved=true
and emits no UI alert. Healthy receipt, false receipt and throwing reload controls
all return the same saved success; the latter logs a warning only. The actual
personal-info bridge is a positive cross-module control: it tests the second
reload result and keeps the page open on refusal. macOS checks reload_toml's
returned committed boolean and notifies on failure.

Regression: require an explicit saved-but-not-live outcome/notice after the actual
catalogue refusal, with truthful persistence state and an unchanged engine;
healthy reload must advance the generation. Coordinate the separate shared-page
immediate saved-toast mechanism rather than treating the JS return as observed UI.

## Reproduction and validation receipts

All probes take `SOURCE_ROOT` as argv1. They do not hardcode the main checkout.
The only absolute tool path is the supplied genuine CI LuaJIT. All files are
synthetic and private; test.runner_home isolates HOME before business imports.
Native file reads/writes and actual luv deadline controls execute; GTK/DOM ports
record calls and model documented native receipts. No live GTK, service, keyboard,
clipboard, network, secret store, user configuration or application is touched.

```
python3 /workspace/scratch/parity-native-ui/linux-webview/probes/sweep.py SOURCE_ROOT replay
```

The driver wrapper asserts each subprocess's real exit code. It replays:

- `scope.lua`: 217 registered cases passed, 0 failed. It loads only nine focused
  WebView/editor test modules plus document lease/retirement and actual native
  deadline controls; no whole-JS suite, package install or full Linux suite.
- `editor.lua`: healthy/refused/throw reload controls; zero close calls;
  actual reload=false with committed private bytes and unchanged real engine.
- `personal.lua`: stale/unknown refuses, actual synthetic dynamic value updated
  on healthy save, cancel exact bytes preserved and late save refused.

`logs/dry-1-*.log` and `logs/dry-2-*.log` retain the complete receipts. The actual
deadline cohort reports four controls, including expiry timing in a bounded
20–1000 ms window, native-close acknowledgement, cancel, callback exception and
reentrant successor retirement; no timer handles remain.

Initial cohort attempt `scope-initial.log` had three fixture setup failures: it
loaded the timing registry for the first time while a physical-host test had
temporarily replaced a source-reading port. The production runner explicitly
preloads `infra.timings` before these fixtures. Adding that same genuine preload
to this standalone harness made the unchanged cases pass (scope-preload.log);
the failures were not laundered into product findings or skipped cases.

The required false-green scanner completed within baseline, `0 vs 0` in
`logs/false-greens.log`. This does not certify fixture fidelity. In particular,
the existing opening fixture's reload stub returns a bare true while the actual
Config API returns count,committed. The actual refusal proof intentionally uses
the real Config instead. Native LGI return/currentness assertions are behavior
checks; they still cannot qualify real WebKit asynchronous JS execution.

## Two complete dry sweeps after the final new root

No fixed finding quota was used. The new-root counter was reset after LVB-002's
actual refusal proof. Two consecutive review/replay passes then covered the
entire bounded register above with **zero additional roots**. These are reviewer
determinations, not automated bug-discovery assertions printed by the harness.

1. Dry sweep 1: rechecked every admitted command, source/epoch ownership through
   publication, success/refusal replies, selection/callback order, hide/reopen/
   cancel, native acquisition/debt and renderer termination. Replayed all three
   probes; 217/217 + both adversarial/control programs exit0. New roots: 0.
2. Dry sweep 2: independently revisited timing/currentness, repeated callbacks,
   source replacement, optimistic shared UI feedback, bulk scope semantics,
   retained sessions and monotonic/native handle cleanup. Same complete replay
   passed, no skipped case. New roots: 0.

## Refutations, watch list and limits

| Candidate                                                                 | Evidence / disposition                                                                                                                                                                                                                             |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Linux WebView worker framing/partial-line/short-write/EOF                 | No such worker/socket lane in the actual production path. Native signal/JSCore/renderer boundary audited instead. Not a missing capability.                                                                                                        |
| Failed native allocation reported as visible                              | Actual manager requires created==true and cancels/retains cleanup debt; headless refusal and constructor/signal/child/window retirement controls pass.                                                                                             |
| Stale native messages or late renderer callbacks mutate replacement       | Actual captured source_epoch and app/bridge pair route guards plus native identity/debt controls pass; stale lifecycle callbacks cannot retire a successor.                                                                                        |
| Personal-info stale-source overwrite or unknown-field insertion           | Real dynamic manager/writer proof refuses both, keeps exact foreign bytes, and does not close the page.                                                                                                                                            |
| Personal-info successful save skips reload/close                          | Actual dynamic value and Config reload/close receipts pass; handler checks committed reload result, unlike LVB-002.                                                                                                                                |
| Personal reset_all absence is automatically a gap                         | Linux clear_override intentionally refuses a nil field for canonical personal files; macOS bulk operations explicitly target common categories. Product scope for applying reset to every personal TOML is not established; no finding.            |
| Linux bulk grey loops personal files while macOS limits common categories | Source difference retained as policy/currentness hypothesis. No reachable harmful mismatch established, no finding.                                                                                                                                |
| Action picker session retained after external native close                | Handler has no on_window_closed callback; one active session/provider capture can remain until next open. No production is_open consumer or unbounded growth demonstrated. Bounded memory watch item, not a leak claim.                            |
| Shared HCW unlimited-zero field                                           | Confirmed source join for coordinator's Windows/shared finding: Linux fields_for emits to_ms(0)==0 and delay_overridden=true; shared bindDelay's falsy fallback substitutes the default. Root owned by Windows/shared review, no duplicate LVB ID. |
| Shared hotstring saved toast before native acknowledgement                | Shared script calls persist then close; page feedback is coordinated with macOS. LVB-002 is specifically the independent Linux returned-reload contract violation.                                                                                 |

Performance: no live desktop latency measurements, so no G4 regression is claimed.
The focused timer timings are native deadline verification, not end-user UI speed.
Synchronous personal source/TOML work and sequential bulk operations remain a
watch list for large files; no measured budget violation was manufactured.
Memory: actual timer handles retire to baseline in the native controls; manager
GTK pump is process-wide, resource-debt retention is intentional. No RSS/native
renderer stress campaign ran. Ordinary page pushes acknowledge submission, not
DOM/JavaScript completion; no actual WebKit load/JS error qualification is claimed.

Cross-OS: Linux uses LGI/WebKit2GTK, macOS Hammerspoon WKWebView, Windows WebView2.
Different ownership/transport APIs alone are intentional architecture differences.
Known dependency capability: Linux native windows require installed LGI/WebKit;
headless or unavailable native runtime refuses creation truthfully. Generic raw
personal-TOML editing equivalence and full live-native execution remain unknown.

AGENTS and routed Linux/shared/text-config/maintainer policies were consulted,
along with adversarial-audit/report-contract and false-green-tests. Prior
platform-parity reports/TODO were searched for the two concrete roots; neither
was already recorded. The stock audit validator only accepts repository paths
under ahk/hammerspoon scopes, so it cannot validate the user-required external
linux-webview destination. Manifest syntax/required fields/enums are checked by
the local artifact validator; that limitation is explicit rather than changing
tracked tooling or mislabelling the scope.

## Integration boundary

Audited source: `3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a`. Canonical confirmed IDs: `LVB-001`. The submitted manifest is retained separately; canonical classification and counterchecks in the campaign report take precedence. No native three-platform certification is claimed.
