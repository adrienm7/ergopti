# Single-use Shift: Windows, macOS, Linux and shared policy

Audited source: `9c565c88c9a1366a2e9b18c1b9d2868509510975`. Date: November 5, 2026.

Four reviewers examined the same module in separate pinned worktrees: Windows,
macOS, Linux and shared declarations/policy. Consolidation retains **five
OS-scoped findings: one Windows, two macOS and two Linux**. Shared review adds
no independent root. The two Caps Lock/Shift failures share a behavioral shape
but belong to separate platform implementations and remain separate repair
obligations. No production behavior was changed by this audit.

This is a detailed audit of single-use Shift and its immediate owners. It does
not certify exhaustive parity of every Ergopti Plus module or every native input
state. The evidence supports original-owner counterexamples and qualified
source contracts; it does not establish three-platform receiving-application
certification.

## Scope and evidence

The review follows public activation, physical tap producers, re-invocation,
next-key spending, punctuation/magic output, editing controls, shortcuts, real
Shift/Caps Lock, CapsWord boundaries, repeat/release ownership, timeout, pause,
stop and stale callbacks. Every retained finding was reread at its original
source owner during consolidation. Existing tests and earlier TODO/audit roots
were inspected before treating a candidate as new.

[Custody summary](validation/custody-summary.json) records **132 authenticated
source claims across 107 distinct source paths**. Claims overlap between
reviewers; these are file-identity receipts, not 132 independent features or
execution cases. Coverage totals **90 summary records**: 47 Windows aspect
rows, nine macOS area summaries, eight Linux subject summaries and 26 shared
rows. These units differ in granularity and basis. They are not 90 native
scenarios, and repeated sweeps do not increase unique coverage.

The later Linux admission and macOS numeric-domain supplements add six distinct
source paths, giving113 distinct authenticated paths across the combined
receipts. They extend the same findings without inflating the original90
summary records or the five-finding count.

- Windows: 40 lexical source checks over 31 authenticated files, with nonempty
  unique function bodies and reader positive/negative controls. No AutoHotkey
  execution or AHK emulation occurred.
- macOS: original public callbacks, adapter, state owner and shared policy run
  under genuine Lua with declared lifecycle/emission ports. Translation uses
  the original layout parser and a stateless projection of the shipped layout.
  Six registered suites pass 106 cases; the public probe records 22 scenarios.
  These do not run Quartz, Karabiner or a receiving application.
- Linux: original Manager, Hook, Engine, XKB adapter and, for the repeat root,
  original Reader, broker and Writer run over recorded native/system-call
  ports. The public probe has 20 streams; the channel probe has five. Seven
  registered modules pass 405 cases per genuine Lua runtime, including
  collateral owner/tap-hold coverage; this is not 405 distinct one-shot cases.
- Shared: actual policy, Unicode casing, macOS portable state owner and feature
  model/inventory guards execute with declared ports. Each Lua runtime passes
  126 assertions. Twelve candidate capability rows describe origins and policy;
  they are not a complete repository feature inventory.

Root consolidation additionally executed actual libxkbcommon through the
original Linux Capture adapter with an explicit standard US keymap. The
[native-component control](validation/native-inverse.lua) proves that live
Caps Lock plus Shift produces `a`, while the detached inverse plan for `A`
uses the same key plus Shift. It closes the native inverse-builder seam for
that explicit keymap. It does not execute the whole Engine with physical input,
acquire desktop authority, grab devices or prove application receiving. The
Linux reviewer report predates this additional root control; its narrower
native-inverse qualification remains an honest description of that reviewer's
own probe.

## Five adjudicated findings

### OSW-001 — Captured named controls lose original modifier attribution

**Windows; medium; source-derived.** `_SIHO_ReadScalar` returns control name
without the completing modifier chord. `OneShotShift` replays only that name
through `SendNewResult(..., False, False)`. The default non-atomic, nonliteral
production path uses ordinary `SendEvent`. The adjacent tap-key contract
explicitly uses `Blind` because ordinary Send lifts externally held modifiers.

Reproduction to execute on Windows: arm through an independent configured
action, finish its carrier modifiers, then hold Ctrl or Shift and press Enter
within the timeout; compare unmodified Enter and modified Backspace/Delete.
Conditional on the genuine hook completing as its configured named control,
the source requests bare `{Enter}` rather than preserving Ctrl/Shift+Enter.
Native admission, suppression/pass-through, exactly-once delivery and final
receiving were not executed. No duplicate control, application submission or
physical modified-control outcome is asserted.

