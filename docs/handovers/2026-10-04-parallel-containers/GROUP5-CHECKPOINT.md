<!-- docs/handovers/2026-10-04-parallel-containers/GROUP5-CHECKPOINT.md -->

# Group 5 macOS input checkpoint

This is a partial feature checkpoint, not group completion or integration into
`dev`. Preserve `feat/macos-input` until its remaining scope is qualified.
The inspected base is `689d30293704093feab2e3caa077604e88560eb6` from the actual
`origin/dev`; no old handover patch belongs to this group.

## Pushed changes

| Commit                                     | Scope                                                                                 |
| ------------------------------------------ | ------------------------------------------------------------------------------------- |
| `7003b559ab20a15474cbe232278359b644cfd355` | Dormant physical-capture ownership and typed version refusal; TODO31 remains partial. |
| `987fb3c838ebf6c7682d802364abf1fcffc455e4` | Close already validated TODO13/35 while preserving the legend and TODO16/38.          |
| `f02abb8bc2365d579bc6246b56b2d40ab3b36b52` | Retain internal producer usage-page identity and strict baseline-v1 boundaries.       |
| `00bec5d2ef036eefde9e19b58c8ecb0ef465fa31` | Expose existing native launch observations through one bounded failure notice.        |

Default startup does not load the new capture session. Opening v1, consumer
baseline v2, producer baseline v1, fixture-only coverage and independent JSON
corpora remain unchanged. The native consumer contract deliberately refuses
`consumer_baseline_version_mismatch` with exit3; do not erase that guard.

Each exact pushed SHA was inspected for automatic Actions runs; none existed.
No release, feature deletion or push to `dev` has been performed.

## Verification receipts

The source-selected `verify-change` gate passed formatting, 356 JS checks,
13,902 portable macOS Lua units and 101 stubbed E2E scenarios. One driver-specific
E2E vector was skipped. After staging new sources, the JS gate was repeated and
passed; subsequent diagnostic/document commits passed their selected format/JS
gates. JS and native suites were serialized.

The capture regression suite uses faithful native task doubles and the actual
accounting, delivery and transport owners. The unsupported-version regression
failed all three original cases; six independent reentry/start-acceptance cases
failed before correction. These results do not establish physical input or
native Hammerspoon task acceptance.

Producer validation compiled and ran six complete programs under C++17 and
C++23, with `-Wall -Wextra -Werror -pthread`: raw capture, session, inventory,
key state, protocol and source. All 12 executions pass with unchanged independent
native JSON receipts. Two changed-page cases fail against the original source.
The unrelated key-element test still fails GCC compilation on an unused local;
an isolated exact-HEAD replay reproduces that failure. The clock/native probe
requires Mach/IOKit and was not executed on Linux.

The launch diagnostic suite passed 225 portable Python cases; the native AppKit
calibration `ManagedLaunchNativeCalibrationTests.test_real_nsworkspace_identity_bool_foreign_and_closed_observations`
is skipped on Linux. Two actual CLI tests fail against the original source
because its notice is missing. Independent reviews found no blocking findings
in the final three bounded source slices. No original deadline, assertion or
failure verdict was relaxed.

TODO13/35 closure reuses inspected native receipts:

- Run37081066757 at `c47624171d2594785f1590a7f0fd7a6e460810fa` passed actual
  signed helper registration, wrong-inode refusal, unregistration and idempotence.
  Its guardian ownership and receipt-judge sources match the current feature.
- The entire launcher matches `38e4ec1c410f2ac3a076b1f71bcbf74a96d03320`;
  run37220040009 passed native Swift tests and macOS packaging. That run's
  clean/Karabiner AppleEvent failures remain blocking under TODO40.
- Windows F2 touchpad ownership paths match `6275cac35`, qualified in the complete
  non-release three-OS run37033032620. Physical desktop acceptance remains under
  TODO16/38; injected registry tests do not establish a physical touchpad.

## Remaining scope and maintainer answers

