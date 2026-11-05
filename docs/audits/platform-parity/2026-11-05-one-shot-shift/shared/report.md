# Shared one-shot Shift: contracts, scopes and output policy

Audited source: `9c565c88c9a1366a2e9b18c1b9d2868509510975`, November 5, 2026.
This scope reviews the shared result data/policy, declaration projections,
timeout and namespace contracts, and actual Lua state decisions. It makes no
production or registered-test change and confirms **zero independent shared
findings**. Driver-specific public admission/output findings remain with their
reviewers; no finding quota is used.

## Executed owners and exact limits

`policy-probe.lua` executes the actual shared `tap_hold.one_shot_shift` and
`unicode_case` modules plus the actual macOS `modules.keymap.one_shot_shift`
state owner under genuine Lua5.4 and LuaJIT. It does not load an event adapter,
post keys or emulate Windows. The state owner is portable Lua; this does not
claim that the production macOS native adapter runs under LuaJIT.

The seven shared scalar results are `=`→`º`, `%`→` %`, `$`→` €`, `.`→` :`,
`,`→` ;`, apostrophe→` ?`, and Space→`-`. The chosen live magic key maps to
`J`. The actual policy returns these literal results without consulting its
native same-key Shift predicate. For other text it uses shared full Unicode
**title** case, not arbitrary native Shift-level punctuation: digit1 stays1,
`é`→`É`, `ß`→`Ss`, `ǆ`→`ǅ`, `я`→`Я`, and capital dotted `İ` becomes
`I` plus combining dot after full lowercase/title processing. The probe also
checks decomposed accents, contextual Greek and uncased emoji.

Accepted canonical magic values★,§ and astral😀 are exercised. Priority-overlap
controls giving `=` or Space as magic are explicitly **abstract**: the current
rare-symbol validator rejects every ASCII special-table input as a new user
magic setting. These controls characterize the lookup contract; they are not a
reachable user configuration or a new magic-setting bug.

Same-key Shift is chosen only when the platform-supplied predicate approves its
promised title. This probe does not validate every physical-flag/CapsWord native
predicate. A whole native multi-codepoint payload is also not the same input as
one scalar: `x-y` titles to `X-Y`, while NNBSP+percent is not the scalar `%`
special and remains unchanged while spending the state deadline. Public input
normalization and native IME/carrier delivery remain driver-owned.

The state controls establish:

- The shared editing names Backspace, Enter, Delete, Tab and Escape spend an arm
  without altering the control. The actual Mac state owner retains its deadline
  for named modifiers, navigation, function keys, shortcuts and nontext. A public
  adapter can classify/control an event earlier, so these are not blanket native
  modifier claims.
- A text attempt spends the deadline; exactly `now==deadline` is accepted on the
  actual Mac state owner. Linux's source uses the same inclusive comparison.
  Native Windows timeout delivery was not executed.
- Fast rolled `abc` is single-use at the actual state owner: only `a` receives
  the decision, and `b/c` do not borrow that press's Shift. The shipped native
  public route and its already fixed historical fast-roll bug are not re-counted.
- Decisions do not claim a physical key before commit. A committed special owns
  its repeat/release debt; a committed shifted press owns only its own repeat and
  release. Re-arming does not let an old absorbed repeat spend the new deadline.
  Disarm retains required absorbed release debt; reset retires all identities.

## Availability is per origin

`declaration-probe.cjs` executes the actual feature model and public inventory
check and authenticates the exact action/menu data. The public generic catalogue
contains Windows `one_shot_shift` and macOS `sticky_shift`, explicitly paired as
equivalent IDs. The namespace reconciliation gate deliberately retains these
spellings; a rename is not an absent whole capability.

Linux's generated **generic action catalogue** declares neither ID and offers
its system accessibility Sticky Keys reason. Separately, the actual Linux
TapHold manager explicitly adds reserved `one_shot_shift` to its supported tap
namespace and reads the same shared result file. The declared default PC/Linux
right-Ctrl tap uses that value; macOS's right-Option tap uses `sticky_shift`.
Linux therefore has a custom single-use Shift **tap capability** even though
these generic catalogue entries are absent. Nor is system Sticky Keys certified
to reproduce the special Space/punctuation/magic mapping above. No generic-action
absence is generalized into a missing whole feature or a proven native OS
accessibility equivalent.

## Timing and deliberate local construction

