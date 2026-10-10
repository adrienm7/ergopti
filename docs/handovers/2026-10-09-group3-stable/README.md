<!-- docs/handovers/2026-10-09-group3-stable/README.md -->

# Group 3 partial stable-release delivery

The [published Linux and native continuation](linux-and-native-continuation.md) records the later feature sources, exact local outcomes, recoverable inactive preparations and remaining software/native acceptance. This capture precedes its next integration; it does not claim stable-release qualification.

The [latest integrated tranche and qualification](latest-delivery.md) extends
this historical delivery; its exact-source evidence and inactive preparations
are recorded separately.

The maintainer requested immediate partial integration before the first stable
release. The reviewed action and input commits are integrated without squash
in `dev` at `a5f6300d872a9741bbd566492185727a738b2a79` (merge parents
`55144c29c91f6660635802d2646aae2edf9fc4fd` and
`2ac579008014e10daeb3c09ca681287c5f904069`). Its tree is exactly the locally
qualified feature tree. Both automatic workflows on that merge SHA were
cancelled; no release was requested or published by this delivery.

This is a partial delivery. None of the 13 Group 3 items is removed from
[the TODO](../../ERGOPTIPLUS_TODO.md). Items 16 and 38 retain their acceptance
requirements; item 22 remains withdrawn. The website is outside this delivery.
The following documentation supplement changes no runtime, generator, workflow,
registry, independent corpus or expected native result.

## Validation

Local selected `verify-change` gates passed: formatting, 393 JavaScript checks,
and 17,687 Hammerspoon Lua assertions in 1,551 modules. This Linux-host Lua
execution does not establish native macOS input, installation or hardware use.

The manual all-OS run
[37911147375](https://github.com/adrienm7/ergopti/actions/runs/37911147375)
tests the exact integrated SHA above on `codex/ci-validation` and is terminal
FAILURE. Release is push-only and its job is SKIPPED in this manual run. The
complete Linux chain is successful; the Windows and macOS verdicts fail.

- Core JavaScript and properties pass.
- Linux unit tests pass: 12,401 assertions in 518 modules. E2E, packaging,
  all 17 installation/launch scenarios and the Linux verdict pass.
- Windows units report 10,512 passes and two failures: revocation of a queued
  managed-curl admission (`test_managed_curl_callers.ahk:37`), and the canonical
  WinHTTP Ex full-PAC entry point (`test_managed_routes_native.ahk:26`). Windows
  E2E, packaging and installation are skipped. File location alone does not
  prove these failures are unrelated to the composed source.
- macOS stubbed unit/E2E and the 12-capture native tooltip gate pass. Native
  launcher compilation succeeds. All 17 OwnedAutomationQueryWorker tests,
  including the three new permission/retirement controls, and all 14
  OwnedProgramWorker tests pass. Sparkle native archive acceptance passes all
  15 tests. The complete XCTest suite reports 357 cases and two assertion
  failures in one Homebrew case: sender exit 66, AppleEvent -1744, reply-read
  -1701. The separate read-only Shortcuts probe reaches checkpoint1, fails to
  return a catalogue within the unchanged 20-second budget, and retires the
  exact process group. Its cause is not established. Packaging/verdict fail
  and native installation is skipped.

The newly compiled permission tests exercise controlled packets. The default
workflow does not execute an authenticated signed-app SDK permission observer;
native API execution, its source/signature provenance and Darwin retirement
remain unrun. Do not equate the passing tests with a consent grant, a catalogue,
shortcut invocation or diagnosis of the JXA stall. Brew's AppleEvent observation
is a separate boundary and does not establish the Shortcuts cause.

## Remaining work

The TODO owns the full requirements. These are continuation pointers, not new
completion claims or a request to repeat already qualified component work.

| Item   | Remaining software or acceptance work                                                                                                                                                                 |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 63     | Final native package/startup chain and actual brightness response.                                                                                                                                    |
| 71     | Joined native migration, packaging and installation acceptance.                                                                                                                                       |
| 73     | Historical category-writer evidence; the maintainer cannot recall the preceding operations. Do not force-enable categories.                                                                           |
| 91     | Final native and physical ordered-pair/modifier acceptance.                                                                                                                                           |
| 93     | Public simultaneous-combination declarations, persistence/Save/copy joins and actual native receiving/modifier acceptance. Private preparations below remain inactive.                                |
| 96     | Final native migration and application/device acceptance.                                                                                                                                             |
| 97, 98 | Effective-source joins, complete owner collision checks, modifier/output/Unicode/dead-key behavior and safe legacy migration. Physical assignments are not enabled on Linux/macOS.                    |
| 106    | Real supported provider inventory/invocation, bounded Shortcuts ownership and chosen-ID revalidation, cancellation/retirement, cross-consumer parameters and authenticated native helper publication. |
| 107    | Original shifted/symbol output and issued native row/source information; coordinate Windows navigation ownership and macOS native input ownership.                                                    |
| 108    | Live effective-source editor retargeting, collision and compensation using issued source epochs.                                                                                                      |
| 109    | Supported nonforeground AHK variable/key-history capture and identity-safe console acceptance; do not replace it with a foreground main-window capture.                                               |
| 111    | Final native installation, actual two-display/Dock switching and modifier custody.                                                                                                                    |

Windows managed-network and macOS Brew/Shortcuts CI failures are software gates,
not tasks that can be replaced by physical-device testing. Remaining hardware
checks on the maintainer's Windows/macOS machines are a last resort after those
software gates and input-owner joins are complete.

## Recoverable inactive preparations

[inactive-recovery-v3.tar.gz](inactive-recovery-v3.tar.gz) is a compact evidence
archive, not installed product source or a generator input. SHA-256:

```text
ebbaa8eb488f990a22791ada4f03c90206965acc63609b03c725bf141953d96b
```

Size: 689,839 bytes. Its outer manifest hash is
`9498a04611cf2f3cb5abff58c868306c6aa7593668a40e17e7d8351e041cb78f`.
Every one of its 22 manifest entries and all outer paths were verified before
saving it. Nested immutable v1/v2 archives retain their original manifests,
source pairs, patches, receipts and focused causal controls.

- SDK permission-only enrollment: reviewed private source; actual signed-app
  enrollment and native SDK execution are absent. Compose any proposed Swift
  test with the integrated wire-line correction; never restore the older
  String-versus-Data comparison from a saved postimage.
- Linux writer sysname and Xorg receiving harness: reviewed private source and
  controlled ABI/refusal checks. Actual kernel IOCTL/desktop receiving and normal
  registry/workflow enrollment remain unrun. Do not apply two cumulative writer
  patches over each other.
- Linux simultaneous runtime v1 is HOLD: a completed buffered cohort could
  retain a stale cleanup map after reader remove/re-add and leave a new reader
  open after Stop. The archive preserves the independent causal failure.
  The two-path v2 successor refreshes the exact cleanup leases only after the
  original successful native-complete publication. Independent source review
  clears the ordered v1+v2 combination, with 189/0 focused assertions on both
  Lua ABIs and causal negative controls. This does not enable the public feature
  or qualify actual kernel/input/desktop behavior.

Extract only into a new owned temporary directory. Check the outer and nested
manifests, relocate historical absolute paths deliberately, and reconcile each
exact preimage against current `origin/dev`. Apply simultaneous v1 followed by
its v2 repair only in a private proposal. Preserve independent oracle bytes.
Coordinate shared declarations, input owners, registry, generators, signing and
workflow enrollment before any adoption. Use proportional `verify-change`
gates, serial JS/native execution, and honest pass/fail/skipped/unrun records.
