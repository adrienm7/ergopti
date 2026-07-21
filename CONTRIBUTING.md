# Contributing & developer notes

## Table of contents

- [Contributing \& developer notes](#contributing--developer-notes)
  - [Table of contents](#table-of-contents)
  - [🏗️ Project overview](#️-project-overview)
  - [💻 Local development setup](#-local-development-setup)
  - [🧪 Running the tests](#-running-the-tests)
  - [🧱 Hotstrings & the shared source of truth](#-hotstrings--the-shared-source-of-truth)
  - [🔒 Private AHK file workflow](#-private-ahk-file-workflow)
  - [🪝 Pre-commit hooks](#-pre-commit-hooks)

---

## 🏗️ Project overview

This repo contains:

- The **Ergopti website** (SvelteKit, `src/`)
- The **driver files** distributed to users, under `static/ergopti_plus/`, one
  directory per platform:
  - `static/ergopti_plus/windows/` — AutoHotkey v2 driver (entrypoint
    `ErgoptiPlus.ahk`)
  - `static/ergopti_plus/macos/` — Hammerspoon / Lua driver (entrypoint
    `init.lua`)
  - `static/ergopti_plus/linux/` — Lua hotstrings daemon (entrypoint
    `ergopti_hotstrings.lua`)
- The **cross-driver shared layer** under `static/ergopti_plus/_shared/`: the
  hotstring TOML catalogues, locales, the domain spec, and the feature
  manifest that the code generators read.

The drivers are built from a single source of truth: data lives once in
`_shared/` (TOML / JSON), and `npm run build:domain` / `npm run build:manifest`
regenerate the per-driver `_generated/` artifacts. There is **no Python
hotstrings generator** anymore — see
[Hotstrings & the shared source of truth](#-hotstrings--the-shared-source-of-truth).

---

## 💻 Local development setup

> **Note for Windows users:** Do not add inline comments (`#`) when copy-pasting commands in `cmd.exe` as it can cause `npm` to crash.

```bash
# 1. Install JS dependencies (also sets up Husky hooks)
npm install

# 2. Install Python dependencies (used by the TOML formatter and a few dev tools)
uv sync

# 3. Start the dev server (the website)
npm run dev
```

---

## 🧪 Running the tests

Each driver and the shared layer have their own headless suite. The same suites
run in CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)); run them
locally before opening a PR.

| Command                            | What it covers                                                        |
| ---------------------------------- | --------------------------------------------------------------------- |
| `npm run test:js`                  | Shared domain pipeline: port compliance, manifest/priority parity, translation audit, strict conventions, architecture diagram |
| `npm run test:hs`                  | macOS (Hammerspoon / Lua) unit + meta suite — `static/ergopti_plus/macos/tests/run.lua` |
| `npm run test:linux`              | Linux (LuaJIT) suite — `static/ergopti_plus/linux/tests/run.lua`      |
| `npm run test:ahk-encoding`        | Verifies every `.ahk` file is UTF-8 **BOM + LF** (AHK v2 aborts silently on encoding drift) |
| `npm run lint:conventions:strict`  | Banner alignment, spacing and section-header rules (the commit gate)  |

The Windows AHK unit suite runs from
`static/ergopti_plus/windows/tests/run_all.ahk` (driven on a Windows runner in
CI). Locally, run it with AutoHotkey v2; pass `--only <substring>` to run a
single test by a distinctive slug.

---

## 🧱 Hotstrings & the shared source of truth

Hotstrings are authored as **TOML** under
`static/ergopti_plus/_shared/modules/hotstrings/` — this is the cross-driver
single source of truth, read directly by both the AutoHotkey and Hammerspoon
drivers so a tweak applies to both with no risk of drift:

- `_index.toml` — category order and dynamic-hotstring metadata
- `defaults.toml` — the shared default delays / colours
- `autocorrection.toml`, `magickey.toml`, `rolls.toml`, `sfbsreduction.toml`,
  `distancesreduction.toml` — the catalogues themselves
- `generated_hotstrings.tsv` — a **gitignored**, self-healing runtime cache the
  drivers regenerate from the TOML; never edit or commit it

Edit the `.toml` files directly. The pre-commit hook sorts and formats any
staged hotstring TOML via `tools/format_toml.py` so the on-disk order stays
canonical. Codegen artifacts under each driver's `_generated/` directory are
rebuilt by `npm run build:domain` (and `npm run build:manifest` for the feature
manifest); CI fails the build if a generated file drifts from its source.

---

## 🔒 Private AHK file workflow

The public `static/ergopti_plus/windows/ErgoptiPlus.ahk` is stripped of the
maintainer's personal shortcuts (the `2/ PERSONAL SHORTCUTS` section) — that
section lives only in a **private** copy of the file and must never be pushed
here. The strip keeps the surrounding `3/ LAYOUT MODIFICATION` section intact.

A **gitignored** one-line pointer tells the tooling where your private file is:

```text
static/ergopti_plus/windows/.local_ahk_path   ← absolute path to your private
                                                ErgoptiPlus.ahk (never committed)
```

The tools live under `tools/dev/`:

- `sync-private-ahk.js` — copies the private file to the public location and
  refreshes the "Last modified" date line. No-op when `.local_ahk_path` is
  absent (e.g. on a contributor's machine or CI).
- `remove_ahk_personal_configuration.js` — strips the `2/ PERSONAL SHORTCUTS`
  block from the public file.
- `watch-ahk.js` — watches the private file and re-runs the two steps above on
  every save.

Run the pipeline once, or start the watcher to run it automatically:

```bash
# one-shot: sync private → public, then strip the personal section
npm run sync:ahk

# or watch the private file and run the pipeline on every save
npm run watch:ahk
```

> **Note:** the sync is **not** run by the pre-commit hook — the public file is
> committed as-is unless you run `npm run sync:ahk` (or the watcher) first.
> Hotstrings are no longer generated from the AHK; the TOML catalogues under
> `_shared/modules/hotstrings/` are the source of truth.

---

## 🪝 Pre-commit hooks

Managed by [Husky](https://typicode.github.io/husky/)
([`.husky/pre-commit`](.husky/pre-commit)). The hook runs, in order:

| Step | Action                                                            | Why                                                                 |
| ---- | ---------------------------------------------------------------- | ------------------------------------------------------------------- |
| 1    | Format staged hotstring TOML via `tools/format_toml.py` and re-stage | Keeps the catalogue order canonical and diffs minimal               |
| 2    | Fix AHK encoding (UTF-8 BOM + LF) on staged `.ahk` via `tools/deploy/fix-ahk-encoding.cjs` and re-stage | AHK v2 silently aborts mid-file on encoding drift → silent CI failures |
| 3    | `node tools/lint/lint-conventions.js --fail-on-violations`       | Blocks the commit on any banner / spacing / section-header violation |
