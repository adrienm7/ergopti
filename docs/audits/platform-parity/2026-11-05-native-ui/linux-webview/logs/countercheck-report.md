# LVB-002 independent countercheck disposition

Date: 2026-11-05. Source SHA: `3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a`.
This is supplemental evidence; the original report, manifest, probes and dry-sweep
logs were preserved unchanged as requested.

**Recommendation: remove LVB-002 from the canonical confirmed-findings list.**
Retain it as an optional applied-receipt/parity watch item. The original proof
established discarded reload receipts, physically committed bytes and unchanged
runtime, but did not establish G2 silence or G5 false preview. The root's
countercheck identifies a real production error router the original proof omitted.

## Actual backstop

- `linux/ergopti_hotstrings.lua:265-266` initializes the actual error-dialog bridge
  and installs `ErrorDialog.on_error` via `Logger.set_error_observer` before main.
- The real `logger.shim` loads/returns the shared `logger` module. Logger emission
  at `_shared/lua/logger/init.lua:530-534` passes every emitted ERROR to that
  observer (after documented logger dedup/repeat suppression).
- Actual `Config.load_all` at `linux/modules/hotstrings/hotstrings_config.lua:1552`
  emits ERROR `Catalogue reload refused: ... keeping ... mapping(s)` before
  returning its false commit receipt for the malformed-source proof.
- `ui/error_dialog/bridge.lua:414` calls the real shared error policy. On `show`,
  `schedule` at266 requests the native window after the policy's 250 ms delay.
  `open_window` at249 attempts manager.show; if native creation refuses it also
  calls `adapters.application_notifier.send` at255. Native delivery itself was not
  attempted or measured in this audit.
- `script.show_error_dialog` is true by default and recommended=true
  (`_shared/modules/features/manifest.toml:404`). The actual policy intentionally
  limits one window per error signature per session, folds errors while open,
  caps windows to three/hour, and honors user disable. Those choices are declared
  policy, not evidence that this path is wholly silent.

## Supplemental replay

```
/workspace/scratch/parity-toolchain/ci-bin/luajit \
  /workspace/scratch/parity-native-ui/linux-webview/logs/countercheck.lua SOURCE_ROOT
```

The script uses the real logger, real error-dialog bridge/policy/default setting,
real Config, hotstring_engine, canonical writer and private physical files.
`Dialog.defer` is a faithful recording timer port; it returns accepted=true and
records the scheduled callback/delay. Deferred callbacks are not run, so no real
GTK window, desktop notification, user config, clipboard, network or secret store
is touched. The existing fixture's host is still a recording native submission
port, not a live UI model.

Receipt in `countercheck.log`, exit0:

```
OBSERVED_ERROR module=toml_reader template=TOML file read did not commit (failure content withheld).
OBSERVED_ERROR module=modules.hotstrings.loader template=Source '%s' did not commit and has no healthy snapshot.
OBSERVED_ERROR module=modules.hotstrings.hotstrings_config template=Catalogue reload refused: %d source(s) failed without a healthy snapshot; keeping %d mapping(s).
COUNTERCHECK saved=true exact_bytes_committed=true engine_unchanged=true explicit_editor_alerts=0 reload_error_observed=1 default_error_window_requests=1
COUNTERCHECK native_visibility=unmeasured actual_logger_and_policy=true
PROCESS_EXIT=0
```

The original `alerts=0` measured only editor-specific `eval_js` alerts. It did not
measure this actual global Logger→ErrorDialog path. Treating it as evidence that
the user receives no warning was too broad.

## Contract and severity reassessment

The handler returns only `{saved=true}` after the canonical writer commits bytes.
That narrow persistence claim is true in the observed failure. It returns no
`applied=true` or `reloaded=true` claim. Although the method comments intend live
reload and macOS checks its explicit reload receipt, a dropped receipt by itself
is not enough to establish an independent G2/G5 failure when the production
catalogue already loudly announces refusal and retains the healthy runtime.

Keeping a separate persistence/applied receipt would improve the API and parity,
but no additional mandatory product invariant was established in this bounded
countercheck. Therefore assigning a named extra property would merely relabel an
unproven requirement. Do not preserve the original medium confirmed finding on
that basis. The shared page's optimistic Saved toast remains a separate root
under the shared-page coordinator; this countercheck neither refutes nor confirms
that broader failure's actual UI semantics.

The synthetic `reload=function() error(...) end` control is not an independently
reachable real-business refusal proof and must not rescue the finding. The
`personal-source-pending` guard was noticed but no legitimate actual editor-save
schedule reaching it silently was established; it was not mocked or asserted as
reachable. No broad resweep was done or needed. LVB-001's log-only close-command
root is unaffected by this countercheck.
