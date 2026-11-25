<!-- docs/audits/accessibility/README.md -->

# Accessibility audit

Started on 2026-11-17 (Paris time) for the TODO section « Full accessibility »
(maintainer request of 2026-11-16). Target: WCAG 2.2 level AA on the site
(ergopti.fr), Ergopti Studio (editor, Comparer, Optimiser, benchmarks) and
Ergopti+ itself, raised to AAA on 2026-11-23 (what each AAA criterion is
checked by: [aaa-criteria.md](aaa-criteria.md)). The public statement is the site page `/accessibilite`
(`src/routes/accessibilite/+page.svelte`); its « known gaps » follow this file.

## Method and limits

- **Automated scan.** `tools/test/browser/site-accessibility.playwright.cjs`
  serves a built site on loopback and runs axe-core 4.14.0 (tags `wcag2a`,
  `wcag2aa`, `wcag21a`, `wcag21aa`, `wcag22a`, `wcag22aa`, and since
  2026-11-24 `wcag2aaa`, `wcag21aaa`, `wcag22aaa`, one list in
  `tools/test/lib/wcag-tags.cjs`) on every page of
  the site and inside every same-origin frame it embeds (the Studio pages and
  the Ergopti+ app windows shown as demos), in the light and dark colour
  schemes, with reduced motion emulated so that reveal animations do not hide
  content from the scan. Headless Chromium only.
- **Ratchet.** Each violation is counted in nodes per page, scheme, frame and
  rule in `tools/test/browser/site-accessibility-baseline.json`. CI runs the
  scan on the received production site (job « Install and launch ») and fails
  on a new row or a higher count; a lower count asks for
  `--update-baseline`. `tools/test/test-site-accessibility-ratchet.cjs`
  proves, without a browser, that the comparison refuses regressions and that
  every page under `src/routes` is audited.
- **Behaviour checks** in the same gate, which a scan cannot see: the skip
  link is the first keyboard stop and moves the focus to the content, the
  settings dialog has no violation of its own, a setting applies to the page,
  reaches the Studio frame, survives a reload and resets, and the narrow-screen
  menu opens from the keyboard and hides its links when closed.
- **Not covered yet.** Automated tools find roughly a third of WCAG failures.
  No screen-reader run, no 400 % zoom or 320 px reflow walk and no native
  window (UI Automation, NSAccessibility, AT-SPI) has been recorded; these are
  the « Manual audit » item of TODO.md. Non-text contrast (WCAG 1.4.11) is not
  checked by axe.

Local run: `npx vite build`, then
`node tools/test/browser/site-accessibility.playwright.cjs build ""`
(`--only=/studio,/` to scan a few pages, `--report=file.json` for every finding
with its first targets, `--update-baseline` after fixes). From Git Bash, set
`MSYS_NO_PATHCONV=1` so the route arguments are not rewritten as paths.

## Results per page

Violation nodes found by the scan, before this pass (the gate's first
baseline, commit « test(a11y): gate the site and Studio pages on an axe-core
ratchet ») and after it (2026-11-17, on dev after « test(ui): read the dark
theme block that yields to a chosen light theme »).

| Page                            |       Light before |       Light after | Dark before | Dark after |
| ------------------------------- | -----------------: | ----------------: | ----------: | ---------: |
| `/`                             |                  1 |                 0 |           1 |          0 |
| `/ergopti`                      |                  1 |                 0 |           1 |          0 |
| `/ergopti/presentation`         |                 15 |                 0 |          15 |          0 |
| `/ergopti/utilisation`          |                  3 |                 0 |           3 |          0 |
| `/ergopti/installation`         |                 12 |                 0 |          12 |          0 |
| `/ergopti/benchmarks`           |                136 |                 6 |         136 |          6 |
| `/ergopti/informations`         |                 20 |                 0 |          20 |          0 |
| `/ergopti-plus`                 |                  9 |                 0 |           9 |          0 |
| `/ergopti-plus/presentation`    |                  2 |                 0 |           2 |          0 |
| `/ergopti-plus/hotstrings`      |                 17 |                 0 |          17 |          0 |
| `/ergopti-plus/ia`              |                 15 |                 0 |          15 |          0 |
| `/ergopti-plus/fonctionnalites` |                  1 |                 0 |           1 |          0 |
| `/ergopti-plus/configuration`   |                  2 |                 0 |           2 |          0 |
| `/ergopti-plus/installation`    |                  1 |                 0 |           1 |          0 |
| `/ergopti-plus/faq`             |                  1 |                 0 |           1 |          0 |
| `/ergopti-plus-old`             |                 28 |                 6 |          28 |          6 |
| `/studio`                       |                  7 |                 0 |           6 |          0 |
| `/studio/comparer`              |                124 |                 7 |         124 |          7 |
| `/studio/optimiser`             |                  2 |                 0 |           2 |          0 |
| `/accessibilite`                |                new |                 0 |         new |          0 |
| **Total**                       | 793 (both schemes) | 38 (both schemes) |             |            |

## Findings

Severity is axe's impact. « Where » is the page for findings in the site's own
document, or the framed shared page. Owner is who should fix what is left:
other agents are rebuilding the Comparer's charts and heatmaps and the
Optimiser, so chart-internal findings stay with them.

| Severity | Where                                                                                                                                                                                                                                                                                                                                                                                                                                | Rule                          | Nodes before | Nodes after | Owner                           |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------- | -----------: | ----------: | ------------------------------- |
| Critical | `/ergopti/presentation`, `/ergopti/utilisation`, `/ergopti/benchmarks`, `/ergopti-plus/presentation`, `/ergopti-plus-old`                                                                                                                                                                                                                                                                                                            | `select-name`                 |           12 |           0 | Site                            |
| Critical | `hotstring_editor/index.html`                                                                                                                                                                                                                                                                                                                                                                                                        | `label`                       |           12 |           0 | Ergopti+ shared UI              |
| Critical | `personal_info_editor/index.html`                                                                                                                                                                                                                                                                                                                                                                                                    | `label`                       |           12 |           0 | Ergopti+ shared UI              |
| Critical | `layout_editor/index.html`                                                                                                                                                                                                                                                                                                                                                                                                           | `aria-required-children`      |            2 |           0 | Studio editor                   |
| Critical | `layout_editor/index.html`                                                                                                                                                                                                                                                                                                                                                                                                           | `aria-required-parent`        |            2 |           0 | Studio editor                   |
| Critical | `layout_editor/index.html`                                                                                                                                                                                                                                                                                                                                                                                                           | `button-name`                 |            2 |           0 | Studio editor                   |
| Critical | `layout_editor/index.html`                                                                                                                                                                                                                                                                                                                                                                                                           | `select-name`                 |            2 |           0 | Studio editor                   |
| Serious  | `layout_analysis/index.html`                                                                                                                                                                                                                                                                                                                                                                                                         | `target-size`                 |          462 |           0 | Comparer / evaluator agents     |
| Serious  | `/ergopti/presentation`, `/ergopti/installation`, `/ergopti/benchmarks`, `/ergopti/informations`, `/ergopti-plus-old`                                                                                                                                                                                                                                                                                                                | `target-size`                 |          146 |           0 | Site                            |
| Serious  | `/`, `/ergopti`, `/ergopti/presentation`, `/ergopti/utilisation`, `/ergopti/installation`, `/ergopti/benchmarks`, `/ergopti/informations`, `/ergopti-plus`, `/ergopti-plus/presentation`, `/ergopti-plus/hotstrings`, `/ergopti-plus/ia`, `/ergopti-plus/fonctionnalites`, `/ergopti-plus/configuration`, `/ergopti-plus/installation`, `/ergopti-plus/faq`, `/ergopti-plus-old`, `/studio`, `/studio/comparer`, `/studio/optimiser` | `label-content-name-mismatch` |           54 |           0 | Site                            |
| Serious  | `layout_analysis/index.html`                                                                                                                                                                                                                                                                                                                                                                                                         | `label-content-name-mismatch` |           26 |           0 | Studio (second pass)            |
| Serious  | `model_browser/index.html`                                                                                                                                                                                                                                                                                                                                                                                                           | `color-contrast`              |           18 |           0 | Ergopti+ shared UI              |
| Serious  | `/ergopti/installation`, `/ergopti-plus-old`                                                                                                                                                                                                                                                                                                                                                                                         | `list`                        |           14 |           0 | Site (legacy page: second pass) |
| Serious  | `/ergopti-plus/ia`                                                                                                                                                                                                                                                                                                                                                                                                                   | `color-contrast`              |           10 |           0 | Site                            |
| Serious  | `hotstring_editor/index.html`                                                                                                                                                                                                                                                                                                                                                                                                        | `color-contrast`              |            6 |           0 | Ergopti+ shared UI              |
| Serious  | `layout_editor/index.html`                                                                                                                                                                                                                                                                                                                                                                                                           | `color-contrast`              |            3 |           0 | Studio editor                   |
| Serious  | `/ergopti/presentation`                                                                                                                                                                                                                                                                                                                                                                                                              | `link-name`                   |            2 |           0 | Site                            |
| Serious  | `/ergopti/utilisation`                                                                                                                                                                                                                                                                                                                                                                                                               | `scrollable-region-focusable` |            2 |           0 | Site                            |
| Serious  | `personal_info_editor/index.html`                                                                                                                                                                                                                                                                                                                                                                                                    | `color-contrast`              |            2 |           0 | Ergopti+ shared UI              |
| Serious  | `changelog/index.html`                                                                                                                                                                                                                                                                                                                                                                                                               | `color-contrast`              |            2 |           0 | Ergopti+ shared UI              |
| Serious  | `layout_optimizer/index.html`                                                                                                                                                                                                                                                                                                                                                                                                        | `color-contrast`              |            2 |           0 | Optimiser agent                 |

## What the pass fixed

- **Site.** Skip link and a two-ring focus style on every page; the
  narrow-screen menu could not be opened from the keyboard (its checkbox was
  `display: none`) and its closed links took the focus invisibly; home links
  whose names did not contain their visible text; unnamed selects, scroll-down
  link and demo pager; a picture directly in a list; a scrolling table
  unreachable by keyboard whose sort headers answered only to the mouse;
  15 px table-of-contents targets; 1.9:1 to 4.1:1 greys in the AI tooltip
  demo; buttons nested in links on the installation page; the keyboard
  drawings are tables (a text view of the layout) and dead keys are named.
- **Reduced motion.** `prefers-reduced-motion` and the site's own setting stop
  AOS reveals, tocbot's and the page's smooth scrolling, CSS animations, the
  hero demo's cycling and the count-up figures, on the site and in the Studio
  frames (`theme.css`).
- **Shared pages.** Filled buttons were white on the Apple blue (4.0:1, 3.6:1
  in dark): a new `--theme-accent-fill` and a darker light accent
  (`#0062cc`) fix them everywhere; dim greys of the model browser and the
  changelog reach 4.5:1; the root `lang` follows the active locale instead of
  `fr` in every language; the editor's layout tabs are a named group (a
  tablist may hold only tabs) and its shortcut view a pressed toggle; unnamed
  hotstring checkboxes, personal-info fields, finger select and home button;
  24 px targets in the Comparer's layout list; the Optimiser's progress bar is
  named by its live status line (the Comparer and the Optimiser already had
  polite status regions).
