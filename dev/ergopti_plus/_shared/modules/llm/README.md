# llm (shared data)

## Purpose

Cross-driver data for the LLM subsystem. Contains the shared defaults file consumed by both AHK and Lua runtimes, the model catalogue, API provider definitions, prompt profiles, and the MLX / Ollama installer scripts. Eliminates duplicated defaults and ensures both drivers use the same model list and stop-token sets.

## Key files

| File                    | Description                                                              |
| ----------------------- | ------------------------------------------------------------------------ |
| `defaults.json`         | Canonical LLM defaults (temperature, debounce, token budget, port, …)   |
| `inference.json`        | Stop-token sequences for all backends (unified batch/line keys)          |
| `models.json`           | Model catalogue (name, size, RAM estimate, engine compatibility)          |
| `profiles.json`         | Named prompt profiles with system prompt and generation parameters        |
| `api_providers.json`    | Remote API provider list (name, endpoint template, auth header name)      |
| `install_ollama*.sh`    | Ollama installation scripts bundled with the driver                       |
| `install_mlx*.sh`       | MLX installation scripts for Apple Silicon                                |

## SSoT rules

- `defaults.json` is the single source for every LLM scalar (§5.2). Never redeclare a default in driver code; read from `defaults.json` via the JSON adapter.
- `inference.json` `stop_sequences` is the SSoT for stop tokens across all backends (P10.2).
- Drift gate: `test-llm-stop-sequences-single-source.cjs` + `test-llm-model-single-source.cjs`.
