<!-- docs/design/layout-option-emulation.md -->

# Layout options on macOS and Linux, live, through one generated `.keylayout`

Status: design note, nothing implemented. It answers the TODO item « Number-row
and layout emulation on macOS and Linux, live » (maintainer request of
27 October) in the form the maintainer settled on: the user picks a layout, the
menu options and later per-key edits, and that produces **one custom
`.keylayout`**, the single source on every OS. Windows emulates it (the
emulation already reads a `.keylayout`), macOS installs it as the input source,
Linux converts it to XKB. No second format, no pre-generated variants: the
per-layer composer of `docs/layout-composer.md` is the base.

Legend used below: **Verified here** means run on this Linux host (libxkbcommon
1.6.0, xkbcomp 1.4.6, setxkbmap 1.3.4, Xvfb) while writing this note.
**To verify** means it cannot be checked here and must be checked on the
named machine before the slice that depends on it starts.

## 1. What Windows does today (the behaviour all three must type)

Read in `windows/modules/keymap/layout/layout_shift_caps.ahk`,
`number_row_send.ahk`, `modules/keymap/layout.ahk` and the shared policy
`_shared/modules/features/number_row_policy.ahk`.

- `layout.direct_access_digits` is an enum: `native` (default), `digits`,
  `symbols`. `layout.number_row_reorder_edges` is a boolean (default false).
  Both are declared for `ahk`, `hs`, `linux` in `manifest.toml`; only Windows
  applies them, macOS and Linux store them.
- It is whole keys, not digits alone. The ten digit keys are `SC002` to `SC00B`
  (1 to 0). For each, the option exchanges the **base** and the **Shift** cell
  of the key: `digits` makes the base level the digit and Shift its symbol,
  `symbols` the other way round. The symbol is whatever the effective layout
  holds there, text or a dead key (a dead Shift level types its accent); a dead
  cell moves with its whole state machine.
- The edge keys are `SC029` (left of 1), `SC00C` and `SC00D` (right of 0). With
  `number_row_reorder_edges` they exchange their own base and Shift cells too.
  They join only while an ordering applies to the digit keys.
- Only the unmodified and the Shift press are intercepted (`SC002::` and
  `+SC002::`). AltGr, Ctrl, Alt and Win levels are not touched: Ctrl+1 stays
  Ctrl+1 whatever the ordering. A held Kana AltGr stands the hotkeys down.
- Applicability is decided per layout from what the ten keys hold
  (`NumberRowPolicyAvailability`), by the class of the base and Shift cell
  (`d` own digit, `s` another character or a dead key, `n` nothing):
  - all ten keys `sd` (symbol, digit): `digits` usable, `symbols` already applied;
  - all ten `ds`: `symbols` usable, `digits` already applied;
  - `dd`, `ss`, `dn`/`nd`, no digit, or a row whose keys disagree: both refused
    with the reasons `digits_on_both`, `symbols_on_both`, `incomplete`,
    `no_digits`, `mixed`.
  - the edges need an ordering in effect and, for each edge key, two different
    non-empty cells (`no_ordering`, `edges_incomplete`, `edges_same`).
  - A refused choice is **inert, never rewritten**: it is kept and applies again
    on a layout where it can.
- Caps: the Caps level of a non-letter key is its base cell (the composer's
  rule), so it follows the new base.

Consequence for the design: the option is a pure function from a layout's cells
to a layout's cells, touching only the base, Shift and Caps keyMaps of 13 keys.
That is exactly what a compiler can do, and it gives one definition for the
three OS.

## 2. How the options feed the compiled `.keylayout`

```
 layout choice ─┐
 menu options  ─┼─▶ composer_model.js: compose ─▶ applyRowOptions ─▶ serialize ─▶ composed.keylayout
 per-key edits ─┘      (existing)         (new, pure)             (existing)         │
                                                                   ┌────────────────┼──────────────────┐
                                                              Windows reads    macOS installs     Linux converts
                                                              (emulation)      as input source    (xkb_converter.lua)
```

- The options become part of the declaration the composer already stores
  (`composition.json`, which only the page reads): `rows: { order, edges }`.
  The compiled file is the only thing a driver installs. No field is added to
  the `.keylayout` format.
- `applyRowOptions(cells, options)` is one pure function in
  `composer_model.js`, the only implementation, with the availability
  classification of section 1 ported from the AHK policy to the same module and
  checked against the same vectors. It runs after composition and before
  serialization, so the `.keylayout` the OS receives already carries the
  swapped cells, dead-key state machines included.
