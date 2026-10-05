# Native notification constructor observations

This separate probe observes the actual macOS application notification
facade and Hammerspoon 1.1.1 constructor. It never sends, schedules, shows, or
withdraws a notification and never invokes a callback. It does not change user
configuration. Its nine-case receipt is independent of the existing 21 program
provider cases. The macOS package job runs it independently with `always()` and
retains only closed receipts, even if another native check fails.

The official public `hs.notify.new` wrapper registers a function callback before
calling the native `_new`. The fixture retains every genuine returned userdata
before reading its properties, checks identity with the facade's return, and
reads actual caption, subtitle, body, auto-withdraw, always-present, withdraw-after,
and delivered status. Expectations are handwritten, including an empty label,
a missing label, Unicode and a decomposed character, false options and zero.
Exact callback registration is proved by `rawequal` against the public registry;
no callback is invoked. Every acquired callback tag is unregistered and its
absence is read back, including a partial constructor refusal.

Hammerspoon 1.1.1 has no public notification `release` method, and unsent
`withdraw` raises. Neither is used. GC is not claimed to destroy the native
object. Physical retirement of the private Hammerspoon owner process supplies
the final destruction boundary, using the existing owned-process capability
controller. Acquired capabilities are registered before downstream adoption,
retained through retirement/report/cancellation refusal, and released only after
acknowledged native settlement. Retirement refusal remains a qualification
failure even if later retries physically settle the same capability.

The official public wrapper source and C backend were downloaded from the exact
1.1.1 tag and are pinned in `official/sources.json`. The native runner composes
reviewed provider helper `e5a90e628149d29ae93e5dba5675d45ad4e7a51cdea1c2221b11677e439c7c0f`
and unchanged owned-process helper
`d3bc862c737e444f22d84fc32368bb8669360bc33ba6008c208f7bf62001314b`.
It preserves the existing release-asset digest/size, archive census, bundle,
signature and runtime authentication. The actual public constructor provenance
must match the exact official source inside that authenticated bundle; its native
backend and getters must be C functions. Both helpers are executed from a single
captured, verified byte sequence. Sources are checked before launch and after
retirement; the persistent MJConfigFile value is independently read before and
after the private runtime, without writing it.

Hosted invocation requires macOS, Python 3.13+, a live WindowServer and the exact
reviewed helper:

```sh
python3 tools/diagnostics/native_notification_constructors/run_native.py \
  --source-root "$PWD" --source-sha "$(git rev-parse HEAD)" \
  --output /absolute/fresh/private-directory --download
```

The caller owns the fresh output directory. A native successful run requires all
nine cases, exact source/nonce/PID identity, no skips, zero dispatch attempts,
zero callback invocations and no owned tag debt, plus native process retirement.
It produces `receipt.json`, `physical-group.json`, and `summary.json`; failures
produce a bounded `failure.json` after settlement when IO permits. If physical
settlement remains pending, the controller keeps its capabilities and publishes
bounded pending retirement facts rather than claiming completion. Output uses
fixed categories and hashes, never raw paths, exceptions, callback values, body
text or notification titles. This proves constructors and callback registration,
not user delivery, focus behavior, clicks, or accessibility.

Portable qualification here comprises 13 Python controls and four fixture
profiles on both Lua 5.4 and LuaJIT. They load the actual application facade,
shared policy and official public wrapper with a recording-table backend.
Recording tables deliberately fail native userdata/C provenance and can never
produce native qualification. A private facade mutation attempts delivery;
the fixture blocks all three attempts without reaching the recording dispatch.
Removing that safety guard is an independent expected-red control. Partial
construction retains and unregisters the callback tag. The pause-custody omission
also fails independently. The initial LuaJIT harness dependency-path mistake was
corrected in this packet; its original failed log is retained separately from
the successful final controls. No native object was allocated locally. All nine
genuine hosted observations remain NOT EXECUTED until a macOS run qualifies the
committed source SHA.
