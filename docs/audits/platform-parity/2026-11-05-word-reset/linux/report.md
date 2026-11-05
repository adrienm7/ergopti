# Linux word-reset and AI-context continuity

Audited SHA: `b17e47ed3bb92c106703d3e3482b3c2973f5bc1e`.

One confirmed finding, **WRSL-001**, covers two explicitly separate action-origin
paths: catalogue action arrows publish no navigation effect to the matcher or AI
context; tap-hold arrow actions instead use the generic tap-hold reset option.
Both violate the declared origin-independent arrow policy. No production or
registered test code was changed. The earlier repeat final-result defect
`URL001`/`URL-001` is a separate root and is not re-counted here.

## Scope and proof boundary

The scope is idle/click/arrow/shortcut/tap-hold word-reset policy, Backspace and
known empty-line authority, and the independent AI context through the following
typed key. It includes configuration publication and Main's actual callers,
not just isolated policy helpers.

`continuity-probe.lua` reads the actual Main character, control, pointer,
privacy-reset, pause-reset and tap-action closures as complete source bodies.
It compiles those unchanged bodies with the real WordReset, Linux/shared engine,
LLM Context and Settings owners. Physical input goes through the real keyboard
hook's reader/drain/dispatch seam over encoded evdev events. Native descriptor,
XKB capture, resident accessibility and clock observations are recording ports.
The AI is active unless the case explicitly disables it. Generation preferences
use the existing sparse preference fixture; the actual Settings validation/cache
owner runs. Predictor/action receiver ports record calls without a model request
or desktop action.

The finding's action variants additionally execute the real gesture manager,
combo emitter, uinput Writer and ModifierBroker. The Writer is the production
file loaded by the existing `tests.fakes.uinput_writer` fixture; only its syscall
backend is controlled. Both DOWN and UP must receive the actual Writer's
acknowledgment. The tap variants also execute the real TapHoldEngine, verify the
action exists in the actual executable catalogue and execute Main's real
tap-action closure. These controls do not stub a business-level arrow observer.

The observed next-key context is the exact string Main passes to its predictor
receiver, not a claim about a completed model request or generated completion.
No native input device, clipboard, user configuration, desktop accessibility
service, compositor or receiving editor was accessed. No native text/caret
receipt is claimed.

## WRSL-001 — Synthetic action arrows bypass their governing policy

Severity: medium. Confidence: high. Guarantee: G2, specifically the missing
effect of an enabled reset setting. Named properties: governing-arrow ownership
and AI-context navigation publication.

The shared manifest explicitly says an arrow follows `arrow_resets_word`
whatever modifier is held and wherever it comes from, including a gesture,
remap or tap-hold (`manifest.toml:561-565`). Its default is true. The separate
AI `reset_on_nav` default is also true. The shared action catalogue declares
`arrow_left` on all OS and maps Linux to `Left`.

**Submechanism A: missing catalogue-action notification.** The actual public
`GestureManager.execute_action("arrow_left")` enters `_execute_action`, selects
the generated `Left` combo and executes the real emitter/Writer. Main wires
`gestures.init` with action handlers, persistence and pause state, but no
WordReset/engine navigation observer. The primitive emitter also publishes no
semantic navigation effect. The ordinary keyboard finder explicitly excludes
the driver's uinput device, so the output must not be fed back into the input
matcher as a substitute for the missing owned notification.

In `catalogue_arrow_does_not_reset`, both preferences are on. After `ab`, the
actual action emits exactly `105:1`, `105:0` (Left DOWN/UP), but the word and AI
context remain `ab`. The next physical `c` gives `abc` in both, and Main's
predictor receiver gets `abc`. Physical-arrow controls independently prove the
word and AI preferences work on the normal input route: with arrow reset on the
word becomes `c`; with AI navigation reset on its context becomes `c`.

**Submechanism B: tap-hold arrow uses the wrong option.** Main's tap-action
callback invokes the catalogue and then calls
`WordReset.apply_tap_action(engine, binding)` without the action's arrow
semantics. That function applies `tap_hold_resets_word` to every own tap action.
It cannot choose the arrow owner from a binding string alone.

| Real tap action `arrow_left` after `ab`, then `c`      | Observed word | Observed AI context | Declared arrow rule |
| ------------------------------------------------------ | ------------- | ------------------- | ------------------- |
| arrow reset off, tap reset on, AI navigation reset off | `c`           | `abc`               | Keep the word       |
| arrow reset on, tap reset off, AI navigation reset on  | `abc`         | `c`                 | Reset the word      |

