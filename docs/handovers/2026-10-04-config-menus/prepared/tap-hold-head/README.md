# Complete Tap-Hold key-head template candidate

This is an incremental, unapplied candidate. The real checkout was never edited.
Base commit: `905b4789f6297b65a765a31724997940d339bcd8`, with the root agent's
11 staged native-command source paths overlaid. The two generated parent
artifacts were derived from that composed source in the isolated copy, rather
than read while the root drift gate could mutate them. The root must check each
preimage, preserve any newer fixture corrections, and regenerate composed
artifacts after adapting this packet to its final sources.

`tap-hold-key-head.patch` owns 16 paths. Its SHA256 is
`98020999760ad87aaff015e82871635f0aac85a78ef99c894072801c6e71f93b`.
`preimages-sha256.json` contains every original file hash (`null` means new).
The patch passes `git apply --check` against its saved preimages.

## Production scope and invariants

The new `tap_hold_key_head` declaration includes the original
`tap_hold_key_native_commands` array unchanged, then declares the separator,
Tap and Hold rows with their existing platform caption variants. Its literal
caption getter names consume the native current action labels. No locales,
configuration schema/defaults, action aliases or persistence policy changed.

The shared Lua `template_rows` method serves both Mac and Linux. The Windows
renderer has `MenuRenderer_TemplateRows`. These return provider data, preserving
its leading separator and source order, then the existing outer renderer draws
it. Includes reuse the existing declared-command readiness/delivery policy.
The native owners supply only command functions, label getters and child arrays;
only Mac/Linux's existing delay tails remain outside this head. The generator
validates missing/cyclic includes, extraneous include payload and malformed
caption getter declarations. A failed template returns no partial head.

Published captions keep exactly one `%s` in all 21 locales. The format operation
replaces it with a literal getter result, including `%` and braces in that data.
The existing zero-placeholder identity i18n stubs keep their old behavior.
Ordinary menu building, choices, generic row normalization and native callback
acknowledgement policies are unchanged.

The old native-row corpus is byte-identical. All three registered native test
files retain their complete old bytes as exact prefixes. Only the obsolete JS
assertion that clearing must be a direct provider `command_row` call is replaced:
it now checks the actual provider body, literal callback/getter bindings,
provider-to-template and template-to-original-head edges. Wrong provider,
wrong template, wrong imported head and every missing binding are individually
rejected. Its original exact two-row declaration assertion remains intact.

## Focused evidence

- Linux owning module: 24 passed, 0 failed. Eleven appended cases exercise actual
  picker/set-hold payloads, declaration order/caption/getter/platform mutations,
  all 21 locale/platform/state projections, retained included-command readiness,
  missing/cyclic include, missing/non-callable getter, non-string caption and
  missing children. Original actual native writer refusal/retry tests remain.
- Mac owning module: 17 passed, 0 failed. Eight appended cases exercise actual
  child/delay placement, order/caption/platform mutations and both real picker
  mutation closures with true/false/nil/truthy port receipts. Persistence refusal
  does not regenerate or redraw. Original clearing refusal/retry cases remain.
- Windows: four appended registered cases cover the actual provider, real Win32
  menu renderer, declaration/getter/order/platform mutations, and broken template
  data. They have NOT executed: no Windows runtime or native runner was used.
- Manifest drift/choice projection, including six new actual-generator malformed
  template refusal vectors: passed. Menu parity: 46 menus, 21 locales, zero
  unreasoned hidden rows. Handler bijection: zero unresolved rows on all drivers.
- AHK encoding: 1814 BOM/LF files; syntax antipatterns: 1802 production files;
  registration: all 1376 test files reachable. Strict conventions passed.
- Both owner generators succeeded. Census source inverse restores 96/153/97;
  candidate is 95/152/96, exactly one retired native separator site per driver.
  No computed caption retirement is falsely counted. `census-proof.json` records
  the independent before/inverse/after counts. Menu and census repeated generation
  produced identical bytes before final comment/indentation changes; the final
  census is regenerated after those changes.

Restoring only the three previous native providers makes Linux 21 pass / 3 fail,
Mac 14 pass / 3 fail and the real JS wiring assertion fail. The failures are the
independent declaration order, caption/getter and platform hiding requirements;
new payload/refusal tests also retain the old correct behavior. Logs are saved
as `final-*.log` and `inverse-*.log`.

No full JS suite, native suite, verify-change execution, E2E, physical X11/Wayland,
Hammerspoon/Karabiner, native Windows, packaging or installation checkpoint ran
for this candidate. The root owns serializing full selected gates and hosted
three-OS qualification. TODO54 and TODO81 remain partial; picker children, delay
rows and other native menu families are still outstanding. No group completion,
integration, push or release is claimed.
