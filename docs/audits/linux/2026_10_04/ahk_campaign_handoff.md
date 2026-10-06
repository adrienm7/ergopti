<!-- docs/audits/linux/2026_10_04/ahk_campaign_handoff.md -->

# Linux findings retained from the AHK hardening campaign

## Record and scope

Prepared on 2026-10-04 for the separate `fix/linux` owner. This is an evidence
handoff, not a new Linux audit or an instruction to integrate cumulative drafts.
No Linux tests, driver, device acquisition, update, Git mutation or primary edit
was performed while preparing this document. All behavioral receipts below were
produced earlier in owned fixtures. Credentials in those fixtures were synthetic.

References inspected without fetching:

- Local `dev`: `dc959706af32c5b253d5c047f64bae984baa9017`.
- Cached `origin/dev`: `f99d67986f5a3cbb5d2d4cbe97e59d4807cb82cd`.
- Cached `origin/fix/linux`: `70c60abc2f55aa57c90da1e5eb98fe1d4fdc8c83`.

There is no local `fix/linux` branch in this checkout. The remote-tracking ref is
an observed snapshot, not a claim about the other agent's current uncommitted
work. Reconcile each source owner before applying a draft. In particular, the
XKB owner on `origin/fix/linux` differs from the tested `dev` implementation.

## Status

| Finding                                            | Evidence                                                       | Status at these references                                                                                            |
| -------------------------------------------------- | -------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Padded native XKB aliases                          | Native libxkbcommon 1.6.0 RED -> GREEN; 1.13 control           | Confirmed, not integrated on inspected `dev`/`origin/dev`; `fix/linux` has a different owner and needs qualification  |
| Fractional LLM context                             | Actual settings and native shared builder RED -> GREEN         | Confirmed, unchanged on all three inspected references                                                                |
| Bare stateless installation-token redaction        | Actual shared redactors RED -> GREEN                           | Confirmed, shared rule unchanged on all three inspected references                                                    |
| Confirmed force quit retargets its PID             | Actual generated shell with recording ports produces wrong PID | Confirmed baseline defect, source unchanged on all three references; incomplete draft has no GREEN receipt            |
| Live-updater opaque bearer admission               | Recording native HTTP adapter RED -> GREEN                     | Already fixed on `origin/dev` by `2d0787ad75fe8ecd51ab9052e0a7d755308b8b9d`; do not list as an unfixed production bug |
| Authentication receipt EOL and case-alias fixtures | Published local commits                                        | Already fixed by `c0b62021b` and `ecf9f4193`; preserve them                                                           |
| Suspected CLI hang                                 | Global command deadline expired, descendant continued past CLI | Not a demonstrated CLI/driver deadlock                                                                                |

## LNX-HANDOFF-01: padded complete aliases are not canonicalized

**Owner:** `static/ergopti_plus/linux/adapters/xkb_source_probe.lua`,
`ordered_aliases`, `canonical_keymap`, and `M.read`. Regression owner:
`static/ergopti_plus/linux/tests/hardware/run_xkb_source_qualification.lua`.

**Tested identity:** `ecf9f4193845dde744a485c63aeda118e487eb8d`, adapter SHA-256
`0487f264b84a17a74da3e2fbe91cd58c0baf903079aaa214578e68b5fae1c96e`.
That adapter hash also matches inspected local `dev` and `origin/dev`.