- **Settings and statement.** A header dialog with reduced motion, Atkinson
  Hyperlegible (self-hosted under `static/fonts/`, SIL OFL 1.1), text size to
  200 %, WCAG 1.4.12 spacing and high contrast, stored per visitor through
  `static/ergopti_plus/_shared/ui/a11y_prefs.js`, tolerant of blocked storage
  and carried into the Studio frames; the statement page `/accessibilite`.

## Second pass (2026-11-17, Paris time)

Violation nodes: 38 before (the baseline after the first pass), 0 after on
every page and frame the scan opens. The gate now also unfolds what the scan
cannot reach and holds it at zero (`exerciseStudio`, `exerciseHeroPause`).

- **Comparer charts.** The score bars' names began with the rank, not the
  visible « name value » (axe `label-content-name-mismatch`, 6 and 7 nodes on
  `/ergopti/benchmarks` and `/studio/comparer`): the name now starts with the
  visible text in all 21 locales and the two cells are two words. Every bar
  figure of the details (classes, travel, modifiers, standing, contributions,
  finger load, hands and rows) and the editor panel's finger load read as a
  table (row header, cell, the drawn bar hidden, the ideal load said with
  the value); the heatmap has « the values as a table » (key, place, finger,
  value, largest first) and each key's name says where it is. The ranking
  table already is the score chart's text alternative. The look is unchanged.
- **Keyboard drawings.** The editor's keys are named by their visible legend,
  printed name, place (« rangée 2, touche 5 ») and what they do on every
  layer, dead keys named as such, the analysis colour's value in words; the
  layout has a table view under the board. The Optimiser's clickable keys say
  their character and place instead of a raw key code; the fingering editor's
  keys say their finger in words and their place.
- **Dragging (WCAG 2.5.7).** The only drags of the Studio are in the editor:
  a key onto a key (swap, Ctrl copies) and a character onto a key. A « Swap
  with the key » choice and button in the key inspector swap without a drag;
  Copy and Paste already copied, and a palette click already typed a
  character into the selected key's text.
- **Colour.** Palette checks with the dataviz validator (OKLab, CVD
  simulation) on the light (`#ffffff`) and dark (`#2c2c2e`) surfaces:
  gain / loss `#2a78d6` / `#eb6834` pass every check (worst colour-blind
  separation ΔE 24.7 protanopia, tritanopia 32.7) and `#3987e5` / `#d95926`
  in dark (26.8, 32.4); the heatmap ramps are one hue, monotone, with visible
  steps, but their light end is 1.16:1 (light) and 1.11:1 (dark) against the
  surface, so a key worth zero is told by its printed character, its name and
  the table, not by its shade (open, owner Comparer). Status text was below
  4.5:1 (system green 2.2:1, red 3.6:1 on white): `--theme-good-text` and
  `--theme-bad-text` (5.1:1 and 5.8:1 light, 6.9:1 and 4.9:1 dark) now colour
  the Studio's better / worse values and error messages. Colour-only
  information found and fixed: the editor panel's and the Optimiser's
  better / worse deltas (now ▲ ▼ and words) and the Optimiser's « key of the
  chosen character » border (now dashed as well). Windows high contrast
  (`forced-colors`) keeps the figures' colours instead of erasing the bars.
- **Reflow.** At 320 px the fingering editor's fixed-size board widened the
  Comparer page: it scrolls inside its own focusable box now; the result and
  heatmap tables scroll in focusable boxes.
- **Site.** A pause button for the Ergopti+ hero demo when it cycles
  (WCAG 2.2.2); the English Ergopti+ page sets `lang="en"` (WCAG 3.1.1); the
  buttons nested in links (installation, benchmarks, presentation: two focus
  stops each, which axe does not flag) are links styled as buttons, and a
  source check refuses a new one; the legacy `/ergopti-plus-old` page (still
  linked from the new one, so kept) holds its paragraphs and spacers inside
  list items.
- **Scan reliability.** The scan waits until no frame is `aria-busy`: a
  Comparer still computing dims its ranking, which once read as 66 contrast
  failures in one run.

## Third pass, Studio and site (2026-11-17, Paris time)

The axe gate stays at 0 nodes; it now also restores, undoes and scans the
Comparer's « Undo » lines.

- **Undo after a restore (WCAG 3.3.4).** The Comparer's four « Restore »
  buttons (weights, ideal load, shortcut letters, keyboard forms) and the
  fingering editor's reset still act at once, then a polite status line
  right after the button says « … : defaults restored. » with an « Undo »
  button one Tab away (`layout_analysis/undo_offer.js`, 21 locales). No
  timer (WCAG 2.2.1): the offer stays until the section is edited again or
  another restore replaces it; after an undo the focus returns to the
  restore button. A section already at its defaults offers nothing.
- **Heatmap keys (WCAG 1.4.11).** The ramp keeps its look; every key wears
  a 1 px edge of the ramp's hue (`--theme-chart-ramp-edge`, `#5f86bf` light,
  `#6d8fbd` dark) inside the surface gap: 3.7:1 and 4.2:1 against the
  surface, 3.2:1 and 3.8:1 against the light end, so a key worth zero keeps
  its shape. The dataviz validator (`--ordinal`) still reports the light end
  itself below 2:1, which the edge answers.
- **Fingering editor.** The four finger tints (30 % of the system red,
  orange, green and blue) failed every validator check (normal-vision ΔE
  7.7, colour-blind ΔE 3.3, 1.3:1 on the surface). The fingers now take the
  validator's first four categorical slots in their fixed order from the
  pinky (`--theme-chart-cat-1..4`): light `#2a78d6 #eb6834 #1baf7a #eda100`
  passes (worst adjacent colour-blind ΔE 9.1 protanopia, normal vision
  22.9; aqua and yellow 2.8:1 and 2.2:1 on white, answered by the finger
  printed on every key), dark `#3987e5 #d95926 #199e70 #c98500` passes every
  check (8.4, 19.8, all ≥ 3:1). The hue is the key's 2 px edge; the key is a
  22 % tint, so its printed finger stays above 4.5:1.
- **App windows.** The metrics dashboards' muted text (units, help, table
  headers) was the system tertiary grey `#86868b`, 3.3:1 to 3.6:1 in light:
  now `#636366` (5.5:1 on the page, 4.8:1 on the headers; dark was already
  above 4.5:1). The AI prediction tooltip's hint line and info bar were
  2.7:1 and 1.8:1 on its `#242424` panel: now `#999999` and `#8f8f8f`
  (5.5:1 and 4.8:1) on Windows and macOS, which read them from
  `_shared/core/ui/data/tooltip/constants.toml`; the Linux prediction
  tooltip draws neither line. The site's tooltip demo
  was fixed in the first pass.
- **Languages (WCAG 3.1.2).** Under the English Ergopti+ page, ten sections
  written only in French (hotstrings, AI, keyboard, metrics, trackpad,
  customization, Ergopti bonuses, the live typing demos) and five blocks
  of the installation page were read as English: they now say `lang="fr"`, their English example words
  `lang="en"`, and the interface languages' names their own language. Every
  literal `t()` key has an English entry (five words spelled alike).
- **Gates.** `tools/test/test-app-colour-contrast.cjs` (edge, finger hues,
  metrics text, both themes), `tools/test/test-ergopti-plus-languages.cjs`,
  a text-contrast rule in `test-tooltip-style-single-source.cjs`, and the
  undo walk in the axe gate (`exerciseUndo`).

## Native Ergopti+ UI (code audit, 2026-11-17)

A read of the three drivers, no screen reader yet. No native layer reads the
system's accessibility settings (Windows high contrast, animations or text
scale; macOS reduce motion, increase contrast or transparency; GNOME
`org.gnome.desktop.interface`) and none announces anything (no UI Automation
notification, NSAccessibility post or AT-SPI announcement); the WebView pages
follow `prefers-reduced-motion` and `forced-colors` through `theme.css`, but the
site's own settings (`a11y_prefs.js`) are kept in browser storage, which the
app's WebViews do not keep across restarts.

| OS      | Where                                                                                                   | Gap                                                                            | Fix                                                                 |
| ------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------- |
| Windows | `core/lifecycle/engine/lifecycle.ahk` `UpdateTrayIcon`                                                  | the tray tooltip is never set; paused is told by the icon only                 | set `A_IconTip` to « Ergopti+ » / « Ergopti+ (paused) », translated |
| Windows | `ai/ui/menu/actions.ahk` (three `TrayTip`)                                                              | title and body swapped, read in the wrong order                                | swap the arguments                                                  |
| Windows | `core/ui/ui/editors.ahk` (GPT link), `modules/updater/changelog.ahk` (channel), `infra/input_probe.ahk` | an Edit or drop-down without a label before it                                 | a Text label before the control                                     |
| Windows | `hotstrings/ui/hotstrings_config_window/hcw_helpers.ahk`                                                | four « ↺ » buttons read as a symbol; a colour swatch read as a progress bar    | a translated word; a Text control painted with its colour           |
| Windows | `core/ui/ui/tooltip/helpers.ahk`, `llm.ahk`                                                             | previews and predictions never announced; colours fixed, high contrast ignored | opt-in UIA notification; system colours when high contrast is on    |
| macOS   | `menu/ui/init.lua`                                                                                      | the menu-bar item is an image with no title or tooltip                         | done: tooltip « Ergopti+ » / « Ergopti+ (paused) », 21 locales      |
| macOS   | `menu/ui/builder/canvas_badge.lua`                                                                      | the first menu row is an untitled canvas image                                 | done: the pill's text is its tooltip                                |
| macOS   | `launcher/Sources/ErgoptiPlus/UpdatePromptPanel.swift`                                                  | unlabelled progress bar                                                        | done: named by its step, each new step announced                    |
| macOS   | `core/ui/ui/tooltip/renderer.lua`, `ui/wpm/wpm_widget.lua`                                              | `hs.canvas` is invisible to VoiceOver                                          | done: previews, spotlight, WPM bursts, banners spoken by VoiceOver  |
| Linux   | `tray/adapters/appindicator.lua`                                                                        | empty accessible description; paused told by the icon only                     | done: the icon's description, paused or not, 21 locales             |
| Linux   | `core/ui/ui/dialog_host.lua`                                                                            | caption not bound to its entry or list; empty window title fallback            | done: caption bound to its field; « Ergopti+ » as fallback          |
| Linux   | `core/ui/adapters/graphics_renderer.lua`, `wpm_surface.lua`, `spotlight_overlay.lua`                    | cairo-drawn, no text for AT-SPI                                                | done: previews, spotlight (Orca notification), WPM window named     |

Third pass on macOS and Linux (2026-11-17): the rows marked « done » above,
and the system settings the previews follow. macOS reads Reduce transparency
and Increase contrast (`hs.screen.accessibilitySettings`, at most once a
second) and draws the hotstring and AI previews opaque under either; while
VoiceOver runs, each new preview is spoken once through VoiceOver's own
AppleScript `output` (allowed in VoiceOver Utility), never otherwise. Linux
reads `screen-reader-enabled`, `high-contrast` and `enable-animations` with
background `gsettings` children every five seconds (never on the keystroke
path): high contrast makes the previews opaque and, with the screen reader on,
the preview window is an AT-SPI notification Orca speaks, a tooltip otherwise.
Announcements follow the screen reader's state, with no setting of their own
(decided on 2026-11-17, to review by the maintainer). The WPM widgets, the
spotlight overlay, the `hs.alert` banners and the GNOME text scale followed in
the fifth pass below; Reduce motion is read, but no native preview animates.

The screen-reader checks only a real machine can answer are in
TODO-tests-windows.md, TODO-tests-macos.md and TODO-tests-linux.md
(« Accessibility » items).

