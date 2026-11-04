# Windows lifecycle qualification: resolved host-runtime admission failure

Baseline SHA: `89b0b774c8c960c7ad458ac3cb98d5c97598e518`.
Date: 2026-11-04. This supplements the existing lifecycle report without modifying it or repository/test files.

## Exact cause

`tools/test/test-windows-updater-original-source.cjs:923` expected three deliberately modeled child-acquisition attempts, but saw zero. The model had already refused admission, with this actual collector receipt:

```json
{
	"calls": 0,
	"errors": ["Error: Regular unaliased source/image required."],
	"status": "FAIL",
	"stderr": ["Error: Regular unaliased source/image required."],
	"exits": [1]
}
```

The collector fingerprints its own Node executable before SDK acquisition or child dispatch (`tools/ci/run-windows-updater-original-diagnostic-cohort.cjs:225-227`), using `readSourceFile(process.execPath, 134217728)`. That receiving function explicitly requires a regular non-symbolic-link file with exactly one hard link (`tools/ci/windows-updater-original-source.cjs:47-52`) and repeats identity/link-count checks on its acquired handle and final pathname.

The pinned Node22 runtime supplied by `npx --package=node@22.22.2` was:

```text
/home/agent/.npm/_npx/5705de4b80ce9477/node_modules/node/bin/node
version=v22.22.2
size=124679552
nlink=2
sha256=81925c0995b5c1427b5d538e6a90ca2fdc4daffb786b09af749beaf7369d4e90
```

Its size is within the 128-MiB receiving bound. Its hard-link count violates the explicit unaliased-runtime policy. A direct call to the real `readSourceFile(process.execPath, 134217728)` returns the same refusal. This explains why no modeled child acquisition took place; it was not a missing updater production callback.

## Validation and control

First repeated the failure with real Linux PowerShell7.4.6 explicitly on PATH, plus the supplied Lua/lfs/luv paths. Failure remained identical. PowerShell availability is unrelated to this pre-child Node-file receiving check.

To expose the receipt, `qualification-diagnose.cjs` loads the original test into memory with one additional observational print immediately before the existing failing assertion. It preserves the assertion, production files, selected source pins and test fixtures. Its output is retained in `qualification-diagnose.log`. This instrumented run is diagnostic only, not the passing evidence.

Then made a task-owned **byte-identical independent file copy** of that same Node22 binary. It had `nlink=1`, the same size and SHA-256. No test assertion, security check, source pin or runtime version was changed. Ran the **unmodified repository test file** with that executable and the same environment:

```sh
PATH=/workspace/scratch/parity-toolchain/pwsh-7.4.6:/workspace/scratch/parity-toolchain/bin:$PATH \
LD_LIBRARY_PATH=/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu \
LUA_CPATH='/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu/lua/5.4/?.so;/workspace/scratch/parity-toolchain/modules/?.so;;' \
docs/audits/platform-parity/2026-11-04-deep/windows-lifecycle/node22-unaliased \
tools/test/test-windows-updater-original-source.cjs
```

Result: exit0, including:

```text
PASS actual local main reaches modeled acquisition with real Source and honest metadata
PASS original child commands clocks and independent oracle remain frozen
WINDOWS_UPDATER_SOURCE controls=23 native=false official=false
```

The run also executed all 12 actual source-seal CLI controls. Full output is retained in `qualification-unmodified.log`. The temporary 119-MiB binary was removed after completion; to repeat, copy the identified pinned runtime into a new task-owned file with one hard link and verify its hash first. No globally installed executable was altered.

## Interpretation

This is a host-runtime prerequisite failure, resolved by supplying a runtime file that satisfies the existing receiving policy. The security refusal was correct for a two-link binary; the final count assertion exposed that earlier refusal with little context. The passing unchanged test establishes its modeled/source-qualification checks under the corrected environment.

It is **not** production updater failure evidence and **not** native Windows updater success. The test explicitly reports `native=false official=false`; it does not install an update or run the real Windows AHK child. Windows native lifecycle and executable-replacement checks remain unavailable. Repository SHA and working tree were verified unchanged and clean after both runs.
