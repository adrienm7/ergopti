# Isolated native macOS global-switcher probe

This CI probe exercises the OS application switcher in a separate official, signed Hammerspoon 1.1.1 instance and two independently owned AppKit fixture apps. It does not load the product configuration or implement a product action. Genuine macOS execution is required; portable tests cannot qualify native behavior.

```sh
python3 tools/diagnostics/native_global_switcher/run_ci_probe.py \
  --source-root "$GITHUB_WORKSPACE" \
  --output "$RUNNER_TEMP/native-global-switcher"
```

Before the native attempt, run the unchanged 40 Lua controls through their owned temporary-scope runner:

```sh
python3 tools/diagnostics/native_global_switcher/run_owner_controls.py --lua lua5.4
```

Use Lua 5.4: the unchanged probe uses native bitwise syntax and is not LuaJIT-compatible. The runner copies the exact probe and test bytes into a fresh temporary directory, prepares the reviewed version-1 control inventory, invokes the literal interpreter without a shell, preserves its failure status, and removes only its own controlled files. It never writes fixture artifacts into the tracked source directory. Its five Python tests verify scope isolation, exact bytes, inventory refusal, status propagation and cleanup after interpreter refusal; the actual Lua execution remains the qualification of the 40 controls.

The output directory must not exist. The wrapper creates it with mode 0700, downloads and verifies the official archive with the existing provider verifier, compiles the two Swift fixtures, and runs the same persistent controller in-process. macOS, Python 3.13+, Xcode tools and a live WindowServer are required. The reviewed provider helper must match `e5a90e628149d29ae93e5dba5675d45ad4e7a51cdea1c2221b11677e439c7c0f`; the native owner must match `d3bc862c737e444f22d84fc32368bb8669360bc33ba6008c208f7bf62001314b`. Official archive members, signatures and source identities are checked before and after observations.

The fixture requires `hs.accessibilityState(false)` and native AX/listen/post prerequisites. It neither requests nor grants TCC permission. Missing permission is **UNQUALIFIED CI failure**, never a pass or skip.

A successful receipt requires four exact tagged Command/Tab down/up events observed by the owned tap and an independent native frontmost change from fixture A to B. Posting an event returns admission only; it does not acknowledge delivery or Dock consumption. Fixture activation establishes the initial MRU order only. There is no activation fallback after the chord starts, and switcher overlay visibility is not claimed.

Fresh `.hidSystemState` key/flag samples guard physical modifier input. Separate same-request `.combinedSessionState` samples track the posted session modifier debt; local up observation and clear HID state cannot replace terminal session release. Unknown, stale or malformed samples refuse success. These are cooperative observations rather than an atomic snapshot; physical keyboard, virtual HID/remapper equivalence and downstream event consumption remain separate qualification requirements.

Cancellation retains exact synthetic input, task, tap and timer owners until fresh native release receipts acknowledge retirement. The controller retains early-registered process capabilities and WNOWAIT leader reservations until each original process group physically settles. Missing receipts, IO refusal, source revocation or elapsed time cannot authorize a PID-only handoff or blanket kill. An unresolved debt keeps the controller alive. Unexpected hard kill, session loss, external CI timeout and deliberately escaped process groups are explicit limits, not successful cleanup. Path/hash/inode checks are cooperative and do not provide atomic executable-handle admission.

Retain these fixed top-level evidence files with an `always()` artifact step:

- `report.json`: qualification status, source/runtime pins, the native receipt and exact process-capability retirement facts, including pending debt.
- `native-result.json`: event witnesses, bounded HID/session samples and task/tap/timer/session cleanup receipts.

Both files are useful on failure when written; early prerequisite failures can occur before either exists. Capture the CI entry's stdout/stderr separately to preserve that outcome. There is no separate `physical-group.json` in this probe: process facts are embedded in `report.json`. Top-level `tool-*.log`, `a-launch.log`, `b-launch.log` and `hammerspoon-launch.log` are optional diagnostic logs, not closed verdict receipts. Never upload the output directory recursively: it contains copied runtime bundles, fixture binaries, the archive and private launch configuration.

Exit zero qualifies only the isolated observed switch and acknowledged retirement. All other completed outcomes fail the CI entry; retained native debt does not exit. The portable suite has 40 Lua controls and 9 controller, 10 receipt and 2 CI-entry Python tests; their recording ports never qualify native input or a product owner.
