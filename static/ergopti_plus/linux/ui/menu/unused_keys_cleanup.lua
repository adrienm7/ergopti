--- ui/menu/unused_keys_cleanup.lua

--- ==============================================================================
--- MODULE: Unused Configuration Keys (Linux)
--- DESCRIPTION:
--- Wires the shared config_unused_keys engine to the Linux readers of
--- config.toml, for the tray row "Clean up unused settings…" under Global
--- actions. The dialogs are the tray's own zenity helpers, handed in by the
--- menu builder.
---
--- FEATURES & RATIONALE:
--- 1. The driver's rule, from its readers. Linux has no single loader: the
---    gestures manager ([gestures], [gesture_parameters] and their legacy
---    [linux.*] spellings), the shortcuts manager ([shortcuts].enabled) and
---    the setup wizard's import each read their own keys. Each marks what it
---    reads through the walk it applies, so the cleanup cannot drift from them.
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
	require("ui.onboarding.bridge")._answers_from_config(decoded, "", mark)
end

--- Lists the unused keys of a config file under the Linux rule.
--- @param path string Absolute path to config.toml.
--- @return table scan `{ status, keys }`.
function M.find(path)
	return Engine.find({ path = path, collect = M.collect })
end





-- ==============================
-- ==============================
-- ======= 2/ Menu Action =======
-- ==============================
-- ==============================

--- Tray action: lists the unused keys of the live config.toml, asks before
--- removing them, and reports the backup path or why nothing changed.
--- @param deps table `{ dialogs = { confirm, inform, fail }, path?, get_text?,
---   stamp? }`. confirm returns true, false, or nil when no dialog could be shown.
--- @return boolean completed
function M.run_from_menu(deps)
	if type(deps) ~= "table" or type(deps.dialogs) ~= "table" then
		error("unused_keys_cleanup.run_from_menu needs the tray dialogs", 2)
	end
	local get_text = deps.get_text or function(key) return require("infra.i18n").get(key) end
	return Engine.run({
		path = deps.path or require("infra.config_paths").config("config.toml"),
		collect = M.collect,
		get_text = get_text,
		stamp = deps.stamp,
		confirm = deps.dialogs.confirm,
		inform = deps.dialogs.inform,
		fail = deps.dialogs.fail,
	})
end

return M
