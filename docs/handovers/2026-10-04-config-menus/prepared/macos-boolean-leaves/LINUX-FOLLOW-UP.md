# TODO33 Linux writer proposal — no implementation

Exact untouched source and five actual-owner diagnostic runs are retained in
linux-proposal/. baseline.json pins base375de99 and four source hashes.
linux-domains-probe.lua uses the real Linux loader, writer, canonical codec,
shared defaults and private file I/O. Logger is recorded and the native engine
reload callback is explicitly controlled to return true. It is not a registered
test module and proves no evdev/uinput/physical daemon behavior.

## Observations

Every row calls Writer.set_tap("caps_lock", "copy").

| Input                                | Observed ordinary publication                           | Reload callback | Fresh actual loader    |
| ------------------------------------ | ------------------------------------------------------- | --------------: | ---------------------- |
| tap_hold = "opaque"                  | returns true; erases scalar and replaces table          |               1 | copy                   |
| [tap_hold] keys = "opaque"           | returns true; erases scalar and replaces table          |               1 | copy                   |
| [tap_hold.keys] caps_lock = "opaque" | returns true; erases scalar and replaces binding        |               1 | copy                   |
| [tap_hold.keys] caps_lock = [1,2]    | returns true; source remains [1,2], copy is absent      |               1 | tap_action is nil      |
| [tap_hold] enabled = "old"           | returns true; preserves old global leaf without warning |               1 | key copy; global false |

The array case is a false publication acknowledgement: the controlled reload
callback succeeds, but independent actual loader projection has no requested tap
value. It is not a nil/failed native reload receipt. The scalar cases show erased
source models, not merely logging differences. Usable unrelated future fields
remain, as seen in exact retained published text.

## Exact owners and smallest next slice

Native writer platform/remap/tap_hold_writer.lua:
section() replaces any non-table root, key_entry() replaces any non-table keys
parent or binding, and save_and_reload() mutates/publishes without structural
admission. is_array()/encode_value() serialize numeric slots while discarding
new named owned fields. Scope render/import are additional users of the same
helpers and must preserve their own original contracts.

Native loader platform/remap/tap_hold_loader.lua:
load_document() ignores scalar parents/bindings without precise outdated
classification. Its global enabled projection treats present wrong types as
false without the shared warning owner. Existing per-key valid table field
classification should remain intact.

Implement and test a bounded pre-publication shape admission through these
owners, preserving obsolete scalar/array models until explicit cleanup. Refuse
a colliding ordinary change before staging/reload; keep usable neighbors and
foreign fields, and never report success without the requested persisted
projection. A direct setter action is not permission to erase an obsolete whole
parent. Classify ignored known shapes once with exact file/path/reason through
existing config_outdated. Preserve malformed/unreadable admissions, staging
write/close acknowledgement and failed reload distinction already implemented.

Do not infer that Lua type(table) proves TOML namespace identity. The generic
codec conflates empty arrays and empty maps and its encode/decode behavior must
not be silently changed for other consumers. The next slice must audit supported
raw-source shape evidence before claiming all array identities fixed; [] and
mixed/nested structures need independent controls. No parser replacement or
broad codec refactor is authorized by this proposal.

## Required independent controls and qualification

Append registered real-owner controls retaining all previous assertions. Pin
complete handwritten source/expected models for scalar root, scalar keys,
scalar/Boolean/numeric known binding, nonempty and empty arrays, valid empty
owned tables, foreign sibling records, direct setter/clear/recommended-import
behavior, explicit manual source repair retry and preserved neutral reads.
Each refusal must leave exact bytes, zero staging/publication/reload and an
honest false receipt. A success must be independently reloaded through the
actual loader and match the requested action. Run original source first to
prove causal reds, then candidate on Lua5.4 and LuaJIT.

Before edits, coordinate with the conditional native admission/LayerPreset
owners and latest root integration. Do not edit shared config_scope_transaction,
native file_system or conditional layer cleanup owners. Linux native writer and
loader are native-specific; any shared classifier/source evidence changes select
all affected driver gates. Root owns serialized JS/Lua/E2E/CI; physical
Linux input, X11/Wayland and installed daemon admission remain separate native
requirements. Windows/Mac corresponding writer policies require source audit and
native qualification where affected. No CI or full suites were run here.

A separate macOS retired karabiner.enabled deletion conflicts with the explicit
cleanup decision; preserve its old assertion until an independently handwritten
complete preserved-model regression and bounded reviewed change are prepared.
It is not part of the frozen Boolean candidate or this Linux implementation.