The Swift update panel's XCTest (`CatalogUpdateUserDriverTests`: the bar
named by its step, a reused bar following its new step, the panel opening
and closing) runs in CI: the macOS « Launcher XCTest and native probes »
cell of dev run 45568762252 (commit 915ec5e8, 2026-11-25 08:54 Paris time)
passed its 15 cases among 778.

### Windows fixes (third pass, 2026-11-17)

Every Windows row of the table above is fixed, with the tests
`tests/unit/platform/system/test_accessibility.ahk` and
`tests/meta/platform/system/test_accessibility_sources.ahk` (slug
`a11y-native-2026-11-17`); `platform/system/accessibility.ahk` holds the
native calls.

- **Tray.** `A_IconTip` says « Ergopti+ » or « Ergopti+ (paused) » in the
  active language (`tray/state_tip.ahk`, from `UpdateTrayIcon`); a pause taken
  while the navigation layer shows its name there becomes the text the layer
  restores. The three swapped `TrayTip` calls of the AI menu take the text
  first; a source guard refuses a title key as the first argument anywhere.
- **Names.** Labels before the Win + G link field, the Releases window's
  channel picker and the input check's field; the release notes and the four
  « ↺ » buttons are named through dynamic annotation (`IAccPropServices`,
  « Restore default: Delay (ms) »…); the colour swatch is a painted Text, no
  longer a progress bar at 100 %.
- **High contrast and text size.** The hotstring and AI tooltips read
  `SPI_GETHIGHCONTRAST` and `TextScaleFactor` at boot and on
  `WM_SETTINGCHANGE` / `WM_SYSCOLORCHANGE`: under a contrast theme every
  text, rule and border takes `COLOR_INFOTEXT` on `COLOR_INFOBK` with no tint
  wash, and « Make text bigger » scales their fonts. No native Windows surface
  animates, and WebView2 gives the pages `prefers-reduced-motion` and
  `forced-colors` from the same settings, so `SPI_GETCLIENTAREAANIMATION` is
  not read.
- **Announcements.** While `SPI_GETSCREENREADER` says a screen reader runs,
  a presented tooltip becomes a polite live region named by its previews (not
  the struck-through alternates) or by the selected line of a finished
  prediction, then raises `EVENT_OBJECT_LIVEREGIONCHANGED`; the same text is
  not repeated within 3 s. A UI Automation notification was tried first and
  refused: releasing the host provider of a driver window blocked the window's
  own thread, which is the keyboard driver's. No setting: the screen reader's
  running flag is the opt-in (decision pending in TODO.md).
- **Left.** Whether Narrator, NVDA and JAWS speak the live region is a
  TODO-tests-windows.md check; native windows other than the tooltips keep
  fixed font sizes at a larger text size (fixed in the fourth pass below).

## Fourth pass, Windows and shared UI (2026-11-18, Paris time)

A code pass on the Windows maintainer's PC with no live check: no key
injection, no native window opened on purpose, headless Chromium only. The
axe gate was already at 0 nodes (`site-accessibility-baseline.json` is
empty), so it had nothing left to lower.

### Native window text size and screen readers (Windows)

- **Text size.** « Make text bigger » (Settings > Accessibility > Text size,
  the `TextScaleFactor` the tooltips already read) reaches the system fonts
  only: a window that asks for a size by number keeps it. Every native window
  of the driver now sets its sizes through `Gui_SetFont`
  (`core/ui/engine/font_scale.ahk`), which multiplies each « sN » by the scale
  read when the window is built: 19 calls in 12 files (update prompt and
  check, Versions window, hotstring settings, action and app pickers, path
  dialogs, model browser fallback, prompt dialog, gestures help, apps editor
  dialog, delimiter prompt, the bundled App Cloner and Encryptor). The display
  scale needs nothing: AutoHotkey turns points into pixels with the screen's
  DPI. Each window file includes the helper itself, so a test child that loads
  one window file gets it. A source guard refuses a size given straight to
  `SetFont` outside the tooltips (scaled through their style globals) and the
  WPM pill (the canon's fixed geometry, shared with macOS and Linux). A window
  already open keeps its size until reopened; fixed widths may wrap or clip at
  225 % (a TODO-tests-windows.md check).
- **Fixed greys.** Three status lines (update prompt date, update check log
  line, hotstring settings status) were painted « Gray », 3.4:1 on the dialog
  face and blind to a contrast theme: they take the system text colour, and a
  guard refuses a fixed text colour in a native window outside the tooltips
  and the WPM pill.
- **WPM widget.** The pill and the graph were nameless painted windows. While
  `SPI_GETSCREENREADER` says a screen reader runs, the shown surface is named
  by the value it draws (« 72 WPM », unit in the active language), set only
  when the value changes; nothing is announced, the value changing every
  second.
- **Spotlight.** While a screen reader runs, the shortcut's circle window
  says « Mouse pointer highlighted » (`accessibility.spotlight_shown`, 21
  locales) through the same polite live region as the tooltips.
- **Note.** `SPI_GETSCREENREADER` was on on the maintainer's PC: some
  programs set it without a screen reader. These names and notices, and the
  tooltip previews of the third pass, then reach Windows' accessibility tree
  without anyone hearing them; the test children that prove timers and
  surfaces read the flag as off instead of trusting the host.

Tests (slugs `a11y-text-scale-2026-11-18`, `a11y-readers-2026-11-18`,
`a11y-cvd-2026-11-18`): `tests/unit/platform/system/test_accessibility.ahk`
(the scaling arithmetic, a real control's font at the system scale, the WPM
names and the Spotlight notice through injected seams) and
`tests/meta/platform/system/test_accessibility_sources.ahk` (the two source
guards).

### Colour vision review

Checked with the dataviz validator (OKLab, Machado 2009 CVD simulation) and
WCAG contrast ratios computed from the resolved `theme.css` tokens.

| Surface                        | Finding                                                                                                                                                                                                                                                                                             | Fix                                                                                                                                                                                                                                                                                                    |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Hotstring palette (14 colours) | As swatches it fails the categorical checks (yellow off the lightness band, cyan, brown and grey below the chroma floor, grey and brown ΔE 3.2 under protanopia, 5.3 in normal vision; yellow 1.4:1, orange 2.4:1, lime 2.9:1 on white). Every swatch has its name beside it in the picker.         | None needed for the picker: the name is the identity, the swatch a hint.                                                                                                                                                                                                                               |
| Tooltip tint of the palette    | The tint keeps the hue at a fixed lightness and saturation: the grey `#6e6e73` (a faint blue, chroma 0.02) became a navy `#05053d` panel, beside the indigo's `#050e3d`, so the default « personal » category looked like the indigo one. Text on every tint is 11:1 or more, labels 4.8:1 or more. | Below a chroma of 0.05 an accent is grey and keeps the neutral panel, in the three drivers (`tint.js`, `tint.lua`, `_TooltipMixTintHex`), with a `near_gray` contract vector. Every other palette hue keeps its tint.                                                                                  |
| Onboarding                     | Step dots told done, current and to come by hue alone (pale grey 1.4:1, green 2.0:1 on the page); hints `#888` 3.3:1; white on the system blue 4.0:1 (primary button); blue selected language, chosen answer and separators 3.5:1 to 4.0:1; a refused trigger character was only a red edge.        | Dots by shape (ring, filled dot, wider bar, edges 5.3:1 and more) and a progress bar « Step 3 of 8 » for screen readers; hints `#636366` 5.5:1; `--theme-accent-fill` and `--theme-accent` (5.1:1 to 5.8:1); a written refusal « Enter 1 to {1} visible characters. » with `aria-invalid`, 21 locales. |
| Download window                | Statistics and detail line `#888` 4.4:1; the Cancel button's red 4.1:1 on its own wash. Progress and kinds are said in words beside their colours; the bars hold 3.3:1 and more against their track.                                                                                                | `#999` 5.4:1; Cancel `#ff8e85` 6.2:1.                                                                                                                                                                                                                                                                  |

Open: the tooltip tints of the other palette hues sit at one lightness by
design (13 %), so a colour-blind reader tells categories apart by the
preview's text, not by its wash; a category shown in words in the tooltip
would be a design change for the maintainer. A concrete proposal (a short
category label beside the trigger label, one resolver with a contract vector
on the three drivers, its own preview switch) waits in `TODO.md` under
« Colour vision ».

### Error messages (WCAG 3.3.3)

A survey of the English locale found 479 error-like keys, about 155 of them
already saying what to do. Of the about 60 shown on Windows or in the shared
pages without a next step, 30 now end with one, in the 21 locales, chosen
from what the calling code allows: try again and read today's log (updater
tag, update check, download window, screenshot, agent action), close the
program holding the file (update settings, proxy setting, personal
hotstrings, unused keys, emulated layout), free space or a writable folder
(onboarding, editor saves, Studio data folder, metrics export), the
clipboard (colour copy, editor copy), browser storage (editor tabs, Compare
hand-off), reload or reopen (Comparer store and corpus, metrics, apps
dashboard, Versions window), reinstall (missing or broken
`constants.toml`), the connection (healthcheck network), the AI model and
key (translation, agent). Left without a remedy on purpose: the Optimiser's
corpus and worker refusals (it already offers « Try again »), labels, titles
and the other codes of `layout_editor.error.*`, which this pass did not
trace to a caller.

The second batch (2026-11-18) traced 33 more to their callers and gave each
the step it allows: the bundled apps (choose the program or the file again,
the password used to encrypt, a writable folder), the Windows gesture rows
(« Auto-configure » in the same menu, reopen the menu), the layout manager
(« Refresh », wait for the running operation, move the foreign file, the
connection, today's log), the model browser (« Install Ollama », « Install
MLX ») and the editor codes shown after an action (the use named in
parentheses, wait for the save, reload the page, a supported browser, the
log). `tools/test/test-error-messages-say-how-to-recover.cjs` pins the
English step of these 63 messages and refuses a locale that keeps the
English text, changes a placeholder or does not quote its own label. Left
without a remedy on purpose: the other `layout_editor.error.*` codes, which
state a validation rule (the fix is the rule itself), and the layout
manager's « No catalogue available », always followed by the cause that
names the remedy.

The third batch (2026-11-19) went through the 40 editor codes left. Eight
were failures after all and now end with their step: a refused compile (undo
the last change), a refused Windows elevation (install again and accept the
prompt), the catalogue and the Studio hand-off (reload or reopen), the layer
file (the place in parentheses), a `.keylayout` that does not read (save it
again in Ukelele), a file that is not a layout source (one the editor
saved) and a newer source version (update Ergopti+). The test now lists the
other 32 with a kind and a reason, and fails on any `layout_editor.error.*`
key that is neither: 22 validation rules (the field is in parentheses), 7
that give their step inside the sentence (the step quoted and checked), one
label (`generic`), one fragment shown only inside « Your saved tabs could not
be restored » and `studio_unreadable`, which suggests nothing on purpose
because moving the damaged file aside would lose the user's Studio data.

### Keyboard walk of the Studio (WCAG 2.1.2, 2.4.3, 2.4.7)