**Failure:** the Lua declaration pattern requires exactly one space between an
alias name and `=`. Native libxkbcommon 1.6.0 aligns alias names with `%-14s`, so
complete padded declarations are not selected for sorting. Equivalent complete
maps with different alias declaration order then fail native source admission.
This is an availability failure, not permission to ignore map differences.
The [official 1.6.0 serializer](https://raw.githubusercontent.com/xkbcommon/libxkbcommon/xkbcommon-1.6.0/src/xkbcomp/keymap-dump.c)
shows the alignment in `write_keycodes`.

**Causal receipts:** the original native 1.6.0 runner reports 26 checks / 1
failure, exactly `alias declaration order cannot refuse a matching native
source`, also observed in Linux CI for published
`10e0c9fbdfdf748eff134606b1afb6aa00862785` (run `37128955060`, job
`111220291755`). Two additional native regressions produce 28 / 2 failures on
the old adapter, then 28 / 0 on the proposed adapter. Native 1.13 originally
passes 26 / 0 and passes 28 / 0 with the proposed adapter.

**Repair and regression:** recognize horizontal alignment around `=` while
retaining each complete alias name and target. Keep sorting the complete
relations, not selected symbols or a digest of a subset. Replay descending
complete alias declarations through the actual input-source/native admission
owner. Change an alias target while preserving a tested symbol and require
refusal. Retain group epochs, modifier/map changes and native Wayland refusal.
The draft changes two files; no system library replacement is required.

**Reproduction environment:** use an owned isolated Xvfb display and run
`luajit tests/hardware/run_xkb_source_qualification.lua` from the copied Linux
root. Repeat with uninstalled Ubuntu `libxkbcommon0` and
`libxkbcommon-x11-0` version `1.6.0-1build1` exposed only through that child's
`LD_LIBRARY_PATH`, then the installed 1.13 control. The recorded old-library
proof used a private mount namespace and separate X11 socket directory. A WSL
host socket directory with mode 777 and one Xvfb readiness timeout produced
separate environment failures before qualification; neither is causal RED.
Do not alter a host mount, chmod shared sockets or replace system libraries.

**Branch reconciliation:** the inspected `origin/fix/linux` adapter compares
native serialization directly and does not contain `ordered_aliases`. Its
SHA-256 is `a91b3c2da495127b22fff0be2da192f4bfb3e511a5bb3a2f3d758fff6c02dceb`.
This report does not certify that different owner as resolved. Port the small
lexical correction after reconciling canonical source ownership and rerun both
native-version receipts; do not overwrite that branch with the full old file.

## LNX-HANDOFF-02: fractional context is published but yields empty context

**Owner:** `static/ergopti_plus/linux/modules/llm/settings.lua`, `BOUNDS`,
`in_bounds`, `M.set`, `M.get`. The downstream owners are
`static/ergopti_plus/_shared/lua/llm/prompt_builder.lua` (`build_params` and
context extraction) and `static/ergopti_plus/_shared/lua/text_utils/init.lua`
(`utf8_sub`). Tests belong in
`static/ergopti_plus/linux/tests/unit/modules/llm/test_llm_settings.lua`.

**Tested identity:** published `10e0c9fbdfdf748eff134606b1afb6aa00862785`;
settings SHA-256
`17319c4914d9d6293f2fe05a7f6fdca365e07884d448f0ba1eb67544c50eeb23`.
The settings hash is unchanged on all three inspected references.

**Failure:** `context_length` has the existing range 80..4000 but omits
`integer = true`. `M.set("context_length", 80.5)` succeeds and publishes a
fractional index. Native LuaJIT replay of the real shared builder with 200 ASCII
scalars or 200 supplementary scalars returns exactly 80 scalars for cap 80 and
zero for cap 80.5. `utf8_sub` protects `utf8.offset` with `pcall`; a fractional
index fails and becomes empty context instead of an observable failure.
The infinity builder probe is an observation of a raw builder argument, not a
claim that the Linux setting admits infinity: existing bounds already refuse it.

**Causal receipts:** actual settings module tests against the published archive
report 15 passes / 2 failures; the minimal Linux change plus two registered
regressions reports 17 / 0. All current automatic-temperature tests were
retained. The native builder transcript independently records ASCII/emoji
output lengths 80 versus 0 at the integer/fractional caps.

**Repair:** add `integer = true` to the existing context bound. Do not invent a
new cross-OS range, change temperature's fractional policy, or rewrite the
shared UTF-8 slicer to hide invalid upstream state.

**Regression:** refusal of 80.5 preserves active settings, durable storage and
the real Unicode builder suffix, with no write. A stored fractional value is
reported through the existing invalid-config admission path and the canonical
default is used. Keep valid integer boundaries and the existing refusal of
numeric strings/nonfinite values. In a fixture initialize compatibility UTF-8,
load the real settings storage owner and call the shared builder; no model,
network, user driver or keyboard is needed.

The original private package also has separate macOS fixes. Linux integration
needs only its two Linux paths, reconstructed against current branch bytes.
Do not copy the old eight-file cumulative package indiscriminately.

## LNX-HANDOFF-03: generic redaction misses a bare stateless installation token

**Canonical owners:**

- `static/ergopti_plus/_shared/modules/diagnostics/redaction.json`.
- `static/ergopti_plus/_shared/tests/corpus/diagnostics/redaction_vectors.json`.
- Consumers: `_shared/lua/diagnostics/redact.lua`, `_shared/ui/redact.js`, and
  `windows/infra/redact.ahk` under `static/ergopti_plus/`.

**Tested identity:** `ecf9f4193845dde744a485c63aeda118e487eb8d`, reconfirmed
against `2f4d8a09c6a34eba3d70053ea0db3e2039d7ab20`; canonical rule SHA-256
`443acd087d793d41742c3bc13b4524a930cf6201cd7a56e557d2f8bfdef10c45`.
That rule is unchanged on all three inspected references.

**Failure:** the `ghs_` rule allows only an alphanumeric body. In the stateless
`ghs_<app-id>_<jwt>` shape, the next underscore stops the body before the
minimum length, leaving the whole bare token visible. The existing `Authorization`
header redactor does not protect a bare token elsewhere in diagnostic text.
GitHub's [official completed rollout announcement](https://github.blog/changelog/2026-10-02-stateless-github-app-installation-tokens-rolled-out/)
confirms the changed format and approximate length, and explicitly recommends
checking validation and secret-redaction assumptions.

**Causal receipts:** three new synthetic cases fail in the actual shared JS,
AHK and Lua redactors. Linux's admitted native LuaJIT diagnostics corpus reports
130 passes / 3 failures before and 133 / 0 after. Headless macOS has the same
130/3 -> 133/0 result; actual AHK `JsonParse` + `Redact_Apply` reports three
failures among 21 vectors then 21/0. JS also rejects all three before and passes
the 21-vector replay after. These are headless/pure results, not UI qualification.

**Repair and regression:** reuse the already-defined HTTP bearer alphabet for
the `ghs_` rule in the shared canonical JSON. Expose that existing class through
the handwritten consumers instead of adding a duplicate alphabet or generated
runtime manifest. Cover JWT punctuation, a synthetic body longer than 520
characters, complete-token removal within quotes/comma, identifier boundaries,
and a short-body false-positive control. No real token is necessary.

**Important distinction:** commit `2d0787ad7` removes a known CI credential from
live-updater response evidence before generic redaction. That is a correct
context-specific fix; it does not change this shared bare-token rule and does
not resolve this separate finding. Coordinate the shared three-consumer change
with the AHK owner rather than replacing its current redactor file blindly.

## LNX-HANDOFF-04: confirmed force quit obtains its PID after approval

**Owner:** `static/ergopti_plus/linux/modules/gestures/system_actions.lua`,
`ACTIVE_WINDOW`, `window_signal`, `M.TARGETS`, `confirmed_command`, `command_for`.
Tests belong in `static/ergopti_plus/linux/tests/unit/modules/test_system_actions.lua`.

**Tested identity:** published `10e0c9fbdfdf748eff134606b1afb6aa00862785`.
The source captured in the retained fixture matches the currently inspected
owner hash `ab3ff46e9811223c44622a6a9c678d1fe73688cfe355d2ea0fe144a82e962744`
on all three references.

**Causal reproduction:** load the actual module and obtain
`command_for("force_quit_frontmost", label, true, has_zenity)`. Execute that
actual generated shell with shell functions shadowing `xdotool`, `xprop`,
`zenity` and `kill`. `getactivewindow` returns XID 100; fake PID state begins at 900001. The recording question changes that state to 900002 and returns
approval. The emitted effect is `RECORDED_KILL -KILL 900002`.
No actual signal, dialog, process lookup or XID reuse is performed.

**Root cause:** only the XID is acquired before the question; the PID and window
kind are read by `window_signal` after approval. The queued effect can therefore
adopt a different process owner of the same XID. This proves late retargeting
in the command, not the real-world frequency of XID reuse.

**Required repair/regression:** capture a complete immutable approved target
before the question and validate its live ownership before the effect. A changed
PID must refuse, never become fresh effect authority. Keep cancel, missing
question tool, shell/desktop/dock/self/PID0/1 refusals, valid approved target and
non-confirmed direct-action controls. Bound fake child lifetimes and keep real
`kill`, focus and devices inaccessible to the fixture.

**Status:** an incomplete private two-file draft exists, but it has no validated
GREEN regression matrix, convention gates or frozen manifest. Use the retained
RED as a specification; do not integrate that draft as a proven fix.

## Already resolved: opaque updater admission and test portability

The old `tests/hardware/run_updater_live.lua` CI guard required token length
20..255 and only `[A-Za-z0-9_]`. The official stateless rollout and synthetic
recording HTTP adapter expose why this rejects valid opaque bearer credentials
before any HTTP request. Tests on `ecf9f4193` failed before the bounded draft and
passed after; accepted synthetic short/JWT/long values reached the actual native
HTTP adapter with authorization scoped to the exact trusted origin. CR, LF,
whitespace, controls, DEL and non-ASCII refused before HTTP; redirect refusal,
private curl stdin, input immutability, secrecy and cleanup stayed asserted.

This is **already integrated in inspected `origin/dev`** as
`2d0787ad75fe8ecd51ab9052e0a7d755308b8b9d`, including known-value literal
redaction of refused response evidence. It is not present in local `dev` yet.
The older `origin/fix/linux` live fixture lacks that newer CI-authentication
wrapper; absence of the wrapper is not a passing equivalent auth receipt.
Reconcile the published fix instead of replacing the fixture with the old draft.

Keep these completed fixtures intact:

- `c0b62021ba5ea17a27d09a277703a7c9886fee11`: native Lua receipt line endings.
- `ecf9f4193845dde744a485c63aeda118e487eb8d`: authentication case identities on
  case-folding filesystems. These are campaign fixes 39/40, not open Linux bugs.
- `fb7cc9fc628ca9bf86e9fcce1b0f8d11d2b52bde`: Linux gates invoked from Windows
  target actual WSL Linux instead of silently passing native Windows Lua;
  published in checkpoint `10e0c9f`.
- `771cff3530068c41d0cf1be81eaf6442a88c0092`: polling and native luv/inotify
  fixture ownership, with a bounded child native-event test; published in that
  checkpoint. Old backend-fixture failures are not new unresolved production bugs.

## Unconfirmed CLI fixture risk; refuted hang attribution

A selected-gates helper timed out after its global 35-minute budget, including
preceding formatting and a 354-case JS phase. Its surviving owned Lua descendant
continued printing beyond CLI edge cases and the rapid `--help` loop into later
unit modules. Captured process evidence included PID 617 in LuaJIT; the observed
state included I/O wait while the log continued to advance; this was not a
verified deadlock. Never infer a CLI hang from the ancestor timeout alone.
The same run's JS signing fixture was 353/354 with its own Git Bash timeout
coincident with disk pressure; that JS result was not reclassified green.

Separate source-backed **fixture risk**, not a reproduced driver defect:
`static/ergopti_plus/linux/tests/unit/meta/test_daemon_cli.lua` launches the real
`ergopti_hotstrings.lua` without owned HOME/XDG roots or a bounded child timeout.
Some non-help routes can enumerate/acquire an actual readable keyboard and enter
the intended event loop. The earlier diagnosis launched no user driver and did
not prove that this happened. A future isolated regression needs recording
child/device-enumeration ports, owned HOME/XDG/runtime roots and bounded cleanup;
it must preserve real help/config/error controls. No patch or GREEN proof exists.

## Local evidence appendix

The reproduction specifications and results above stand independently of these
machine-local files. Preserve these paths as provenance if still available:

`C:/Users/admin/AppData/Local/Temp/ergopti-ahk-audit-2e77b3e8698c462893a1147e65168d13/`

- `linux-ci-native-roots-nundpfcj/fix-xkb-padded-aliases/manifest.json`, originals,
  payload; `xkb-lib16-original.log`, `xkb-lib16-regression-red-qualified.log`,
  `xkb-lib16-fixed.log`, `xkb-namespace-original.log`, `xkb-lib113-fixed.log`.
- `linux-ci-native-roots-nundpfcj/fix-updater-opaque-auth/manifest.json`,
  `updater-original-red.log`, `updater-fixed-green.log` (superseded by the published
  fix for integration; still useful historical receipts).
- `linux-ci-native-roots-nundpfcj/fix-github-installation-redaction/manifest.json`
  and redaction original/fixed JS/AHK/Linux/macOS logs.
- `fractional-context-published-2p_oj5yw/manifest.json`, `finding.json`,
  `fractional-context-original-linux.log`, `fractional-context-fixed-linux.log`,
  `builder-probe-linux.log`, `probe_context.lua`.
- `system-action-payloads-10e0c9-input-audit/linux-confirm-probe.lua`, `.sh`, `.log`.

Other owned evidence:

- `D:/Temp/ergopti-linux-target-input-audit-9441ea2f8c70/`: incomplete Linux
  target draft, not a validated payload.
- `D:/Temp/linux-gate-budget-diagnosis-ay_5kg3i/receipt.json`: source hashes,
  actual log progression and the explicit CLI attribution limitations.

No repository-ready secrets, real credentials or copied user journals are
included. When integrating any fix, use current source bytes, one atomic
root-cause commit with meaningful regression coverage, and actual native Linux
qualification selected for that change. A green targeted receipt is not a
certificate that the installed driver is bug-free.

## LNX-HANDOFF-05: external clipboard writes are not fenced before restoration

**Status:** source-only external-writer overwrite risk observed on 2026-10-05.
No Linux or macOS runtime, clipboard, driver or suite was executed. This is a
separate handoff for `fix/linux`, not a qualified Linux fix or reproduced user
clipboard loss. The earlier reference table does not bind this new source scan.

**Linux owner and actual caller:**
`static/ergopti_plus/linux/adapters/clipboard.lua`, `M.paste_text`, lines 292-334;
`static/ergopti_plus/linux/modules/hotstrings/injector.lua`, line 269. The adapter
saves the prior value, publishes its payload, waits, emits the paste chord,
waits again, then calls `write_backend_checked(b, saved)` at line 328. That path
checks backend success, but neither the last writer nor current content before
restoring. Adapter SHA-256: 1b865cfdb61c91c5bd840378c396407ad21b4f225b65a494e03079e52a2b8bf0. Caller SHA-256: f5d32e73be890328e794ae65dbb4760f2f66219223d34d44ab213c50f18f3887.

**Narrow source witness:** save A, publish B, let an external copy publish C
inside the injected restore-delay sleep, then return to the actual owner. Its
next restoration still requests A. This proves the absence of an external
ownership decision in the source path; it does not observe a native overwrite.
A recording backend/sleep regression should call the actual `M.paste_text`,
record each publication and inject C during that existing wait. Preserve an
unchanged-payload restoration positive control, originally empty snapshot,
write/refusal cases, exact callback results and genuine caller coverage. Do not
copy the Windows sequence-number predicate into a backend without that contract.
The Linux owner must choose and qualify the supported backend ownership policy.

**Windows comparator:** `CB_RetryRestoreDebt` formerly exempted attempt one
when ExpectedSequence was zero and Force was true. The private Windows delta
removes only that exemption when a positive sequence becomes observable; the
actual recording-owner proof is original 9/1, fixed 10/0, inverse 9/1. The
forced-zero observation path remains unresolved, and a matching sequence read
is not an atomic guarantee against a later external write. These Windows
receipts do not qualify Linux clipboard behavior.

**macOS comparator:** `static/ergopti_plus/macos/adapters/text_sender.lua`,
`restore_clipboard`, lines 176-182, calls `Clipboard.restore` while its local
`_paste_owns_clipboard` flag is set; it does not compare a current external
pasteboard generation there. Timer and failure callers use that helper.
Source SHA-256: 312426306010af8395d662739aab179df41ec78aa9d594b85308840c3d95d59c. This is likewise a separate source observation,
not macOS native-loss proof or permission to edit that driver in this handoff.

**Frozen provenance:** the four cross-driver source snapshots and exact hashes
are recorded in the private first-fence review
`D:/Temp/ergopti-clipboard-first-fence-delivery-review-c938a205-63fd-4a3b-a9f0-708c7094049c/review.json`
(SHA-256 `681d74bd9351c8394083a3fa3847ca5dd26fbea11e4e5b9c12d764323bfbd7d7`).
The Windows passive receipt is
`D:/Temp/ergopti-root-audit-ca55cd2fb8d24de2a3089b45cd7dbe3e/passive-clock-i6siyX/receipt.json`
(SHA-256 `4b6bd03a5076adf3f34ec3ad9600e957be22a700e94de3d875fd40beebce7510`).
Its malformed auxiliary JSON was not admitted as metadata; the TAP evidence
remains distinct from the serializer-only successor.
