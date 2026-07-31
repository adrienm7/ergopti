--- _generated/logger_sub_files.lua
--- AUTO-GENERATED from _shared/modules/logger/sub_files.toml.
--- DO NOT EDIT BY HAND — run `npm run codegen:logger-sub-files` to refresh.

--- ==============================================================================
--- MODULE: Logger Sub-file Routing Table (macOS)
--- DESCRIPTION:
--- The [[sub_files]] entries whose platforms list includes "hs", as the table
--- lib/logger.lua fans log lines out with. A line is routed to a sub-file when
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
	-- MLX backend server, API calls, dependency installer.
	{ name = "ErgoptiPlus_mlx.log", patterns = { "[mlx", "[llm.api_mlx]", "MLX-", "[mlx_deps]" } },
	-- Ollama backend server, API calls, dependency installer.
	{ name = "ErgoptiPlus_ollama.log", patterns = { "[ollama", "[llm.api_ollama]", "[ollama_deps]" } },
	-- LLM menu, model switching, warmup, toggle events.
	{ name = "ErgoptiPlus_llm.log", patterns = { "[llm.", "[menu_llm", "[keymap.llm", "WARMUP", "[TOGGLE]" } },
	-- Keymap processing, dynamic hotstrings, personal info, TOML reader.
	{ name = "ErgoptiPlus_hotstrings.log", patterns = { "[keymap.", "[dynamic_hotstring", "[personal_info]", "[toml_reader]", "hotstring" } },
	-- Keystroke logging, SQLite writes, rotation, export.
	{ name = "ErgoptiPlus_keylogger.log", patterns = { "[keylogger" } },
	-- Karabiner-Elements config generation and reload.
	{ name = "ErgoptiPlus_karabiner.log", patterns = { "[karabiner" } },
	-- Menu builder, UI components, app picker, download window.
	{ name = "ErgoptiPlus_menu.log", patterns = { "[menu]", "[menu_", "[builder]", "[ui_builder]", "[app_picker]", "[download_window]" } },
	-- Notification toasts and the notifications module.
	{ name = "ErgoptiPlus_notify.log", patterns = { "[notify", "[notifications" } },
	-- Driver initialisation, path resolution, config loading.
	{ name = "ErgoptiPlus_boot.log", patterns = { "[init]", "[menu_paths]", "[paths]", "[config" } },
}
