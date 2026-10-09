<!-- video/README.md -->

# Ergopti+ promo video

The two-minute promo film and the README feature GIFs, made with
[Remotion](https://www.remotion.dev/) (React components rendered frame by frame
to MP4). The plan of the film, scene by scene, is in
[STORYBOARD.md](STORYBOARD.md).

## Nothing here is a copy

The project reads the repository instead of duplicating it, so a change to the
driver or the site shows up at the next render with no synchronisation step:

| On screen                                     | Comes from                                                                      |
| --------------------------------------------- | ------------------------------------------------------------------------------- |
| Hotstring editor, model catalogue, dashboards | The driver's real windows (`static/ergopti_plus/_shared/ui/`), rendered live    |
| Data those windows show                       | `src/lib/js/driverWindowHost.js`, the host module the website uses too          |
| Dashboard demo data                           | `static/demo/*_prefetch.json` (`tools/dev/gen-demo-metrics.cjs`)                |
| Figures (2,994 hotstrings, 110 models…)       | The sales page's build-time loader, `src/routes/ergopti-plus/+page.server.js`   |
| Hotstring outputs (`pex★` → `par exemple`)    | The driver's hotstring TOML files; only the triggers live in `src/data/`        |
| Tap-holds, action labels, gesture count       | `_shared/tap_hold/defaults.toml`, `actions.toml`, `en.json`, the menu manifest  |
| Tooltip look and AI line colours              | `_shared/modules/tooltip/constants.toml`                                        |
| Colours, gradients, radii, fonts              | The site's CSS (`global.css`, `ergopti_name.css`, `ergopti-plus.css`), imported |
| Music and interface sounds                    | Synthesised by `scripts/make-audio.mjs`; no licensed asset                      |

`scripts/prepare.mjs` runs before every studio session and render. It fails
when a demonstrated trigger, locale key or source folder no longer exists, so
a rename in the driver cannot silently produce a wrong video.

`public/` is generated: a tree of hard links to the `static/` folders the
windows need (no disk space, no privilege on any system). Never format or edit
files through it; the root `.prettierignore` and `.eslintignore` exclude it.

## Commands

Run from this folder after `npm install`:

```bash
npm run studio
```

Opens Remotion Studio to preview and scrub every scene (`Promo` is the film,
`Scenes/Scene-<id>` one scene each).

```bash
npm run render
```

Renders the film to `out/ergoptiplus-promo.draft.mp4`, checks it for flicker
(below), and only then moves it to `out/ergoptiplus-promo.mp4`.

```bash
npm run gifs
```

Renders every scene flagged `gif` in `src/data/timeline.json` to
`static/media/ergopti_plus/<id>.gif` for the README, at 800 px and 12 fps. A GIF
over 3 MB, or a scene that flickers, fails the run instead of landing in git.
`npm run gifs -- metrics` renders one.

```bash
npm run stills
```

Writes a few frames of every scene to `out/stills/` for a quick visual review.

```bash
npm run capture:screen
```

Windows only. Records the unedited "real capture" clips of the film on a
machine where the driver runs, then updates `assets/real/`. See below.

## No flicker, ever

Remotion captures frames in several browser tabs at once. A scene whose look
depends on anything but the frame then alternates between the tabs' states,
which reads as stutter. The real driver windows are the risk: they compute in
the background, draw charts on canvas and read the clock. `DriverWindow`
therefore, before any capture:

- waits for the window's DOM to stay unchanged, after loading and after each
  scripted change (scroll, tab switch), then for the window to paint;
- turns off CSS and Chart.js animations and stops the window's clock at one
  instant shared by every tab;
- calls `settleDriverWindow()` (`src/lib/js/driverWindowHost.js`), which
  redraws the window once it is idle, so charts drawn early on canvas (raw
  legend keys, half-height) reach the same final state in every tab.

`scripts/check-flicker.mjs` enforces it: a picture that leaves a state for one
to three frames and returns to it exactly is flicker, which no real animation
does. `npm run render` and `npm run gifs` refuse to publish a video that fails
it; `npm run check-flicker -- <file.mp4>` checks any render. A new window or
scene that fails it needs its source of non-determinism found and frozen, not
the check relaxed.

## Updating the video

- **The driver UI changed**: run `npm run render` and `npm run gifs`.
- **A figure or a hotstring changed**: same; `prepare.mjs` picks it up.
- **A scene's wording or timing**: edit `src/scenes/<Scene>.tsx`; lengths and
  order live in `src/data/timeline.json`, which the soundtrack follows too.
- **A new feature**: add a scene component, register it in
  `src/scenes/index.ts`, add it to `timeline.json` and to the storyboard.

## The real capture

`npm run capture:screen` opens Notepad (close yours first: it refuses to run
next to it), records the top-left of the screen (`region` in
`scripts/real/scenarios.json`) and types each scenario. Everything beyond the
typed characters (expansions, tooltips, predictions) is the installed driver's
own doing. Leave the keyboard and mouse alone while it runs (about a minute).

- Notepad, because it exposes a Win32 caret: the driver anchors its tooltip
  exactly at the caret there. A browser field only offers the field's box, so
  the tooltip lands elsewhere.
- The untitled tab is closed through File > Close tab > Don't save, so
  Notepad's session restore keeps nothing.
- The wait for an AI prediction is cut: the script reads the driver's log to
  know when the prediction is fully shown, stores the segments to keep in
  `clips.json`, and the film marks the cut ("AI wait shortened").
- Typing uses Unicode key events, so it is independent of the keyboard layout.
- Every key checks that the editor still has focus and stops otherwise.
- Scenarios never send Ctrl, Alt or Shift combinations: the driver's tap-holds
  own those keys, so an injected Ctrl would become a tap (LCtrl tap = Paste).
- The driver accepts a prediction only from the user's own Tab key. The
  `accept` step instead posts the registered window message
  `Ergopti.LLM.AcceptPrediction.v1`, which the driver's LLM bridge honours
  with the same focus and modifier checks (`llm-automation-accepts`). The
  driver must run code that includes it, so reload it after updating.
- A prediction needs a working AI backend. The film's caption names the one
  used for the capture; edit it in `scenarios.json`.
