# ErgoptiPlus — macOS driver (Hammerspoon / Lua)

The macOS implementation of ErgoptiPlus.

> **The three driver trees do not currently mirror each other** (18.9 % tree
> identity, measured). Use the cross-driver path table in
> [`docs/ERGOPTI_PLUS.md`](../../../docs/ERGOPTI_PLUS.md) §2.1 to locate the
> counterpart of a file; making the trees identical is invariant I1, measured
> and ratcheted by `tools/test/test-driver-tree-parity.cjs`.
>
> Name collision to know first: `modules/keymap/` is the **hotstring expansion
> engine** here, while on Windows the same path is the **physical layout remap**.
> The layout remap lives in `platform/remap/` plus
> `modules/keymap/{layout_install,input_sources}.lua`.

## Install with Homebrew

Releases are published as casks in the
[`adrienm7/homebrew-ergopti`](https://github.com/adrienm7/homebrew-ergopti) tap,
one cask per update channel of
[`_shared/modules/updater/channels.json`](../_shared/modules/updater/channels.json):

```bash
brew tap adrienm7/ergopti
brew install --cask ergoptiplus        # main (stable) channel
brew install --cask ergoptiplus@dev   # dev channel: every 0.0.0-dev.N prerelease
```

- **Channel.** The cask installs that channel's newest build, and a build
  follows its own channel until another one is picked in the app's About menu.
  The two casks conflict: to switch, `brew uninstall --cask ergoptiplus@dev`
  then `brew install --cask ergoptiplus` (or the reverse); the settings in
  `~/.config/ergopti_plus/` stay. A channel chosen in the About menu is kept in
  `config.toml` and wins over the installed build's channel. The stable cask
  exists once the first stable release is published.
- **Updates.** Two paths update the same app. `brew upgrade` updates it with
  the other casks: brew quits the app, replaces it and relaunches it if it was
  running. The app also keeps updating itself (Sparkle): _Check for updates_
  in its About menu, and automatic checks at the frequency chosen there. After
  an in-app update, the next `brew upgrade` reinstalls that same version once,
  since brew only knows the version it installed itself.
- **Gatekeeper.** The app is not notarised; the cask clears its quarantine
  flag after installing, as the manual `xattr` step does.
- **Uninstall.** `brew uninstall --cask ergoptiplus` removes the app;
  `--zap` also removes `~/.config/ergopti_plus/` and the launcher's
  preferences and caches.

The release job (`Publish Homebrew cask` in
[`ci.yml`](../../../.github/workflows/ci.yml)) renders the released channel's
cask with [`tools/build/homebrew-cask.cjs`](../../../tools/build/homebrew-cask.cjs)
and pushes it to the tap. It needs the `HOMEBREW_TAP_TOKEN` repository secret:
a fine-grained token with _Contents: read and write_ on
`adrienm7/homebrew-ergopti` only. Without it the release still publishes and
warns that the tap kept its previous cask.

## Entry point

`init.lua` is the driver entry: it requires the modules, wires shared state, and
runs the boot sequence. Like the Windows entry it holds orchestration only —
feature logic lives in the modules it loads.

## Layout

| Path                 | Role                                                                                                                                                                                                      |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `init.lua`           | Thin entry: module wiring + boot sequence.                                                                                                                                                                |
| `adapters/`          | OS-isolation layer — every `hs.*`, `io.open`, `os.execute` call lives here (one file per port). The purity guard `tests/meta/test_port_adapter_coverage.lua` enforces it.                                 |
| `lib/`               | Infrastructure & domain helpers (no UI windows).                                                                                                                                                          |
| `modules/<feature>/` | One folder per feature (`gestures/`, `keylogger/`, `llm/`, `keymap/`, `karabiner/`, …).                                                                                                                   |
| `ui/<window>/`       | One folder per UI window (`menu/`, `tooltip/`, `onboarding/`, `changelog/`, `wpm/`, `model_browser/`, `hotstrings_config_window/`, `hotstring_editor/`, the webview editors, …), each with an `init.lua`. |
| `data/`              | Pure data + `generate_models.py` (MLX model-list codegen) and its `pyproject.toml` / `uv.lock` venv pins.                                                                                                 |
| `tests/`             | `meta/` (source-introspection + port-coverage guards), `unit/`, `helpers/`, `stubs/`.                                                                                                                     |

> AI runtimes: neither is bundled, and neither is fetched at startup, when the
> AI is enabled with another backend, or after an update. The first selection
> of the MLX backend runs `modules/llm/ensure-mlx-deps.sh`, which builds the
> venv from the pinned `pyproject.toml`; later selections reuse it. When its
> packages stop importing (a `uv.lock` bump in an update, a partial venv), the
> model check marks it not installed and the next MLX selection rebuilds it.
> A backend row switches only after its runtime install succeeds. The first
> selection of the Ollama backend reuses an installed Ollama
> (`modules/llm/ollama_binary.lua`: Ollama.app, `~/Applications`, Homebrew,
> Ergopti's Application Support copy, then `PATH`) or offers to download the
> release pinned in `modules/llm/ollama-release.sh`.
> `ui/menu/menu_llm/runtime_install_offer.lua` is the only caller of either
> checker's `install_for_selection()`. `modules/llm/mlx_deps_checker.lua`
> resolves its script relative to the Hammerspoon root, so moving these files
> requires updating their path resolution — the Lua unit suite does not exercise
> the bash/venv runtime.

## Running the tests

```
lua tests/run.lua
```

Pure-Lua unit/meta tests run headlessly with stubbed `hs.*`. The canonical
commands for every layer live in [`../../../docs/TESTING.md`](../../../docs/TESTING.md).

## Conventions

Repository-wide delivery rules live in [`AGENTS.md`](../../../AGENTS.md), macOS
semantics in the
[`hammerspoon-driver` skill](../../../.agents/skills/hammerspoon-driver/SKILL.md),
and logging in the shared [`logger contract`](../_shared/modules/logger/SPEC.md).
Hard-won gotchas live in
[`../../../docs/memory/README.md`](../../../docs/memory/README.md). Work that is
known but not done lives in the gate that measures it: each ratchet under
`tools/test/` carries its own count and, in its header, what would move it.
