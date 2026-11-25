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

Lua drivers (`platform/vision/screen_vision.lua`):

| Call                                       | Answer                                                         |
| ------------------------------------------ | -------------------------------------------------------------- |
| `init(options)` / `stop()`                 | one owner; a second `init` is refused                          |
| `availability()`                           | `{ capture, region, ocr }`, each `{ ok, reason }`              |
| `capture_window(window)`                   | image, or `nil, reason`                                        |
| `capture_region(rect)`                     | image, or `nil, reason`                                        |
| `match(image, templates, options)`         | image hits, and `{ [id] = reason }` for templates that refused |
| `recognize_text(image, options, callback)` | `callback(words)` or `callback(nil, reason)`, asynchronous     |
| `recognize_file(path, options, callback)`  | the same for an image file                                     |
| `find_text(words, targets)`                | text hits                                                      |

`options` of a recognition is `{ layout = "sparse" | "block", locale }`:
sparse finds scattered words such as a button caption, block keeps the reading
order of a region the user selected. The matcher options are the keys of
`_shared/shortcuts/data/auto_click_defaults.json`.

The Windows driver exposes the same calls as `ScreenVision*` functions
(`ScreenVisionAvailability()`, `ScreenVisionCaptureWindow(Hwnd, &Reason)`, …),
with the shared matcher and text targets ported and replayed on the same
corpora.

## Per OS

- **Linux** (built): X11 GetImage through libxcb on the window's own drawable,
  so an XWayland window (VS Code's default) is captured under Wayland too; a
  screen region needs X11, and under Wayland the Ctrl+O action keeps the
  screenshot tool cascade and reads its file. OCR is the optional `tesseract`
  command (TSV output), with the interface language and English when
  installed; without it the text options are greyed with `ocr_engine_missing`.
- **macOS**: capture, matching and Vision OCR run in the signed launcher
  (a headless worker mode, as the Keychain worker), since the shared Lua
  matcher takes about 0.8 s per scale on Lua 5.4 for an 800 × 600 window.
  Screen Recording permission missing is `capture_permission_missing`.
- **Windows**: GDI capture of the window rectangle, the matcher in the native
  DLL for speed, and Windows.Media.Ocr through one long-lived bridge so the
  engine is created once.

## Shared code and corpora

- `_shared/shortcuts/engine/auto_click_matcher.lua`, pinned by
  `_shared/tests/corpus/keep_awake/auto_click_match_vectors.json`.
- `_shared/shortcuts/engine/text_target.lua` and
  `_shared/core/text/data/text_fold.json`, pinned by
  `_shared/tests/corpus/keep_awake/text_target_vectors.json`.
- `_shared/shortcuts/data/ocr_languages.json`: the OCR language of each
  interface locale, per engine.
