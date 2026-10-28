--- _generated/logger_sub_files.lua
--- AUTO-GENERATED from _shared/modules/logger/sub_files.toml.
--- DO NOT EDIT BY HAND — run `npm run codegen:logger-sub-files` to refresh.

--- ==============================================================================
--- MODULE: Logger Sub-file Routing Table (Linux)
--- DESCRIPTION:
--- The [[sub_files]] entries whose platforms list includes "linux", as the table
--- infra/logger_sink.lua fans log lines out with. A line is routed to a sub-file when
--- ANY of its patterns is a substring of the complete line; it is always also
--- written to the main daily log.
---
--- Both drivers used to parse the TOML themselves — two hand-rolled
--- array-of-tables parsers, each of which had to have the same bug fixed
--- separately (a "]" inside a quoted pattern closed the array early), plus a
--- hardcoded fallback list that had already drifted from the source.
--- ==============================================================================

return {
	-- Gesture recognition, probe loop, swipe events.
	{ name = "ErgoptiPlus_gestures.log", patterns = { "[gestures", "gesture" } },
	-- Ollama backend server, API calls, dependency installer.
	{ name = "ErgoptiPlus_ollama.log", patterns = { "[ollama", "[llm.api_ollama]", "[ollama_deps]", "[LLM.ollama", "[modules.llm.api_ollama]", "[modules.llm.managed_ollama_proxy]" } },
	-- LLM menu, model switching, warmup, toggle events.
	{ name = "ErgoptiPlus_llm.log", patterns = { "[llm.", "[menu_llm", "[keymap.llm", "WARMUP", "[TOGGLE]", "[LLM", "[modules.llm.", "[infra.llm_", "[ui.llm_", "[ui.menu.llm_", "[ui.tooltip.llm]" } },
	-- Keymap processing, dynamic hotstrings, personal info, TOML reader.
	{ name = "ErgoptiPlus_hotstrings.log", patterns = { "[keymap.", "[dynamic_hotstring", "[personal_info]", "[toml_reader]", "hotstring", "[Hotstring", "[HSE", "[UserHotstrings", "[PersonalToml", "[PersonalInfo", "[modules.dynamic_hotstrings.", "[infra.personal_info_fields]" } },
	-- Keystroke logging, SQLite writes, rotation, export.
	{ name = "ErgoptiPlus_keystats.log", patterns = { "[keystats", "[Keystats", "[KL", "[modules.keystats.", "[infra.metrics_" } },
	-- Menu builder, UI components, app picker, download window.
	{ name = "ErgoptiPlus_menu.log", patterns = { "[menu]", "[menu_", "[builder]", "[ui_builder]", "[app_picker]", "[download_window]", "[Menu", "[TrayMenu]", "[ui.menu.", "[manifest_menu]", "[adapters.tray_menu]" } },
	-- Notification toasts and the notifications module.
	{ name = "ErgoptiPlus_notify.log", patterns = { "[notify", "[notifications", "[Notifier]", "[adapters.notifier]", "[adapters.application_notifier]" } },
	-- Driver initialisation, path resolution, config loading.
	{ name = "ErgoptiPlus_boot.log", patterns = { "[init]", "[menu_paths]", "[paths]", "[config", "[Boot]", "[BootProfile]", "[Startup]", "[FirstBoot]", "[ConfigPaths]", "[timings]", "[infra.runtime_guard]", "[ergopti_hotstrings]" } },
}
