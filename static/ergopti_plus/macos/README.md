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

## Entry point

`init.lua` is the driver entry: it requires the modules, wires shared state, and
runs the boot sequence. Like the Windows entry it holds orchestration only —
feature logic lives in the modules it loads.

## Layout

| Path | Role |
|---|---|
| `init.lua` | Thin entry: module wiring + boot sequence. |
| `adapters/` | OS-isolation layer — every `hs.*`, `io.open`, `os.execute` call lives here (one file per port). The purity guard `tests/meta/test_port_adapter_coverage.lua` enforces it. |
| `lib/` | Infrastructure & domain helpers (no UI windows). |
| `modules/<feature>/` | One folder per feature (`gestures/`, `keylogger/`, `llm/`, `keymap/`, `karabiner/`, …). |
| `ui/<window>/` | One folder per UI window (`menu/`, `tooltip/`, `onboarding/`, `changelog/`, `wpm/`, `model_browser/`, `hotstrings_config_window/`, `hotstring_editor/`, the webview editors, …), each with an `init.lua`. |
| `data/` | Pure data + `generate_models.py` (MLX model-list codegen) and its `pyproject.toml` / `uv.lock` venv pins. |
| `tests/` | `meta/` (source-introspection + port-coverage guards), `unit/`, `helpers/`, `stubs/`. |

> MLX provisioning: `modules/llm/ensure-mlx-deps.sh` builds a `.venv` from the
> pinned `pyproject.toml` on startup (hash-gated). `modules/llm/mlx_deps_checker.lua`
> resolves that script relative to the Hammerspoon root, so moving these files
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
