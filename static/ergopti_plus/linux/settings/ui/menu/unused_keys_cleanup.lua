--- settings/ui/menu/unused_keys_cleanup.lua

--- ==============================================================================
--- MODULE: Unused Configuration Keys (Linux)
--- DESCRIPTION:
--- Wires the shared config_unused_keys engine to the Linux readers of
--- config.toml, for the tray row « Nettoyer config.toml » under
--- Configuration. The shared cleanup WebView owns review and confirmation.
---
--- FEATURES & RATIONALE:
--- 1. The driver's rule, from its readers. Linux has no single loader: the
---    gestures manager ([gestures], [gesture_parameters] and their legacy
---    [linux.*] spellings), the shortcuts manager ([shortcuts].enabled), the
---    updater ([updater].channel) and the setup wizard's import each read their
---    own keys. Each marks what it reads through the walk it applies, so the
---    cleanup cannot drift from them.
--- 2. Same semantics as Windows: a verified byte-exact backup first, a refusal
---    that leaves the file untouched on any failure, and a report of the backup
---    path.
--- ==============================================================================

local M = {}
local Engine = require("settings.engine.migration.unused_keys")





-- =================================
-- =================================
-- ======= 1/ Driver Readers =======
-- =================================
-- =================================

--- Runs every Linux reader of config.toml over a decoded file, marking what
--- each one consumes.
--- @param decoded table Decoded config.toml.
--- @param mark function mark(...segments).
function M.collect(decoded, mark)
	require("gestures.engine.manager").mark_config_reads(decoded, mark)
	require("modules.shortcuts.manager").mark_config_reads(decoded, mark)
	require("modules.shortcuts.chatgpt").mark_config_reads(decoded, mark)
	require("hotstrings.engine.repeat_key").mark_config_reads(decoded, mark)
	require("hotstrings.engine.word_reset").mark_config_reads(decoded, mark)
	require("hotstrings.engine.catalogue.config").mark_config_reads(decoded, mark)
	require("hotstrings.engine.matcher.preferences").mark_config_reads(decoded, mark)
	require("hotstrings.engine.matcher.terminator_settings").mark_config_reads(decoded, mark)
	require("modules.shortcuts.tap_keys").mark_config_reads(decoded, mark)
	require("modules.shortcuts.caps_word_auto_off").mark_config_reads(decoded, mark)
	require("modules.shortcuts.script_chords").mark_config_reads(decoded, mark)
	require("modules.shortcuts.accented_shortcuts").mark_config_reads(decoded, mark)
	require("modules.shortcuts.keyboard_shortcuts").mark_config_reads(decoded, mark)
	require("infra.metrics_preferences").resolve(decoded, mark)
	require("infra.pause_layout_preferences").resolve(decoded, mark)
	require("infra.number_row_preferences").resolve(decoded, mark)
	for _, name in ipairs({ "settings", "trigger_settings", "display_settings", "navigation_settings", "profile_settings" }) do
		require("ai.engine.settings." .. name).mark_config_reads(decoded, mark)
	end
	require("ai.engine.settings.profiles").mark_config_reads(decoded, mark)
	require("ai.engine.settings.agent_settings").mark_config_reads(decoded, mark)
	require("ai.engine.preferences").mark_config_read(decoded, require("settings.engine.keys").KEY.LLM_MODELS_SELECTED, mark, function(value)
		return require("ai.engine.prediction.engine").is_backend(value)
	end)
	require("modules.updater.manager").mark_config_reads(decoded, mark)
	require("ui.onboarding.bridge").config_values(decoded, mark)
end

--- Lists the unused keys of a config file under the Linux rule.
--- @param path string Absolute path to config.toml.
--- @return table scan `{ status, keys }`.
function M.find(path)
	return Engine.find({ path = path, collect = M.collect, whole_unread_roots = true })
end





-- ==============================
-- ==============================
-- ======= 2/ Menu Action =======
-- ==============================
-- ==============================

--- Opens the shared cleanup page with the Linux readers' ownership rule.
--- @param deps table|nil Test seams: path, host and file_adapter.
--- @return boolean opened
function M.run_from_menu(deps)
	deps = type(deps) == "table" and deps or {}
	return (deps.host or require("settings.ui.cleanup")).open({
		path = deps.path or require("settings.engine.paths").config("config.toml"),
		collect = M.collect,
		whole_unread_roots = true,
		file_adapter = deps.file_adapter,
	})
end

return M