Both variants emit the acknowledged Left DOWN/UP pair through the actual Writer.
The physical arrow policy recognizes arrows before tap-hold ownership; the
catalogue action route never receives that classification. This is not absence
of native output and not a claim the emitter failed. It is missing/wrong logical
effect publication after the admitted action.

No diagnostic reports the ignored arrow setting. Existing word-reset event tests
cover physical keys and navigation-layer remaps, and emitter tests cover primitive
ordering, but that does not join an own tap action or catalogue arrow to the
canonical reset policy.

Future regression/fix work must cover **both submechanisms**. Add an owned
semantic effect protocol or equivalent explicit notification that applies the
arrow policy exactly once after the admitted synthetic arrow, independently of
the initiating gesture/chord/tap. Include all four arrows, modifiers, both reset
settings, private/focus/lifecycle admission and output refusal. Preserve synthetic
input provenance filtering. A fix only in one caller must not close the other
admission path. No fix is implemented in this audit.

## Observed availability and intentional distinctions

| Aspect                              | Actual result and qualification                                                                                                                                                                                                                                                                                                                                                                                                       |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Defaults                            | Canonical idle threshold 3 seconds; click/arrow/shortcut/tap-hold reset true; AI navigation reset true. Tap-hold reset is Windows/Linux only: macOS Karabiner output follows ordinary shortcut ownership.                                                                                                                                                                                                                             |
| Physical arrows                     | Word-reset off deliberately preserves both the buffered word and its left-edge authority across a caret move. AI navigation reset is independent. The actual next key and predictor receiver confirm Linux retains the earlier sentence with AI reset off; it does not reconstruct context from the newly reset matcher.                                                                                                              |
| Other navigation keys               | Home, End, Page Up/Down, Insert and Delete reset the matcher at an unknown position regardless of arrow-reset off. The AI navigation option still owns their context effect.                                                                                                                                                                                                                                                          |
| Ctrl+Z/Y/Shift+Z and paste          | Actual Main forgets unknown-edit AI context even with navigation reset off. With shortcut reset off it deliberately keeps the hotstring word. It does not promise the retained word describes an editor's resulting text.                                                                                                                                                                                                             |
| Other shortcuts                     | Ctrl+S and GUI Alt+B retain the AI context when navigation reset is off. A chord emitted through a held tap-hold Ctrl follows tap-hold word ownership; the actual hook reports `tap_hold = true`.                                                                                                                                                                                                                                     |
| Terminal Alt+B                      | Main conservatively treats selected terminal Readline movement/edit chords as unknown edits and clears AI context even with navigation reset off. The same GUI chord is retained. The source explicitly describes the conservative terminal rule.                                                                                                                                                                                     |
| Ctrl/Alt/Super Backspace            | Modified deletions clear unknown AI context. Ctrl+Backspace establishes a word start; Alt/Super variants establish an unknown start. Bare Backspace after a long pause still edits the previous word; its control callback does not apply an idle wipe.                                                                                                                                                                               |
| Selected whole field and empty line | Ctrl+A outside terminal and Ctrl+L in a browser establish known empty-line authority. An empty-buffer Backspace retains that boundary; terminal Ctrl+A has no whole-field authority, so Backspace makes it unknown. This is logical policy, not a native selection receipt.                                                                                                                                                           |
| Idle reset                          | The next ordinary character after the configured threshold clears the old matcher and AI context. Idle is measured through the actual Main clock port. Settings zero disables it.                                                                                                                                                                                                                                                     |
| Escape                              | Main/WordReset makes a known word start; the AI context follows navigation reset independently.                                                                                                                                                                                                                                                                                                                                       |
| Typed newline                       | The actual hook sends bare Enter to Main's text callback. In a GUI, it stays a typed multiline `\n`, including in the AI context; in a terminal Main resets the word to an empty prompt. AI navigation reset on clears the terminal context, off keeps the typed line and newline. A Ctrl+Enter is a control route. These are caller-policy distinctions; this role does not infer a universal obligation to erase multiline context. |
| Shift+Enter in a terminal           | It follows the same text callback as bare Enter and resets the prompt. Loss of modifiers on typed newlines is already documented in routed memory; it is a known limitation, not a newly found root or asserted intentional choice.                                                                                                                                                                                                   |
| Own tap paste                       | The generic tap-action policy treats its action as navigation. With AI navigation reset off, this action's prior context stays, unlike the explicit direct Ctrl+V unknown-edit branch. The proof records action dispatch and the context result; it does not paste clipboard data. The policy granularity is unresolved, not another confirmed finding.                                                                               |
| Click/focus/Tab                     | Main's pointer callback first invalidates the actual privacy guard. The guard invokes Main's real `reset_text` closure and clears AI context before the later navigation reset, even with navigation reset off. Click word reset off still leaves an unknown boundary. Focus and raw Tab similarly revoke old context. The conservative privacy boundary takes precedence; preserving it is mandatory.                                |
| Pause and AI off                    | Actual Main pause-reset closure clears the matcher and AI context. Context stores nothing while the AI is off. Runtime pause-controller execution and real desktop resume were not exercised by this role.                                                                                                                                                                                                                            |

