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

## Release artifacts

### project-release-notes-are-not-joined-to-the-assets

Release notes and uploaded binaries are separate publication steps. Verify the
tag, notes, and every expected asset explicitly.

### project-the-drift-guard-crashes-on-this-windows-box

When a cross-platform drift tool fails on Windows path/process semantics, use
the repository's supported wrapper and preserve the failure as a test fixture;
do not silently skip the guard.