The same decoder and ordinary bare-key replay occur in the sibling `DeadKey`
control branch. This is one shared capture/replay root, not another independent
finding or a full dead-key audit. Existing meta checks pin end-key spelling and
order; native scalar fixtures require physical modifiers released, and do not
assert original modified controls at a target.

Regression direction: retain the original completing modifier identity through
capture and replay, plus final destination/admission. Include modifiers released
between capture and dispatch. Adding `Blind` alone preserves live modifiers,
which may already differ from the captured chord. Preserve unmodified controls,
exactly-once delivery, pause/rearm refusal and scalar ownership guards.

### OSM-001 — Caps Lock plus held Shift loses the requested title

**macOS; medium; original public callback over a declared translation port.**
The shipped layout translates its `a` key as `a/A/A/a` for no modifiers,
Caps Lock, Shift, and both. Shared policy requests title `A` for captured `a`.
The adapter's predicate tests Shift alone, then `add_shift` applies Shift by
ORing it into the original flags, retaining Caps Lock. Translation remains `a`
and the activation is spent.

The original public callback/adapter/state/policy replay records `A/A/A/a` for
these controls; the failing case keeps raw flags 196608 and emits no replacement.
This is a logical event-transformation counterexample, not physical macOS
application receiving. The decisive source is
`macos/adapters/one_shot_shift.lua::key_down/add_shift`.

Regression direction: validate the complete prospective flags actually applied.
Use serialized title output when that state cannot produce the requested
result, while preserving physical flag and release ownership. Do not simply
strip the user's Caps Lock state. CapsWord may hold the same lock, but an actual
CapsWord activation-to-output experiment was not performed.

### OSM-002 — Programmatic timeout validation publishes values rejected by arming

**macOS; low; original public setter and public arm executed separately.**
`Remap.set_sticky_timeout` accepts positivity before `math.floor`. A programmatic
`0.1` or `0.9` ms transaction therefore commits zero, publishes zero through the
live getter and sends zero to the acknowledged persistence port. Public
`Keymap.arm_one_shot_shift` requires a positive timeout and raises
`invalid one-shot Shift timeout` for that value.

The configuration probe runs the original setter and transaction with remapping
initially disabled. A separate public probe executes original arming with the
same zero value; the real getter/setter source contract links the two. These
are not one simultaneous full application instance. Real disk persistence and
native application failure are not claimed. Controls include 0, 1, 2.5 and
2000 ms. The ordinary menu floors first, so its zero is rejected before commit;
this finding is the public programmatic API invariant.

The later [numeric-domain supplement](macos/validation/config-domain-report.md)
also executes numeric NaN: the setter returns true and publishes NaN through
its live getter and acknowledged save payload; separate public arming rejects
the same value. NaN bypasses the `value <= 0` guard. Positive infinity is
accepted by both owners and remains active at a recorded clock of1e12, whereas
a1ms control expires. That characterizes programmatic behavior, not a supported
unlimited menu choice or actual persistence. The setter fixture uses a no-op
logger; a separate original shared formatter execution confirms its protected
format fallback handles these nonfinite numbers without raising. Full native
logger transport is unexecuted.

Regression direction: validate the final positive integer domain before
mutation, including NaN and fractions, and validate numeric configuration
leaves on load. Define the infinity policy explicitly rather than assuming
that positive means finite. These observations extend the same timing-domain
root and do not increase the finding count.

### OSL-001 — Caps Lock plus physical Shift defeats the title optimization

**Linux; medium; original-owner execution over declared native ports, plus the
qualified native-component control above.** `take_one_shot` accepts an inverse
plan consisting of the same key plus Shift, without validating the live locked
state. With Caps Lock and either physical Shift, captured `a` requests `A`;
retaining/adding Shift still produces lowercase. The recording stream is `aB`
and the arm is spent. Caps Lock alone gives `AB`, Shift alone gives `Ab`, and
neither gives the expected first-only `Abc` roll.

The original public Hook/Manager/Engine path executes; the reviewer inverse
and character model are explicit ports. Root's actual libxkbcommon control
independently confirms why a detached, lock-cleared inverse plan cannot prove
the output under live Caps Lock plus Shift. No desktop/application receipt is
claimed. This is the Linux counterpart of OSM-001, with a different predicate
and native state owner.

Regression direction: drive original owners with Caps Lock and each physical
Shift, retain legitimate physical modifiers, and check the requested first
title using the complete prospective state. Test native inverse separately;
changing a recording map would not repair the source root.

### OSL-002 — Repeat of the first wrapped letter retires the keyboard channel

