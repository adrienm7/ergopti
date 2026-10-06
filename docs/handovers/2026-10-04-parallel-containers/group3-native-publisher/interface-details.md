<!-- docs/handovers/2026-10-04-parallel-containers/group3-native-publisher/interface-details.md -->

# Frozen optional native publication API for Group 2

Prepared for personal metadata TODO 102 and common migration TODO 104. This is an
inactive interface/evidence handoff, not an installed source change or a claim
that the controllers are integrated. Group 2 owns its distinct hotstring
controllers; preserve the native publisher and shared writer hunks below.

## Frozen source and inactive packet

Base: `origin/dev` / remote `refs/heads/dev`, both verified as
`689d30293704093feab2e3caa077604e88560eb6` by read-only operations.

Packet: [native-publisher-only.patch](native-publisher-only.patch).
SHA-256: `e0fb4e31fd11a12ca46724bc1e10b5d9f6a29b447f5b3fab28ce0fa1ec6ba5a4`.
`metadata.json` records the pinned base, exact old/new Git blob IDs, SHA-256,
byte counts and modes. The patch preserves the exact source delta against that base.
An isolated `git apply --check` against those preimages passed. No repository,
index, branch or remote was changed; the patch was not applied.

The patch contains only these three native publisher dependencies:

- `static/ergopti_plus/_shared/lua/diagnostics/operation_reporter.lua` (new).
- `static/ergopti_plus/_shared/lua/toml_codec/writer.lua`.
- `static/ergopti_plus/macos/adapters/file_system.lua`.

It deliberately omits Preferences, PreferencesTransaction, shortcut/menu
controllers and the TODO 106 product implementation. Their observer contract is
documented below for coordinated reuse. The patch has not been independently
executed as a standalone install; the underlying frozen composed source was
reviewed and tested. Recheck preimages before consumption if `dev` advances.

## Native publication and opaque ownership

The mandatory `FileSystem.write(path, content)` remains a two-argument API and
returns exactly `written, detail` (two values, including a nil detail).

The optional macOS capability is
`FileSystem.write_if_unchanged(path, candidate, expected, on_error)`.
`expected` is an exact classified source: `{status="ok", content=bytes}` or
`{status="absent"}`. Reuse the same exact requested path and prepared candidate.
`on_error` is nil for ordinary operations, or one stable callback instance for
the scoped private operation. The callback receives only a fixed failure
category; its return value is not an acknowledgement. Ordinary nil-policy
failure diagnostics retain their existing concrete arguments.

Ordinary native returns remain `written, detail` (two values). An actual private
native publication or retained acquired-lock release debt may instead return
`written, detail, native_receipt` (three values). Receipt absence is not evidence
that no native operation was attempted. Preserve all returned values on failure.

Native ownership derives from that invocation's acquired replacement mutex and
actual rename/release state. Equal bytes alone never mint a receipt. Validate it
using the optional native port:

```lua
local view = files.publication_receipt_view(
    native_receipt, path, expected, candidate, on_error
)
```

This returns nil unless the native registry recognizes the exact receipt object,
requested path, expected source, candidate and **same callback identity**. Do not
recreate an equivalent callback for verification or retry. A valid view is a
detached `{published=boolean, source={status, content}}`. `published=false` means
a release-only owner with the original expected source, not a successful write.
`published=true` identifies that invocation's candidate publication; it does not
assert that a later foreign edit is absent or that native cleanup is settled.

The publication receipt exposes immutable ordinary Lua access and these bound
zero-argument methods (call with dot syntax):

- `matches_source()` requires the exact observed route and the receipt-owned
  physical source; an equal-byte foreign symlink retarget still fails.
- `is_settled()` reads whether that owner's actual native lock/staging debt has
  finished. It is a native terminal readback, not an inferred writer result.
- `retry()` refuses a changed route/source, releases only its retained native
  ownership, and never republishes candidate bytes. Retain the receipt on false.
  Require `is_settled()==true` after a true retry before dropping debt.

The capability exposes no native handle or mutable native ownership state.
It does not enforce a controller's runtime revision, menu state, epoch, current
configuration path, loaded-source owner or checkpoint; those guards belong to
the controller. Guard them before native retry, before each inverse mutation,
after callbacks/reentrant effects and before releasing the controller fence.

## Shared Writer return shapes

All ordinary call shapes remain unchanged; an optional diagnostic callback does
not itself guarantee a native receipt. `Writer.prepare_batch(..., on_error)` and
`Writer.read_classified(path, files, on_error)` forward scoped failure policy.
The mandatory adapter fallback still calls `files.write(path, content)` with
exactly two arguments. A conditional adapter receives the optional callback.

