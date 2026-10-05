--- ui/menu/unused_keys_cleanup.lua

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
local Engine = require("config_unused_keys")





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
	require("modules.gestures.manager").mark_config_reads(decoded, mark)
	require("modules.shortcuts.manager").mark_config_reads(decoded, mark)
	require("modules.shortcuts.chatgpt").mark_config_reads(decoded, mark)
	require("modules.hotstrings.repeat_key").mark_config_reads(decoded, mark)
	require("modules.hotstrings.hotstrings_config").mark_config_reads(decoded, mark)
	require("infra.hotstring_preferences").mark_config_reads(decoded, mark)
	require("modules.hotstrings.terminator_settings").mark_config_reads(decoded, mark)
	require("modules.shortcuts.tap_keys").mark_config_reads(decoded, mark)
	require("modules.shortcuts.script_chords").mark_config_reads(decoded, mark)
	require("modules.shortcuts.keyboard_shortcuts").mark_config_reads(decoded, mark)
	require("infra.metrics_preferences").resolve(decoded, mark)
	for _, name in ipairs({ "settings", "trigger_settings", "display_settings", "navigation_settings", "profile_settings" }) do
		require("modules.llm." .. name).mark_config_reads(decoded, mark)
	end
	require("modules.llm.profiles").mark_config_reads(decoded, mark)
	require("modules.llm.agent_settings").mark_config_reads(decoded, mark)
	require("infra.llm_preferences").mark_config_read(decoded, "llm.models.selected", mark, function(value)
		return require("modules.llm.prediction_engine").is_backend(value)
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
	return (deps.host or require("ui.config_cleanup.bridge")).open({
		path = deps.path or require("infra.config_paths").config("config.toml"),
		collect = M.collect,
		whole_unread_roots = true,
		file_adapter = deps.file_adapter,
	})
end

return M