**Linux; medium; original Reader/Hook/Manager/Engine/broker/Writer over recorded
native ports.** Quick-tap default RightCtrl, press A, then deliver its legitimate
EV_KEY repeat (value 2) before release. Ordinary physical tap arming sets the
deadline without `input_arms[self]`. The first A has an Engine output holder;
the wrapped repeat branch retains that holder only when `input_arms[self]`
exists. The unguarded physical case falls through with a physical-owner row.

The actual broker refuses that unmatched repeat. Hook logs emergency stop for
code 30/value 2. Before fixture cleanup, Hook is inactive, broker debt exists,
the original Writer output is retired and destroyed/closed once, and both
Reader sources are closed. The no-repeat control stays active with no debt and
produces `Aa`. This is an observed fail-safe retirement of the original logical
input session, not a silent success or proof of a native stuck key.

The decisive trigger is the physical standalone RightCtrl tap. The initial
fixture admits an otherwise unavailable ordered-pair declaration solely for
initialization. A [further admission countercheck](validation/public-channel-admission-receipt.json)
removes that declaration override, traps any attempt to load it, and uses an
empty valid `config.toml` plus the explicitly enabled shipped tap-hold preset.
Original production feature getters remain intact throughout. Both Lua5.4
and LuaJIT still reproduce the repeat failure and healthy no-repeat control.
The transport fixture briefly constructs an unused legacy owner/base Engine;
the real Manager replaces them before physical events. This is a reachable
enabled-preset configuration, not the neutral installation being enabled by
default, and it is not generic-action admission. Its28 pin/current source
checks include four additional manifest-reader files beyond the initial132
claims. Native FFI/syscall/XKB boundaries remain recorded ports.

Regression direction: repeat and release must retain the first press's holder.
Exercise the original broker and Writer lifetime, not only Engine row bytes,
and preserve guarded-arm, refusal and no-repeat controls.

## Parity and documented construction differences

| Aspect                         | Windows                                                                            | macOS                                                                   | Linux                                                                                          |
| ------------------------------ | ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Generic action origin          | `one_shot_shift`                                                                   | Equivalent catalogue ID `sticky_shift`, directly arming Keymap          | Both generic IDs intentionally excluded; OS Sticky Keys is the catalogue alternative           |
| Separate custom tap capability | Physical LAlt/RCtrl and configured action routes                                   | Right-Option/default tap and Keymap sentinel/action routes              | Default RightCtrl standalone tap uses custom shared-policy one-shot                            |
| Meaning                        | Capture a complete scalar and transform/replay                                     | Transform one physical press or serialize special title text            | Wrap one physical press or issue shared-policy text                                            |
| Timeout configuration          | Shared 2000 ms; nonpositive/unset constant falls back to 2 s                       | Positive per-user timeout under the driver-specific menu                | Shared 2000 ms                                                                                 |
| Re-invocation                  | Exclusive capture refuses a second incumbent                                       | Public re-invocation refreshes deadline                                 | Ordinary physical re-trigger extends deadline; guarded consumed input-arm admission can refuse |
| Spending controls              | Explicit named Backspace/Enter/Delete; native Tab/Escape representation unverified | Five shared editing controls spend; navigation/function/shortcut retain | Five shared editing controls spend; navigation and Ctrl-letter retain                          |
| Magic setting lifetime         | Snapshot before capture waits                                                      | Live reader at decision                                                 | Live lookup at consumption                                                                     |

These are per-origin facts and explicit local constructions. An alias does not
prove identical mechanics; a missing generic action does not mean Linux lacks
the whole custom tap capability. System Sticky Keys is not certified to reproduce
Ergopti's special output table. Canonical Linux key-combination declarations
reject `one_shot_shift`; legacy fixture admission does not make it supported.

Windows LAlt starts capture on key-down and can hold native Shift after capture
until release; RCtrl distinguishes tap from a bounded Shift hold. Generic action
invocation has neither physical carrier lifetime. macOS `sticky_shift` is not
the generic sticky-modifier owner; compound sticky actions remain separate.
No common product rule is invented to label every construction difference a bug.

The shared result table is `=→º`, `%→ %`, `$→ €`, `.→ :`, `,→ ;`, apostrophe→` ?`
and Space→`-`, with the chosen magic key producing `J`. Lua policy applies full
Unicode title case for other text; native Shift punctuation is not an equivalent
contract. Windows uses AHK titlecasing, whose complete Unicode equivalence was
not measured. Abstract magic-priority overlap controls are not reachable new
user ASCII magic settings under the rare-symbol validator.