`tools/test/browser/studio-keyboard.playwright.cjs` serves `static/` as the
site does and walks the editor, the Comparer (folded, then with its details
and settings open) and the Optimiser with Tab alone, then back with
Shift+Tab: the focus must leave the page at both ends, never meet a stop
twice, go down the page, land on visible elements, and retrace its way;
`tools/test/test-keyboard-walk.cjs` proves the analysis refuses each of these
failures. The first run found a trap: the editor's « Try » field simulated
every key, Tab included, so the keyboard could enter it but not leave
(WCAG 2.1.2). Tab and Shift+Tab now move the focus on from it. The walks:
editor 216 stops, Comparer 76 (256 unfolded), Optimiser 64, each out at both
ends. No Studio page has a time limit (WCAG 2.2.1): the third pass's undo
offers stay until replaced.

### Keyboard walk of the native windows (Windows, WCAG 2.1.1, 2.1.2, 2.4.3)

`tests/unit/platform/system/test_native_keyboard_walk.ahk` opens 14 native
windows of the driver through their real openers (the AI profile prompt,
the gesture backend picker and manual setup window, the composer check
report, the ChatGPT link editor, the application picker, the native
fallbacks of the hotstring settings, paths editor, action picker and update
prompt, the keyboard slot picker, the new delimiter prompt, the bundled
apps' question and the Encryptor drop window), off screen and without
activation, and walks each with Tab and back with Shift+Tab
(`tests/support/native_keyboard_walk.ahk`). The keys are posted to the
focused control of the driver's own thread, so AutoHotkey's message loop
handles them as a real key and nothing reaches another program. Every
focusable control (one stop per radio group) must be reached, no control may
keep the focus, no stop is met twice and Shift+Tab retraces Tab; the first
three tests prove it refuses a WantTab trap and a control without a tab
stop. No window trapped the keyboard. The update prompt's release notes sit
in a WebView2 that Tab does not enter (« Open on GitHub » shows them); WebView2 hands the focus back to the next native control on its own
when Tab leaves its last element. Not walked: the magic key captures (their
input hook takes the next key by design and says Escape cancels), the
system MsgBox and InputBox, and the WebView2-only windows (walked in the
browser, next section).

## Fifth pass, the app's WebView windows (2026-11-18, Paris time)

`tools/test/browser/app-windows-accessibility.playwright.cjs`
(`npm run test:browser:app-accessibility`, its own step of Core / js) opens
the 21 windows Ergopti+ shows in its own WebView, at their
`apps.manifest.json` size, from a loopback server that serves `static/`. A
fake host takes the page's bridge messages and answers them with fixture
data (`app-windows-fixtures/`), so every list, chart and table is filled;
each window also has the states a user opens (forms, dialogs, tabs, failure
views, onboarding steps): 65 states in all. Each state is scanned by axe in
both colour schemes and walked with Tab and Shift+Tab, as the Studio walk
does, and each stop must show a focus indicator of its own (its look
focused differs from its look blurred). Axe nodes and walk problems are
counted against `app-windows-accessibility-baseline.json`;
`tools/test/test-app-windows-accessibility-ratchet.cjs` proves, without a
browser, that the ratchet refuses a new row, that every page under
`_shared/ui/` is audited or exempt for a stated reason (the Studio pages and
the Studio window, scanned by the site gates), and that each fixture posts to
its page's bridge. The pages post over WebView2's `chrome.webview` by
default; `--bridge=webkit` posts over `webkit.messageHandlers`, the macOS and
Linux bridge, and gives the same counts.

Before the fixes, scanned on the previous commit's pages with the same
fixtures: at least 390 nodes. After: 35, all in the layout manager, whose
files another change owned at the time. Per window: onboarding 87 → 0,
changelog 56 → 0, metrics_apps 36 → 0, hotstring_editor 33 → 0,
hotstrings_config_window 28 → 0, metrics_typing 27 or more → 0,
action_picker 24 → 0, paths_editor 20 → 0, numeric_prompt 12 → 0,
healthcheck 10 → 0, model_browser 10 → 0, prompt_editor 9 → 0,
token_prompt 2 → 0, update_check 1 → 0; error_dialog, config_cleanup,
download_window, release_notes, personal_info_editor and physical_shortcuts
had none.

- **Contrast (1.4.3).** Hints, notes, tags, dates and KPI colours; white text
  on light metrics cards; the onboarding accent under a dark system; white
  labels on light accents (now the accent fill token); the speed and accuracy
  gradients of the typing tables.
- **Links (1.4.1).** Release-note links are underlined at rest.
- **Names (1.3.1, 4.1.2).** Labels bound to their fields, rich editors named
  as text boxes, document titles, scrolling boxes focusable and named,
  dialogs with their role and name.
- **Keyboard (2.1.1).** The changelog's release rows, the action picker's
  headings and contents, the hotstring editor's folds, titles and deletes,
  the onboarding's language choice, the metrics' app names and categories are
  buttons now.
- **Focus (2.4.3, 2.4.7).** The dialogs of the hotstring editor and the
  metrics windows keep the focus inside (the rest of the page is inert),
  Escape closes them and the focus returns to the opener; the hotstring
  editor's trigger and output fields no longer take Tab (Shift+Tab was
  trapped there, Tab jumped to Save); the hotstring settings and the bulk
  move list lost their `outline: none`.

Proof by reverting: the gate run on the previous commit's `static/`
(`--root=<copy>`) shows every row above again, or stops on the state
assertion that covers a fix the scan cannot see (a release row selected from
the keyboard, a heading folded with Enter, the focus entering a dialog, one
tab read as pressed).

Host paths checked: the fixes are HTML, CSS and page script, with no new
`<link>` or `<script>` tag (the macOS builder inlines only its exact
`<link rel="stylesheet" href>` and `<script src>` forms) and no new inline
event handler (the Linux document policy refuses them on nonce pages); no
host script queries a selector or calls a function the fixes renamed.
`inert` and `Array.prototype.at` need WebView2 102, Safari 15.5 and
WebKitGTK 2.36 or later. Not exercised: the Linux `document_bridge`
admission handshake, which the fake host skips by calling the pages' entry
points.

Left: the layout manager's 35 contrast nodes; the hotstring editor's section
reordering is drag only (2.5.7); the metrics tooltips open on hover only
(1.4.13); the action picker's list is not a listbox, so the arrow-key
highlight is not announced; the typing metrics' trend arrows have no text;
the physical shortcuts page declares English whatever its strings; a few
untranslated labels (the hotstring editor's search, the action picker's
« Table of contents »).

## Fifth pass, macOS and Linux drawn surfaces (2026-11-18, Paris time)

A code pass with unit tests only; the spoken results are the « Accessibility »
items of TODO-tests-macos.md and TODO-tests-linux.md.

- **macOS mechanism.** Hammerspoon has no NSAccessibilityPostNotification:
  `hs.axuielement` reads and observes other applications' elements and posts
  nothing, and an `hs.canvas` or `hs.alert` window has no accessibility
  element to name. Every drawn surface therefore speaks through VoiceOver's
  AppleScript `output`, the route the previews already took
  (`core/ui/adapters/system_accessibility.lua`). `announce_event` says one
  user-caused event while VoiceOver runs, and leaves the previews' repeat
  suppression as it was.
- **macOS surfaces.** The spotlight (and a screen teleport) says « Mouse
  pointer highlighted » once it is fully up; the keep-awake on and off banners
  are said when they are really shown; the WPM widget, which a canvas cannot
  name as Windows names its window, says the burst's last speed once when it
  hides, never per refresh, not for a burst at zero, not on a stop or a pause.
- **Linux surfaces.** While `screen-reader-enabled` is on, the spotlight ring
  window is an AT-SPI notification named « Mouse pointer highlighted », which
  Orca speaks when it is mapped (the crosses say nothing), and the WPM window
  is named by the speed it draws, renamed only when it changes, with nothing
  spoken, as on Windows. Off, neither window is touched. The settings reading
  starts with the first drawn surface that binds GTK, not only the preview.
- **GNOME text scale.** `org.gnome.desktop.interface text-scaling-factor` is
  read with the other settings (background `gsettings`, 0.5 to 3): GTK
  applies it to its own widgets and the dialogs, and the cairo previews, which
  set their Pango sizes themselves, now multiply every font size by it, as the
  Windows tooltips follow « Make text bigger ». The WPM pill keeps the canon's
  fixed geometry on every OS.

Tests (slugs `a11y-macos-event`, `a11y-macos-spotlight`, `a11y-macos-alert`,
`a11y-macos-wpm`, `a11y-linux-drawn`, `a11y-linux-text-scale`): macOS
`tests/unit/core/ui/test_system_accessibility.lua`,
`tests/unit/modules/shortcuts/system_actions/test_system_mouse_pause_ownership.lua`,
`test_keep_awake.lua`, `tests/unit/ui/wpm/test_wpm_widget_voiceover.lua`;
Linux `tests/unit/core/ui/test_system_accessibility.lua` and
`test_drawn_surfaces_for_atspi.lua`.

## Sixth pass, reading and languages of the site (2026-11-19, Paris time)

The TODO items « Dyslexia and reading » and « Languages », on the site only
(`src/`); the Studio pages framed by the site keep their own gates.

### Reading (WCAG 1.4.8, 1.4.10, 1.4.12)

`tools/test/browser/site-reading.cjs` measures each page of the site's own
document, in three reading modes, inside the axe gate
(`site-accessibility.playwright.cjs`, `--reading-only` to run it alone):

- **zoom**: a 200 % browser zoom of the scan's 1440 × 900 window (720 × 450
  CSS pixels, device scale 2) with the WCAG 1.4.12 user style sheet (line
  height 1.5, paragraph spacing 2 em, letter spacing 0.12 em, word spacing
  0.16 em);
- **text**: the site's own reading settings at their largest, 200 % text and
  wide spacing, in the full window;
- **default**: an unchanged visit.

Checks: `text-clipped`, a text line outside the padding box of an ancestor
that hides its overflow (up to the first one that scrolls);
`text-overlap`, two text lines of different elements sharing at least a
quarter of the shorter one's height, each cut to what its scrolling
ancestors show (rotated text, the corner banner, is left out: its client
rects are its upright bounding box); `justified-text`, a block laid out
justified; `line-length`, a paragraph, list item or quote of 120 characters
or more with a line of more than 80 characters (counted per laid-out line).
Elements are counted per page, mode and check in
`site-reading-baseline.json`, ratcheted like the axe rows;
`test-site-accessibility-ratchet.cjs` checks the modes' values and the
baseline's rows without a browser, and refuses `text-align: justify` in the
sources.

| Mode and check          | Before | After |
| ----------------------- | -----: | ----: |
| default, justified text |    406 |     0 |
| default, line length    |    255 |     0 |
| zoom, justified text    |    406 |     0 |
| zoom, clipped text      |      6 |     0 |
| zoom, overlapping text  |      2 |     0 |
| text, justified text    |    406 |     0 |
| text, clipped text      |     29 |     0 |
| text, overlapping text  |     42 |     0 |
| **Total**               |   1552 |     0 |

« Before » is the base commit measured with the final checks; the first run
of the checks, before they cut lines to their scrolling boxes, counted 195
overlaps in the text mode, most of them a scrolled table's hidden rows.

What changed, at the root:

- **No justified text.** `typography.css` justified every paragraph and list
  above 600 px; prose now starts at the line's start. Its line height is
  unitless (1.5, not 1.5em), so a larger child gets its own height.
- **Line length.** The article pages' prose column is `58ch` wide and
  centred (`bloc-main main`), the Ergopti+ pages' paragraphs `55ch` (their
  font is narrower), and the components that set a wider `max-width` in
  pixels cap it at `55ch` too; the home and overview introductions likewise.
  70ch measured 84 to 91 characters per line. A block holding a keyboard
  drawing keeps the full width (`:not(:has(keyboard))`): the drawing is
  sized on the window and lost its last keys in a narrowed list.
