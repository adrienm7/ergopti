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

Terminal capture admission (`LLM_NavEventOwner_BeginTerminalCapture`) runs
inside the completing key's `OnChar`, so it must stay one native call. A
terminal-route registration (`LLM_NavEventOwner_RefreshTerminalRoutes`)
re-checks the whole canonical layout source at every custody guard and measured
300-900 ms per call in a live session (2026-10-18). Running it there made every
terminal expansion slow and let typed keys interleave ("cc'était"). Register
routes at Start or off the keystroke path, never in admission;
`(hsfix-terminal-admission)` fails if admission registers anything.

### project-windows-notepad-garbles-typed-text

Windows 11's Notepad (`RichEditD2DPT`) loses the characters of a text typed
as Unicode key events (`{Text}`, `KEYEVENTF_UNICODE`) and types the last one
of the batch in their place: « général de l’histoire militaire » arrives as
« général eeee », or as 32 « e ». It is the application, not the driver: one
raw `SendInput` from a separate process reproduces it, a classic Edit control
receives every character, and `SendEvent` with no key delay or one character
every 10 ms still drops some (20 ms passed once). Backspace followed by Ctrl+V
also produced `v` and incomplete replacements in the receiving Notepad. Primitive
emission is not evidence that the editor consumed the intended replacement.

The Notepad host rule now selects the native editor worker for `TextSend` auto
mode and literal HSE output. Keep the exact deleted suffix and final admission;
worker startup and READY cannot publish mirrors, accepted rows or fire logs.
Only complete document/caret verification followed by native thread retirement
permits completion. Uncertain effects invalidate mirrors without retrying.

On the actual `RichEditD2DPT` receiver, WM_GETTEXT spells line breaks as CRLF
while EM_GETSEL counts each break as one native coordinate. Normalize the read
image and both replacement strings together; UTF-16 surrogate pairs still count
as two units. Use pointer DWORD selection results past 65535. InputHook may see
the completing character before the editor stores it; a visibility wait may
accept only that independently predicted scalar with the rest of the document
and original caret unchanged. It must never accept arbitrary later text.

