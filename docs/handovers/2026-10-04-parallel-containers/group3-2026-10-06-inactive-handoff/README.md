<!-- docs/handovers/2026-10-04-parallel-containers/group3-2026-10-06-inactive-handoff/README.md -->

# Inactive Group 3 continuation — 6 October 2026

This is a portable, archival source handoff. The collector did not modify the Root checkout, index, branch or workflows. Importing and committing the archive will change Git state, but does not admit its prepared production sources or any native capability. Physical delivery remains unavailable. The collector ran byte/hash checks only; it did not rerun the recorded tests or allocate native resources.

Frozen receipts, controls, patches, original documentation, preimages and postimages all carry a `.txt` suffix. Their bytes are unchanged, including the UTF-8 BOM on AHK files and LF line endings. `manifest.json` maps original paths to portable paths and records SHA-256 and size. Original receipts still contain their original paths; use that map instead of treating those paths as portable launch commands. Generated catalogue bytes are reference material: regenerate through the actual generator after source review and ownership coordination.

The archive includes 17 ordered packets and 56 source-pair records. It omits raw logs, old archives, ELF binaries, caches and unrelated whole snapshots. Original evidence hashes and small machine-readable outcomes remain in the frozen receipts. Historical pinned workflow bytes are an inactive dependency reference, not a workflow change. Toolchain pins are external prerequisites, not bundled executables.

## Verify without modifying a repository

From this directory:

```sh
sha256sum -c files.sha256
python3 verify_handoff.py --manifest manifest.json
```

An external tar archive and its checksum may accompany the private preparation. They are optional transport files, not required contents of a repository import. The commands above verify the imported directory without either external file.

Check one packet's current repository preimages read-only:

```sh
python3 verify_handoff.py --manifest manifest.json --repo /path/to/ergopti --packet one-shot --require-preimage
```

Use a packet identifier from `manifest.json`. `EXPECTED_ABSENCE` requires a genuinely absent source entry. Occupied directories, unreadable entries and source symlinks are refused, including symlinks whose targets have the expected bytes. Frozen archive members must also be regular files, with no symlink ancestors. `ALREADY_POSTIMAGE` is reported separately; `--require-preimage` refuses it. A mismatch requires an additive composition and fresh review, never a whole-file overwrite. Successor preimages are their predecessor postimages, so checking every packet directly against the same checkout is intentionally not an application plan. The checks do not apply patches or prove native behavior.

## Recorded scope and predecessor order

| Chain                                                                                  | Recorded controlled result                                                                                                          | Remaining boundary                                                                                                                                                                                          |
| -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `one-shot` → `one-shot-origin`                                                         | Final producer 14/0 per Lua ABI; independent 15/0. Original nil/untrusted-receipt bypass was red and remains archived.              | Metadata/context dependency below; native physical source/output custody and full final-source qualification remain separate.                                                                               |
| `caps-word` → `caps-word-tick`                                                         | Final controlled cohort 171/0 and unchanged title-word cohort 59/0 per ABI; independent delayed-tick source-revocation red → green. | Prototype remains inactive. Its daemon wiring must not expose manual CapsWord before joint native source/output custody is qualified. No CapsLock writes, unsupported layout or multiscalar fallback claim. |
| `context-catalogue` after `one-shot-origin`                                            | 92/0 per ABI, source/codegen controls recorded. Generic GestureManager still refuses native-only one-shot dispatch.                 | Regenerate catalogue with its generator, coordinate shared action/context ownership, register and qualify actual final sources. CapsWord context is not enabled.                                            |
| `writer` → `writer-transaction`                                                        | Final writer 60/0 per ABI; independent refusal/retirement controls recorded.                                                        | Kernel uinput and physical output not executed; no global modifier custody or physical availability.                                                                                                        |
| `reader-origin` → `reader-identity` → `reader-held-query`                              | Final held-query 65/0 per ABI; independent SOURCE CLEAR `df59ff99`. Earlier identity BLOCKED reviews are retained.                  | EVIOCGKEY/kernel, source-device deployment, output join, full driver/packaging/install not executed. Observations do not create a kernel/global held-key lease.                                             |
| `hook-held-witness`                                                                    | 14/1 per ABI, deliberately red.                                                                                                     | Regression witness only. This is not a repair and cannot be admitted as one.                                                                                                                                |
| `windows-hkl` → `windows-hkl-scalar` → `windows-hkl-any-refusal` → `windows-hkl-bound` | Portable source/loop/syntax controls; joint SOURCE CLEAR `49ac33f9`.                                                                | Six actual AHK cases, Windows compile/unit/E2E and real HKL behavior remain unexecuted. Readonly descriptor preparation does not qualify Windows 107 delivery.                                              |
| `mac-app-switcher` → `mac-app-switcher-terminal`                                       | macOS controlled 37/0; pure shared LuaJIT 27/0; terminal seal SOURCE CLEAR `895bf708`.                                              | Genuine Hammerspoon/native application switching, modifier/output custody, host E2E and packaging remain unexecuted. Availability stays false.                                                              |

These are independent branches of preparation, not a single safe full feature patch. In particular, the CapsWord branch and the context branch share the one-shot prerequisite without claiming that their combined final source has been qualified. BLOCKED predecessors and expected-red omission controls are retained; a later source-clear review applies only to the exact successor bytes it names. Review receipts and outcome JSON files distinguish successful, failed, intentionally red, and unexecuted checks. No TODO item is completed by this handoff.

## Before any future admission

Read current `AGENTS.md`, routed memories, `verify-change`, TODO and coordination handover. Fetch current `origin/dev`, inspect index/working tree, and preserve other groups' source. Confirm ownership leases for Linux `evdev_reader`, `uinput_writer`, keyboard hook/remap engine, shared action/context/casing definitions and generators. Windows `key_state`/AHK tests and macOS gesture-switcher ownership also require coordination. This archive grants no leases.

Rebuild a separate owned source snapshot in predecessor order and compare every exact preimage before mutation. Preserve native-only action contexts and all original corpus/assertion contracts. Resolve callbacks, output/source/held-key custody and actual platform availability before enabling a capability. Run required final-source portable, native, E2E, packaging and installation gates with no releases, following current CI serialization rules. A source review or controlled model is not native qualification. Keep physical getters false until their actual producer/consumer chain is qualified.
