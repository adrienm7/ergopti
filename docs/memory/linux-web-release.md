<!-- docs/memory/linux-web-release.md -->

# Linux, web, and release memory

## Linux input

### project-linux-grab-is-a-contract-not-a-flag

Observe mode and `EVIOCGRAB` mode have different correctness contracts. A driver
that does not grab cannot prevent a physical terminator from reaching the app;
replay logic must reflect the active mode.

### project-linux-a-field-must-be-named-at-every-boundary

Linux input records cross evdev, resolver, injector, and Lua boundaries. Preserve
the exact canonical field names at each hop.

### project-linux-writing-a-table-nobody-reads

Persisting a mapping is not implementation if the runtime resolver never reads
it. Tests must execute selection through injection.

### project-a-computed-label-is-a-list-of-one

Provider APIs may return a single computed label wrapped as a list. Normalize at
the adapter boundary rather than spreading shape checks through the driver.

### project-linux-keymap-before-libxkbcommon-1-8

`xkbcli dump-keymap-{wayland,x11}` only exists from libxkbcommon 1.8; Ubuntu
24.04 ships 1.6. `adapters/keyboard_layout.lua` therefore falls back to
XWayland's keymap (`xkbcomp -xkb $DISPLAY`, exact because XWayland receives the
compositor's keymap) and then to `xkbcli compile-keymap` from the session's
layout names (`infra/xkb_rmlvo.lua`). Action: a keymap source must be proven on
the runner's own libxkbcommon through `refresh()`, never through a fallback the
test writes itself.

### project-linux-injection-table-comes-from-libxkbcommon

The char → keystroke table is probed on the validated keymap
(`XkbCapture.inverse_table()`): each chord the injector can press is applied to
a fresh XKB state. A text model that maps level N to a fixed modifier is wrong
for keypad types (NumLock) and Ergopti's `ERGOPTI_SEVEN_LEVEL` (Shift = level
3). Shortcut letters (Ctrl+V, Ctrl+W) go through
`keyboard_layout.shortcut_keycode()`. Action: never add a hardcoded evdev
letter or a level → modifier table.

### project-linux-atspi-focus-is-per-application

Every GTK application keeps STATE_FOCUSED on its last focused field; only the
window manager's STATE_ACTIVE frame says which one the user is in. A
desktop-wide search is ambiguous with two windows open, and the daemon fails
closed on ambiguity: every expansion blocked. Measured cost is ~1 ms per node
against a 1 s probe deadline. Action: keep the search scoped to the active
window and prove changes with `tests/hardware/run_atspi_focus.sh`.

### project-linux-first-install-needs-luajit-module-builds

Generic `lua-*` packages are Lua 5.4 builds on Fedora, Arch, openSUSE and
Alpine; LuaJIT needs `lua51-*` (Arch), `luajit-*` (openSUSE), `lua5.1-*`
(Alpine, Fedora). Fedora has no LuaJIT lgi, so its WebKit windows cannot open
(declared in the `first-install-distros` matrix). GNOME shows no tray icon
without an AppIndicator extension. Action: prove installer changes with
`tests/distro/run_in_docker.sh <image>` and the first-install matrix.

### project-linux-tap-holds-run-in-the-daemon

Since 2026-09-24 the Linux tap-holds and navigation layer run in the daemon
(`platform/remap/tap_hold_engine.lua`, installed by `tap_hold_manager` through
`keyboard_hook.set_remapper`, which releases every held key on swap, pause and
stop). They replaced kanata, which needed glibc 2.39 (absent on Debian 12 and
Ubuntu 22.04), was never started by the daemon, and broke its whole config on
one free-text action. No Linux release had been installed, so nothing
migrates an old kanata unit. Action: do not reintroduce an external remapper or a `kanata.kbd` release asset; change
tap-hold behaviour in the engine and its loader/writer, with Lua tests.

### project-linux-uinput-drops-a-press-of-a-held-key

The kernel keeps one bit per key: a press of a key already down is dropped, and
its release lifts the key whoever held it. A chord tap written straight to
uinput therefore released a Ctrl a tap-hold was still holding. Action:
`combo_emitter` skips the chord modifiers `keyboard_hook` reports held, and the
tap-hold engine masks a lone Alt or Super release with KEY_F24.

## Website and documentation

### project-site-i18n-gettext-french-key

The website's gettext source keys are French user-facing strings. Do not replace
them with English developer identifiers without a deliberate catalog migration.

### project-svelte-script-comment-closing-tag

The HTML parser can terminate a Svelte `<script>` block on a closing-tag token
inside a comment. Avoid spelling that token literally in script comments.

