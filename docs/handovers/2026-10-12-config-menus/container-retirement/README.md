<!-- docs/handovers/2026-10-12-config-menus/container-retirement/README.md -->

# Configuration container retirement

This capsule preserves the inputs needed after the maintainer-requested Dev
integration and deletion of Group 1's feature, private and CI branch names.
The global [ErgoptiPlus TODO](../../../ERGOPTIPLUS_TODO.md) is the sole current
work checklist. This directory records recovery and receiving, not another TODO.

## Source and historical validation

The delivery preserves feature `c90aab10318aa29f4f7dc00b741dd39c02d5cc39`
and fresh Dev `c8a7b1f6e19f508dee1f1e132d4ca1c77f6ec95d` through an ordinary
merge. It keeps all published atomic commits. The maintainer explicitly ordered
this delivery before removal of the container; historical integration HOLDs are
not a current request to leave the work on a disappearing feature branch.
Actual delivered commits are the containing commit and its Git descendants,
not an invented preassigned final SHA.

The parent [handover](../README.md) indexes exact prior source and CI outcomes.
The final new local composition is received separately in
`retirement-gate-receiving.tar.gz`; it does not retroactively make failed hosted
runs pass. No new manual CI branch is needed for documentation or recovery.
Windows native and installed acceptance, complete daily-log source work and
all partial requirements remain explicit in the global TODO.

Existing public archives already contain the inactive Personal four-constructor,
paths-editor, picker and Snapshot source/fixtures/receipts. Retain those archived
proposals as inactive until their actual owners compose and qualify them. Old
container paths and retired branch names in historical receipts are evidence,
not files a future task is expected to find.

## Deleted branch recovery

`branch-recovery.json` names every owned local branch and remote CI tip before
cleanup. `owned-branches.bundle` preserves all unique private/CI commits and
objects, including earlier test snapshots, without duplicating the public base
history. Its prerequisites belong to the two parent histories above and are
therefore retained by this Dev delivery. It is deliberately an incremental
bundle, not a standalone repository clone.

In an ordinary complete Dev clone, verify and import its historical objects
without creating branches or altering the worktree:

```sh
git bundle verify docs/handovers/2026-10-12-config-menus/container-retirement/owned-branches.bundle
git bundle unbundle docs/handovers/2026-10-12-config-menus/container-retirement/owned-branches.bundle
```

Then use an exact tip from `branch-recovery.json` with `git show TIP:PATH`.
A shallow clone must first acquire the declared public prerequisite histories.
Do not restore obsolete candidates over current Dev or recreate CI refs merely
to resume work. The unowned `work` branch, other groups, `dev` and `main` are
outside cleanup. Branch deletion does not imply any partial TODO is complete.

The native Git bundle verifier and an isolated object database receive all
1,084 unique objects: 146 commits, 655 trees and 283 blobs. Every thin delta
base is checked against retained public history before the temporary alternate
is removed and each unique object is decoded again. Source scanning found no
signed URLs, credential-token patterns, authorization literals or private keys;
synthetic identity canaries remain unchanged in their original privacy tests.

## Portable environment sources

`reproduction-tools.tar.gz` preserves the exact installer, base activation and
native-HTTP replay source previously available only in this container. Its own
README records fixed-path relocation, required signed package metadata, actual
installation/readmission results and the reviewed but unexecuted reconstruction
mode. It includes no runtime binaries, SDK payloads, private validation keys or
customer logs. Existing GTK wrapper/overlay and SDK metadata are already in the
parent receiving archives, as indexed there.

Reinstall and verify actual dependencies in a new environment. Historical
successful activation or readmission does not qualify a fresh restoration,
reconstruction mode, new source tree, native Mac/Windows runtime or installed UI.
No secret, raw signed-redirect stderr, conversation database, whole duplicate
checkout or runtime cache is needed from the disappearing container.
