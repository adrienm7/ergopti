<!-- docs/handovers/2026-10-11-groups-247/group4-macos-execution.md -->

## Group4 Mac continuation: native and device qualification

Container controls execute the actual Lua production modules over controlled task/HTTP ports. They are not native macOS service, Hammerspoon, rendering or physical-device qualification. `NATIVE_PRODUCTION_QUALIFIED=False` remains unchanged; Group6 receiving, asset qualification and release integration retain their existing owners.

On a genuine Darwin VM or Mac, first pin the repository to the delivered SHA, use an admitted signed Hammerspoon app/framework, prepare the exact official Ollama archive/catalogue/launcher, reserve a fresh output directory, and follow the existing Group6 network and trust preconditions. Run each supported network profile independently, retaining all receipts and exact child/process cleanup:

```sh
python3 tools/diagnostics/macos_managed_ollama_receiving.py \
  --archive "$TASK_OLLAMA_ARCHIVE" --catalogue "$TASK_OLLAMA_CATALOGUE" \
  --launcher "$TASK_NATIVE_LAUNCHER" --framework "$TASK_HS_FRAMEWORK" \
  --output "$TASK_NEW_OUTPUT" --repository "$PWD" --profile pac-inline
```

Repeat with `--profile pac-url` and `--profile explicit-proxy`, using separate fresh outputs and each profile's prepared environment. Expected: actual READY/RETIRED receipts, real model/API receiving and strict native closure at this exact source; any missing trust, receiving or cleanup must remain a failure. These commands do not themselves authorize changing a production qualification flag.

For the cold-start resolver/bootstrap boundary, prepare the admitted signed app and its exact official Hammerspoon archive, with an isolated user/configuration and fresh output:

```sh
python3 tools/diagnostics/macos_cold_ollama_bootstrap.py \
  --app "$TASK_HS_APP" --official-archive "$TASK_HS_ARCHIVE" \
  --repository "$PWD" --output "$TASK_NEW_COLD_OUTPUT"
```

Expected: unchanged production resolvers and the diagnostic's independent acquisition/closure fences; preserve refusals imposed by unqualified managed production inputs.

After the existing native qualification process admits exact managed inputs, replay in actual Hammerspoon: distinct runtime/model consent and decline/cancel; per-user installation/restart; download streaming and failure text; READY followed by retained foreground lifetime; selecting MLX/API or Quit sends EOF only to Ergopti's original foreground owner and retains debt until both RETIRED and native completion. An independently started external Ollama process must remain alive and keep its personal configuration/models. A refused or delayed EOF/RETIRED/completion must block an owned successor without a global process-name kill.

For menu/model authority, run actual Ollama endpoints on two distinct configured loopback ports. Select the configured server and verify discovery, connection warmup, health display, loadability and inference target its origin. Hold an old response, change the configured port, and release that response: no readiness, checkmark/model selection or old health result may publish. A failing post-pull model load must leave the prior model selected and report failure; a successful model must publish only once. Before the confirmed loadability response, no “model ready” notification may appear; require exactly one after the current model returns HTTP 200, and none after HTTP 500 or a superseding origin/model. Switch local providers while model requirements remain pending or fail: the committed provider must display immediately and refused menu/persistence acknowledgements must restore the prior provider. For local OpenAI-compatible models, refused backend persistence or a superseding live provider/model must not report the stale selection as successful.

The service/process, configured-endpoint, consent and persistence cases can use a native macOS VM with real app/service processes. Actual MLX execution additionally requires supported Apple Silicon with a usable Metal runtime; a VM without that device support cannot qualify MLX inference. Actual appearance at multiple physical displays/DPI, physical typing, keyboard shortcuts, trackpad/focus behavior and a user's installed applications require the corresponding hardware/user environment; no Linux control closes those validations.
