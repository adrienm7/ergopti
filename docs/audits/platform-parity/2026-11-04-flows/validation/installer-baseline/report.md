# Pre-existing installer inventory omission

The macOS owned-runtimes registry omission predates the parity audit delivery. An exact-parser, immutable-blob replay confirms the same missing `installer` program at all three inspected commits:

| Commit                                   | Missing registry program | Programs derived from the Swift owner          |
| ---------------------------------------- | ------------------------ | ---------------------------------------------- |
| 213d65af24d2aa4845ba47743c9bab6787b61964 | installer                | launchctl, pkgutil, installer, sh, echo, sleep |
| 1fa4c28f318258dd1af31920b1a55b8bb4c33de1 | installer                | launchctl, pkgutil, installer, sh, echo, sleep |
| 89d477dcc06b85b71071e6d5f1fe8d701bf51649 | installer                | launchctl, pkgutil, installer, sh, echo, sleep |

`OwnedRuntimeCoreLaunchctl.swift:40` passes `/usr/sbin/installer` to its native child owner. The production inventory extractor `tools/test/lib/spawned-tools.cjs:306–311` derives `installer` from this actual Swift source; `tools/test/test-owned-runtimes-inventory.cjs:185–195` rejects derived program names missing from the OS registry. The loaded, validated `static/ergopti_plus/_shared/data/owned_runtimes.json` contains no macOS program `installer`. `launchctl` from the same Swift file is covered, which supplies a useful positive control.

Reproduce:

```sh
npx --yes --package=node@22.22.2 node /workspace/scratch/parity-flows/installer-baseline/bounded.cjs
```

Result: exit0 for the diagnostic assertions, Node22.22.2, each baseline derives six programs `[launchctl, pkgutil, installer, sh, echo, sleep]` and reports exactly `installer` missing from the macOS registry. Diagnostic exit0 means the pre-existing omission was confirmed; it does not mean the original inventory suite passed. Raw per-commit results and decisive blob hashes are in `bounded-receipt.json` and `*-bounded.log`.

The replay reads each commit's exact parser, registry loader/helper, registry JSON and complete Swift owner through a read-only git-backed virtual filesystem. The directory view is intentionally bounded to the one Swift owner; it does not execute or weaken the full inventory test or pretend to cover other native tools. No application source is rewritten, no checkout is created and no install command executes. All six decisive blob identities, including the unchanged original inventory test itself, are identical across the three commits. Working-tree and staged comparisons of these six inputs against213d65 are empty (`working-inputs-diff.txt`, `staged-inputs-diff.txt`); the reviewed-baseline diff is also empty.

TODO review at213d65 and1fa4c28 found no explicit installer/inventory omission entry. TODO.md:540 has a general owned-runtimes backlog concerning the shared Karabiner/managed daemon, not this missing system-installer registry program. Exact matches are retained in `*-todo-matches.txt`; no task was added in this read-only verification.

The optional full immutable-FS suite replay was CPU-bound and safely terminated in its own Node process at the parent's request. It produced no completion receipt; no full-suite result is inferred from that attempt (`full-scan-aborted.txt`). This bounded proof demonstrates that the reported source/registry mismatch already exists at each baseline; it makes no native Mac execution claim and no assessment of other failures in the full current JS suite.
