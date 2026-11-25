<!-- docs/design/screen-vision.md -->

# Screen vision service (capture, image matching, text recognition)

Written on 2026-11-25 for the anti-sleep auto-clicker (Ctrl+M), the Ctrl+O text
capture and the user workflows. Those three features call only the interface
below, one implementation per driver. The matching and the text comparison are
shared code pinned by shared corpora, so a hit means the same thing on every OS.

## Data shapes

- **Image**: `{ width, height, pixels, scale, frame }`. `pixels` is a row-major
  array of `width × height` gray integers (0 to 255, ITU-R BT.601 weights
  rounded as `auto_click_matcher.gray`), index 1 at the top-left corner.
  `scale` is capture pixels per screen unit (2 on a Retina capture, 1 on X11
  and GDI). `frame` is `{ x, y, width, height }`, the captured area in screen
  coordinates, so a hit at `(hx, hy)` is clicked at
  `auto_click_matcher.click_point(frame, scale, hit)`.
- **Template**: `{ id, image, threshold }`, a library image already in gray.
- **Image hit**: `{ id, x, y, width, height, score, scale }` in image pixels.
- **Word**: `{ text, x, y, width, height, confidence, line }` in image pixels;
  `confidence` is 0 to 1 and `line` groups the words of one line, in reading
  order.
- **Text target**: `{ id, variants = { … }, max_distance }`; a **text hit** is
  `{ id, variant, text, x, y, width, height, distance }`.
- **Reason**: one word naming a refusal (`capture_unavailable`,
  `capture_permission_missing`, `capture_no_x_display`,
  `capture_wayland_region`, `capture_unsupported_visual`, `capture_refused`,
  `capture_empty`, `no_foreground_window`, `ocr_engine_missing`,
  `ocr_language_missing`, `ocr_timeout`, `ocr_failed`, `template_uniform`).
  A caller shows it translated and never fails silently.

## Interface

Lua drivers (`platform/system/vision/screen_vision.lua`). Every call that captures,
matches or recognises answers through a callback, so the macOS driver can run
it in the launcher; Linux calls back before returning.

| Call                                         | Answer                                                          |
| -------------------------------------------- | --------------------------------------------------------------- |
| `init(options)` / `stop()`                   | one owner; a second `init` is refused                           |
| `availability()`                             | `{ capture, region, ocr }`, each `{ ok, reason }`               |
| `capture_window(window, callback)`           | `callback(image)` or `callback(nil, reason)`                    |
| `capture_region(rect, callback)`             | the same for a screen rectangle                                 |
| `match(image, templates, options, callback)` | `callback(hits, refused)`, `refused` = `{ [id] = reason }`      |
| `recognize_text(image, options, callback)`   | `callback(words)` or `callback(nil, reason)`                    |
| `recognize_file(path, options, callback)`    | the same for an image file                                      |
| `scan_window(window, request, callback)`     | capture, match and text targets in one call: `callback(result)` |
| `find_text(words, targets)`                  | text hits, synchronously (pure)                                 |

`request` of `scan_window` is `{ templates, options, text_targets, ocr }`;
`result` is `{ image, hits, text_hits, refused, text_reason }`. It is the
auto-clicker's tick: on macOS one launcher run captures, matches and reads.

`options` of a recognition is `{ layout = "sparse" | "block", locale }`:
sparse finds scattered words such as a button caption, block keeps the reading
order of a region the user selected. The matcher options are the keys of
`_shared/shortcuts/data/auto_click_defaults.json`.

An image returned by the macOS service keeps its pixels in the launcher: it
has no `pixels` field but a private `source` file, and is only ever passed
back to the service. A caller never reads `pixels` itself.

The Windows driver exposes the same calls as `ScreenVision*` functions
(`ScreenVisionAvailability()`, `ScreenVisionCaptureWindow(Hwnd, Callback)`, …),
with the shared matcher and text targets ported and replayed on the same
corpora.

## Per OS

- **Linux** (built): X11 GetImage through libxcb on the window's own drawable,
  so an XWayland window (VS Code's default) is captured under Wayland too; a
  screen region needs X11, so the Ctrl+O action uses the screenshot tool
  cascade (grim and slurp under Wayland) and reads its file. OCR is the optional `tesseract`
  command (TSV output), with the interface language and English when
  installed; without it the text options are greyed with `ocr_engine_missing`.
- **macOS**: capture, matching and Vision OCR run in the signed launcher
  (a headless worker mode, as the Keychain worker), since the shared Lua
  matcher takes about 0.8 s per scale on Lua 5.4 for an 800 × 600 window.
  Screen Recording permission missing is `capture_permission_missing`.
- **Windows**: GDI capture of the window rectangle, the matcher in C# for
  speed, and Windows.Media.Ocr through one long-lived bridge so the engine is
  created once. The C# (`windows/native/ergopti_screen_vision_*.cs`) is
  compiled at build time into `vendor/ergopti_screen_vision.dll` by
  `tools/build/build_windows_screen_vision.ps1`; the worker loads it and never
  compiles at run time. A source run on Windows runs that builder once after a
  checkout or a change to the C# sources; without the assembly the service
  refuses with `capture_unavailable` and logs the missing file.

## The « Capture → texte » action (Ctrl+O)

`_shared/shortcuts/engine/ocr_capture.lua` (Windows twin
`modules/shortcuts/ocr_capture.ahk`) runs it through five ports: `select`
(the region, written to a file; reason `cancelled` on Escape), `recognize`,
`set_clipboard`, `notify` and `remove`. Its outcomes are `copied`,
`nothing_recognised` (the clipboard is left unchanged), `cancelled` (no
notice) and `failed`; the text is never logged, only its line and character
counts. The selection is screencapture's own on macOS, the screenshot region
cascade on Linux, and an overlay (`platform/system/vision/region_select.ahk`) on
Windows, whose rectangle `ScreenVisionCaptureRegion` captures. Pinned by
`_shared/tests/corpus/keep_awake/ocr_capture_vectors.json`.

## Shared code and corpora

- `_shared/shortcuts/engine/keep_awake/auto_click_matcher.lua`, pinned by
  `_shared/tests/corpus/keep_awake/auto_click_match_vectors.json`.
- `_shared/shortcuts/engine/keep_awake/text_target.lua` and
  `_shared/core/text/data/text_fold.json`, pinned by
  `_shared/tests/corpus/keep_awake/text_target_vectors.json`.
- `_shared/shortcuts/data/ocr_languages.json`: the OCR language of each
  interface locale, per engine.