- **Header.** It was `position: fixed` at `height: var(--header-height)` over
  a spacer of that height: at 200 % text its title wrapped out of the box,
  above the window and over the page. It is now sticky in the page's flow
  with that height as a minimum, a direct child of the page so it holds down
  to the footer, and the narrow-screen menu opens under it whatever its
  height.
- **Skip link.** Hidden at `top: -100px`, it hung over the header once taller
  than 100 px; it now moves up by its own height (`translateY(-100%)`).
- **Banner.** Its subtitle was pulled over its title by a negative margin;
  the two lines now stack in the flow.
- **Cards and grids.** The home products, the overview pages of Ergopti and
  Ergopti+, and the Ergopti+ tap-hold, navigation and power grids had fixed
  column counts or pixel minimums: they now fit as many columns as cards of
  at least a few rem, so larger text gives fewer columns instead of cut or
  overlapping names. Fixed pixel sizes became minimums (the WPM pill, the
  delegation bar, a glyph column), and the provider families and window
  titles wrap instead of ending in an ellipsis.
- **Code blocks** wrap their long lines (`white-space: break-spaces`): the
  article column hides what passes its edge.

Not measured: a plain-language review of the texts (only « trigger »,
« output » and « tracking » were replaced by French words), the table of
contents, which is
sticky at `--header-height` and slides under a header grown taller at 200 %
text, and the Studio frames. The seventh pass did the first two.

### Languages (WCAG 3.1.2)

`tools/test/test-site-languages.cjs` lists, in the markup of every Svelte
file under `src/`, the French text runs holding words at least 20 times more
frequent in English than in French subtitles (the tracked OpenSubtitles 2018
lists of `static/corpus/frequency/`), outside an element that declares a
language, code (`code`, `pre`, `samp`), addresses and identifiers. The
detector found 25 such words on 20 files; each was reviewed by hand:

- **Marked `lang="en"`:** the quoted terms « Same Finger Bigram(s) », « 1u
  Distance From Home » and « rolls », the example words (people, does, don't,
  won't, can't, TYPEWRITER, YOU, the OLD/COULD, AND, -ING, -OUGHT, ALLOW…,
  TWO/WOMAN… lists), « features », « Data Scientists », the « ● live » badge
  of the window frames, and the model catalog's provider labels (English data,
  « Other models » among them).
- **Reworded in French:** « un trigger connu » became « une abréviation
  connue », « les output » « les sorties », « pas de tracking » « pas de
  pistage » (twice, with its English key), and « La license MIT » « La
  licence MIT ».
- **Accepted without `lang`** (`ACCEPTED_TERMS`): the technical terms,
  key names and product or mode names WCAG 3.1.2 exempts (tap-hold, driver,
  layer, layout, bundle, Shift, Enter, Home, Windows, Sway, XKB Symbols, the
  Legacy method, Batch Avancé…), and four French words spelled like English
  ones (office, relatives, natives, replace).

The French site's header, footer, skip link and banner say `lang="fr"`: the
Ergopti+ pages read in English set `lang="en"` on the document, under which
the whole chrome was read as English. The test pins the 17 English passages,
the 6 French chrome texts and the provider label's attribute, refuses a new
English word without `lang` (ratchet `site-foreign-passages-baseline.json`,
empty) and asks to lower the baseline when one goes. Text built by
expressions (`{…}`) is out of its reach: the same detector run over the
built pages' HTML found « tracking » twice (reworded) and otherwise only
names (the model families, « Window Spy », the menu's « Dossier Logs »,
Slack) and a list of letter groups.

The accessibility statement and the settings dialog were kept French by this
pass; the maintainer had them translated through the Ergopti+ `t()` dictionary
on 2026-11-21 (`docs/memory/maintainer-decisions.md`, « The site reads in
English where Ergopti+ does »).

### Gates and host

`node tools/test/test-site-languages.cjs`,
`node tools/test/test-site-accessibility-ratchet.cjs`, and the browser gate
(`npx vite build`, then
`node tools/test/browser/site-accessibility.playwright.cjs build ""`). Each
fails on the base commit: the languages test on the 25 unmarked words, the
ratchet contract on `typography.css`'s justification, the reading gate on
its 1552 elements. On the Windows host of this pass the axe rows matched
the base (6 rows, all in Studio frames, the same counts), and the Comparer's
« fits a phone » check failed on the base as well as after the pass (its
compact tabs measure 327 px in a 320 px window with this host's fonts).

## Seventh pass, header offset, media and plain language (2026-11-19, Paris time)

The three items the sixth pass left on the site (`src/`): the sticky table
of contents, « Images and media », and a plain-language review.

### Nothing under the sticky header (WCAG 1.4.10, 1.4.12)

The header is sticky with `--header-height` as a minimum and grows with the
text. The boxes placed under it read that minimum: the sidebar table of
contents (`layout.css`), the narrow-screen banner (`banner.css`), the
keyboard reference (`+layout.svelte`), the anchored headings
(`scroll-padding-top`) and the narrow-screen menu. The header now measures
itself (a `ResizeObserver` in `Header.svelte`) and publishes its height as
`--header-offset`, which all of them read; the sidebar's `max-height` also
lost a missing space that made its `calc()` invalid.

The reading gate gained a `header-cover` check in the zoom and text modes:
each box positioned sticky or fixed at a nonzero `top` (so meant to sit
under the header) is measured where it starts to stick, the window scrolled
to the top of its parent, and must not start above the header's bottom edge
(a box pushed up by the end of its parent scrolls away, as it should).
`test-site-accessibility-ratchet.cjs` refuses `var(--header-height)` outside
the header itself.

| Mode and check     | Before | After |
| ------------------ | -----: | ----: |
| text, header cover |      6 |     0 |
| zoom, header cover |     20 |     0 |

Before, the table of contents started 71 px under the header at 200 % text
on the six pages that have one, and the dev banner 8 px under it at 200 %
zoom on the 20 pages scanned at that width. Left: the Studio shell
(`src/routes/studio/+layout.svelte`) still subtracts `--header-height` from
the window height; it was being changed elsewhere, so the ratchet lists it
as pending and it should read `--header-offset`.

### Images and media (WCAG 1.2.1 to 1.2.3)

The site has no `<video>` and no embedded player. Its demos (the Ergopti+
hero, the live session, the WPM widget) are animated text in the page, so
their words are in the DOM, and the hero has a pause button. The GIFs under
`static/media/ergopti_plus/` are shown only by the repository README on
GitHub, not by the site; the promo video under `video/` is not published
on it. Nothing needed captions. `tools/test/test-site-video-captions.cjs`
guards the next video: each `<video>` under `src/` holds a default
`<track kind="captions">` whose WebVTT file exists under `static/`, and each
video or embedded player is tied to a transcript (`aria-describedby`, or a
link marked `data-transcript-for`). Its self-test proves it refuses each
missing part.

### Plain language (WCAG 3.1.5)

Sentences of 30 words or more were listed on the main pages and edited,
not rewritten, one commit per page group: the layout presentation (10
sentences), the Linux installation (5, and a typo), the Ergopti+ overview
and presentation (« hotstrings » and « tap-holds » glossed as « expansions
de texte » and « touches à double fonction », « driver » and « layout »
replaced by « logiciel » and « disposition », « snippets de boilerplate »
dropped; the English dictionary follows), the home card of Ergopti+ and
the accessibility statement. The diffs are the evidence. The longer hero
subtitle then made an 86-character line in its 600 px box: the box is now
`min(600px, 55ch)` like the other Ergopti+ paragraphs. Left: the layout
use, information and benchmark pages and the other Ergopti+ pages.

### Gates and host

`node tools/test/test-site-accessibility-ratchet.cjs`,
`node tools/test/test-site-video-captions.cjs`,
`node tools/test/test-site-languages.cjs`,
`node tools/test/test-ergopti-plus-languages.cjs`, and the reading gate
(`node tools/test/browser/site-accessibility.playwright.cjs build ""
--reading-only`) on a fresh build: 0 reading elements, and the 26 above on
the base build. The full gate stops on the Comparer's « fits a phone »
check, on the base build as well, as in the sixth pass. `npm run test:js`
and `verify-change` refuse this host (Node 22.16, pinned 22.22.2).

## Eighth pass, reflow on a phone (2026-11-19, Paris time)

### No sideways scroll at 320 and 375 px (WCAG 1.4.10)

With the site's 200 % text on a 320 px phone every page was 390 px wide
(392 at 375 px): the header did not wrap and its title, a flex item, could
not shrink below its longest word, so the accessibility button and the
menu icon sat past the window's edge. The header now wraps: the title
takes the first row, the two controls a second one, right aligned, still
in the tab order and at 40 and 48 px (WCAG 2.5.8). Its tagline is a block
rather than a paragraph, so the wide spacing's 2 em under paragraphs no
longer makes it taller (258 px at 320 px, 269 before). The dev and release
banner's two lines became block labels for the same reason: under the
WCAG 1.4.12 spacing they spilled out of the banner's fixed height, under
the header.

Once the header fitted, four pages still scrolled sideways, each fixed at
its cause: a page-title word wider than the window (headings break such a
word), a phrase kept on one line (`.nowrap` wraps under 480 px), the
gradient name's half-em side padding when it ended a line (its gradient
keeps its stretch through its background size), and the legacy Ergopti+
cards, whose implicit grid track was as wide as their longest word.

