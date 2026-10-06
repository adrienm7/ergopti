# Native descriptor catch-Any successor

This private successor depends on immutable scalar-capture packet `d7b5917c`
and its immutable observation predecessor `23813ae6`. Only the two new native
observation boundaries change from `catch {}` to `catch Any {}`. Existing native
readers and every other production source byte remain exact.

AHK v2's default catch handles Error objects. Optional ReadFn/MapFn ports and
own Count/Text getters can also throw String or Integer values. Such values
previously escaped instead of producing the promised closed zero refusal.
Both new boundaries now discard any thrown value and return zero without
logging its details.

The existing sixth registered method retains all old assertions and adds actual
String/Integer throw vectors for direct read ports, row reads, row mapping and
both own getters. A test-only catch-Any wrapper converts an escaped throw into a
fixed nonzero sentinel, so the closed-zero assertion still fails meaningfully
without exposing the thrown scalar through the framework. It does not turn
an escaped exception into success. All previous test-source lines remain in
their original order; the native method count stays six.

Private source controls reject the default-catch predecessor and either omitted
catch-Any boundary; the final source projection, BOM/LF, partial syntax, Ruff
and private apply checks pass. The actual six AHK methods and all native HKL /
stateful/non-Error behavior remain UNEXECUTED locally. Parent must run Windows
CI and independent peer source review before admission. No physical output,
forced native availability, schema, locale, hook or Root source changed.

`successor.patch` applies after `d7b5917c`; `joint.patch` applies the exact final
two sources against the actual original Root preimages `969f960c` / `e5059ddd`.
