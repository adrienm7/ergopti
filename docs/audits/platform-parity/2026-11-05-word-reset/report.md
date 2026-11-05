# Word reset and AI-context continuity parity

Audited source: `b17e47ed3bb92c106703d3e3482b3c2973f5bc1e`, November 5, 2026.

This module started after all four repeat/recovery reviews closed and the root
replayed their final driver programs. Four reviewers reused their separate owned
worktrees and stayed on word-reset/context continuity. The scope follows the
next character after navigation, shortcuts, edited controls, idle, tap-hold and
synthetic action output. It adds 98 aspect rows and five qualified findings;
the shared reviewer adds positive controls without inventing another finding.

## Confirmed findings

- **WRSW-001, Windows, source only:** the public synthetic Alt/Win+Backspace
  path declares a known word start, while the physical equivalent explicitly
  refuses that promise. A successful sender verdict cannot establish where
  an unknown edit left the caret.
- **WRSW-002, Windows, source only:** physical modified-Backspace and shortcut
  branches return before the AI key notification. The invalidator discards
  incomplete UTF-16 fragments but leaves complete prediction/agent text.
  The next character can therefore append to old text and a fresh observer
  forwards the wrong context despite correct stale-generation checks.
- **WRM-001, macOS, actual Lua owners:** navigation initially respects the
  independent AI option, then the next character rebuilds AI context from the
  hotstring buffer. With keep-AI/reset-word, the old sentence disappears;
  with reset-AI/keep-word, the cleared sentence returns. Twelve public scenarios
  expose five mismatches. A separate genuine prediction serializer over fake
  HTTP corroborates the four option combinations; it is not the same public
  eventtap process or an actual network request.
- **WRM-002, macOS, conditional native receiving:** the empty-terminal-prompt
  receipt handles main Return but omits the declared keypad Enter identity.
  Actual public-owner controls show the later boundary consequence. The
  reproduction requires a target terminal treating bare keypad Enter as submit
  and later Backspaces occurring at an empty prompt. CR/ETX controls do not
  measure the native event payload. This is a low-severity key-identity finding,
  not an unconditional native no-output guarantee.
- **WRSL-001, Linux, actual Lua owners:** synthetic action arrows do not apply
  their declared governing policy. Catalogue dispatch omits word/AI navigation
  notification; Main's tap-action callback instead applies the generic tap-hold
  switch to an arrow action. These are two explicit admission submechanisms in
  one semantic-publication finding. A future fix/regression must cover both.

The [canonical findings](findings.json) and [generated comparison](capabilities.md)
come from the root-adjudicated [owner](owner.json); [index.json](index.json)
retains every role's qualified coverage. Earlier repeat reset `URL-001` is not
re-counted. Prior campaign/TODO searches and explicit rejected hypotheses remain
in the role reports.

## Policy and intentional differences

The shared feature model resolves the effective defaults: three-second idle
reset; arrow, shortcut, click and supported tap-hold word-reset switches true;
AI reset-on-navigation true. Raw macOS state-table false values are initialization
placeholders, not the effective default. Zero disables idle. Word-reset options
and AI context have explicitly separate lifetimes in the shared ContextBuffer;
its actual corpus includes retaining context through navigation and following
typing.

The arrow declaration explicitly covers every modifier and origin, including
driver-produced navigation-layer, remap, tap-hold and gesture keys. Shortcut and
tap-hold attribution remain distinct where origin is known. macOS's separate
tap-hold-origin option is explicitly unavailable because Karabiner origin is not
qualified; this preexisting limitation already has a TODO and is not a new bug.

Bare terminal Return can establish an empty line; multiline/Shift+Return does
not necessarily establish that receipt. Linux's typed-newline hook lacks Shift
provenance, a previously documented limitation. GUI typed newline and control
Enter take different Linux routes; the audit records observed policy behavior
without inventing a universal Enter-reset guarantee.

Physical Ctrl/Cmd+Z remains application-owned. Navigation retention is not a
promise to preserve text across unknown edits, private fields, focus changes,
pause or shutdown. Linux's real focus guard clears context on pointer/focus
invalidation even with keep-context selected; the conservative privacy boundary
is preserved. Tap-paste versus directly observed paste and modified Home/End/Page
keys retain explicit policy qualifications. In particular, the manifest's broad
shortcut language and other-navigation wording leave modified-key scope
ambiguous; this is not silently classified as an intentional permanent exclusion
or a newly confirmed defect.

Idle recovery architecture also differs intentionally: Windows forgets and can
restore the exact word for an immediately following Backspace; macOS avoids the
bare-Backspace idle wipe; Linux applies typed-character idle policy. These
mechanisms are described in routed `project-backspace-word-start` memory. The
Windows 49-day rollover hypothesis was refuted from the actual 64-bit tick owner.
No latency or G4 measurement is claimed.