macOS explicitly exposes a positive user timeout. An earlier root
[programmatic boundary control](validation/infinity-qualification.lua) executes
the original state owner's `arm`: zero is rejected, while `math.huge` is
accepted. Positive does not imply finite. That earlier state-only control does
not execute the setter with infinity. The later numeric-domain supplement does,
under its acknowledged persistence port; neither establishes a supported
unlimited UI choice or actual persistence contract. Old TODO prose is not
proof of those features.
Windows/Linux do not expose the same editable timeout leaf in this source
scope. This records configuration availability without asserting an intentional
permanent product exclusion. Similarly, magic snapshot-versus-live lookup is
source-observed; a normal setting change during a pending arm was not shown.

Shared table-load fault behavior differs: Windows logs once and caches an empty
mapping, Linux raises before publishing a new manager candidate, and macOS
construction asserts invalid input. Shipped data passes. These are fault-path
contracts, not observed baseline startup failures.

## Positive controls, rejected candidates and open gaps

Current macOS public callbacks produce `Abc` for overlapping fresh downs and
`AAa` for repeat/release; the already fixed historical roll root is not repeated.
Linux fresh rolls release one-shot Shift before the second key. Registered
original-owner controls cover shared punctuation/magic results, scalar/Unicode
policy, inclusive deadline boundaries, pause, stop, reset and stale ownership
within their declared ports. Windows exact token/hook retirement rejects stale
capture settlement; refusal preserves an already disabled incumbent. None is a
blanket native scheduling guarantee.

Ctrl+Enter spends Linux arming because editing-control classification precedes
shortcut text lookup; Ctrl+A retains it. macOS also classifies named controls
before its shortcut branch. This is not retained as a cross-platform defect.
Windows Tab/Escape are not proved missing: `_SIHO_ScalarEndKeys` contains BMP
controls while the explicit named list has only three names. AHK EndKey
representation, native suppression and pass-through need genuine execution.

Windows `OneShotShift` itself does **not** cancel CapsWord. `DisableCapsWord`
in the same source file belongs to sibling `ToggleCapsLock`. No file-level
cancellation inference is retained. macOS generated punctuation has a concrete
missing CapsWord relay candidate, but combined original serializer/watcher
execution and native tap ordering are absent; it remains unconfirmed. Physical
Caps Lock controls do not establish actual CapsWord activation on either Lua
platform.

The stale Windows logical enabled bit after ordinary completion is not another
pending native capture. Post-retirement reentry before replay, fast typing
under delayed AHK scheduling, arbitrary Ctrl-letter capture and native IME/layout
behavior remain unproved. The shared narrow table guard accepts a duplicate
under a private mutation port, but the actual macOS constructor rejects it;
that candidate does not establish an overall CI false green.

No reviewer measured G4 end-to-end desktop latency, native hook allocation cost
or long-duration memory growth. Reset/release correctness is not a memory-leak
experiment. macOS Option/Command modifier-map geometry, Quartz dead-key state,
IME, secure input and focus are outside the stateless translator. Linux native
grabs, uinput, descriptor behavior and receiving applications remain unacquired.
Windows has zero AHK runtime cases. These are explicit evidence gaps, not
inferred feature absences or successful native tests.

## Reproduction and retained evidence

Platform reports preserve exact source owners, counterexample controls,
commands and seam qualifications:
[Windows](windows/report.md), [macOS](macos/report.md),
[Linux](linux/report.md), and [shared](shared/report.md).
Their findings and coverage JSON remain the detailed machine-readable evidence.
Custody manifests authenticate archived artifacts and identify formatting
provenance. Run the source checker and projection workflow described in the
[campaign README](README.md); a source or inventory check cannot substitute for
the native receiving work above.

Each reviewer completed two final bounded sweeps after its last new root. Final
Windows sweeps repeat source checks; macOS reruns public/config probes and six
registered modules; Linux repeats 19 fresh processes per sweep across genuine
Lua 5.4/LuaJIT; shared repeats its policy/model/source controls. No sweep adds a
new independent root. Mechanical false-green scans stay within their zero
baseline, but do not establish semantic adequacy. Earlier diagnostic fixture
attempts are not acceptance evidence and no production body was changed to make
a probe pass.

The separate [root replay receipt](validation/root-replay/receipts.json) retains
37 successful process exits, their exact programs and output hashes, and
explicit control assertions. All149 initial frozen role artifacts remained unchanged.
The132/107 current-and-pinned source check is included. An earlier replay
comparison saw a20.27ms HotPath warning under test load; its exact output and
failed-comparison receipt remain alongside the final successful replay. The
warning is not normalized away and no G4 conclusion follows from either run.

The generated comparison is scoped, evidence-qualified audit data. It can feed
future inventory work, but does not claim automatic semantic feature discovery
or global repository exhaustiveness. The five retained repair obligations and
remaining native checks must stay distinct when publishing parity information.