| API                                                                        | Without a receipt            | With a native receipt                                  |
| -------------------------------------------------------------------------- | ---------------------------- | ------------------------------------------------------ |
| `publish_if_unchanged(path, candidate, files, expected, on_error)` success | `true` (one value)           | `true, nil, receipt`                                   |
| Same API failure                                                           | `false, detail`              | `false, detail, receipt`                               |
| `batch_write(path, updates, files, expected, on_error)` success            | `true, nil, committed_bytes` | `true, nil, committed_bytes, receipt, candidate_bytes` |
| Same API failure                                                           | `false, detail`              | `false, detail, nil, receipt, candidate_bytes`         |

Preserve nil slots with `table.pack`/explicit bindings, rather than converting
the result to a boolean before ownership handoff. With a batch failure,
`candidate_bytes` is the prepared payload, not an acknowledged committed result.
Verify native ownership using this exact payload and the native input source.
The shared Writer transports optional receipt data; only the native registry
proves its identity.

## Scoped Preferences observer contract (outside the inactive patch)

The frozen composed source adds optional parameters:

```lua
Preferences.publish_owned(path, updates, source, on_error, observer)
Preferences.save(path, state, hotfiles, core_modules, snapshot_view,
                 on_error, observer)
-- The function returned by PreferencesTransaction.bind:
save(on_error, observer)
```

Preferences validates the native receipt before invoking `observer(event)`.
Return literal true to acknowledge retaining the handoff. The envelope contains:

```lua
{
    native = native_receipt,
    path = exact_requested_path,
    expected = {status = prior_status, content = prior_bytes},
    source = {status = owned_status, content = owned_bytes},
    published = boolean,
    acknowledged = boolean, -- native writer's original boolean result
    adopt = function() ... end,
}
```

`adopt()` revalidates native proof, physical source and the loaded-source
preimage, and advances only that owned loaded-source view. It does not modify
runtime, issue a save receipt, advance a checkpoint or release native debt.
Preferences attempts this narrow adoption before handoff, but still delivers
the capability when a foreign physical source prevents immediate adoption, so
the controller can retain debt and resume only after exact reinstatement.
The observer must therefore tolerate `matches_source()==false` at delivery.

An observer failure/refusal reports a fixed category; it does not turn the
original native result into success or automatically compensate it. Retain the
verified envelope/receipt through any boolean-coercing setter boundary. The
TODO 106 controller records the allowed owned source and retains unsettled or
unacknowledged native publications under its existing admission fence.

A false native publication remains a false Preferences save. The source view
may honestly identify its partial native publication, but no ordinary full-save
receipt or checkpoint revision advances. Do not infer a successful save from
equal bytes, source adoption, `published=true` or terminal native cleanup alone.
On recovery, retain exact forward and inverse source preimages and separately
verify runtime, current path/epoch, receipt and checkpoint ownership. A foreign
source or revision remains fenced until safely resolved; never overwrite it.

## Exact absence compensation (same publisher dependency packet)

`files.remove_if_unchanged(path, expected, on_error)` requires exact regular-file
bytes under the same cooperative replacement lock and returns
`removed, detail, removal_receipt` when a native owner exists. Parent symlinks
retain their observed route; a newly introduced final symlink is refused.
`Writer.remove_if_unchanged(path, files, expected,
{require_conditional=true, on_error=on_error})` refuses a fallback adapter lacking
the capability. Its optional receipt transport does not strengthen a legacy
compare-before-unlink fallback.

The removal receipt is a distinct existing object with `path`, `expected`,
`removed`, `matches_source()`, `is_settled()` and `retry()`. Unlike the publication
capability, it is not documented as immutable. An acknowledged unlink followed
by native release refusal retains its exact physical inverse. Retry releases
that owner without a second unlink and refuses a recreated file or foreign
route. Validate its exact source/absence, fields and method receipts, then read
terminal settlement before dropping controller debt.

## Evidence and qualification limits

Frozen composed source passed 94 tests with zero failures in five focused
modules: native publication 13, retained program transaction 28, private
publication diagnostics 8, conditional remove 5, program providers 40.
The new 13-case actual stack exercises the native adapter, shared Writer,
Preferences, PreferencesTransaction, real keyboard setter and admission owner
with real temporary-file I/O and doubled `hs.fs` native primitives. It covers
assignment/full-save release refusal, prepublication release-only debt, forward
and inverse recovery, delayed owned inverse adoption, foreign source/runtime/
checkpoint preservation, equal-byte symlink route refusal, capability identity
and unchanged ordinary return counts.

Private in-memory controls omitting native receipt minting produced 3 passes /
10 failures; omitting observer handoff produced 4 passes / 9 failures. Assertions
and production files were not weakened or swapped. Independent read-only
review found no additional bounded recovery blocker.

These are composed-source evidence, not proof for a new controller or a separately
applied three-file packet. Group 2 must supply its own causal controller tests.
Real macOS `hs.fs` interprocess locking and physical symlink qualification still
require native CI. Cooperating Ergopti writers share the advisory lock; a foreign
writer ignoring it can race public Darwin rename, so this API does not claim
pathname compare-and-swap against arbitrary external writers. No full suites,
JavaScript suites, native CI or standalone packet integration ran for this
handoff. Root decides safe publication and consumption.