- A user who has chosen no layout (the OS layout stays) has no source to
  transform. The options then stay stored and inert with the reason
  `no_source_layout`, the same « stored, not applied, why » behaviour as
  Windows. The two built-in reference sources (`qwerty`, `azerty`) and every
  registry layout are valid sources, as the composer already says.
- **Modifiers follow the layout by construction.** Only keyMaps 0, 1, 2 (base,
  Shift, Caps) change. The serialized Ctrl (6), Alt (7), Win/Cmd (5) and AltGr
  (3, 4) maps are copied from the layout, so Cmd+1 and Ctrl+1 stay digits and
  Ctrl+a is the layout's `a`, as on Windows.
  - macOS: the system reads those keyMaps natively.
  - Linux: the `ERGOPTI_SEVEN_LEVEL` type sends Control, Alt and Mod4 (with or
    without Shift) to Level5, which the converter fills from the Command
    keyMap. Ctrl+1 therefore types the layout's Command cell, a digit.
    Verified by reading `xkb_types.txt` and the converter; the Ctrl and Alt
    rows stay indistinguishable on Linux (`shortcuts: "single"`, already
    documented in the composer note).
- Dead keys and symbols come from the layout because the compiler never
  invents a cell: it moves cells that exist. The refusal reasons of section 1
  are what the compiler returns when a move would lose one.

## 3. Live replacement, with no logout

The invariant on both OS: **a build is never written over the file the system
already loaded.** Each build gets its own identity (a counter in the layout
name, hence a new `id` derived from it), is installed, selected and verified,
and only then is the previous one retired.

### 3.1 macOS

What is in the repository today:

- `install_local` writes the verified file to `~/Library/Keyboard Layouts` and
  enables it by editing `AppleEnabledInputSources` of `com.apple.HIToolbox`
  through `defaults export/import` and a SystemUIServer restart
  (`input_sources.lua`; the entry is `Keyboard Layout` + integer
  `KeyboardLayout ID` + `KeyboardLayout Name`, no bundle id).
- The Swift side (`launcher/.../InputSourceSelectionWorker.swift`,
  `InputSourceUpgradeWorker.swift`) already calls `TISCreateInputSourceList`
  (all installed sources), `TISEnableInputSource`, `TISDisableInputSource` and
  `TISSelectInputSource`, in an isolated signed process the Lua owner bounds.
- Hammerspoon exposes `hs.keycodes.layouts()`, `currentSourceID()`,
  `setLayout()/setMethod()` and an `inputSourceChanged` watcher, which is
  enough to observe and select; it has no registration call. `TISRegisterInputSource`
  is not called anywhere in the repository.
- The composer note states the known limit: macOS may read a rewritten file only
  after the input source is toggled or the user logs in again.

Proposed sequence (worker `--replace-input-source`, the upgrade worker's
retain-before-mutate shape):

1. Compile the new `composed.keylayout` with the name `<Base> <n>` (counter from
   the installed record; the integer `id` follows from the name).
2. Write it atomically as `~/Library/Keyboard Layouts/ErgoptiPlusComposed-<n>.keylayout`.
3. `TISRegisterInputSource(fileURL)` so the system lists it without a login.
   (If it is refused, fall back to the existing enabled-list edit; to verify.)
4. Find the new source by id in the full inventory (`TISCreateInputSourceList(nil, true)`),
   `TISEnableInputSource`.
5. If the previous build was the selected source, `TISSelectInputSource(new)`;
   if the user had selected another source meanwhile, do not take the selection.