The worker edits a few 10 ms polls after the completing key, longer when the
AHK thread is busy (the error window's WebView2 creation took 1.5 s). Until
2026-10-18 the HSE Notepad owner held no keyboard capture, so a key typed in
that span reached Notepad and HSE: before the decision it cancelled the
expansion (« output admission rejected »), during the edit it made the effect
indeterminate, after the verified edit it revoked the commit (« completed after
its admission changed »); each was an ERROR and an error window in plain
typing, and the first one's window caused the next. The owner now admits
`LLM_NavEventOwner_BeginTerminalCapture` at dispatch and releases it in
`_HSE_CompleteNotepadOwner`, so held keys replay after the commit or refusal.
A key that passed the hook before admission is already on screen and fed; the
worker refuses to edit around it, which is logged as a warning (« yielded »),
not an error. `(hsfix-notepad-interleave)` and `(hsfix-notepad-capture)` pin it.

### project-hotstring-engine-internals

Each physical character enters the custom engine exactly once. Windows and macOS
word-boundary framing differ intentionally because their event ownership differs.

### project-backspace-word-start

The word-start flag (`HSE_StartIsWordBoundary`, Lua `_start_is_boundary`,
macOS `start_is_word_boundary`) describes the left edge of the buffer, and the
Windows and macOS buffers keep terminators, so a Backspace that empties the
buffer is back where the typing began: it sets the flag (2026-10-21, all three
drivers; Windows only for the user's Backspace, `HSE_FeedBackspace(true, true)`,
never the driver's probe Space). A Backspace on an empty buffer flips it
unknown, except at a known empty line (`HSE_StartIsLineStart`, Lua
`reset(true, true)`, macOS `start_is_line_start`): a bare Enter in a terminal,
Ctrl/Cmd+A outside a terminal, Ctrl/Cmd+L in a browser. Every reset that moves
the caret must clear that line-start flag. The proven incident (typing ledger,
Windows Terminal running Claude Code): Enter, a pause, `c★` fired, six
Backspaces over the five characters of « c’est », then `C★` was not offered;
the sixth Backspace hit the empty prompt. Two more rules ship with it: the idle
reset never throws away the word a following Backspace edits (Windows restores
it through `_PrefixRestoreIdleForgottenWord`, macOS skips the wipe for a bare
Backspace, Linux never idle-resets on a control key), and Ctrl+Backspace
(Option+Backspace on macOS) starts a word. The ledger's `typing` rows are
batched about every 200 ms, so a sequence must be rebuilt across rows from the
per-key delays, never read row by row. Known limits, not bugs: after a
browser's inline autocompletion the first Backspace deletes the suggestion, not
a typed letter, so the buffer runs one character ahead (no driver reads the
field's text); Linux sees no modifiers on a typed newline, so Shift+Enter in a
terminal TUI also reads as submitting the line.

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
reload-only exceptions. A submenu's « check all » / « uncheck all » follows the
same rule (Windows `_ConfigCommitHotstringIntent` + `_HS_SelectionAppliesLive`):
until 2026-10-17 every bulk click reloaded the Windows driver through the scope
journal, which takes minutes on a real setup, and every click queued behind it
was refused. A bulk selection switches only the sections its own submenu draws:
never an extension's bound section (Ergopti's magic-key `replace` and repeat
corrections), never the programmable `hotstrings.dynamic.user_code`, and the
Hotstrings menu has no whole-tree « all sections » row (it enabled every
language pack at once).

### project-personal-folder-skips-writer-backups

Every `.toml` under the personal hotstrings folder is a source, but the scoped
writers back up each owned file beside itself as `<stem>.backup-<stamp>.toml`.
Discovery skips that reserved name on all three drivers through the generated
`PersonalFileIsBackup` / `personal_files.is_backup` (single source:
`personal_files.json` `backup_infix`); a scan that misses it loads each copy as
a duplicate source and the next reset backs up the backups.

### project-hotstrings-master-tick-reads-the-engine-gate

The Hotstrings switch's tick must read the state the engine gates expansion
on, never « every category on »: the wizard's recommendation opens one section
of one category. Windows reads `category_enabled.hotstrings`; macOS reads
`hotstrings.enabled` (`state.keymap`), which starts or stops the typing engine
through `KeymapLifecycle.ensure_started`/`ensure_stopped`, so off silences
personal and dynamic hotstrings too, and AI predictions ride the same taps;
Linux stores no flag, so its tick is `hotstrings_config.any_enabled()` or the
dynamic master, and off closes every gate plus the dynamic master (on is
`enable_all`). On Windows and macOS the categories keep their choices under
the master, and each submenu's « check all » is the row that switches them.

### project-hotstring-language-packs-and-opt-in

Language-specific hotstrings live in `_shared/modules/hotstrings/<language>/`
and are declared in `_index.toml [languages]`; each file loads as the group
`<language>_<stem>` (config, manifest and menu key). Resolve bundled TOML paths
through the driver's single helper, never by concatenating `<cat>.toml`. Every
bundled section ships disabled, so an absent per-section state means "manifest
default": macOS and Linux persist an explicit `true` on enable rather than
clearing the key.

### project-layout-extension-bound-hotstrings

Distance reduction, SFB reduction, rolls and the magic key's `repeat_corrections` section live in
the Ergopti layout extension (`static/layouts/registry/ergopti/hotstrings/`),
bound by `[extension.hotstring_bindings.<stem>]` to their historical category,
feature section and common tier, so preference ids never change. Binding
`source = "common"` identifies the historical priority, not the directory.
The separate `french/distancesreduction.toml` stays a bundled language category.
Resolve their
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
delimiter string in the override file. The shared writer cannot address one
`[[array-of-tables]]` element; both Lua drivers can replace the whole custom
delimiter list through the shared writer, including quoted table-array headers.

### project-hotstrings-self-healing-cache

Grouped hotstrings are canonical TOML plus a gitignored TSV runtime cache, not
versioned generated AHK. Validate freshness and rebuild from TOML when stale.

### project-prefix-index-rebuild-cost-is-cold-disk

Prefix-index rebuild cost is dominated by cold TOML reads. Build from the
already-loaded hotstring cache rows rather than reparsing disk.

### project-the-preview-index-is-file-driven-only

Preview/search indexes are derived only from canonical source files. Runtime
caches must not become an additional content source.

### project-the-bubble-never-offers-a-doubling

The maintainer ruled that no driver previews the magic key's doubling (the
repeat fallback, `x★` → `xx`): it is available after almost every mid-word
letter, so its row was constant noise. It still fires. Windows keeps it in
`HSE_PreviewNextDecision`, so no lower candidate is promoted in its place, and
`_PrefixCollectCandidates` withholds any decision whose Spec carries
`IsRepeat`. macOS and Linux preview only registry mappings, and the doubling
is an engine fallback outside the registry: never fold it into their preview.
`repeat_corrections` entries (ê → u after a doubled letter) are not doublings.

### project-the-windows-time-gate-times-every-observed-key

Every Windows hotstring loaded from TOML is time-gated: `LoadHotstringsSection`
applies `HotstringsResolve().Delay`, which falls back to the shared 0.75 s.
`_HSE_PrepareDispatchDecision` fails closed when `LastSentCharacterKeyTime`
has no entry for the trigger's previous key, for the preview oracle and for
dispatch alike. Only the layout emulation stamped that map, so with the
emulation off (the W1 neutral layout setting) nothing delayed fired or
previewed. The ungated repeat doubling was the only bubble left, then none
once it was withheld. The prefix watcher now stamps each observed character
through `AppState_TouchLastSentKey` (`infra/hotstrings/hotstring_send.ahk`)
before feeding the engine. Action: a new path that feeds the engine a
character already on screen stamps it through that owner. Never write the map
elsewhere, and never push the ring (`_LSCPush`) from the watcher: the emulation
has already pushed that character.

### project-a-driver-that-types-also-types-into-its-own-keystats

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
moving or retyping a config key ships a registry step in the same commit, with
a corpus case each named driver replays. Retired keys reported by the explicit
cleanup remain on disk until that cleanup; boot migrations and ordinary saves
preserve them (ADR-009's retirement exception). Readers drop the old spelling
at once. Invalid schema stamps retain strict boot and session-write refusal.
A writer stamps only a file it creates; an existing file
keeps the stamp the boot migration gave it, or its remaining steps are skipped.
The Windows full save is the one exception: it always writes the current
version, which is safe only because it runs after the boot migration and never
in a read-only session.

### project-action-id-migration-is-per-key

Retiring an action id stored in config.toml needs one `map_value` op per key
that can hold it, since the op set has no section-wide map. Every driver
parses the whole registry at every boot: measured with the pure-Lua
`toml_codec` (Lua 5.4), the 17 KB registry took 36 ms and v5_to_v6's 42 ops
of six pairs doubled it to 77 ms; listing macOS's 200 keyboard-slot keys as
well would have added about 250 ms. v5_to_v6 therefore covers gesture slots,
tap keys and script-control keys only, and a keyboard slot naming a retired
id is reported as outdated. Action: before retiring more stored ids, add a
section-wide map op to all three interpreters (with Windows runtime tests)
rather than enumerating keys.

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
Other files (layers.toml, tap_hold.toml, installed.json, storage.json,
api_keys.json, hotstrings_overrides.toml, config_karabiner.toml) follow the
same rule through `config_outdated.report_in_file`: one WARNING naming the
file and the entry to fix by hand, since only config.toml has a cleanup, and
never recorded by a cleanup scan. The entry is ignored and the rest of the
file kept; a record the app writes back (installed.json, api_keys.json)
carries such an entry over unchanged, never deleting it. A file its owner
refuses as a whole must still not stop a driver's startup: the installed
layouts' packs are skipped with an ERROR on all three drivers.

### project-batch-writer-addresses-every-spelling

A macOS menu save sends the whole preference state as one sparse batch, so a
key the shared writer cannot address fails every menu action, not one feature.
Older macOS builds wrote config.toml whole through `codec.encode`, which gives
every empty map its own header (`[hotstrings.delays]`,
`[llm.models.user_models]`), and today's saves still write structured values
(`[metrics.shortcut]`) as headers. `toml_codec/writer.prepare_batch` therefore
replaces a header-held key as one value (header lines and assignments go,
comments stay), leaves a value already held in any spelling untouched, and
matches quoted keys; only a changed key inside an inline table or a root
entry is refused, naming its path. Action: a new writer shape must stay
addressable by the batch, and a whole-table reset in `Preferences.save` must
keep the load-outdated entries below it (`reset_keeping_outdated`). The Lua
codec resolves dotted assignment keys with the same strict quoted-segment
identity as headers. A quoted dot stays literal, while a bare dot defines a
nested table. Dotted parents can extend implicit header parents, but scalar,
array, explicit inline and explicitly declared header values stay closed. A
no-op batch over an unaddressable dotted leaf preserves the exact source; a
changed leaf stays refused until its physical record has a writing owner.
Windows document/config readers still use their flat section model; their
inline-table reader independently supports the common dotted-key contract.

Legacy `[features]` overrides project scalar semantic leaves onto their flat
settings keys through `config_override_projection`; read marks retain the
original segment arrays. Literal and nested paths that project onto the same
setting refuse the entire candidate set before either owned section writes.
`[script]` stays a flat scalar section, and arrays stay unconsumed.

### project-configuration-noop-preserves-the-live-inode

Windows queues a boot full save to settle normalization and schema obligations;
that is not evidence that 347 collected operations changed 347 settings. Its
batch writer must not materialize a missing section for a neutral-value deletion.
After rendering, a byte-identical canonical UTF-8 image is acknowledged without
staging or replacing the live file, and the read cache is invalidated normally.
The existing full-save generation owner still records that acknowledgement.

Both Lua drivers share the fallback no-op check in `toml_codec/writer`: re-read
the exact source before acknowledging identical bytes. macOS performs the same
check inside its native cooperative writer lock and revalidates the symlink
route; lock acquisition and release remain mandatory even without staging.
Explicit writes without a source precondition still publish normally. Source
changes and session fences remain failures. The common typed operations live in
`_shared/tests/corpus/config_noop/vectors.json` and run in all three suites;
Windows also checks retained modification time, and macOS checks the native
lock and absence of staging/publication.

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

### project-config-toml-spacing-is-five-and-three

Five blank lines before a top-level `config.toml` header and three before a
nested one is the house style of both codecs (`EnsureTrailingBlankLines(5)` in
`toml_helpers.ahk`, `codec.lua`), decided by the maintainer on 2026-10-20. Runs
of five blank lines are not accumulation.
`windows/_generated/config_template.toml` follows the same spacing and changes
only through `npm run build:manifest`.

### project-newer-schema-is-read-only

A configuration saved by a newer schema is never downgraded and its unknown keys
are never offered for cleanup: boot keeps the migration refusal, refuses session
writes and posts `config.read_only.newer_schema` (once after boot on macOS and
Linux, on each refused save on Windows).

### project-wizard-rerun-keeps-user-keys

A wizard rerun reads each folder's existing tap-hold keys: user-owned keys are
locked, backed up and never overwritten, a changed folder retires the prior
intent, and Finish waits for the exact read response. A category created by a
personal-hotstring editor save is enabled; it once took the neutral-off default
of an undeclared section and never loaded (issue #96).

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
macOS keycode as the tap sees it behind Karabiner's ANSI virtual keyboard,
evdev code). Backquote and IntlBackslash answer to both keycodes a bare ISO
board swaps them to, as the tap keys do; never read the tap in nav_layer's ISO
form, which names Karabiner's input side. Its default `auto` means
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
