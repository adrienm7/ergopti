<!-- docs/memory/text-input-and-config.md -->

# Text input and configuration memory

## Expansion ownership and ordering

### project-typing-order-and-atomicity

macOS consumes the completing event in its event tap; Windows and Linux observe
physical input and must compensate for characters that already reached the
application. Do not copy replay logic across drivers without accounting for that
ownership difference.

An expansion is one ordered transaction: deletion, replacement, and canonical
tail. Provenance filtering, not a timing window, prevents self-observation.

Some terminal/TUI renderers compute rapid repeated deletions from stale state.
On Windows, schedule the edit after the visible `OnChar` callback returns, expand
the count into explicit `{BackSpace}` tokens, and send the complete edit through
one `SendEvent` under `BlockInput("Send")`. Separate sends allow physical text to
interleave; `BSCount - 1` leaves a trigger character behind; `{BackSpace N}` does
not apply `SetKeyDelay` between repetitions. The shared terminal delay is 20 ms.

macOS already owns the completing event and sends tagged deletion pairs to the
exact application with the shared pacing delay. Keep terminal pacing off normal
GUI applications.

### project-hotstring-engine-internals

Each physical character enters the custom engine exactly once. Windows and macOS
word-boundary framing differ intentionally because their event ownership differs.

### project-hotstring-delay-architecture

Typing delays live in shared timing constants with explicit per-driver
interpretation. Do not introduce a second driver-local default.

### project-hotstring-case-flags-are-orthogonal

Case conformity, case sensitivity, and ending-character behavior are independent
flags. Preserve them independently through parsing, caching, and dispatch.

### project-shifted-comma-case-variants

The uppercase form of comma/apostrophe/period variants uses the configured
non-breaking-space prefix, never a plain ASCII space; the prefix is part of
matching semantics and protects emoticons such as `:D`.

### project-hotstring-live-rebuild

Section and category toggles rebuild the custom hotstring registry in-process.
Native-engine and layout-backed features under `hotstrings.*` remain explicit
reload-only exceptions.

### project-hotstrings-self-healing-cache

Grouped hotstrings are canonical TOML plus a gitignored TSV runtime cache, not
versioned generated AHK. Validate freshness and rebuild from TOML when stale.

### project-prefix-index-rebuild-cost-is-cold-disk

Prefix-index rebuild cost is dominated by cold TOML reads. Build from the
already-loaded hotstring cache rows rather than reparsing disk.

### project-the-preview-index-is-file-driven-only

Preview/search indexes are derived only from canonical source files. Runtime
caches must not become an additional content source.

### project-a-driver-that-types-also-types-into-its-own-keylogger

Synthetic text can re-enter metrics and preview hooks. Filter by owned provenance
at the shared injection choke point.

## Configuration and serialization

### project-config-v2-refactor

The v2 configuration schema is canonical. Driver-prefixed legacy sections such
as `[ahk.layout]` are invalid; migration must remove them after preserving valid
canonical values, not keep logging the same startup error forever.

### project-toml-cache-returns-real-booleans

TOML caches return native booleans. Do not compare their values to string
spellings such as `"true"`.

### project-init-json-decode-of-toml

Do not probe TOML by calling `hs.json.decode` under `pcall`; LuaSkin may print the
native decoding error even when Lua catches it.

### project-locale-parity-test

`en.json` is the canonical locale key set. The AHK locale meta-test enforces key
parity, and `tools/locale/check_locales.py --fix` performs manual backfill.

### project-locale-fast-cache

Windows locale TSV is a gitignored, self-repairing cache generated from canonical
JSON. Never edit or version it as source.

## Gestures and keymaps

### project-gestures-reversal-detection

Gesture reversal thresholds differ between x1 and incremental modes. Preserve
the mode-specific accumulated-distance semantics when changing direction logic.

### project-gestures-startup-design

The macOS gesture primer is a wake signal, not a burst benchmark. Do not replace
it with repeated synthetic probes.

### keymap-module-architecture-and-refactor-decisions

Keymap defaults live in the owning keymap module and flow through explicit
injection. Menus and bridges consume those defaults rather than redeclaring them.
