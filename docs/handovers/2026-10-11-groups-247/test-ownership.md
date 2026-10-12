<!-- docs/handovers/2026-10-11-groups-247/test-ownership.md -->

# Test ownership and migration checkpoint

Functional checkpoint: `92cbad33907ae4ce7e32494f8990f35e81eba983` on `codex/groups-247-completion` (33 atomic commits since `origin/dev`).

No moves are planned. The publication owner retains the CI/test reorganization.
Agree an integration SHA and explicit old-to-new path table before moving these
73 changed test, runner, diagnostic or native build paths. No workflow or gate
was interrupted for coordination. This inventory is a change inventory, not a
replacement for the repository canonical test inventory.

## State and ordering constraints

- Run JavaScript and Lua driver suites sequentially: drift checks temporarily
  regenerate source outputs; parallel Lua reads can observe those transient bytes.
- macOS scoped fixtures retain precise scanner/module ledgers and original
  collaborators. Preserve their cleanup ordering, not just their file names.
- Linux persistence tests retain real writers: use fresh writable XDG configuration
  directories while keeping inherited HOME. macOS portable tests use supported
  private ERGOPTI_PATHS_FILE overrides, except independent HOME/path matrices.
- Windows native custody tests depend on run_all includes, production adapters,
  route/FIFO receipts and exact source-bound DLL generation. Their actual AHK
  execution is still unqualified. Native C census retains one unexecuted editor case.
- Hook receipts distinguish entry QPC, completion order and fixture attribution.
  Keep case-scoped natural retirement and sticky loss/overflow refusals intact.
- Keep independently authored JSON corpora unchanged during test relocation.

## Owned paths

