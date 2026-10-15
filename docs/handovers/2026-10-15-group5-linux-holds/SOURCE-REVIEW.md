<!-- docs/handovers/2026-10-15-group5-linux-holds/SOURCE-REVIEW.md -->

# Linux physical-hold source review

This is the independent incremental review of the six files changed for
observed hold exclusion. It preserves its complete JSON body below, whose
SHA-256 is `a328d3c7f8eef264ed3bfbe92b5b2a2762e1a0576c418fa9f08e23ceccc333eb`.
It grants source review only; native supplier approval and actual desktop
qualification remain separate.

```text
{
  "format": "group5-independent-six-source-review-v1",
  "verdict": "SOURCE_CLEAR",
  "scope": "Independent final incremental semantic review of exactly six Linux files against genuine Git base f4811656d3755d16fd9a4ae00c06f5df7378b78d. This body is self-contained; no unseen historical approval is inherited.",
  "base_commit": "f4811656d3755d16fd9a4ae00c06f5df7378b78d",
  "source_images": [
    {
      "path": "static/ergopti_plus/linux/adapters/keyboard_hook.lua",
      "mode": "100644",
      "pre_git_blob": "83e158b89f6a24d8978ad5d49845ff2084ee31f9",
      "pre_bytes": 184889,
      "pre_sha256": "747618881c989f2b514dd16c82bf5903b945a98047e3d342d20f5b63ae3dcd27",
      "post_git_blob": "ba1fed9dc3df0b942f1a06ac6101b60e7c49870a",
      "post_bytes": 186780,
      "post_sha256": "df2fcc5b78f90c760514a484c4f75762dcaaab40f221a0d25c8443064bcfca98"
    },
    {
      "path": "static/ergopti_plus/linux/modules/keylogger/keylogger.lua",
      "mode": "100644",
      "pre_git_blob": "0b0e62f3b100bbaa0def2535ea8a2e3d467f8b77",
      "pre_bytes": 77555,
      "pre_sha256": "1c68f44b7b31397ac2314294fafbb1034abe42b90a97a48ba44287457cf0f149",
      "post_git_blob": "d4b952ec1614b401503188e6a12071ef48315286",
      "post_bytes": 78877,
      "post_sha256": "5af6e83a2fe20b3a3b9f27c47ab5ddb9429a9041c7e48dfe21fe4c356302afb2"
    },
    {
      "path": "static/ergopti_plus/linux/ergopti_hotstrings.lua",
      "mode": "100644",
      "pre_git_blob": "c577ab1ce09288ece02aa13ec3f65d2b8cca5403",
      "pre_bytes": 115075,
      "pre_sha256": "78a3870abcc387009774700379f24a2e63c9b2bc4a2a7c18cedce3d165b18c9c",
      "post_git_blob": "d08fdacd2b1d901edb9a893687fe9471dd711cbd",
      "post_bytes": 115696,
      "post_sha256": "a918392a625144ee6a506286fbced4a8afc2c20522671dfec54352be0c8a8f1d"
    },
    {
      "path": "static/ergopti_plus/linux/tests/unit/modules/keylogger/test_hold_durations.lua",
      "mode": "100644",
      "pre_git_blob": "15f6c0617fc8549e87836244dea1d29556235fe8",
      "pre_bytes": 8948,
      "pre_sha256": "000716b06490736a0c2d8f3333e077e790987418947cf9d22d54805b6f5905bd",
      "post_git_blob": "5d1094d83ec405096a3e1fc2c1958879e2e0df5f",
      "post_bytes": 20182,
      "post_sha256": "f7f5147099b76d5dcc19af7dbec9cc786b47d58ce16ad6dd52a729b3a3b08f09"
    },
    {
      "path": "static/ergopti_plus/linux/tests/unit/modules/hotstrings/test_dynamic_multibyte_trigger.lua",
      "mode": "100644",
      "pre_git_blob": "5e66238279ee306b17a54c8df0a2fc5d9d257f61",
      "pre_bytes": 10347,
      "pre_sha256": "1db1f6bf30961cefabe91a68ea3d0ef2d866d6a1ee46aab6c809a942e20ac186",
      "post_git_blob": "98e9b689de0480f059debd87785395a133afdbd5",
      "post_bytes": 10407,
      "post_sha256": "aa091e76ff15065e4dee14e671f430973fae804b19d418c40486c00427b8551e"
    },
    {
      "path": "static/ergopti_plus/linux/tests/unit/modules/hotstrings/test_magic_key_source.lua",
      "mode": "100644",
      "pre_git_blob": "7c6d3a38283d1e40e34f077ace2fe5b9c3b53119",
      "pre_bytes": 83559,
      "pre_sha256": "9716504c1c23eb2e47d7e9fba017b4488f99b06b310f44714280d249f27d0b3f",
      "post_git_blob": "282dfa0eab1a3ab576ca72afd399ac2bb1965ab7",
      "post_bytes": 83613,
      "post_sha256": "6004b244820a535ed2e994acadf29e0872e69b80033b9c022291abd1f1f7e813"
    }
  ],
  "problem": "A physical DOWN in an included context could be credited on UP after private, secure, authentication, pause or UI-capture exclusion had begun and ended. Release-time permission alone loses the excluded interval.",
  "findings": [
    {
      "area": "Token and physical identity",
      "reason": "Hook retains the plain-table policy token plus exact admission callback for each original source_key. A missing/refused DOWN token cannot become eligible later. UP clears the original record before callbacks and credits only matching token and callback identities. Excluded intervals are discarded whole rather than subtracted or reconstructed."
    },
    {
      "area": "Effective policy and durable refusals",
      "reason": "Logger rotates the token on effective existing may_record/password-app denial. Private/secure setters and successful enabled/filter/configuration commits settle before logging or foreign publication. Existing Preferences/store_bool, migration and cipher refusal paths precede these additions, so a refused policy write does not pretend that the requested policy committed. Existing included policy updates retain eligibility."
    },
    {
      "area": "Actual focus and authentication",
      "reason": "Main publishes actual focus and private classification before existing UI/engine callbacks, including initial focus. In-memory focus lets committed secure/Auth filters invalidate a held interval without another input event. Statistics reset rotates the token but retains that actual focus; module initialization separately resets it and Main seeds it. Existing physical DOWN unsuppresses after leaving Auth before the new hold admission runs, preserving the first fresh included press."
    },
    {
      "area": "Pause, capture and reentry",
      "reason": "Main revokes at the top of genuine ScriptActions reset before engine/UI callbacks, as well as pause notification and UI-gate on_block. Thus synchronous reset-to-resume cannot preserve a token even when both later notifications report false. A new unblocked DOWN clears only the prior captured-press metrics marker, so a completed captured press does not suppress the next fresh duration."
    },
    {
      "area": "Startup and source reconciliation",
      "reason": "New callback is validated in a local during startup and published only after original successful source transaction/number-row construction plus exact capture-session/running check. Session mismatch denies tentative borrowing; refused startup does not replace the admitted callback. Reconciled already-held keys receive no fresh eligible timestamp when admission is enabled. Legacy callback-less callers retain their original route, and real Main explicitly supplies the new admission callback."
    },
    {
      "area": "Forwarding and remapping",
      "reason": "The six literal diffs leave original raw forwarding, modifier/CapsLock dispatch, consumed-event handling, remapper operations, repeat nonreset behavior and maximum-duration clamp intact. New denied metrics do not introduce an early event-path return. Per-source cleanup now removes the corresponding metrics owner alongside the original timestamp."
    },
    {
      "area": "Registered controls",
      "reason": "The existing registered hold test receives an appended source-composed cohort. It executes real Hook/Logger, real InputCaptureGate and ScriptActions, and exact Main physical/hold/reset/pause fragments plus actual startup binding over disclosed evdev/clock/writer/UI ports. Controls include excluded intervals without another event, durable refusal, Auth-reset memory, first post-Auth press, startup refusal/reentry and reset-triggered resume. It does not boot the whole daemon."
    },
    {
      "area": "Two existing fixture dependencies",
      "reason": "Dynamic-multibyte callback compiler adds the genuine keylogger require; magic-key pause compiler adds the same real module to its environment. These are exact setup bindings required by the new actual Main calls. They add no fake return, runtime nil guard, assertion weakening or alternate production behavior."
    }
  ],
  "preservation": {
    "original_hold_cases": 8,
    "original_hold_test_prefix_bytes": 8948,
    "original_hold_test_prefix_sha256": "000716b06490736a0c2d8f3333e077e790987418947cf9d22d54805b6f5905bd",
    "original_assertion_call_occurrences": 14,
    "original_assertion_calls_and_expected_values": "All original test bytes, including every original assertion and expected value, remain the exact prefix.",
    "hold_case_enrollment": "Existing eight plus fifteen appended cases; no new runner/registry/workflow entry.",
    "other_fixture_assertions": "Both complete original fixture files are recoverable by removing only the exact keylogger setup insertions; all assertions and case bodies otherwise unchanged.",
    "linux_disabled_apps": "No metrics disabledApps gate exists in these inspected sources; no new parity policy is claimed."
  },
  "boundary": {
    "reviewer_actions": "Read the six complete genuine-parent diffs, relevant existing call graph, and exact pre/post bytes. No target test/import/compiler/native execution and no canonical/source/index/ref changes in this final pass.",
    "authority": "Source-only approval of these exact six images. No new native/supplier/profile approval, X11/Wayland grab or injection credit, permission/ABI/readiness grant, hardware qualification or customer exit73 resolution.",
    "automated_receipts": "Earlier targeted and full isolated Linux software receipts remain separate observations; this snapshot neither reruns nor expands them."
  }
}
```