- TODO24: actual Login Items/guardian approval UX still needs a real Mac.
- TODO30: physical magic-key acceptance remains; preserve equivalent OS behavior.
- TODO31: WP3 production context/log-sink/holds/recovery/shutdown and WP4-WP10
  remain incomplete. The current preparatory modules do not enable the runtime.
  Per-device keyboard-type classification and an authenticated provider
  compatibility tuple are missing. The maintainer chose to block an incompatible
  VirtualHIDDevice runtime with an explanation and offer an update only after
  confirmation. Package numbers, an official DMG version and fixture-only
  receipts cannot be used as an invented ABI compatibility matrix.
- TODO40: original managed AppleEvent admission, timer measurements and all eight
  native Karabiner publication vectors remain mandatory. A supplementary
  bootstrap or Lua bridge witness cannot replace them. The pinned Hammerspoon
  handler returns immediately for disabled scripting once entered; a sender
  timeout alone does not identify TCC, handler entry or a blocked main queue.
- TODO43: the maintainer no longer has the original backed-up `karabiner.json`
  behind the 25-ambiguous-rules report. Do not claim that exact configuration was
  diagnosed. Preserve cleanup confirmation, backup and ambiguity refusal.
- TODO44: physical pointer cancellation of Karabiner-activated CapsWord remains
  unqualified. Existing sentinel implementation must not be redone without
  evidence of regression.

A real work Mac is available only as a last resort. Maximize meaningful CI;
collect the remaining physical checks together after CI has resolved everything
it can prove. Hardware double results cannot close these acceptance requirements.

## Native CI reservation status

No new group5 native CI has been executed. The existing remote lock
`0563f0d589a181698bd2b13d75026aec673dbb61` belongs to group7, branch
`feat/windows-native`, candidate `45d5c2db602ee74711da965ba17207c69b6dcba5`.
Its first run37228466168 reached terminal failure; the owner subsequently
continued the same reservation with new manual runs, including37232550379.
Inspect the current terminal result and actual owner release before reserving. Do not take it over or delete it. Group5 has
not moved `codex/ci-validation` and does not own either CI ref.

Group4 published the standalone shared Core provisioning correction at
b57a94802986adb80496d8abb7e4c1bcb6298299. Group5 reuses only its workflow hunk;
`.github/workflows/ci.yml` matches that released owner image byte-for-byte.
Stock Lua5.4 receives lua-luv for unchanged exact native file admission; no
fallback, assertion, lane or release-policy change is made. Fresh hosted proof
remains pending. The group5 macOS phase must verify candidate/CI tree equality,
the actual tested SHA, terminal job conclusions and skipped Release before
releasing its own newly acquired lock.

## Coordination and setup

Coordination is recorded in GitHub issue86. Group3 owns only its new native
program worker/helper/fixtures and the new headless dispatch hunk in `main.swift`;
it must preserve guardian/remap roles, AppKit mode and Package.swift. Group5
holds no shared manifest/schema/locales/generator ownership.

Use the remote `codex/ci-lock` only as a lock. Its empty commit must parent the
latest `origin/dev` and name group5, feature branch and exact candidate. An
existing lock blocks reservation; only its owner deletes it after terminal CI.
Dispatch exclusively through `codex/ci-validation`. A validation-only two-parent
commit can retain the previous CI ancestry while using the exact candidate tree;
verify both tree equality and actual tested SHA. Do not force-push or import
other groups' unintegrated payloads into the feature.

The installed cloud tooling is outside the checkout. Activate
`/workspace/ergopti-cloud-activate.sh`; run validation under
`python3 /workspace/ergopti-cloud-reap.py COMMAND ...` to reap only adopted children
and preserve the exact command status. `TMPDIR=/var/tmp/ergopti-cloud-validation`
avoids protected `.git` ancestors; never remove those markers. Restricted sessions
need the execution tool's approved escalation for that temp path. A private signed
APT sysroot supplies Lua5.4/LuaFileSystem/luv, Linux LuaJIT/luv, sqlite3, xmllint
and nlohmann headers; Node follows `.node-version`, Ruff is repository-pinned,
and RTK is checksum-verified. The complete saved installation script passed
again on the current clean feature. Saved environment settings remain a draft
until the user saves and publishes them; no fresh-task restoration is claimed.