- `package.json`
- `static/ergopti_plus/_shared/tests/corpus/hotstrings/personal_editor_preservation.json`
- `static/ergopti_plus/linux/tests/test_manifest.lua`
- `static/ergopti_plus/linux/tests/unit/infra/test_personal_editor_preservation.lua`
- `static/ergopti_plus/linux/tests/unit/infra/test_user_hotstring_runtime.lua`
- `static/ergopti_plus/linux/tests/unit/meta/test_ui_bridge_handlers.lua`
- `static/ergopti_plus/linux/tests/unit/modules/llm/test_api_entries.lua`
- `static/ergopti_plus/linux/tests/unit/ui/test_llm_backend_rows.lua`
- `static/ergopti_plus/macos/tests/meta/test_menu_preference_calls_fail_closed.lua`
- `static/ergopti_plus/macos/tests/support/gesture_actions_fixture.lua`
- `static/ergopti_plus/macos/tests/support/tooltip_renderer_fixture.lua`
- `static/ergopti_plus/macos/tests/unit/lib/test_personal_editor_preservation.lua`
- `static/ergopti_plus/macos/tests/unit/lib/test_quit_never_blocks.lua`
- `static/ergopti_plus/macos/tests/unit/modules/dynamic_hotstrings/test_user_code_native.lua`
- `static/ergopti_plus/macos/tests/unit/modules/gestures/test_actions_fixture_scope.lua`
- `static/ergopti_plus/macos/tests/unit/modules/llm/test_ai_runtime_selection_install.lua`
- `static/ergopti_plus/macos/tests/unit/modules/llm/test_api_ollama.lua`
- `static/ergopti_plus/macos/tests/unit/modules/llm/test_backend_detection_endpoint_identity.lua`
- `static/ergopti_plus/macos/tests/unit/modules/llm/test_backend_detector_respects_user_override.lua`
- `static/ergopti_plus/macos/tests/unit/modules/llm/test_local_openai_backends.lua`
- `static/ergopti_plus/macos/tests/unit/modules/llm/test_mlx_discovery_backoff_persists.lua`
- `static/ergopti_plus/macos/tests/unit/modules/llm/test_ollama_warmup_endpoint_identity.lua`
- `static/ergopti_plus/macos/tests/unit/ui/menu/menu_llm/test_api_panel_system1_entries.lua`
- `static/ergopti_plus/macos/tests/unit/ui/menu/menu_llm/test_backend_panel_runtime_install.lua`
- `static/ergopti_plus/macos/tests/unit/ui/menu/menu_llm/test_backend_panel_save_gate.lua`
- `static/ergopti_plus/macos/tests/unit/ui/menu/menu_llm/test_health_probe_generation.lua`
- `static/ergopti_plus/macos/tests/unit/ui/menu/menu_llm/test_managed_ollama_retirement_owner.lua`
- `static/ergopti_plus/macos/tests/unit/ui/menu/menu_llm/test_ollama_readiness_async.lua`
- `static/ergopti_plus/macos/tests/unit/ui/test_tooltip_renderer_fixture_scope.lua`
- `static/ergopti_plus/windows/native/nav_event_owner/CMakeLists.txt`
- `static/ergopti_plus/windows/native/nav_event_owner/hook_trace_test.c`
- `static/ergopti_plus/windows/native/nav_event_owner/nav_event_owner_test.c`
- `static/ergopti_plus/windows/native/nav_event_owner/replay_route_core_test.c`
- `static/ergopti_plus/windows/native/nav_event_owner/terminal_output_plan_test.c`
- `static/ergopti_plus/windows/tests/hardware/group7_hook_trace.ahk`
- `static/ergopti_plus/windows/tests/hardware/group7_send_receiving.ahk`
- `static/ergopti_plus/windows/tests/meta/test_fast_timer_inventory.ahk`
- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/llm_nav_event_owner/test_terminal_output_custody.ahk`
- `static/ergopti_plus/windows/tests/unit/llm_nav_event_owner/test_terminal_output_preview.ahk`
- `static/ergopti_plus/windows/tests/unit/llm_nav_event_owner/test_terminal_route_metadata.ahk`
- `static/ergopti_plus/windows/tests/unit/test_keylayout_emulation.ahk`
- `static/ergopti_plus/windows/tests/unit/test_llm_nav_event_owner.ahk`
- `static/ergopti_plus/windows/tests/unit/test_ollama_managed_bootstrap.ahk`
- `static/ergopti_plus/windows/tests/unit/test_ollama_managed_bootstrap.ps1`
- `static/ergopti_plus/windows/tests/unit/test_ollama_model_pull.ps1`
- `static/ergopti_plus/windows/tests/unit/test_ollama_runtime_launch.ps1`
- `static/ergopti_plus/windows/tests/unit/test_ollama_runtime_owner.ahk`
- `static/ergopti_plus/windows/tests/unit/test_personal_file_controls.ahk`
- `static/ergopti_plus/windows/tests/unit/test_personal_toml_io.ahk`
- `static/ergopti_plus/windows/tests/unit/test_personal_toml_preservation.ahk`
- `tools/build/build_windows_nav_owner.ps1`
- `tools/diagnostics/run-windows-group7-send.ps1`
- `tools/diagnostics/run-windows-group7-trace.ps1`
- `tools/diagnostics/run-windows-group7-window.ps1`
- `tools/diagnostics/test_windows_group7_receipt.cjs`
- `tools/diagnostics/test_windows_group7_trace.cjs`
- `tools/diagnostics/windows_group7_receipt.cjs`
- `tools/diagnostics/windows_group7_trace.cjs`
- `tools/test/run-js-suite.cjs`
- `tools/test/run-nav-event-owner-portable.cjs`
- `tools/test/run-windows-hook-trace-core.cjs`
- `tools/test/run-windows-replay-route-core.cjs`
- `tools/test/run-windows-terminal-output-plan.cjs`
- `tools/test/support/nav_event_owner_portable/runtime.c`
- `tools/test/support/nav_event_owner_portable/runtime_test.c`
- `tools/test/support/nav_event_owner_portable/windows.h`
- `tools/test/test-fast-timer-inventory.cjs`
- `tools/test/test-mlx-deps-lock-fingerprint.cjs`
- `tools/test/test-windows-hook-trace-source.cjs`
- `tools/test/test-windows-managed-bootstrap.cjs`
- `tools/test/test-windows-nav-portable-registration.cjs`
- `tools/test/test-windows-terminal-output-custody-adapter.cjs`