The reading gate (`site-reading.cjs`) gained four phone modes, `text-320`,
`text-375` (the site's largest text settings) and `zoom-320`, `zoom-375`
(a 200 % zoom of a window twice as wide), with a `reflow` check: when the
page's scroll width passes the window's, the outermost boxes ending past
its right edge outside a box that scrolls or clips them sideways, or the
scroll width alone (a text node, a pseudo-element). Rows are ratcheted
with the other reading rows, and the baseline stays empty.

| Mode and check   | Before | After |
| ---------------- | -----: | ----: |
| text-320, reflow |     42 |     0 |
| text-375, reflow |     22 |     0 |
| zoom-375, reflow |      1 |     0 |

Before, on the base build with the gate added: 38 rows, every page
measured at both text widths (the header's two controls), and the four
pages above.
The Studio pages are left out of `text-320` by name (`PENDING_ROUTES`):
the Studio shell (`src/routes/studio/+layout.svelte`, changed elsewhere)
is at least 480 px tall under the header and its menu bar alone takes
about 500 px there, so the workspace is 0 px tall and the page never
shows. Fixed afterwards (2026-11-19, Paris time): below 24 em of its own
text the shell folds its tabs and « Apparence » into a menu button named
after the current tab, the open menu laid over the workspace, and the row
is removed. At 320 × 640 px with 200 % text the bar went from 503 to 83 px
and the workspace from 0 to 397 px; `exerciseStudioBar` in
`site-accessibility.playwright.cjs` opens that menu on every tab and
requires the workspace to outgrow the bar.

Gates: `node tools/test/test-site-accessibility-ratchet.cjs` and
`node tools/test/browser/site-accessibility.playwright.cjs build ""
--reading-only` on a fresh build (0 reading elements), format and
convention lints. `npm run test:js` and `verify-change` refuse this host
(Node 22.16, pinned 22.22.2).

## Eighth pass, outline, tables and error steps (2026-11-19, Paris time)

### Headings and landmarks (WCAG 1.3.1, 2.4.1, 2.4.6)

`tools/test/lib/heading-landmarks.cjs` reads a page as a screen reader moves
through it (hidden, unrendered and inert parts left out; inside an open
modal dialog, the dialog alone) and asks for one h1, no skipped level, one
main landmark, and a name on every navigation, region, complementary,
search and form landmark, never two of one kind under one name.
`tools/test/test-heading-landmarks.cjs` proves each refusal without a
browser. The Studio keyboard walk now fails on any of them: the editor had
no h1 and two unnamed complementary landmarks (the inspector column and the
magnifier inside it); it has a visually hidden h1 « Layout editor », the
column is « Key properties » and the magnifier a region named by its
heading. The app windows' scan counts them under `heading-landmarks` in its
ratchet. Its first run found problems in 50 states of 17 windows (a few of them open modal dialogs, which it now reads alone); the windows
now have one main each (a `main` element or `role="main"` on the existing
container, so no layout changes), an h1 (the visible title, or a visually
hidden one, `.theme-sr-only` in `theme.css`, where the title bar is the
title), release notes read from level 2 under it (`renderMarkdownInto`
`topLevel`, through `aria-level`, so the look stays) and the typing
dashboard's scrolling tables named once their card's heading is
translated. Left in the baseline: the apps dashboard's three chart tabs,
whose h3 chart titles follow the h1 while their h2 cards sit on another tab.

### The Optimiser's result as a table (WCAG 1.1.1, 1.3.1)

Under the two boards, « Show both layouts as a table » unfolds a focusable
region with a row per drawn key in reading order: its place (« row 2,
key 3 »), what it types on the start and the best layout (a dead key and
Space in words), and « Changed » or « Unchanged », with a glyph and a
dashed edge as the boards outline it. `exerciseResultTable` in
`layout-optimizer.playwright.cjs` checks it against both boards.

## Ninth pass, semantic markup, keyboard operability and reading choices (2026-11-19, Paris time)

Maintainer requests of 2026-11-19: no div or span where an element has the
meaning, blocking gates, and everything operable from the keyboard on the site
and in the WebView windows.

- **Semantic markup.** The site's Svelte files held 576 div and span
  elements (255 div, 321 span, counted by the compiler's parser); 451 are
  left (163 div, 288 span, three of them from the Studio shell's new menu),
  each justified. Cards and lists became ul / li
  (with article where a card stands alone), label and value pairs dl, steps
  of a page section with a heading, page tops header, captions figure /
  figcaption, the contact box address, the installation links a named nav,
  the filter row search, the corner banner a named aside, the footer links a
  named nav. What stays is listed in
  `tools/test/site-semantic-html-allowlist.json`, one entry per file and
  element (first class, id or none) with its exact count, a kind (layout,
  styling-hook, icon-layer, decorative, mount, aria-widget, dl-group,
  language) and a reason. Pixel screenshots of every page at 320 px and
  1280 px, light and dark, before and after: identical except the regions
  that differ between two runs of the same build (the framed Comparer, whose
  results and height settle at different times).
- **Gates.** `tools/test/test-site-semantic-html.cjs` (shared judgement
  `tools/test/lib/semantic-markup.cjs`, Svelte reader
  `tools/test/lib/svelte-markup.cjs`) fails on an unlisted div or span, on a
  count above or below its entry, on any interactive div or span (handler,
  interactive role, tabindex other than -1), on any Svelte a11y warning and
  on an unlisted svelte-ignore. `tools/test/test-site-image-alternatives.cjs`
  fails on an img without alt, an svg neither hidden nor a named image, and an
  icon-font glyph neither hidden nor named. On the code before this pass they
  report 2 interactive div, 3 Svelte a11y warnings and 55 unnamed icons.
- **Keyboard operability.** `tools/test/lib/keyboard-operability.cjs`
  records every pointer and key listener before the page's scripts and fails
  on a shown element the mouse can use that Tab cannot reach, that has no
  interactive role or that no key answers; it drives every disclosure (Enter
  opens and closes), popup (Escape closes and gives the focus back) and
  composite widget (arrow keys move the focus). The site runner
  `tools/test/browser/keyboard-operability.playwright.cjs` (CI, on the
  received site, after the axe gate) also walks each page with Tab and
  Shift+Tab, refusing a stop without a visible indicator (2.4.7) or hidden
  under another box (2.4.11). The app windows gate counts the same problems
  under the rule `keyboard-operability` of its ratchet: 673 nodes on
  2026-11-19 (sortable table headers and chart canvases of the metrics
  windows, the action picker's rows, the hotstring editor's command
  references and drag handles, the category titles of the hotstring settings),
  a higher count fails.
- **Fixes.** The narrow-screen menu is a button with `aria-expanded` that
  Escape closes (it was a checkbox, focusable but invisible on a wide
  screen); the table of contents' click catcher is no longer a div with a
  handler; the reference keyboard's button says whether it is open and Escape
  closes it; the SFB definition, shown on hover only and hidden from screen
  readers, is a toggletip (a button described by a role="tooltip", shown on
  focus, Escape hides it); the keyboard drawings' toggle buttons no longer
  hold a p; the Ergopti+ metrics tabs follow the tabs pattern (arrows, Home,
  End); each drawn key says its finger (`aria-description`), which only its
  colour told (1.4.1).
- **Reading choices.** The settings dialog adds OpenDyslexic (SIL OFL 1.1,
  `static/fonts/opendyslexic/`, served by the site), shorter lines (50
  characters), all text aligned to the start, and colours for colour-blind
  readers (Okabe-Ito finger colours and a one-hue frequency map on the
  keyboard drawings, blue instead of green in the AI demo, blue and orange
  status text in the Studio, 5.5:1 and more). All apply before the first
  paint through `a11y_prefs.js`.

## Tenth pass, semantic markup and keyboard operability of the app windows (2026-11-19, Paris time)

The maintainer asked for windows with no non-semantic tag (« no span or div
if possible »), for blocking tests, and for everything to work from the
keyboard alone. Scope: the 20 app windows outside the Studio and the shared
helpers they load.

### Gates (all blocking)

- **`tools/test/test-app-windows-semantic-markup.cjs`** (`npm run
test:app-windows-semantic-markup`, shared-ui suite). Static, so it reads
  every branch of the scripts: each `<div`/`<span` in HTML, strings and
  templates, each `createElement('div')` and `el('span')` call. Every one must
  be claimed by an entry of the window's list,
  `tools/test/app-windows-semantic-markup/<window>.json`: the part of its
  opening tag that finds it, its exact count and the reason no element
  carries its meaning (« layout » or « wrapper » alone refused). A new div needs its own reason, a removed one lowers its count in
  the same change. Refused whatever the list says: a div or span with an
  interactive role or a pointer handler (in its tag, or a listener added to
  the created element), an img without alt, an svg neither hidden nor named
  as an image. Its source scanner (HTML and the scripts that build DOM) is
  a section of the shared `tools/test/lib/semantic-markup.cjs`, beside the
  site's Svelte judgement.
- **The app windows scan** (`app-windows-accessibility.playwright.cjs`)
  counts, besides the shared `keyboard-operability` rule of the ninth pass,
  two rules of its own (`tools/test/lib/app-window-checks.cjs`) per state,
  in the same ratchet: `keyboard-operable`
  (an element with a click or hover listener, recorded before the page's
  scripts run, that the keyboard cannot reach; a control role without focus;
  a tab list, list box, menu, grid, tree or radio group whose arrow key moves
  neither the focus nor the active descendant; an open modal dialog that
  Escape leaves open) and `text-alternatives` (an image, drawing or chart
  canvas neither named nor hidden). A self check proves each detection on a
  small page before any window is read (`--self-check` runs it alone).

### Results

The first run of the two rules counted 506 nodes (action picker 42,
hotstring editor 8, hotstring settings 2, apps dashboard 64, typing
dashboard 390), and the shared `keyboard-operability` rule held 673. After:
none; the baseline keeps only the layout manager's contrast rows (a Studio
page). The last ones were the chart canvases (a shared Chart.js plugin,
`metrics_chart_values.js`, now writes next to each chart a disclosure of
the values its tooltips show, in the tooltips' own words, out of sight
until the focus enters it, and names it as the canvas's keyboard
equivalent), the model browser's sortable header cells (buttons now), and
two readings of the shared judgement: the options a combobox drives through
`aria-activedescendant` and the rich editors, which Tab reaches although
Chromium reports `tabIndex -1` for them. div and span, before → after (each one left
is listed with its reason):

| Window                   | Before | After |
| ------------------------ | -----: | ----: |
| metrics_typing           |    542 |   207 |
| metrics_apps             |    277 |    22 |
| hotstring_editor         |    101 |    27 |
| changelog                |     35 |     1 |
| model_browser            |     34 |     0 |
| hotstrings_config_window |     27 |     0 |
| download_window          |     26 |     3 |
| onboarding               |     22 |    11 |
| action_picker            |     22 |     0 |
| prompt_editor            |     15 |     2 |
| paths_editor             |     13 |     0 |
| healthcheck              |     11 |     0 |
| numeric_prompt           |      6 |     0 |
| token_prompt             |      6 |     1 |
| config_cleanup           |      5 |     1 |
| update_check             |      3 |     0 |
| personal_info_editor     |      3 |     0 |
| physical_shortcuts       |      3 |     0 |
| error_dialog             |      1 |     1 |
| release_notes            |      0 |     0 |
| shared helpers           |      7 |     0 |
| **Total**                |   1162 |   276 |

What stays: the boxes Chart.js needs to size a canvas, horizontal scroll
boxes, grid rows and cells with no element of their own, the rich text
editors (a contenteditable box named as a text box), dialog backdrops,
`div` groups inside a `dl`, and label text whose style follows the checked
state of its input.

- **Apps dashboard outline.** The five tabs are a tab list (roving tab
  stop, arrows, Home, End); each tab's blocks sit in their own tab panel
  named by the tab, under a hidden h2, with h3 card and chart titles. Its
  three heading rows left the baseline. The overview's two charts showed on
  every tab (an inline `display: flex` beat the hiding rule); they no longer
  do.
- **Keyboard.** Tooltips of both dashboards open on focus too, stay while
  hovered and close with Escape (1.4.13); the typing dashboard's 19 table
  tabs are one tab list and every sortable header is a button; the hotstring
  editor's sections move with the arrow keys on their handle, the focus
  follows and a status says the new place (2.5.7); the action picker's
  search is a combobox over list boxes, so the highlight is announced; the
  prompt editor's and hotstring editor's suggestions are list boxes; the
  changelog's releases are buttons the arrows move through; folds are native
  buttons.
- **Text alternatives.** Chart canvases and svgs are named images (their
  title and largest entries); the typing trend arrows say rising, falling or
  stable; flags and glyphs are hidden.
- **Semantics.** Headers, footers, mains, named sections and searches,
  fieldsets with legends, lists, description lists, `progress`, `output`,
  `time`, `kbd`, `samp`, `data`, `mark`, `bdi` where they fit.

Proof by reverting: the semantic gate on the old pages refuses every pending
element (the apps dashboard's old `index.html` alone gives 314 lines); the
browser scan with `--root=` on the old tree fails on the new fixture states
(a tab read as selected, the keyboard section move, the card tooltip on
focus, the announced picker highlight, the arrows of the release list).

### Reading preferences in the app windows

Every app window loads `a11y_prefs.js` first in its head. A host may seed
`window.__ergopti_reading` (the same names and values as the site's
preferences: `font`, `spacing`, `motion`, `text`, `contrast`) next to
`window._i18n_locale`; the seed wins over storage and is sanitized
(`test-site-accessibility-ratchet.cjs`). theme.css then applies the
hyperlegible font stack, the WCAG 1.4.12 spacing and reduced motion. Until
the eleventh pass (« Reading preferences in the app windows, done »), no
driver wrote the seed: there was no setting for it in
`_shared/settings/data/features/manifest.toml` (its `[sections.ui]` is
macOS only). What each host needs:

- **Windows (WebView2).** The seed goes in `Seed` beside `_i18n_locale`
  (`windows/core/ui/engine/webview/utils.ahk`, about line 622). The system's
  « Show animations » setting already reaches `prefers-reduced-motion`.
  The font: the page is served from the `_shared` virtual host, so a copy of
  the woff2 files under `_shared/ui/fonts/` would load by URL;
  `static/fonts/` is not in `windows_bundle_manifest.json`.
- **macOS (hs.webview).** The page is an inline string without a base URL
  (`macos/core/ui/ui/builder.lua`): the seed joins `i18n_boot`, and the
  HTML cache key must include the preference. A font file cannot load by
  URL there; it must be inlined as a `data:` URL, or the page loaded with a
  base URL. Reduce Motion reaching WKWebView is not verified here.
- **Linux (WebKitGTK).** The seed joins the boot script in
  `webkit_host.lua` (`build_i18n_boot_script` pattern, JSON encoded, before
  the CSP pass that adds the nonce); a file:// fetch is refused, the policy
  allows `font-src data:`, so the font is a `data:` URL too.
- **All.** The font is outside every package today (`static/fonts/`); the
  physical shortcuts page does not load theme.css, so the seed has no style
  to apply there.

## Tenth pass, the Studio's markup and keyboard (2026-11-19, Paris time)

The same requests on the Studio pages under `static/ergopti_plus/_shared/ui/`
(the Comparer and its panels, the editor and its app window, the Optimiser,
the layout manager, the composer and the layer editor), counted in their HTML
and in the DOM their scripts build.

| Folder                 | div and span before |   After | Interactive before |
| ---------------------- | ------------------: | ------: | -----------------: |
| `layout_analysis`      |                 263 |      76 |                 16 |
| `layout_editor`        |                  76 |      22 |                  2 |
| `layout_editor_window` |                   5 |       0 |                  0 |
| `layout_optimizer`     |                  82 |      45 |                  0 |
| `layout_manager`       |                  18 |       0 |                  0 |
| **Total**              |             **444** | **143** |             **18** |

« Interactive » counts the divs and spans the shared judgement refuses
outright (a pointer handler, an interactive or computed role, a tabindex):
the Comparer's chart rows played buttons, its tables' scroll boxes and heat
keys took the focus. In the rendered pages the Comparer went from 376 div and
3074 span to 41 and 984, the editor from 102 and 287 to 75 and 358 (the
analysis panel's table cells), the Optimiser from 44 and 22 to 30 and 0.

- **Markup.** Sections with their heading, header and footer, lists, dl
  tiles, native tables for every bar figure (their rows laid out as grids,
  their roles kept for WebKit), fieldset and legend, output for live values,
  data for shares, kbd for keys, b, small and strong for inline text, a
  `<dialog>` for the editor's question and the « i » popover, `main` for the
  layout manager. Every UA style a new tag adds is reset by class, and
  screenshots in light and dark at 320 and 1280 px match before and after
  (run-time text and timings aside).
- **Keyboard.** The Comparer's chart rows and table rows open a layout from
  a native name button; its tabs, the editor's tool, layer and document tabs
  and the Optimiser's tabs follow the tabs pattern (one stop, arrows, Home,
  End); the editor's board, the fingering map and the Optimiser's boards are
  toolbars of key buttons walked with the arrows, a key swapped without a
  drag (2.5.7); the « i » popovers open with Enter inside a row, close with
  Escape and give the focus back even after the panel redraws; renders keep
  the focus on the same control.
- **Reading.** The app's Studio window and the layout manager now load
  `a11y_prefs.js` after the theme, as the site's Studio pages did, so the
  hyperlegible font, the larger text, the wider spacing and reduced motion
  reach them. The layout manager's muted text, links and filled buttons
  reach AA in both themes (35 axe nodes, removed from the app windows
  baseline).
- **Gates.** `tools/test/test-studio-semantic-html.cjs` is the Studio scope
  of the shared judgement (`lib/semantic-markup.cjs`), with its reader
  `lib/studio-markup.cjs` (HTML, template strings and builder calls,
  followed through their variable) and `studio-semantic-html-allowlist.json`
  (97 entries, 143 elements, each with its kind and reason).
  `tools/test/browser/studio-keyboard.playwright.cjs` now opens every tab of
  each page's main tab list (the Comparer's on a link naming four layouts, a
  fresh visit ranking some 650 rows) and on each runs the shared operability
  judgement and widget driver, a focus indicator at every stop, the rendered
  images check (`lib/page-images.cjs`) and its tab lists' single stop, Home
  and End. `tools/test/test-studio-reading-preferences.cjs` requires the
  preferences script on the five Studio pages.
- **Proof by revert.** On the pages before this pass the semantic gate finds
  444 unjustified elements, 18 of them interactive; the keyboard gate's
  report lists the chart rows answering to the pointer only, the editor's
  nine-stop tool tabs, the Optimiser's End key and the « i » popovers'
  focus return; the reading check fails on the Studio window.

Left: the Comparer's ranking table on a fresh visit offers some 11,000 Tab
stops (650 rows of percentile chips), one grid stop with arrow keys would
fit it; the heat board's keys are images read in their table, no longer
stops; the editor's « + level » buttons sit inside its levels tab list; the
board's arrow keys have no visible hint (a new string in 21 locales); the
fingering map's scroll box is a stop of its own beside the map.

## Eleventh pass, reading in the frames, plain language and help text (2026-11-20, Paris time)

### The Studio frames in the reading gate (WCAG 1.4.8, 1.4.10, 1.4.12)

The reading gate (`site-reading.cjs`, run by
`site-accessibility.playwright.cjs`) now measures every same-origin frame of
a page as well as the page: the Comparer, the editor and the Optimiser of
the Studio pages and the benchmarks, the model browser of the AI page and
the release notes of the configuration page. A frame reads the same stored
settings (it loads `a11y_prefs.js`) and gets the same style sheet; it has
no site header, so « header-cover » is left to the page. Rows are counted
per page, mode, frame and check (`route | mode | frame | check`); the
baseline stays empty.

The clip check compared a box's client size, in the box's own CSS pixels,
with text rectangles in the window's. The shared theme's larger text zooms
the body (`theme.css`), so in a frame every text past half a box read as
cut; the box is now scaled by its rectangle over its own size.

| Frame, before the fixes                    | Rows |
| ------------------------------------------ | ---: |
| layout_editor, text-clipped (zoom, text)   |   81 |
| layout_editor, reflow (text-320, text-375) |   49 |
| layout_optimizer, reflow                   |   25 |
| layout_optimizer, line-length              |    4 |
| layout_editor, line-length                 |    2 |
| layout_analysis, Studio Comparer           |    4 |
| layout_analysis, benchmarks page           |   59 |
| model_browser, text-clipped and overlap    |  268 |
| changelog, text-clipped                    |    1 |

The Studio page counts come from the base build with the frames measured
and the old clip box; the model browser, benchmarks and changelog rows from
the same gate with the corrected box. Fixed at their cause: grid minimums
became `min(N, 100%)`, toolbars, tool tabs, drop-down labels, tab lists and
n-gram rows wrap, the analysis panel's tables wrap their cells below 300 px
of panel, long names (layout tabs, chart and leader names, model names, the
layouts summary, key names) wrap instead of being cut by an ellipsis,
`fitLegends` fits a key's legend to its height as well as its width, prose
is held to 60ch, and the release header wraps. The editor's « Import a
fingering » showed the browser's own file control beside its button (the
rule that hid it was scoped to the Comparer's root); it moved to
`fingering_editor.css`. Left, named with its reason in
`PENDING_FRAME_ELEMENTS`: the names of five one-unit keys of the editor's
navigation block, which still pass their key's edge by a pixel or two under
the WCAG 1.4.12 spacing.

### Plain language, the other pages (WCAG 3.1.5)

The default reading mode counts every sentence of 30 words or more in the
running text of a page (`long-sentence`: p, li, dd, blockquote, figcaption
of main; a sentence ends at a full stop, a question or exclamation mark or
an ellipsis before a capital, a digit or a quote). The Studio frames are
left out: their words are the 21 locales' catalogue. On the pages before
this pass it found 64: the layout presentation (9) and installation (9),
the benchmarks (9), the information pages (25), the Ergopti+ features and
configuration pages (1 each), the legacy Ergopti+ page (9) and the
accessibility statement (1). Each was cut or lost its filler, without a
rewrite, and two typos went with them; the diffs are the evidence. The
layout use page renders its text in the browser and had none.

### Plain language, the Studio's catalogue (2026-11-25, Paris time)

The frames' words are now measured in the catalogue itself:
`tools/test/test-studio-plain-language.cjs` cuts every string of the
`layout_analysis`, `layout_editor`, `layout_optimizer` and `layout_try`
namespaces into sentences by the reading gate's rule (widened to scripts
without capitals) and counts those of 30 words or more. English had 28 and
French 36; each was cut in two or three, without a rewrite, and the test
refuses an English or French row. The other spaced locales keep 315 rows in
`studio-plain-language-baseline.json`, which only shrinks; formulas are not
prose, and Japanese and Chinese, which put no space between words, are left
to the manual review.

### Help text of the typing dashboard (WCAG 3.3.5)

Every card of the typing dashboard says what it counts behind its « i »,
except the AI and hotstring cards: their figures were explained by `title`
attributes, which neither the keyboard nor a touch screen reaches, and their
unit was written in English. Both have their « i » now, in 21 locales, in
the cards' own labels. `test-metrics-cards-explained.cjs` (`npm run
test:metrics-cards-explained`) requires help text on every card and fails
on the page before. The Studio's 37 metrics all have their definition
(`layout_analysis.info.<id>`).

### Reading preferences in the app windows, done

The fonts moved from `static/fonts/` to `_shared/ui/fonts/`, beside the
pages: the site serves them from there and every driver package ships them
(`test-studio-reading-preferences.cjs` asks the Windows bundle builder for
each file). The Configuration menu offers `script.reading_font` (default,
hyperlegible, dyslexic) and `script.reading_spacing` (default, wide) on the
three drivers, kept in config.toml like the other script rows. Every
Windows window seeds `window.__ergopti_reading` (13 seed sites,
`ReadingPrefs_SeedScript`) and the font loads by URL from the virtual host.
macOS (`builder.lua`, whose page cache key includes the choices) and Linux
(`webkit_host.lua`) add the shared fragment of
`_shared/core/ui/engine/webview/reading_preferences.lua`: the seed and the
chosen font's faces as `data:` URLs, which the document policy allows. The
physical shortcuts window now links theme.css. Gates:
`test-reading-preferences-seed.cjs`, which fails on the previous tree with
« script.reading_font is not a feature »; the shared Lua contract with each
builder's real page; `test_reading_preferences.ahk`. Left: a change reaches
only the windows opened after it; OpenDyslexic was not looked at in a real
WKWebView or WebKitGTK window; Reduce Motion reaching WKWebView is still
unverified.

### Gates and host

`node tools/test/browser/site-accessibility.playwright.cjs build ""
--reading-only` on a fresh build: 0 reading elements on every page and
frame. `test-site-accessibility-ratchet`, `test-studio-reading-preferences`,
`test-metrics-cards-explained`, `studio-keyboard.playwright.cjs`, the
semantic markup gates, the locale gates, format and convention lints.
`npm run test:js` and `verify-change` refuse this host (Node 22.16, pinned
22.22.2).

## Twelfth pass, AAA in the gates (2026-11-24, Paris time)

The maintainer raised the target to WCAG 2.2 AAA on 2026-11-23. The tools
surveyed and every AAA criterion, measured or checked by hand, are in
[aaa-criteria.md](aaa-criteria.md).

- **Gates.** The site and Studio scan and the app windows' scan run axe-core's
  AAA tags (`wcag2aaa`, `wcag21aaa`, `wcag22aaa`) beside the A and AA ones,
  from one list (`tools/test/lib/wcag-tags.cjs`); both ratchet contracts fail
  if an AAA tag leaves it. The settings dialog and the Comparer's panels keep
  their zero assertions, now at AAA.
- **First measure.** 1,505 app-window nodes and 686 site nodes of
  `color-contrast-enhanced` (1.4.6, 7:1), nothing else at AAA.
- **Fixed through the shared tokens of `theme.css`**, in both themes: the
  accent (`#0062cc` to `#004a99` in light and under white text, `#4a9eff` to
  `#9ccaff` in dark), the secondary and muted greys (`#6e6e73`, `#636366`,
  `#666`, `#555` to `#48484c`; dark ones to `#c8c8c8`, `rgba(235, 235, 245,
0.8)` and `#c4c4ca`), the dialog and status colours. Section 7 of
  `tools/test/test-app-colour-contrast.cjs` holds every shared text token to
  7:1 on its grounds without a browser. The site's own settings dialog and the
  AI demo of `/ergopti-plus` were raised too.
- **Left in the baselines:** 4 site nodes (the changelog frame) and 402
  app-window nodes, all colours a page spells itself: the changelog's dark
  palette, the download window, the metrics dashboards' tints, the hotstring
  and prompt editors' chips, the paths, token and physical-shortcut editors.
- **Also fixed:** the diagnostics window's day-log checkbox was 13 px, below
  the AA 24 px target of 2.5.8 (axe `target-size`, state `day-log`).

## Thirteenth pass, enhanced contrast to zero (2026-11-24, Paris time)

- **`color-contrast-enhanced` (1.4.6) at zero** in both gates, light and dark:
  the 4 site nodes (the changelog frame) and the 389 app-window nodes left by
  the twelfth pass are gone; both baselines hold no contrast row.
- **What changed**, all colours a page spelled itself, each now 7:1 on its
  ground: the changelog's dark palette (blue `#4da6ff` to `#a8d8ff`, purple
  `#bf7af0` to `#d9b3f7`, greys `#999` and `#aaa` to `#c8c8cc` and `#ccc`,
  green to `#9ae6ac`); the download window's greys and reds; the hotstring
  editor's tags (`#005cc5` to `#0a3a6e` in light, `#64b5f6` to `#a8d8ff` in
  dark), hints, bulk delete and the confirmation's filled button (`#b3261e`
  and `#9a6700` under white to `#8a1a14` and `#5c3800`); the hotstrings
  window's and layout manager's danger buttons, badges, meta greys and links;
  the apps dashboard's drill-down tiles and the light chart cards (a dark veil
  had turned the page grey under their headings); the typing dashboard's
  hotstring and AI figures; the paths, token and numeric prompts; the prompt
  editor's chips; the onboarding consent note; the release notes' links; the
  physical-shortcut editor's buttons and list, which kept the browser's dark
  `#6b6b6b`.