6. Verify (the acknowledgement of section 5): the current keyboard-layout
   source id is the new one and the digit row translates as expected
   (`UCKeyTranslate` over the source's `kTISPropertyUnicodeKeyLayoutData`).
7. Only then `TISDisableInputSource(previous)`, remove its enabled-list entry,
   delete its file, update the record.

Bound on stale sources: at most **two** builds exist (current and, until step 7
succeeds, previous). A failed retirement is recorded as `pending_removal` and
retried at the next boot and before the next build; if two retirements are
already pending the build is refused (`stale_sources_pending`) rather than
growing the list. The counter wraps in the record, never in the name space of
other layouts.

Must be verified on the maintainer's Mac (none of this can run on Linux):

| #   | Question                                                                                                                                               | Why it decides the design                                                                                                |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| M1  | Does `TISRegisterInputSource` make a file written into `~/Library/Keyboard Layouts` appear in `TISCreateInputSourceList(nil, true)` without a logout?  | If yes, step 3 is the live path; if no, the enabled-list edit plus a SystemUIServer restart must be shown to do the same |
| M2  | What `TISPropertyInputSourceID` does a bare user `.keylayout` get (`org.unicode.inputmethod.keylayout.<Name>`, `com.apple.keylayout.<Name>`, another)? | The worker finds sources by id; the repo only knows the bundle forms                                                     |
| M3  | After rewriting the **same** file and name, does the source type the old or the new cells, and after one toggle?                                       | Confirms that the versioned name is needed at all                                                                        |
| M4  | Does a new name (new integer id) type the new cells at once after register, enable, select, with no logout?                                            | The core claim                                                                                                           |
| M5  | Does `TISDisableInputSource` plus deleting the file of the old build leave no ghost in System Settings, and does it survive a logout?                  | The stale-source bound                                                                                                   |
| M6  | Is the selected source preserved when the previous one is disabled after the new one is selected?                                                      | Step 5 and 7 ordering                                                                                                    |

The probe is a runnable file, `tools/diagnostics/macos_tis_register_probe.swift`
(written without a Mac or a Swift toolchain; the first version compiled and ran on
the maintainer's Mac on 27 October). From the repository root:

```
swiftc -O -o /tmp/ep_tis_probe tools/diagnostics/macos_tis_register_probe.swift && /tmp/ep_tis_probe
```

Result of the first version (arm64, current source `com.apple.keyboardlayout.ergopti.plus`):

- M1 PASS: `TISRegisterInputSource` returns 0 and the source is listed at once, with no
  logout. Its id for a bare user file is `org.unknown.keylayout.<Name>` (M2).
- M3: a file rewritten in place under the same name keeps typing the old cells, so a
  versioned name is needed.
- M6 PASS: disabling a source leaves the selection alone.
- M5a FAIL: a disabled source whose file was removed stays listed (a ghost) until logout.
- M4a/M4b FAIL: `TISSelectInputSource` on the freshly registered loose file returns
  -50 (paramErr), so the live switch is blocked until a way to select is found.

The second version tries the ways around -50, one line each: P1 capabilities before
selecting (IsSelectCapable, IsEnableCapable, category, type) with a numeric id outside
every installed layout's range, P2 select at once, P3 select after a run-loop turn and
after re-reading the list, P4 the same layout as a `.bundle` (Info.plist plus
`Resources/*.keylayout`), P5 (only with `--write-prefs`, which edits the user's
`AppleEnabledInputSources` and puts it back) select once the source is enabled through
the preferences, P6 ghosts after the cleanup; `/tmp/ep_tis_probe after-logout` repeats
P6 after a logout. It changes only throw-away layouts named `EPProbe<pid>...`, puts the
user back on the source they started with and removes its files, also on failure.

If M1 prints a non-zero status the note
is amended before slice 5.

### 3.2 Linux

What is in the repository today: `user_layout_installer.py` installs a converted
layout into `$XDG_CONFIG_HOME/xkb` (symbols, `rules/evdev` with the types rule,
`rules/evdev.xml` for pickers), refuses an Xorg session
(`refuse_xorg_session`), and `desktop_activation.py` selects it through
`gsettings` on GNOME, `kwriteconfig` plus a reload on KDE, and `setxkbmap` for a
**system-installed** layout on X11; wlroots-style compositors only get printed
configuration lines. The daemon already captures the live XKB keymap
(`infra/xkb_keymap.lua`).

Verified here:

- **libxkbcommon loads a user XKB file.** A layout `zzergo` with two variants
  placed only in `$XDG_CONFIG_HOME/xkb/symbols/` compiled with
  `xkb_keymap_new_from_names` and returned the right keysyms at four levels of
  the digit key (`1 ! dead_circumflex &` for one variant, `! 1 & dead_circumflex`
  for the other); with the user tree absent the compile fails and names the
  searched paths (`$XDG_CONFIG_HOME/xkb`, `~/.xkb`, `/etc/xkb`, system). That is
  the mechanism every Wayland compositor built on libxkbcommon uses, and what
  the existing installer relies on. It says nothing yet about a particular
  compositor (see W1 to W3).
- **X11 live replace from a user tree works, with a different command than
  today.** Plain `setxkbmap -I<dir> -layout zzergo` fails
  (`Error loading new keyboard description`: `-I` is not passed to the keymap
  compile). The pipe `setxkbmap -I<dir> -layout L -variant V -print | xkbcomp -I<dir> - $DISPLAY`
  succeeded on Xvfb, with no sudo, and a dump of the server keymap changed
  between the two variants and back, three times, with no restart. The
  existing `apply_x11` (plain `setxkbmap`) only reaches a layout installed in
  the system tree.

Proposed Linux sequence (same invariant as macOS):

1. Convert with `xkb_converter.lua` to `<id>.xkb` + XCompose, where the id is
   `ergopti_composed_<n>` (counter from the record).
2. `user_layout_installer.py install` writes it, atomically, with the types rule.
3. Activate by session:
   - **X11 (any desktop):** the `setxkbmap -print | xkbcomp` pipe above, no
     versioning needed (every call compiles), but see W4: the desktop's own
     settings daemon may re-apply its layout.
   - **GNOME Wayland:** `gsettings set org.gnome.desktop.input-sources sources`
     to `[('xkb','ergopti_composed_<n>')]` plus `current`, with read-back
     (already implemented for registered layouts). A new id forces mutter to
     compile again; rewriting a file under the same id and setting the same
     value generates no change, which is why the id is versioned.
   - **KDE Wayland:** `kxkbrc` `LayoutList`/`VariantList` through
     `kwriteconfig6` and the existing reload (`_kde_reload`).
   - **Other compositors (sway, Hyprland, niri, river, Wayfire):** a live
     command exists for some (`swaymsg input type:keyboard xkb_layout`,
     `hyprctl keyword input:kb_layout`) but is not implemented today; until it
     is, the refusal below applies.
4. Verify (section 5), then remove the previous build's files and registry
   entry. Same bound as macOS: current plus one pending retirement.

Refusal and failure text, one closed code each (strings go through the `i18n`
skill, all 21 locales):

| Code                               | When                                                                             | What the user sees (EN, to be localised)                                                                                                                            |
| ---------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `no_source_layout`                 | options stored, no layout chosen                                                 | « Choose a layout first: the number-row options change the layout you pick. »                                                                                       |
| `row_mixed`, `digits_on_both`, ... | availability of section 1                                                        | the existing `menu.layout.number_row_*` reason strings                                                                                                              |
| `session_unsupported`              | Linux compositor without a live path                                             | « This desktop cannot switch keyboard layouts while running. Your choice is saved; add the layout to your compositor configuration (shown below) or log in again. » |
| `userspace_xkb_unreadable`         | libxkbcommon older than the user tree support, or the compositor ignores it (W1) | « This desktop does not read user keyboard layouts. » + the legacy system-install command                                                                           |
| `x11_reapplied`                    | after the apply the server keymap no longer matches (W4)                         | « The desktop restored its own layout. »                                                                                                                            |
| `stale_sources_pending`            | two retirements already pending (macOS or Linux)                                 | « Previous layout copies could not be removed; remove them in System Settings, then retry. »                                                                        |
| `select_refused`                   | `TISSelectInputSource` or gsettings read-back differs                            | the OS status in the log, a fixed sentence in the UI                                                                                                                |

In every refusal the stored choice stays and the typed layout stays the last one
that was verified: nothing is half applied.

To verify on a real desktop (no GNOME or KDE is available on this host):

| #   | Question                                                                                                                                                                                                                                |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| W1  | Does mutter (GNOME 45+) and KWin (Plasma 6) compile a layout id found only in `~/.config/xkb`, including the `ERGOPTI_SEVEN_LEVEL` type through the user `rules/evdev`?                                                                 |
| W2  | After changing `sources` to a new id, does the new keymap type at once in already-open applications?                                                                                                                                    |
| W3  | Does rewriting the file under the same id plus re-setting the same value leave the old keymap (the claim behind versioning)?                                                                                                            |
| W4  | On GNOME or KDE under X11, does the settings daemon re-apply the layout on device hotplug or layout switch and drop the xkbcomp-loaded keymap? Then the daemon must re-apply or X11 on those desktops falls back to the system install. |

A small shell probe for W1 to W3 will ship with slice 3 (it prints the
compiled keysyms through `xkbcli` or the ctypes call used here and the
`gsettings` read-back), so the check is one command on the target desktop.

## 4. Counts

There is no variant matrix. One compiled file per request. The number of
files on disk is bounded: current plus at most one pending retirement per OS.
The inputs that decide the cells are `order` (3) × `edges` (2) × the chosen
layout, of which only five combinations differ from the layout itself (native;
digits; digits and edges; symbols; symbols and edges).

## 5. Scope participant: acknowledge only after the layout is selected

`layout.direct_access_digits` and `layout.number_row_reorder_edges` are stored
by the existing scope composition (`config_scope_composition`,
`config_scope_participant.synchronous`). The participant for this feature is
asynchronous and settles through the continuation contract:

- `apply(mode, done)`: compile, install, activate (section 3). `done(true)` is
  called **only** when the verification passes, never after the write or after
  the command returned:
  - macOS: the current keyboard-layout source id is the new id **and**
    `UCKeyTranslate` of the 13 keys at base/Shift equals the compiled cells;
  - Linux: the daemon's XKB capture (`infra/xkb_keymap.lua`) reports a keymap
    whose layout name is the new id and whose digit row equals the compiled
    cells; on GNOME the `gsettings` read-back must also match.
- A verification that does not pass within the bounded deadline calls
  `done(false, code)` with a code of section 3.2 and leaves the previous
  build selected: `revert` selects the previous build again if it is still
  present; `retry_restore` retries the retirement; `pending()` is true while a
  retirement is outstanding, so the composition never reports a settled state
  over an unsettled system; `release` drops the owner.
- A stored option that is inert (a refusal of section 1) acknowledges as
  applied-with-reason, like Windows, not as an error.

## 6. Tests

Shared vectors first, then each replay.

- `_shared/tests/corpus/row_options/*.json`: for each source (`qwerty`,
  `azerty`, Ergopti, Ergo-L, a layout with a dead key on the Shift level of a
  digit key, a mixed row, a row without digits) and each of the 5 option
  combinations: the expected cell matrix of the 13 keys for keyMaps 0 to 7, or
  the refusal code. Hand-written from the Windows behaviour of section 1, not
  produced by the new code.
- Node: `composer_model.js` `applyRowOptions` against the vectors; round trip
  through the reader; Ctrl/Cmd maps unchanged; dead-key state machines moved
  whole; inert choice kept.
- Windows parity (AHK, existing `test_e2e_number_row.ahk` harness): the
  hotkey implementation and the compiled `.keylayout` read by the emulation
  type the same characters for the same vectors. This is the proof that the
  three OS agree, and the precondition to ever retire the hotkeys (not planned).
- Lua (macOS and Linux unit tests, shared contract): `layouts/keylayout.lua`
  reads the compiled file; the converter produces XKB whose levels equal the
  vectors; `test-keylayout-canonical-parity.cjs` extended to the new corpus so
  the Lua and Python converters stay byte-identical.
- Linux hardware-class test (runs on CI Linux, uses libxkbcommon through ctypes
  as in section 3.2): compile the generated XKB from a temporary
  `XDG_CONFIG_HOME` and compare keysyms at the 7 levels with the vectors; and
  an Xvfb test of the `setxkbmap | xkbcomp` replace, three consecutive builds.
- macOS (Swift tests plus the maintainer probe): the replace worker with the
  injectable backend of `InputSourceUpgradeWorker` (ordering, refusal at each
  step, nothing retired before verification, the stale bound); the real TIS
  behaviour only on a Mac.
- Scope participant: replay of apply / settle / revert / retry_restore with
  fakes, including a verification that never arrives.
- Failure injection per step (write refused, register refused, select refused,
  gsettings differs, retirement refused): each ends in the closed code and the
  previous build still selected.

## 7. Slices

0. **Probes.** The macOS probe (maintainer) and the Wayland probe script;
   amend section 3 with the answers. No code depends on it before slice 3 and 5.
1. **Shared model.** `applyRowOptions`, availability port, vectors, Node
   tests. Declaration field `rows`. No driver change.
2. **Windows parity test.** Replay the vectors on the AHK emulation next to the
   hotkey path; fix any divergence in the vectors first (they are the spec).
3. **Linux Wayland live.** Versioned ids, user installer reuse, GNOME and KDE
   activation, XKB-capture verification, refusals, i18n, probe script.
4. **Linux X11 live.** User-tree pipe, re-apply check (W4), refusal or system
   install fallback.
5. **macOS live.** Swift replace worker, Lua orchestration, bounded stale
   sources, `UCKeyTranslate` verification; gated on M1 to M6.
6. **Menu and scope.** The `direct_access_digits` / `number_row_reorder_edges`
   rows live on macOS and Linux (manifest platforms, reason keys), the scope
   participant, onboarding page controls, all 21 locales.
7. **Per-key edits page** (later, outside this item): the composer page already
   edits cells; options and edits then compose in one compile.

Each slice is a separate commit series with its own regression tests; slices 3
and 5 are the two that need a person with the real desktop.
