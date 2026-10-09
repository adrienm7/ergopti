<!-- video/STORYBOARD.md -->

# Ergopti+ promo video: storyboard

The single plan for the promo film and the README feature GIFs. Scenes, copy
and timing live here; the Remotion code under `src/` implements them with one
component per scene, so a scene can be reworded, retimed or swapped without
touching the others.

## Intent

- Audience: people who type all day (developers, writers, multilingual users)
  and have never heard of Ergopti+.
- Message: one free app that augments typing everywhere on the computer, on
  Windows, macOS and Linux, from the same configuration files. Typing data
  stays local; the AI runs locally or through an API the user chooses.
- Language: English for every on-screen word. French appears only inside
  demonstrated text when a French expansion is the honest example.
- Proof: motion design explains the features; a section of real screen
  captures on Windows 11 shows the same things happening on a real machine.

## Deliverables

| Composition     | Size      | FPS | Length | Output                                   |
| --------------- | --------- | --- | ------ | ---------------------------------------- |
| `Promo`         | 1920×1080 | 30  | ~2 min | `out/ergoptiplus-promo.mp4`              |
| `Gif-<feature>` | 1920×1080 | 30  | 6–12 s | `out/gif/<feature>.gif` (scaled to 800w) |

Every scene is designed once at 1920×1080. A feature GIF is the same scene
component rendered alone, scaled to 800 px wide at 12 fps with a generated
palette. Each GIF must stay under 3 MB so the README stays light; the README
shows them in a feature table, one GIF per row.

## Visual language

- Ground: the site's navy gradient (hsl 205 100% 5% → hsl 207 100% 32%).
- Accents: brand blue `rgb(49,190,255)`, blue gradient `#3088ed → #02c9db`,
  the name gradient `#0084ff → #4af0ff → #c1d6ff → #ff40fc → #ff2a2a`.
- Feature colours come from the driver tooltips: magic ★ `#e53935`,
  autocorrect `#43a047`, rolls `#1e88e5`, personal `#8e8e93`, AI `#ec407a`.
- Type: Noto Sans for copy, a monospace for typed text.
- Motion: one easing everywhere, `cubic-bezier(0.16, 1, 0.3, 1)`; springs for
  entrances; nothing moves without a reason.
- Every scene opens with a chapter label that mirrors the tray menu
  (Hotstrings, AI, Tap-holds, Shortcuts, Gestures, Metrics), so the film reads
  like a tour of the menu.
- Real driver windows (hotstring editor, model browser, action picker,
  dashboards) are captured from their own HTML with the site's demo data,
  never redrawn.

## Scenes (`Promo`, ~3 min 20)

After the overview, the film follows the tray menu's order: Tap-Holds,
Shortcuts, Gestures, Hotstrings, Metrics, Artificial Intelligence.

| #   | Len  | Scene / GIF id        | On screen                                                                                                                                                                                                      |
| --- | ---- | --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | 5 s  | `hook`                | "Type less. Write more." and the name.                                                                                                                                                                         |
| 2   | 11 s | `three-os`            | "Works on every system.": a hotstring fires on Windows, then macOS, then Linux, one at a time, full frame.                                                                                                     |
| 3   | 15 s | `menu`                | The tray menu exactly as `menu_manifest.json` lays it out for Windows, every row, walked from top to bottom with a liquid highlight; each submenu fans out with all its rows (placeholders for run-time rows). |
| 4   | 13 s | `tap-holds`           | One key, two jobs (Space: tap = space, hold = an example layer), then any key every system has, with tap and hold chosen per key.                                                                              |
| 5   | 9 s  | `nav-layer`           | The recommended navigation layer on a legend-free keyboard, group by group.                                                                                                                                    |
| 6   | 6 s  | `shortcuts`           | The recommended Win + letter slots, each re-assignable.                                                                                                                                                        |
| 7   | 33 s | `shortcut-*` (×6)     | Teleport the mouse (why: lost pointer, unknown screen edges), select the line, change case, colour under the cursor, open anything selected (file, link or web search), wrap the selection with any symbol.    |
| 8   | 6 s  | `gestures`            | Trackpad gestures.                                                                                                                                                                                             |
| 9   | 13 s | `personal-hotstrings` | The real editor: "+ Add a hotstring", the real form, Save, then the hotstring fires.                                                                                                                           |
| 10  | 12 s | `extreme-hotstrings`  | The best-of list, then "pex★ tu peux écrire" completed by an AI prediction ("à la vitesse de l’éclair"), with a keys / characters counter.                                                                     |
| 11  | 15 s | `metrics`             | A tour of the real typing dashboard: savings, speed, most typed words, most used shortcuts, distance per finger.                                                                                               |
| 12  | 9 s  | `screen-time`         | The real screen-time dashboard scrolled to the time per app, then the day's timeline.                                                                                                                          |
| 13  | 42 s | `ai-*` (×4)           | Prediction with Tab; every app on every system; local models or an API; rewrite, translate, ask.                                                                                                               |
| 14  | 6 s  | `private`             | Privacy promises.                                                                                                                                                                                              |
| 15  | 25 s | `real`                | "Ergopti+ in real life.": Notepad, tooltips at the caret, each AI prediction shown then inserted, the waits cut and marked.                                                                                    |
| 16  | 5 s  | `outro`               | Name, systems, URL.                                                                                                                                                                                            |

The exact length comes from `src/data/timeline.json`.

Tap-holds and shortcuts never suggest a forced setup: every example is
labelled as one choice among many, and only keys every system has (Space,
Shift, CapsLock, Tab, Enter…) illustrate tap-holds.

## Feature GIFs (README)

One GIF per scene flagged `gif` in `timeline.json`, shown in the README in the
film's order.

## Assets and their owners

| Asset                  | Owner                                     | Refresh with             |
| ---------------------- | ----------------------------------------- | ------------------------ |
| Driver window captures | `static/ergopti_plus/_shared/ui/*`        | `npm run capture:ui`     |
| Dashboard demo data    | `tools/dev/gen-demo-metrics.cjs`          | regenerate, then capture |
| Real screen recordings | the installed driver on a Windows machine | `npm run capture:screen` |
| Logo                   | `static/img/logo/`                        | copied by `capture:ui`   |

Feature counts shown on screen (2,994 hotstrings, 110 models, 173 actions,
335 settings, 21 languages) are the figures the sales page measures at build
time; update `src/data/facts.ts` when they move.
