# Linux single-use Shift audit

Pinned source: `9c565c88c9a1366a2e9b18c1b9d2868509510975`. Two distinct source roots are confirmed: **OSL-001**, CapsLock plus physical Shift defeats the title-case optimization; **OSL-002**, repeating the first wrapped letter unexpectedly stops the keyboard input session. No production or registered test code was changed.

## Evidence boundary

`public-probe.lua REPO` executes the original tap-hold Manager, Hook, Engine, shared policy, layout owner and actual XKB adapter. It loads the existing integration test's native session factory up to a checked delimiter; it does not copy or replace production bodies. Recording native ports provide an explicitly simple Latin layout whose letter case is CapsLock XOR either Shift. Native keysym metadata identifies left/right Shift, left/right Control, Alt, AltGr, Super, CapsLock, Return, Tab, Backspace, Escape, Delete and arrows. Thus the Ctrl and Shift cases exercise the real modifier-role route, unlike a key_sym=nil fixture.

The inverse layout table is an explicit native seam. Source inspection independently establishes that production `backend.inverse` creates a fresh state and clears held, latched and locked modifiers before enumerating output chords. Its A-on-key-30-with-Shift result is therefore consistent with the test table, but this audit does **not** execute libxkbcommon's native inverse builder.

`channel-probe.lua REPO` additionally executes the original Reader, broker and Writer through `tests.support.input_owner_fixture.with_manager_session`, with recorded FFI/syscall ports and original issuance/retirement. Its configured action source fixture admits an otherwise unavailable ordered-pair declaration solely to initialize that existing fixture; the decisive trigger is the normal physical RightCtrl standalone tap, never the legacy pair. This does not establish normal public gesture-action admission. Physical source classification, descriptors, native grabs, uinput and a receiving application are not acquired. Wire ACK and the recording character model are not application delivery receipts.

The two final dry sweeps each execute 19 fresh processes: two probes under each genuine Lua 5.4 and LuaJIT, seven registered modules under both runtimes, and one source receipt/root check. Every process has a distinct private TMPDIR. The registered modules total **405 passed / zero failed per runtime**; their total includes collateral tap-hold and input-owner cases and is not 405 distinct one-shot cases. Each sweep repeats the same coverage. The public probe has 20 named asserted streams; the channel probe has five asserted streams (repeat/no-repeat and three lifecycle cases). See the two `final-dry-*` result manifests for exact commands and log hashes. The false-green baseline scan passes at 0 versus 0; it does not certify the native seams.

## OSL-001 — CapsLock with held Shift emits lowercase

Severity: medium. Confidence: high for the original owners over the stated native seam. Property: title-case result correctness.

Reproduce: toggle physical CapsLock on; quick-tap RightCtrl to arm; hold physical left Shift; type A; release Shift; type B. The native capture correctly reports lowercase `a` while CapsLock and Shift are both on. Shared policy requests title `A`. `tap_hold_engine.lua::take_one_shot` accepts any inverse plan consisting of the same key plus Shift, without checking the live CapsLock state. It presses or retains Shift and consumes the arm. The recording wire's case remains **a**, giving `aB`; the requested first result was `A`. Right Shift reproduces the same root.

Matched controls: CapsLock alone gives `AB`; Shift alone gives `Ab`; neither gives the ordinary first-only `Abc` fast roll. No stale CapsLock state carries between cases: each scenario constructs a fresh actual Capture session. The production inverse's deliberate lock clearing is appropriate for detached output planning, but insufficient as a proof that adding Shift to the currently held state produces the requested title.

A regression should drive the original Hook and Engine with CapsLock ON and each physical Shift, preserve live modifiers and verify the first output title. Test the native inverse separately; do not repair this by changing the asserted recording map. macOS/Windows comparisons are owned by their respective reviewers.

## OSL-002 — Auto-repeat unexpectedly retires the keyboard channel

Severity: medium. Confidence: high. Additional properties: valid input session continuity; matching original output ownership for repeat. This is a loud fail-safe, not a silent success or a proven stuck native key.

Reproduce through the original Reader: quick-tap the default RightCtrl one-shot; press A; send A's legitimate EV_KEY repeat (value 2) before its release. The ordinary Engine tap calls private `arm_one_shot(self, now_ms)` without a guarded input owner. The first A is held with an Engine output-holder identity. The repeat branch only emits that holder when `input_arms[self]` exists. Ordinary physical tap arming has no such guard, so the repeat falls through as a physical-owner row.

