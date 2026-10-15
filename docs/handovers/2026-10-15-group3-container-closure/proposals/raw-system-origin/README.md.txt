# Raw system-event origin before terminal recipe admission

Private five-path proposal. No canonical file, index, DLL, builder, manifest,
workflow or active gate was modified. The exact suppliers are in `paths.json`:
`nav_event_owner.c` is published delivery073800ed8 (including Root's hook fix);
replay C/header/existing tests are incoming Deve850833c. The new inline header
needs no separate C object or builder target. Original source packets remain exact.

## Concrete bounded defect and fix

The original terminal capture normalizes `KBDLLHOOKSTRUCT.scanCode & 0xFF`,
sets `incoming.origin = PHYSICAL` and `source_id = 1`, then calls the original
portable recipe state machine. A supplied raw0x21D Up aliases the retained real
0x1D Ctrl source and retires that real modifier recipe. The same alias exists
for raw0x22A/0x236 versus genuine Shift. This is an actual portable state-loss
counterexample at the native producer's existing projection, not a Windows
physical observation.

The new classifier receives the untouched full raw VK/scan/flags. It downgrades
known/unmodeled high scan bits, unknown flags and absent raw identity to an
explicit `UNPROVEN_SYSTEM` origin. Existing injected/lower-integrity classifications
stay refused. The recipe core recognizes that origin and returns unsupported
before touching any held source. The actual native terminal producer uses this
classifier instead of its unconditional physical constant. Fixed-width structures
and the existing FIFO, replay/output, hook/menu and effective-modifier source
policies are not edited; that is not proof of identical observed protocol
behavior. The classifier cannot promote a previously nonphysical tuple.

A newly downgraded DOWN returns unsupported after the actual
`NavLiftTerminalClockLocked` call. The unchanged native fallback at
`NavCaptureTerminalEventLocked`956–957 therefore latches
`terminal_routes_uncertain = 1`, including when no terminal capture debt exists.
With capture debt, the same original FIFO path retains the exact incoming edge
and its unsupported metadata; the downgrade does not skip raw capture or
acknowledge replay. Subsequent ordinary character recipes are refused by the
existing uncertainty check at952–955. Keeping that fail-closed law is intended;
this patch adds no automatic clearing or guessed known source. A successful fresh
registration clears the flag only subject to the original retained-hold checks
at3131–3137; independent Caps/modifier uncertainty can still refuse recipes.
Thus newly unknown system input can reduce recipe admission until genuine
registration receiving. FIFO release, uncertainty recovery and actual native
replay consequences require owner-native qualification and are not established
by the portable held-ledger tests.

The legacy PHYSICAL label for ordinary modeled hook input is retained for
compatibility, not claimed as RawInput device or genuine pair input provenance.
The separate `NavBuildHookEventLocked` effective-modifier tracker is untouched;
this repair is confined to the terminal recipe ledger. It does not close every
native Ctrl/AltGr problem or connect the simultaneous engine.

## Raw source-domain evidence and its limit

Authentic AutoHotkeyv2.0.26 `keyboard_mouse.h`133–150 explicitly says these
system-generated scan values can only be found in KBDLLHOOKSTRUCT::scanCode,
identifies0x0200 as SCANCODE_SIMULATED and defines rawCtrl0x21D and rawShift
0x22A/0x236. `raw-domain-source.txt` preserves those literal lines and URL;
the full supplier SHA256 is in `raw-domain-source-receiving.json`. The pinned
original hook.cpp157–216 takes that same struct directly from lParam, masks a
local copy, then compares the untouched event.scanCode to SC_FAKE_LCTRL.
These are raw API observations described by the upstream source, not invented
internal AHK scan IDs. The Microsoft hook-structure documentation fetch was
refused403 by this environment and is explicitly NOT_RECEIVED.

No current Windows device/run was observed supplying these tuples or flags.
The source-domain possibility and portable loss are established; native
occurrence, precise current system flags and physical qualification remain unrun.
The unknown-raw downgrade stays conservative even if a particular layout emits
other sequences.

## Actual focused receiving

All 151 original assertion-start lines and all eight original matrices remain
in their exact order. Two handwritten matrices add three genuine-versus-system
Ctrl/Shift sequences and ten literal flag/scan classifications. Expected masks
and retained-state assertions are handwritten; the independent original route
vectors and corpus are unchanged.

Actual GCC14 strictC11 optimized receiving passes the original eight matrices
plus both additions. The same suite passes under ASan+UBSan, exit0, empty stderr.
The original portable product plus the exact original non-injected native
producer constant, projected as a finite portable supplier, compiles and aborts
on the real held-state equality after fake Up. Candidate passes; withdrawing
only the raw downgrade again loses the real hold and aborts at that same
assertion; restoration passes. No missing enum/API or fixture setup error is the
causal negative. The baseline projection is explicit: the original complete
Win32 hook was not compiled or executed on Linux. Exact sources, compiler
commands, outputs and projected supplier remain in the owned unique/tmp tree
named in `causal-receiving.json`; final executions used those own directories
with core dumps disabled. `final-receiving.json` preserves actual outcomes.

## Finite owner handoff

Root/Cloud247 must reconcile the exact include/SDK flag assertion and
`NavCaptureTerminalEventLocked` incoming-origin supplier, the new diagnostic
origin in the replay enum/unsupported guard, and the append-only existing test
changes. The new header is automatically part of the native recipe fingerprint;
the owner must independently verify the regenerated manifest's
`fingerprint_files = 19`, not retain an old generated fingerprint. Root must then
regenerate its actual DLL/manifest and qualify the Windows SDK/compiler,
original native tests, uncertainty/re-registration, FIFO/native replay/output
and installed receipt on the resulting source. None of those native steps was
run here.

The true sole hook/RawInput source/press ledger, shared policy/action binding and
output/retirement bridge for simultaneous combinations remain absent. This
patch supplies no source capability, pair enablement, output ACK or native
retirement proof; no menu availability changes are proposed.