The shared timing registry declares `tap_hold.one_shot_shift_timeout_ms=2000`.
Windows loads it into its seconds constant, Linux passes it to its engine and
macOS defaults read that same registry. Windows's source fallback for an
uninitialized/nonpositive constant is2 seconds; changing the trusted registry is
not a normal per-user zero/infinite setting.

macOS explicitly supplies the `hs`-only `tap_hold_timings` submenu with
`platform_reason.remap_engine_is_per_driver`; it exposes positive user
`tap_holds.sticky_timeout_ms`, a generated configuration-key extra rather than
an ordinary feature-model row. The current Mac setter, reader and arm contract
require a positive timeout. Old checked TODO prose describing a configurable
infinite timeout is not evidence of current support. This source/model review
finds no same editable timeout leaf on Windows/Linux. It records local
configuration availability rather than claiming those OSes could never offer it.

Re-invocation is another ownership distinction: the actual Mac internal owner
can refresh its deadline while retaining old key claims; Linux input-arm lease
admission can refuse while an old arm is consumed; Windows source refuses a
second exclusive SIHO capture rather than replacing an incumbent. Physical
producer admission may impose more rules. There is no inferred universal
re-invocation product decision from this internal comparison.

Windows snapshots `ScriptInformation["MagicKey"]` before waiting. Linux lookup
asks live `MagicKey.get()` at consumption, and the Mac adapter passes its live
reader to each decision. Whether a normal UI configuration change can occur
without consuming/canceling a pending Shift remains unqualified; this is a
setting-lifetime observation, not a newly confirmed visible bug.

## Refutations and qualified fault behavior

The Windows file also defines `ToggleCapsLock`. Its `DisableCapsWord` block
belongs to **that sibling**, not `OneShotShift`. Shared source attribution
explicitly checks the nonempty activation body; no claim that Windows one-shot
activation itself cancels CapsWord is retained. Other producers and real held
Shift/CapsWord combinations remain driver reviewer scope.

A catalogue duplicate candidate was tested against the actual narrow CJS
single-source guard via a private file-read port. The guard passes a duplicate
row but rejects multi-scalar input, an empty result and a missing magic result.
Actual Mac `Owner.new` rejects duplicate input, and the registered real-data Mac
unit constructs that validating owner. Thus this is **not** established as an
overall CI false green: the narrow source guard is not the complete native data
validation gate. This candidate adds no finding.

Source fault behavior differs: Windows logs a table-read failure once and caches
an empty mapping, leaving capitalization-only until restart. Linux read/parse
failure raises before publishing a new manager candidate; Mac construction
asserts unreadable/malformed input. These are source fault contracts, not an
observed current shipped-data failure or a full startup outcome. The shipped
table and baseline single-source guard pass.

Two initial audit diagnostics are retained without credit: the first Unicode
fixture wrongly expected composed `İ` instead of the actual full-title
`I`+combining-dot; the first ESM declaration run lacked the worktree's npm lookup.
The corrected expectations and a task-owned node_modules symlink to the main
installation permit the real owners to run. No production assertion or data was
changed to make a result pass. The link is disposable infrastructure, not audit
source evidence.

## Reproducibility and remaining limits

`source-contract.py` authenticates exact named source bytes against the pinned
Git object and records lexical relationships. Lexical checks are not AHK
execution or semantic parity proof. Source/date, output hashes, per-process
commands and actual runtimes are retained in `source-receipt.json`,
`dry-receipts.json` and `handoff.json`.

The retained coverage contains 26 qualified rows and 12 candidate capability rows.
The pinned-source receipt authenticates 57 files, including all 21 locale files,
with 16 source relationship checks. Each Lua runtime passes 126 assertions.
All 12 processes across the two final bounded dry sweeps exit successfully.

Both final bounded dry sweeps execute the frozen shared/state program on
Lua5.4/LuaJIT, actual catalogue-guard mutation controls, actual inventory/model
projection, pinned-source checks and the baseline single-source guard. Neither
reveals another independent shared root. This does not certify all native input
states. There is no G4 latency measurement, no long-duration memory-growth
measurement and no native CapsLock/keyboard/app receiving experiment. Logical
reset/release controls are not a memory-leak experiment.

The candidate capability rows distinguish origin availability, explicit local
intent, observed constraints and unknown common policy. They are input to the
parent's adjudication, not an automatic whole-repository feature inventory.