The original broker refuses the unmatched repeat owner. Hook logs `Emergency keyboard stop — raw ownership settlement failed (code=30 value=2): refused.` Before fixture cleanup the Hook is inactive, broker debt is present, the original Writer output view is retired, its output has been destroyed and closed once, and both Reader sources have closed. No subsequent scripted A reaches the character callback. Wire before retirement is `42:1 42:0 42:1 30:1`.

The matched no-repeat stream remains active, has no debt, retains its current Writer output, closes no source/output before teardown and produces `Aa`. Wire is `42:1 42:0 42:1 30:1 30:0 42:0 30:1 30:0`. The first Shift down/up pair belongs to the default RightCtrl hold, and is not itself a leak. The recorded retirement proves loss of this input session; it does not prove a real application retains a stuck Shift or that real native descriptors were grabbed.

A regression must include the original broker and matching Writer lifetime, not merely assert Engine row bytes. Repeat and release must retain the original holder; preserve guarded logical-arm and refusal controls. The existing registered suites pass despite this original-channel counterexample.

## Intentional differences and rejected candidates

- The shared generic gesture catalogue excludes Linux `one_shot_shift` and `sticky_shift`, with OS Sticky Keys as the documented alternative. That exclusion does not remove the separate Linux tap-hold one-shot implementation. This audit does not report the intentional generic-action absence as a new bug.
- Current canonical Linux key-combination declarations explicitly reject `one_shot_shift`; existing owner-invariant tests' unavailable-declaration fixture does not make those legacy logical pairs a normal supported producer.
- The public Linux producer reads `_shared/tap_hold/one_shot_shift.json`; its result table and magic-key override are covered by registered integration/engine cases. The audited live-XKB probe limits its custom map to letters, space and period; it does not independently claim native punctuation/magic receiving-app proof.
- Ctrl+A preserves the arm and the next B is capitalized. Ctrl+Enter spends it and the next B is lowercase: the five spending controls are classified before text/shortcut lookup. This was cross-checked with the shared reviewer; it is not a proven macOS divergence.
- Left/right arrows preserve the arm; Enter, Backspace, Delete, Tab and Escape spend it. Timeout is inclusive at the 2000 ms deadline; 1 ms later the result is plain. Re-trigger extends the deadline; rearm after a consumed result works. Fast rolling letters release one-shot Shift before the second letter, even when the first remains down.
- Actual original-channel ordinary tap tests additionally prove that pause/resume, Manager reload and Hook stop clear the old one-shot arm. Pause/resume and reload then produce plain `a` with a healthy broker; reload replaces the Engine. The stopped Hook stays inactive.
- CapsWord holds or rides the Hook's CapsLock lock (`lock_caps_for_word`), rather than a separate one-shot Shift state. The physical CapsLock controls characterize that downstream lock combination; this audit does not claim a combined actual CapsWord activation → one-shot → receiving-app execution.
- Registered input-owner tests exercise guarded action callbacks, stale origins, replacement output, source retirement, pause/configuration mutation, partial ACK and refusal; those are qualified owner-invariant tests, not evidence that the currently excluded logical producer is public. No new stale-owner root is asserted from those green tests.
- Existing TODO's completed macOS fast-roll entry and prior Linux CapsWord/expansion-repeat roots are distinct. The exact-root dedup search over all prior audit documents and TODO is retained in `dedup-exact-roots.txt`; no earlier entry with either of these two mechanisms was found. Expansion magic-key repeat is unrelated to kernel EV_KEY auto-repeat here.

## Reproduction

Use `PATH=/workspace/scratch/parity-toolchain/ci-bin:$PATH LOGNAME=agent python3 sweep.py REPO LABEL` from this evidence directory. A managed execution toolchain supplying genuine `lua`, `luajit` and native library dependencies is required. `source-contract.py REPO` checks the pinned HEAD, 24 unchanged source byte receipts and the exact root contracts; these checks are source evidence only. The sweep creates an individual temporary directory for each process and retains logs plus return codes. `run-registered.lua` refuses a zero-case module.

Early `public-initial` through `public-ninth` and `channel-initial` files are retained diagnostic development traces, not final acceptance evidence: earlier fixture attempts included an invalid nil/false XOR, stale Capture state, logger leakage or a benign performance-warning assertion. Only the final sweeps are credited.