### project-pages-deploy-branch-vs-workflow

GitHub Pages deployment source can be branch-based or workflow-based. Verify the
repository setting before changing CI; workflow files alone do not prove the
active deployment mode.

### project-xkb-extensions-dir-is-the-clean-install-contract

Since libxkbcommon 1.13 + xkeyboard-config 2.45, layout packages install under
`/usr/share/xkeyboard-config.d/<package>/{symbols,types,rules}` and compose
rules through a `<ruleset>.post` file - never by patching the system
`rules/evdev`. The Ergopti clean installer relies on this contract; the sandbox
tests override the roots via `ERGOPTI_XKB_*` env vars. Two limits measured on
libxkbcommon 1.13.1: an unindexed `! layout = types` rule only matches
single-layout configurations, so the `.post` fragment must also carry
`layout[1]`..`layout[4]` or the custom type vanishes as soon as GNOME/KDE
compile a second input source (dead Shift/AltGr, issue #84); and only
libxkbcommon reads extensions directories, Xorg's `xkbcomp` never does, so the
detector routes X11 and unknown sessions to the legacy method. The repository
does not ship a separate AUR `PKGBUILD`: the former handwritten recipe
referenced an absent tag and hook and drifted from the canonical package
builder. Action: any new install target must reuse/generate from the canonical
builder, pass a real package build in CI, keep the extensions-dir contract, and
prove the type with `xkbcli compile-keymap` for `ergopti`, `ergopti,us` and
`us,ergopti`; never reintroduce an X11 symlink bridge, which cannot carry the
types rule.

### project-french-xkb-variant-must-preserve-the-system-default

A variant registered under `ergopti` is not offered by input-method pickers
that enumerate variants of `fr` (issue #84). Publishing `fr(ergopti)` requires
both an extension `symbols/fr` section and variant-specific types rules in
every group. A file containing only that section can also capture plain `fr`
when the system file has no explicit default: measured on libxkbcommon 1.13.1,
the original French keymap became Ergopti. Action: delegate the extension's
explicit default to `%S/fr`, keep other named sections resolving through the
system search path, and compare plain French, OSS and Bépo before/after install
with the real compiler. Register the variant under `fr` in libxkbregistry too;
successful compilation alone does not establish picker discoverability.

### project-legacy-xkb-types-go-inside-the-section


The legacy installer edits `types/extra`, a single
`default partial xkb_types "default" { ... };` section that `complete`
includes. A `type` block appended after the closing `};` is a syntax error:
Xorg's `xkbcomp` rejects the whole `complete` file and libxkbcommon drops the
block with no diagnostic, so "it compiles" proves nothing. Action: insert
through `insert_type_sections()` (inside the last section), then require the
type name in the compiled keymap; roll every backed-up file back otherwise.

### project-gsettings-input-sources-must-be-merged-not-set

GNOME stores the user's keyboard list in `org.gnome.desktop.input-sources
sources`; writing a single-entry list silently deletes the user's other
keyboards (reported as "my old layout disappeared"). The installer reads,
merges with the new layout first, writes, then reads the value back: dconf
reports success even when a root process wrote into root's own database.
gnome-shell activates `mru-sources[0]` at login, not `sources[0]`, so the
most-recently-used list is aligned as well. Plasma keeps `LayoutList` and
`VariantList` index-aligned and ignores both unless `Use=true`; the legacy
layout is `fr` + `Ergopti_<version>` there, never GNOME's `fr+variant`.
Action: reuse `merge_gsettings_source()` / `merge_layout_specs()` from
`layout_package.py`, run activation as the desktop user, and never hand-write
a sources value.

### project-a-keymap-that-compiles-can-still-have-dead-layers

libxkbcommon and xkbcomp both accept a symbols file whose key type is
unknown: the key silently falls back to `ONE_LEVEL` (`type= "ONE_LEVEL"` on
`<AD01>` in the dump), which users experience as a dead Shift key (issue #84).
The dumps spell groups and levels differently (`type[1]=`, `map[Shift]= 3`
for libxkbcommon; `type[Group1]=`, `map[Shift]= Level3` for xkbcomp) and
neither compiler logs the fallback at warning level. Action: never accept
"it compiles" as proof; require the probe key to be bound to the custom type
in the group carrying Ergopti and the type to map/preserve Control
(`inspect_keymap()` in `desktop_activation.py`), print the compiler command
and diagnostics on failure, and make a failed verification a non-zero exit.

### project-linux-install-is-proven-by-the-distribution-matrix

The maintainer has no Linux host: `linux-layout.yml` runs
`tests/e2e_distro.sh` in a container per distribution (old and new
libxkbcommon, glibc and musl, sudo and doas, Python 3.6 to 3.14) with the
distribution's own compilers, from an unprivileged user through the documented
piped command, and requires the system tree to be byte-for-byte pristine
after uninstall. The Arch entry replays the host of issue #84 (fish, wlroots
compositor, generation-2 leftovers) and a GNOME session on a private D-Bus bus
with a real dconf. Action: any installer change lands with a green matrix; a
new distribution family is added as a matrix entry, not as a manual checklist.

### project-linux-daemon-is-proven-live-through-a-real-kernel

`tests/hardware/run_daemon_live.sh` (CI step in `test-linux`) starts the real
daemon with `--tray` on a uinput keyboard, types "adn " and decodes what the
daemon's own virtual keyboard sends, while `sni_host.py` reads the tray menu.
It found three bugs that no recorder-based test could: every tray row's
`ffi.cast` callback leaked (LuaJIT never frees them, so the daemon crashed
with "too many callbacks"; one process-wide dispatcher now routes by id), a
100k-row menu that took seconds to build, and the expansion's replayed
terminator dropped because its key-down was still held on the virtual
keyboard (the kernel ignores a key-down for a key already down). Action:
inject through `injector.run_transaction`, which releases
`keyboard_hook.held_forwarded_keys()` first; never add a per-item FFI
callback; keep this live step green for any hook, injector or tray change.

### project-linux-tray-dialogs-and-windows-cross-the-grab-and-json

Two boundaries silently broke every tray UI on Linux while unit tests stayed
green. (1) A zenity/kdialog dialog runs inside a menu callback and blocks the
event loop that forwards the grabbed keyboard, so nothing could be typed into
it: every blocking dialog must go through `ui/modal.lua`
(`keyboard_hook.while_released`). (2) The webview manager decoded page
messages and encoded replies through `dkjson`, which is never installed: all
page objects arrived as nil. It uses the shared `json` codec now; bridge tests
that pass Lua tables to `route_message` cannot catch this, so
`tests/hardware/run_webview_roundtrip.lua` lets a real page post its own
request. Action: never add an optional JSON dependency or a dialog outside
`Modal.run`; a new window needs a round-trip check, not only a bridge test.

### project-linux-ai-is-proven-against-real-servers

The AI path is exercised end to end in CI: `run_daemon_live` accepts a
prediction from `fake_llm_server.py` (OpenAI dialect, as Cerebras) with a
bare 1 (the default chord since 2026-09-24; Alt+1 once the AI menu requires
Alt) through the real kernel, and `run_ollama_live.lua` drives the real Ollama
(model list, `/api/pull`, predictions, and the remote backend on Ollama's
`/v1` endpoint). They caught what scripted tests could not: text typed while
the accepting Alt was still held (every injection now releases Ctrl/Alt/Super
after an F24 mask tap, never restoring them), a double space from the parser
spacing against the word-rebuilt tail, and curl argv exposing keys and typed
text (headers, body and URL now go through `--config -`). Remote API keys
live in `~/.config/ergopti_plus/api_keys.json`, mode 0600, outside the
possibly-synced config folder. Action: keep both live steps green for any
change to the injector, the engine, the parser or the HTTP client.

## Release artifacts

### project-release-notes-are-not-joined-to-the-assets

Release notes and uploaded binaries are separate publication steps. Verify the
tag, notes, and every expected asset explicitly.

### project-packages-name-their-commit-through-a-build-stamp

An installed package has no .git, so `git rev-parse` or a HEAD read reports
"unknown" in every release. macOS and Linux package builds write
`_shared/build_stamp.txt` (`commit=<sha>`) through
`tools/build/write_build_stamp.sh` (the Linux packagers `verify` their copy);
Windows stamps `BUNDLE_COMMIT` in `infra/bundle.ahk`. Every diagnostic surface
resolves the commit through one resolver per driver
(`diagnostic_snapshot.resolve_commit` / `DiagSnapshot_ResolveCommit`): stamp,
then checkout, then a logged "unknown". Relatedly, macOS `hs.configdir` is the
script directory (inside the app bundle when packaged), never the configuration
directory; report `config_paths.get_config_dir()` for the latter. Action: a new
package format or diagnostic field goes through these owners, and
`test-package-builds-stamp-commit.cjs` must stay green.

### project-the-drift-guard-crashes-on-this-windows-box

When a cross-platform drift tool fails on Windows path/process semantics, use
the repository's supported wrapper and preserve the failure as a test fixture;
do not silently skip the guard.
