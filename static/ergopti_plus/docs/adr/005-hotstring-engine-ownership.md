# 005 — Hotstring engine canonical spec lives in `_shared/domain/`

| Field | Value |
|---|---|
| **Date** | 2025-09-01 |
| **Status** | Accepted |
| **Deciders** | Core team |

---

## Context

The hotstring expansion pipeline has two concrete implementations:

- **AHK driver**: `static/ergopti_plus/windows/lib/hotstrings/hotstring_engine.ahk`
  — handles trigger detection, expansion dispatch, and caret positioning.
- **Hammerspoon driver**: `static/ergopti_plus/macos/modules/keymap/registry.lua`
  + `expander.lua` — implements the same pipeline in Lua.

Both implementations evolved independently and diverged in edge-case handling:
backspace-triggered corrections, nested hotstrings, and the treatment of
Unicode terminators were handled differently in each driver. Bugs fixed in one
driver were not ported to the other.

The core algorithm — character-by-character matching, word boundary detection,
terminator classification, expansion emission — is **entirely platform-agnostic**.
It requires no OS API, no file I/O, and no timer. Yet no authoritative
specification existed that both drivers could be validated against.

## Decision

The **canonical behavioural specification** for the hotstring engine lives in
`static/ergopti_plus/shared/domain/` as a set of JavaScript spec files
(`HotstringMatcher.spec.js`, `Expander.spec.js`, `Registry.spec.js`,
`Terminators.spec.js`). These specs define the expected input/output
behaviour for every component of the pipeline via test vectors.

Both the AHK and Hammerspoon driver tests are required to pass the same
logical assertions expressed in those specs (either directly or via the
cross-driver corpus — see ADR-006). If a driver's behaviour diverges from the
spec, the driver is wrong, not the spec.

New algorithm changes must first update the `shared/domain/` spec, then be
propagated to both driver implementations.

## Consequences

### Positive

- A single document of truth governs hotstring behaviour across all drivers.
- Bugs are now fixed in one place and the fix is verified against both drivers.
- New drivers (Linux, Espanso) inherit the spec automatically and can
  self-certify by running the shared corpus (ADR-006).
- The spec is executable — running `node --experimental-vm-modules` on the
  spec files verifies correctness without any driver runtime.

### Negative / Trade-offs

- The `_shared/domain/` specs are written in JavaScript (to stay in the Node
  test ecosystem), while the implementations are in Lua and AHK. Translating
  spec assertions into driver-specific test idioms requires manual effort.
- Any spec change must be propagated to two driver test suites.

### Neutral

- `Terminators.spec.js` and `Registry.spec.js` cover parts of the pipeline
  that AHK implements in native hotstring syntax; the AHK tests are
  necessarily more integration-style for those components.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Designate one driver as authoritative | The other driver would still drift; no executable cross-check |
| Shared Lua spec run under both runtimes | AHK cannot run Lua specs; requires a second spec format anyway |
| No spec, rely on shared corpus only | Corpus vectors test outcomes, not component-level invariants |

## Evidence in the codebase

- Domain specs: `static/ergopti_plus/shared/domain/HotstringMatcher.spec.js`, `Expander.spec.js`, `Registry.spec.js`, `Terminators.spec.js`
- Hammerspoon driver tests: `static/ergopti_plus/macos/tests/unit/modules/keymap/test_expander.lua`, `test_registry.lua`, `test_terminators.lua`
- Domain spec documentation: `static/ergopti_plus/shared/domain/SPEC.md`