## Independent evidence and test trust

Root replays opened the actual owning source, retained program and observations.
Windows authenticates 22 files and 24 lexical contracts; no AHK code, worker,
native input, real editor or model request ran. These checks never simulate AHK.

macOS executes four decisive programs over faithful Hammerspoon native ports:
12 public-context scenarios, four serialized fake-transport requests, 16 edit
controls, and three keypad-receipt plus three payload controls. Ten exact
registered modules run 145 positive cases. Structural/outage controls remain
identified as such. No native terminal or application Undo was exercised.

Linux executes 43 actual hook/Main scenarios under both genuine Lua 5.4 and
LuaJIT, plus 500 positive cases in 11 existing isolated modules. Its action
variants use the real manager/emitter, production Writer with a recording syscall
backend, ModifierBroker, executable catalogue and tap-hold engine. The predictor
port records the actual Main argument; it does not execute a model request.
Reviewer physical-arrow controls independently isolate each option. Root adds
one matched-default physical-arrow control in a fixture wrapper: both flags
true yield word/context `c/c`, while catalogue arrow under those flags leaves
`abc/abc`. Only fixture invocations are extended; actual production bodies are
unchanged. The wrapper replays 44 cases and does not inflate the reviewer's
43-case count.

Shared execution covers 208 WordReset/engine/context option scenarios, seven idle
vectors, 13 actual context vectors and nine private-mark vectors: 1,388 assertions
per runtime. An independently frozen macOS peer replay corroborates the same
12 public cases/five mismatches; it is not another defect. Initial harness
bootstrap/cwd failures and one diagnostic generator-invocation mistake are
retained and not credited as positive coverage. No registered assertion was
edited or skipped. The diagnostic regeneration changed no frozen metadata bytes.

Each role performed two bounded complete dry sweeps after its last new root.
Root replay receipts are separate from worker receipts and do not infer dry
source review merely from passing probes. Counts from repeated sweeps and
overlapping modules are not added as distinct tests.

No native desktop/input device, real clipboard, user configuration or external
service is accessed. Native focus/caret/IME/grapheme deletion and application
receiving remain explicit gaps. Bounded buffers and owned timers are source
watch points, not measured memory-growth or latency results. Claimed source
hashes cover named files, not every transitive dependency.

## Generated review and delivery

The ordinary live configuration/action inventory and supplementary behavior
catalogue remain distinct from this dated evidence. The root TODO tracks the
five new implementation findings. No word-reset or AI-runtime fix is included.
The supplementary catalogue from the preceding module is the only live
availability-schema addition; its source-review receipts cannot discover every
undeclared behavior automatically.

The custom four-role metadata schema accepts zero-finding scopes and checks
source/date, evidence custody, qualifications, references and deterministic
projections. It is not the legacy AHK/HS report envelope. Its controls do not
certify runtime parity. Commands are in [README.md](README.md):

```sh
python3 replay.py /path/to/ergopti --output /tmp/ergopti-word-reset-replay
python3 check_sources.py /path/to/ergopti --output /tmp/ergopti-word-reset-sources.json
```

`validation/` retains root evidence and delivery qualification. Worker receipts
name their original worktrees/scratch locations as historical provenance;
portable decisive programs take the repository root explicitly.

Four worker-hashed shared JSON files changed presentation under repository
Prettier. Exact originals, current digests and verified JSON-value equality are
retained through [format-provenance.json](validation/format-provenance.json).
Original worker receipts remain unchanged; root evidence hashes use the formatted
archive rather than pretending the two byte representations match.

## Delivery validation qualification

The [delivery qualification](validation/delivery/qualification.json) retains the
original full verification with two subprocess timeouts: the App Cloner physical
CLI fixture and the managed Ollama independent clock receiver. The exact commands
subsequently returned exit zero in isolation, without altered assertions or
deadlines. Seven final selected gates and the production website build also
passed; the original aggregate remains unsuccessful.

The original native archive admission refusal is retained separately from the
subsequent genuine Linux pipeline result: three actual native cases, fifteen
checks, zero skipped. That pass covers the earlier staged snapshot before late
metadata/documentation edits; it is not a final-source rerun or physical input
receiving. Windows source-only and Lua controlled-port qualifications still apply.
No full aggregate pass or exhaustive whole-repository parity is asserted.

The original aggregate also rejected formatting in two audit evidence files;
those files were subsequently formatted with the pinned repository formatter.
That correction is recorded separately from the unsuccessful aggregate result.
