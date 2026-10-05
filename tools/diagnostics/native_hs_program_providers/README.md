<!-- tools/diagnostics/native_hs_program_providers/README.md -->

# Actual Hammerspoon provider inventory qualification

This preparation has not run on macOS. Its eleven portable Python parser controls passed in the Linux cloud container; they validate receipts and never produce a native PASS. The hosted runner must execute the native command below against the final committed source SHA.

The subject is actual Hammerspoon 1.1.1 `hs.fs`, native Lua file IO, the repository macOS provider adapter, shared policy, and central `FsDir.collect_private`. Only ConfigPaths, Paths and the logger are isolated configuration ports. Filesystem functions, directory state, source modules, native stat values and IO remain real. No Accessibility permission, TCC grant or shell script execution is requested.

## Hosted command

Place these four files together in the checkout, for example under `tools/diagnostics/native_hs_program_providers/`. Register this command after the existing native XCTest and diagnostic collectors in the macOS package job:

```sh
python3 tools/diagnostics/native_hs_program_providers/run_native.py \
  --source-root "$PWD" \
  --source-sha "$GITHUB_SHA" \
  --output "$RUNNER_TEMP/group3-native-hs-providers" \
  --download
```

The output directory must not exist. Reusing another verified bootstrap is optional: replace `--download` with `--app /absolute/Hammerspoon.app --archive /absolute/Hammerspoon-1.1.1.zip`. The archive and every installed bundle member are still checked, and the native signature verification still runs. Do not pass an unverified application alone.

Python parser controls are separate:

```sh
python3 -m unittest discover -s tools/diagnostics/native_hs_program_providers -p test_receipt.py -v
```

The native runner refuses Linux, Python older than 3.13, missing WindowServer, a modified source file, stale or malformed receipts, missing case results, failed/skipped cases, timeouts, missing signatures, and missing physical group settlement. The exact source SHA must include the macOS integer fingerprint correction: real native stat integers above 2^53 must remain exact. System interpreter targets are observed directly before any owned binary-copy substitution; the fixture must expose native APFS precision failures instead of masking them.

## Integrity and ownership

The TLS-verified GitHub release API supplies the required digest for the uniquely named official 1.1.1 release asset. At preparation time, its digest was `sha256:11bb1c90faf5427f37c7bd4fe7eab9774ae43e1d5cb020c5b3088dac32849efa`, size 9704557 bytes. The runner requires the API digest and verifies the downloaded archive before extraction, then checks exact bundle files/symlinks, version, bundle identifier, and native `codesign --verify --deep --strict`. There is no verification bypass, modified signature or replacement native runtime.

The existing `tools/diagnostics/macos_owned_process.py` owner acquires each Hammerspoon process and metadata utility in its own Darwin process group. It reserves the leader with WNOWAIT, checks actual libproc group membership, closes the group before reap, and emits the physical receipt. No Popen polling releases that reservation early. Registration retains the exact capability before acquisition returns, so an interruption in the handoff still reaches cleanup. Controller SIGTERM/SIGINT handlers raise; exact retirement temporarily ignores repeated interruption signals and then restores the handlers. Two portable register-then-raise controls cover metadata and Hammerspoon acquisition without allocating a native process. The fixture is bounded by 45 seconds and is terminated through the same owner on failure. The receipt explicitly reports `escaped_sessions_managed: false`; it makes no claim about processes that intentionally escape their inherited group.

A fresh owned directory contains the config, Unicode fixtures, nonce, receipt and script inventory. NSArgumentDomain `-MJConfigFile` selects its init.lua; persistent `MJConfigFile` is compared before and after through read-only defaults commands. Native stdout/stderr are discarded. Only bounded closed case identifiers and source hashes appear in result diagnostics. No user discovery names, contents or raw native exception text are emitted.

## Independent native census

The full process has 16 required cases: real native Lua/fs/runtime, source hashes before/after, four independently expected script choices, exact v1 literal argv with empty/Unicode/NFD/newline/percent/quote/backtick/substitution text, real interpreter symlink resolution and retarget refusal, replaced-script staleness, proven missing root, script-root symlink refusal, directory cap/truncation, repeated early-close FD observation, private native listing refusal, invalid UTF-8 filename refusal, configured-route staleness, and absence of diagnostics/execution.

A second process has five required cases with actual PATH `/usr/bin:/bin`: real runtime, source hashes before/after, actual `/usr/bin/python3` regular executable presence, and its exclusion as an installed Python provider. Both native processes must produce exactly their specified positive nonzero census, zero failures and zero skips.

The invalid-name case records whichever real native boundary refuses the input: macOS may reject creation of a non-UTF-8 filename; otherwise actual shared discovery must reject it. This is an input-refusal claim, not proof that macOS permits that pathname.

This proves inventory and lowering only. It does not execute scripts, qualify effective ACL access, prove an atomic execution lease, or observe a kernel closedir errno. Repeated early-close FD counts qualify the public Lua/native close observation. Native C directory close returns no kernel acknowledgement; the final receipt states this limitation. Actual program start, execution, descendants and cancellation remain the separate owned-program worker qualification. A passing inventory summary is not a package, installation, Apple Shortcuts, or complete item 106 verdict.

## Evidence

Retain the output directory as its own CI artifact even if a later XCTest/build/package step fails. `summary.json` is created only after both native receipts, post-run source pins, persistent config comparison and physical settlement succeed. Each process has its bounded native `receipt.json` and `physical-group.json`. Portable controls reject duplicate JSON fields/cases, zero/missing cases, stale source/nonce/PID, malformed counters, fabricated scope, failures/skips, oversized receipts, timeout and early exit without a receipt. They do not stand in for the hosted native command.
