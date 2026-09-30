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

### project-hotstring-language-packs-and-opt-in

Language-specific hotstrings live in `_shared/modules/hotstrings/<language>/`
and are declared in `_index.toml [languages]`; each file loads as the group
`<language>_<stem>` (config, manifest and menu key). Resolve bundled TOML paths
through the driver's single helper, never by concatenating `<cat>.toml`. Every
bundled section ships disabled, so an absent per-section state means "manifest
default": macOS and Linux persist an explicit `true` on enable rather than
clearing the key.

### project-layout-extension-bound-hotstrings

SFB reduction, rolls and the magic key's `repeat_corrections` section live in
the Ergopti layout extension (`static/layouts/registry/ergopti/hotstrings/`),
bound by `[extension.hotstring_bindings.<stem>]` to their historical category,
feature section and common tier, so preference ids never change. Resolve their
file through the bound-source owner (`HotstringsBoundTomlPath`, macOS
`ExtensionPacks.route`, Linux `route_bound_sources`), never the shared folder;
the Windows TSV cache must not compile them. "Installed" is discovery: the
manager's committed generations plus the shipped Ergopti `{ pack = dir }` root,
placed after them so a stale generation cannot hide the bindings. Every install
shape must therefore carry `static/layouts/registry/` below the driver root: a
Linux checkout install copies it through `install/layout_registry.sh` and the
Nix flake copies it too; any new packager needs the same step. A binding
replaces only the driver's own file: the user's same-stem copy (Linux user
folder, macOS configured hotstrings folder) keeps the category, or each bound
section it declares, so route with the source's origin, never by stem alone.

### project-word-delimiters-are-config-leaves

Both Lua drivers keep word delimiters in config.toml:
`[hotstrings.terminator_states]` maps a delimiter key to its state (an absent
key is the shared catalogue default; Linux writes only differences) and
`hotstrings.terminators` is an inline list of `{ key, char, label, consume }`
records. Linux reads and writes them through
`modules/hotstrings/terminator_settings` (storage.json is imported once): a
save writes only what differs from the catalogue at the last sync, so hand
edits and outdated entries survive, and the Hotstrings scope resets only the
shipped delimiters' states, keeping the user's own. Windows keeps its
delimiter string in the override file. The shared writer cannot address an
`[[array-of-tables]]` element: such a list is read, but only an inline list
can be saved.

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

### project-config-versioning

`config.toml` carries `[_meta] schema_version`, read at boot by every driver
against `_shared/core/config_schema/migrations.toml` (ADR-009). Renaming,
moving, retyping or removing a config key ships a registry step in the same
commit, with a corpus case each named driver replays; readers drop the old
spelling at once. A writer stamps only a file it creates; an existing file
keeps the stamp the boot migration gave it, or its remaining steps are skipped.
The Windows full save is the one exception: it always writes the current
version, which is safe only because it runs after the boot migration and never
in a read-only session.

### project-outdated-config-entries-warn-never-refuse

An unknown, retired or outdated config.toml entry (a removed key, a value
naming a gone hotkey, action, slot, section or mode, an old-shape value) is
never an ERROR, a refusal, a crash or a rolled-back sync on any driver (the
maintainer rule behind dev.146's `at_hash`). Lua readers route it through
`_shared/lua/config_outdated.lua` (`report`, `partition`, `settings_table`,
`manifest_value_fits` with the owner's own rule): one WARNING per entry and
reason, read as absent, left unmarked. The cleanup offers every reported path
even when another reader marks it, and cuts an outdated inline-table member
alone. Windows shares `TomlConfigOutdatedReason` between the loader and
`ConfigUnusedKeysFind`, never counts such a value as a rejected override, and
full saves keep boot-outdated entries on disk for the cleanup. Judge
"retired" only against a published catalogue; before one exists, keep every
choice. Real failures stay fail-closed: an unreadable or malformed file, a
native refusal, and a scope's own post-write candidate still refuse.

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

### project-physical-magic-key-is-one-keyboardevent-code

`hotstrings.magic_key_source` names the physical magic key on every driver by
its KeyboardEvent.code, resolved through the physical-key tables (scan code,
macOS keycode in nav_layer's ISO form, evdev code). Its default `auto` means
the layout owns the key: Windows keeps its declared, detected, then shipped
Ergopti chain, while macOS and Linux remap nothing, because their Ergopti+
OS layouts already type the magic key on KeyC. Action: add a candidate only
through the manifest enum and mac_keycodes.json (test-magic-key-source.cjs
pins both and the v4_to_v5 map); never make a Lua driver remap `auto`, which
would take KeyC from every QWERTY user who turned the replace section on. A
key the user chose is another key of their layout: every driver remaps its
plain press only. Windows' every-level RemapKey (Shift gives "J"), Ctrl+★ save
and Win+★ editor belong to the layout's own position alone
(`LayoutRegistry_MagicKeyHotkeys`).
