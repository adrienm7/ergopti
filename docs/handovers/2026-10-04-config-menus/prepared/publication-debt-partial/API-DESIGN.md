# Conditional publication receipts (candidate design, not integrated)

Baseline: 375de99fbfdaf0ecf4d4ba06e71be7940fe0470c.

The optional native conditional publisher keeps its existing first two returns.
A refusal can additionally return one private closure. Calling that exact
closure settles only native cleanup owned by that publication and returns
`settled, detail, published`. Both terminal flags must be literal booleans.
The closure is idempotent after settlement and never publishes, unlinks a live
source, releases a successor's lock, or obtains another caller's capability.
The shared exact-byte writer forwards the same function identity unchanged.
The ordinary two-argument FileSystem port and shared port map stay unchanged.

| Native outcome                           | First result | Third capability       | Compensation                                                                      |
| ---------------------------------------- | ------------ | ---------------------- | --------------------------------------------------------------------------------- |
| Refused before mutation, released        | false        | none                   | No publication inverse                                                            |
| Refused before mutation, release pending | false        | exact cleanup          | Settle cleanup; published=false; preserve any successor                           |
| Published candidate, released            | true         | none                   | Existing exact-source inverse                                                     |
| Published candidate, release pending     | false        | exact cleanup          | Remain pending; settle cleanup; published=true; exact-source inverse              |
| Inverse published, release pending       | false        | exact cleanup          | Remain pending; settle cleanup and verify inverse target; no repeated publication |
| Source changed while an inverse is owed  | false        | retained private state | Preserve external bytes; remain pending                                           |
| Backup written, release pending          | false        | exact cleanup          | Retain admission debt; settle cleanup only; keep backup data                      |

A failed layer import returns `nil, detail, failed_record`; that record stays
private on the scope sibling. It owns exact preset/path plus the native closure.
A pre-publication record becomes KEPT only after a literal published=false
receipt. A post-publication record remains IMPORTED and is removed only through
the existing conditional source-fenced undo. Absence cannot bypass cleanup.
No successful public layer receipt is issued for a failed preparation.

## Consumer map

- Shared config_scope_transaction: backup, forward publication, inverse
  publication; all are TODO5 owners and must retain exact cleanup/effect state.
- Shared config_scope_file: backup, forward, inverse; macOS Hotstrings uses this
  secondary owner with a native adapter. Its parent only restores an adopted
  source today; a failed publication must also cause retained secondary debt.
- LayerPreset + macOS NavLayer + ScopeLayer: third receipt propagation and
  retained failed-import private record, including the no-record shortcut.
- Mac remap Config.save_user_config: directly calls native conditional write and
  discards extras. Bulk init persistence also discards them; its failed forward
  save enters sibling rollback without a settings-file inverse. Backup writer
  debt is also discarded before the bulk transaction is retained. Required
  coordinated native journal slice; cannot be waved away by layer-only tests.
- Linux TapHold: uses shared LayerPreset and shared Transaction; actual adapter
  uses the synchronous shared fallback and has no native advisory lease. New
  optional capability must leave this path unchanged; controlled receipt
  contracts should replay on both Lua hosts.
- Windows TapHold/global: detached layer candidate is admitted to the existing
  conditional WAL, not this Lua adapter. Native qualification remains required.
- Other exact writer consumers (cleanup, migration, editor, non-scope setters,
  wizard) and shared batch-write wrappers currently discard extra false-result
  returns. They must be reported explicitly; no blanket retry or success claim.
  Their source ownership is outside the narrow TODO5 owner correction unless
  independently authorized. FileSystem.create_if_absent also has a separate
  three-value status API and needs an independent debt design.

Actual causal controls currently executed: import+cohort real-file probe and
shared Transaction real-file native probe. Both expose unacknowledged native
publication cleanup. Neither proves physical Hammerspoon/Karabiner behavior.