- The tokens no page uses any more left `theme.css`, and
  `native_theme_data.lua` was regenerated from it.
- **Target size (enhanced), 2.5.5.** axe's `target-size` measures the AA 24 px
  of 2.5.8 only; both gates now measure the 44 px themselves
  (`tools/test/lib/target-size.cjs`, rule `target-size-enhanced` in their
  ratchets, proved on a small page by the app windows' self check). A link in
  a sentence, a field together with its labels and an unstyled range or
  colour field are the exceptions a page can show; a target is counted once
  per kind (tag, classes, role and type), so one more row of data does not
  move the count (the benchmarks' Comparer alone draws 13,597 small nodes).
  First measure: 220 kinds on the site and its frames, 391 in the app
  windows' states.
- **The public statement** `/accessibilite` names AAA as the target in its
  text and description, and lists the small targets among its known gaps;
  `test-site-accessibility-ratchet.cjs` holds it to the level the gates run.

## Fourteenth pass, no made-up element on the site (2026-11-25, Paris time)

- **The last 34 made-up elements** of the site's markup (WCAG 4.1.1 and
  1.3.1: a custom element name means no more than a div) are standard
  elements: the keyboard drawings' `<keyboard>`, `<keyboard-row>` and
  `<keyboard-key>` became `div.keyboard-drawing`, `div.keyboard-row` and
  `div.keyboard-key` (their `role="table"`, `row` and `cell` kept), the
  home-row drawings' legend a `p.keyboard-legend`, the controls' wrappers
  `div.keyboard-controls` and `div.keyboard-control-*`, the brand names
  `span.name-ergopti` and `span.name-ergopti-plus`, and the drawn narrow
  no-break space of the macOS installation page a `span.nbsp` (the layouts'
  generated key contents keep their `<nbsp>`, drawn by the same rule). The
  drawing is `.keyboard-drawing` because `.keyboard` already names sections
  of the Ergopti+ page. Keyboard.css, the controls' stylesheet, the shared
  site stylesheets, `Keyboard.js` (which kept the key's class when it clears
  a key) and the site structure test select them by class.
- **Gate.** `npm run test:site-semantic-html` refuses any made-up element in
  the site's list, so none can come back through a reviewed entry: 460
  justified divs and spans, none made up.

## Fourteenth pass, HTML_CodeSniffer beside axe (2026-11-25, Paris time)

The maintainer added HTML_CodeSniffer to the AAA audit on 2026-11-24
([aaa-criteria.md](aaa-criteria.md), « Tools surveyed »).

- **Gates.** `html_codesniffer` 2.5.1 is an exactly pinned devDependency; its
  `build/HTMLCS.js` is read from `node_modules` (no network) and run with the
  `WCAG2AAA` standard in every page, frame, state and scheme the two axe gates
  already open, right after axe (`tools/test/lib/htmlcs.cjs`). Its errors are
  counted per page (or window), scheme, frame (or state) and code in
  `site-htmlcs-baseline.json` and `app-windows-htmlcs-baseline.json`, under
  the same ratchet as axe; its warnings and notices only go to the
  `--report` file (`htmlcs.warningsAndNotices`). Both ratchet contracts check
  the exact pin, the injected bundle's version, the standard and that each
  gate runs the scan.
- **First measure** on `origin/dev` of 2026-11-25: the site and its frames,
  220 rows and 18,420 error nodes, of which 18,232 are contrasts it could not
  compute (`.Unmeasured`: HTML_CodeSniffer 2.5.1 reads only `rgb()` and hex
  colours, not the `color(srgb …)` and `oklab(…)` Chromium computes for
  `color-mix()` and `oklch()`), 2 a measured 6.24:1 (`b.mark.on` in the model
  browser shown on `/ergopti-plus/ia`) and 186 markup errors (mostly
  `1_3_1_AAA.G141` heading levels, `1_1_1.H30.2` image links without text,
  `4_1_2.H91` unnamed buttons and fields); the app windows, 346 rows and
  10,698 nodes, of which 8,695 unmeasured, 1,605 measured contrasts below
  7:1 that axe's `color-contrast-enhanced` does not report, and 398 markup
  errors.
- **Also fixed:** the action picker's second focus try on its search field
  took the focus back from a control reached within its 60 ms, which failed
  the app windows' `keyboard-fold` state whenever its steps fell inside it;
  the state now reproduces the race.

## Fifteenth pass, HTML_CodeSniffer measures what it read as NaN (2026-11-25, Paris time)

- **The tool, first.** HTML_CodeSniffer 2.5.1 parses only integer `rgb()` and
  hex colours and gives up on any alpha below 1, so nearly all of its contrast
  errors read « NaN:1 » (18,232 of the site's and 8,695 of the app windows'
  errors). `tools/test/lib/htmlcs.cjs` now hands its parser the browser's own
  conversion (a one-pixel canvas) and its style reader each translucent
  background or text colour composited over what is behind it, down to the
  page's `Canvas` colour, as axe does. A layer over a background image or
  gradient, and SVG text (painted over sibling shapes the tool never sees),
  stay `.Unmeasured`. An error on an element the page does not render (inside
  a `hidden` screen or a closed dialog) goes to the report, not the count: the
  state that shows it is scanned with it rendered (to review, TODO
  « Maintainer decisions pending »). The app windows gate's `--self-check`
  proves each case on a small page and fails on the previous scanner.
- **What it then found, which axe passed or skipped.** axe-core 4.14 reported
  a measured 2.11:1 as a pass in the typing dashboard and skips one-character
  text as « too short »; both were real. Fixed at their source, 7:1 in both
  appearances: the key chips' blue (5.2:1) and the control keys' red (3.0:1),
  the modifier chips (2.0:1 to 5.3:1, now the table's ink rule:
  `--hue-ink-base` and `--hue-ink-shade`), the speed and accuracy gradient
  (shaded 65 % black, or 60 % white on dark), the error table's pink (2.3:1),
  the cards' precision, distance, repetition and speed inks (3.6:1 to 6.9:1),
  the speed chart's yellow title (2.1:1, `--chart-wpm-ink`), the app badges'
  white initials (1.5:1 to 4.1:1, shaded 60 %), the diagnostics' « checking »
  amber (4.9:1 light, 6.5:1 dark), the dashboards' muted grey on the red split
  boxes (6.99:1) and the AI page's shortcut chips (6.5:1).
- **Markup.** The action picker's search field and the typing dashboard's two
  search fields are named (a placeholder vanishes as one types); the
  onboarding's folder field is named by its description; groups that had no
  legend are named ARIA groups (the onboarding's languages and checklist, the
  action picker's program editor, the info editor's rows) or keep a fieldset
  with a visually hidden legend (the Comparer's filters); filter bars and
  editors that never submit are no longer forms (the apps dashboard, the paths
  and info editors, the analysis panel's settings); the analysers table's
  column headers carry `scope`; the release header's empty heading is hidden
  until a release names it; the site logo's link is named by the logo's `alt`.
- **Counts.** App windows: 344 rows and 10,694 errors to 16 rows and 1,240
  (1,232 SVG key labels left unmeasured, 4 `G141` and 4 `H43`). Site: 218 rows
  and 18,418 errors to 76 rows and 6,386, all contrast over a gradient or an
  image left unmeasured.
- **Left, each a limit of the tool.** `G141`: a release body's « ### » is read
  at level 2 through `aria-level`, which the tool ignores (the tags keep their
  look by design). `H43`: the model browser's backend and provider headers use
  `scope="rowgroup"`; the tool expects every backend's header on every cell,
  which would misname the rows for a screen reader, so the `headers` it asks
  for were not added. The `.Unmeasured` rows need a pixel measure of the
  backdrop.

## What remains

The open items live in TODO.md, section « Full accessibility ». The rows of
the findings table with nodes left are their automated part.
