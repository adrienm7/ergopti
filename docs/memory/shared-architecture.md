<!-- docs/memory/shared-architecture.md -->

# Shared architecture memory

## Ownership and vocabulary

### project-shared-tree-layout

`_shared/` is a source of truth per layer, not a dumping ground. Drivers may own
adapters and runtime orchestration while consuming shared schemas, constants,
and generated data. Bypassing the shared source creates silent drift.

### project-a-second-vocabulary-fails-silently

Use the same field names at every boundary. Translating a concept into a second
vocabulary often yields `nil` plus a plausible default rather than an exception.

### project-fixed-field-lists-drop-flags

When a record schema grows, fixed allowlists silently discard new fields. Prefer
schema-owned projection or update every serializer, bridge, and test together.

### feedback-loader-target-explicit

AHK loaders and writers that populate a shared `Map` take that map explicitly.
They must not reach through a global with the same conceptual name.

### project-a-path-resolver-must-know-every-layout-that-ships

Path resolution is a product contract. Test packaged, source-tree, installed,
and test-harness layouts rather than assuming one directory depth.

### project-a-depth-cap-is-right-for-a-provider-and-wrong-for-a-filesystem

Depth limits belong to bounded provider APIs, not generic filesystem discovery.
Use explicit roots or cycle-safe traversal for real directory trees.

## Cross-driver UI and data

### feedback-ui-must-be-i18n

All user-facing text uses the locale system in every supported language. English
is the canonical key set; developer logs remain English.

### project-locale-placeholder-parity-is-not-a-defect

Locale values may reorder placeholders. Validate placeholder sets and types, not
byte-identical order, unless the formatter itself requires order.

### project-one-menu-two-shared-descriptions

Shared menu metadata has one canonical description per action. Drivers own
rendering but must not fork labels or help text.

### project-a-caller-owned-menu-is-still-the-renderers-to-fill

Owning a native menu object does not transfer content ownership. The shared
manifest remains authoritative for ordering and entries.

### project-a-toggle-is-opt-in-per-driver

A shared setting is not automatically supported by every driver. Add explicit
capability wiring and parity tests rather than inferring support from schema
presence.

### project-two-keys-for-one-row-is-two-menus

Two manifest keys that describe one visible row create two sources of truth.
Normalize aliases before rendering or remove the duplicate schema key.

### project-an-enumeration-is-not-a-feature

Discovering or listing a value is not proof that selecting, persisting, and
applying it works. Test the complete user transaction.

### project-debug-menu-sync

The debug submenu order lives in
`_shared/modules/menu/menu_manifest.json`; both desktop drivers consume it.

### project-menu-manifest-macos-hotstrings-layout-gap

macOS does not yet consume every hotstrings/layout manifest key that Windows
does. Treat the asymmetry as known scope, not proof that all menu parity exists.

### project-ui-dynamic-buttons

Windows dialogs use `Gui_HarmoniseButtonWidths`; macOS web UIs size through CSS
padding. Do not hardcode per-label widths.

### project-tooltip-shared-style

Tooltip style constants are shared. Per-driver alpha differences are
intentional because native compositors blend differently.

## Logging and observability

### errors-only-log-sink

Daily `ErgoptiPlus_errors_YYYY-MM-DD.log` files contain WARNING and ERROR events.
`crash_reports/` is reserved for uncaught fatal failures.

### project-instrumentation-absence-is-invisible

Missing profiling instrumentation produces deceptively clean output. Assert the
expected segment and boot-stamp inventory before interpreting timings.

### project-profile-label-placeholder-convention

Profiler labels and placeholders are schema. Producers and reports must use the
same exact names so missing segments cannot masquerade as zero cost.

## Intentional asymmetries

### project-category-gating-ahk-only

Runtime category gating through `CategoryEnabled[...]` is intentionally AHK-only
unless another driver explicitly implements equivalent ownership.

### project-declared-answered-and-absent

Distinguish declared capability, answered query, and absent value. Collapsing
them into false changes fallback and UI behavior.

### project-the-wrong-dialect-is-invisible

Shared data can be syntactically valid in the wrong consumer dialect. Validate
with each real parser, not only a generic JSON/TOML check.

### project-dynamic-places-list-materialises

Dynamic lists become persisted user choices. Preserve stable identifiers and
handle entries disappearing between discovery and use.