The broad source/memory description that “click navigation retains context with
reset off” is therefore incomplete after privacy-guard integration. Treat the
measured click override as qualification/documentation debt; do not weaken focus
invalidation to make a preference appear effective.

## Verification and two dry sweeps

`continuity-probe.lua` executes **43 owner scenarios** under genuine LuaJIT and
Lua 5.4. Eleven already registered modules run in fresh LuaJIT processes:
**500 passed, zero failed**. Final A and B each repeat this same bounded set;
the repeated case totals are not additional distinct coverage.

The registered set covers WordReset canonical sparse persistence and refusal,
actual keyboard/tap routing, independent AI context and its shared corpus,
prediction retirement, generation settings, late shortcut destination admission,
tap-hold lifecycle, native combo ordering/parsing and Hotstrings scope adoption
and restoration. Passing these does not certify all tests are behavioral or
that native editors consumed their input. The new actual-caller cases expose
the gap missed by separately passing policy and emitter tests.

Two initial isolated-harness failures are retained. The generation-settings
module initially had 17 passes/1 failure because the minimal audit runner lacked
the canonical unit runner's `menu_part_reload.install()` bootstrap. After adding
that same bootstrap it passes. A tap-hold lifecycle case initially had 35 passes/
1 failure because it opens `ergopti_hotstrings.lua` relative to the driver CWD;
the audit runner had used the repository CWD. The official `run-linux-lua.cjs`
sets the driver CWD. The corrected runner now does too. Original outputs are
`bootstrap-missing-menu-reload.txt` and `bootstrap-wrong-driver-cwd.txt`. No
production or registered assertion was changed, deleted or skipped.

Final sweep A revisited defaults/settings/cache publication, all input entry
routes, timing, scalar Backspace/boundary rules, known empty lines, macro action
semantics and the next-key predictor context. Final sweep B revisited native
output acknowledgment versus semantic publication, all admission origins,
pause/focus/click/Tab retirement, privacy precedence, terminal/multiline policy,
unresolved hypotheses and older-root deduplication. Each replayed all 43 cases
under both runtimes and the eleven registered modules. No further distinct root
was confirmed after WRSL-001's two admission paths were established.

See `final-A-receipt.json`, `final-B-receipt.json`, `dry-ledger.json`,
`coverage.json` and `source-receipt.json`. Raw process stdout is retained as
`.txt` so repository JSON formatting does not change its byte hashes.

## Coverage gaps and memory watch-list

No actual desktop caret, multiline editor, terminal/TUI, selection, native Undo,
input layout/IME/dead-key, physical touchpad gesture, real model backend or
prompt completion was exercised. Public catalogue action dispatch is executed;
physical gesture classification/reader acquisition is outside this role's proof.
The missing notification is confirmed through actual logical state and issued
native-event acknowledgments, not editor screenshots or hardware reception.

No runtime latency, memory or G4 claim is made. The matcher and shared context
are bounded rolling buffers; one attached context per engine is enforced by
existing tests. Those are source/functional observations, not a heap profile or
resident-secret-zeroization measurement. Source hash claims name exact files,
not every transitive dependency in the repository.

## Replay

```sh
PATH=/workspace/scratch/parity-toolchain/ci-bin:$PATH LOGNAME=agent \
  luajit continuity-probe.lua /path/to/ergopti
python3 run-proofs.py /path/to/ergopti --pass-name review
```

The first command runs the decisive caller proof. The second runs both Lua
runtimes plus the eleven isolated modules, retaining outputs and hashes beside
the runner. These programs assert current defective behavior and positive
controls; passing them is not a production fix.
