# Hammerspoon audit scope

Audit `static/ergopti_plus/macos/`. Read `hammerspoon-driver`,
`false-green-tests`, and only the macOS plus workflow topics routed by
`docs/memory/README.md`.

## Dedicated sweeps

- Every native task/timer/watcher transaction: construction, activation,
  publication, callback, cancellation, cleanup debt, and teardown. A file-level
  ownership spelling does not prove every task is pinned.
- Callback visibility. Verify the live boundary before claiming errors vanish:
  timer runtime capture, shell runner, and HTTP client have evolved. Test the
  behavior, not the presence of `pcall`/`xpcall` text.
- Native return contracts. A successful `pcall` does not make false/nil an
  operational success; stubs must preserve real arity and refusal modes.
- Event-tap latency and recovery. `doAfter(0)` is not a worker thread, and the
  bundled native extension handles CoreGraphics disable notifications before
  Lua. Inspect the enabled-state watchdogs rather than inventing unreachable Lua
  handlers.
- Synthetic-input provenance, input-source ownership, pause/reload transitions,
  ignored/private application pass-through, clipboard restoration, and exact
  Karabiner lease isolation.
- All three shutdown paths: `hs.shutdownCallback` and both explicit `os.exit`
  routes. `os.exit` does not invoke the shutdown callback.
- Preview/engine parity across trigger precedence, word boundaries, group and
  feature state, dynamic entries, and stale asynchronous output.
- Recent fixes and sibling sites. Run suspicious test files alone and in the
  suite because `package.loaded` contamination can manufacture a green result.

For G4 evidence, use `perf-profiling`'s Hammerspoon reference. Resolve the live
config directory before reading `hammerspoon/logs/`, and distinguish code-derived
hypotheses from observed runtime evidence.
