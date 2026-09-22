--- ui/menu/unused_keys_cleanup.lua

--- ==============================================================================
--- MODULE: Unused Configuration Keys (macOS)
--- DESCRIPTION:
--- Wires the shared config_unused_keys engine to the macOS readers of
--- hammerspoon/config.toml and to the driver's own dialogs, for the tray row
--- "Clean up unused settings…" under Global actions.
---
--- FEATURES & RATIONALE:
--- 1. The driver's rule, from its readers. A key is used when one of the three
---    readers of this file takes it: config_overrides ([script] / [features]
---    scalars, applied to hs.settings at boot), Preferences.load (the menu
---    state) and the setup wizard's import of an existing file. Each marks what
---    it reads through the walk it applies, so the cleanup cannot drift from
---    them.
--- 2. Same semantics as Windows: a verified byte-exact backup first, a refusal
---    that leaves the file untouched on any failure, and a report of the backup
---    path.
--- 3. The preference save baseline follows the cleanup, so the next menu change
---    is not refused as an external edit.
--- ==============================================================================

local M = {}
local Engine = require("config_unused_keys")





-- =================================
-- =================================
-- ======= 1/ Driver Readers =======
-- =================================
-- =================================

--- Runs every macOS reader of config.toml over a decoded file, marking what
--- each one consumes.
--- @param decoded table Decoded config.toml.
--- @param mark function mark(...segments).
function M.collect(decoded, mark)
	require("infra.config_overrides").mark_config_reads(decoded, mark)
	require("infra.preferences").mark_config_reads(decoded, mark)
	require("ui.onboarding")._answers_from_config(decoded, mark)
end

--- Lists the unused keys of a config file under the macOS rule.
--- @param path string Absolute path to config.toml.
--- @param file_adapter table|nil File adapter; the macOS FileSystem by default.
--- @return table scan `{ status, keys }`.
function M.find(path, file_adapter)
	return Engine.find({
		path = path,
		collect = M.collect,
		file_adapter = file_adapter or require("adapters.file_system"),
	})
end





-- ==============================
-- ==============================
-- ======= 2/ Menu Action =======
-- ==============================
-- ==============================

--- Tray action: lists the unused keys of the live config.toml, asks before
--- removing them, and reports the backup path or why nothing changed.
--- @param deps table|nil Test seams: `{ path, dialog, i18n, file_adapter,
---   preferences, stamp }`; production resolves each from the driver.
--- @return boolean completed
function M.run_from_menu(deps)
	deps = type(deps) == "table" and deps or {}
	local i18n = deps.i18n or require("infra.i18n")
	local dialog = deps.dialog or require("infra.dialog_util")
	local preferences = deps.preferences or require("infra.preferences")
	local path = deps.path or require("ui.menu.menu_paths").get("ConfigTomlPath")
	local get_text = function(key) return i18n.get(key) end
	local remove_label = get_text("button.remove")

	return Engine.run({
		path = path,
		collect = M.collect,
		get_text = get_text,
		stamp = deps.stamp,
		file_adapter = deps.file_adapter or require("adapters.file_system"),
		confirm = function(title, text)
			return dialog.block_alert(title, text, remove_label, get_text("button.cancel"),
				"warning") == remove_label
		end,
		inform = function(title, text)
			dialog.block_alert(title, text, get_text("button.ok"), nil, "informational")
		end,
		fail = function(title, text)
			dialog.block_alert(title, text, get_text("button.ok"), nil, "critical")
		end,
		on_removed = function(result)
			preferences.adopt_cleanup(path, result.previous, result.content)
		end,
	})
end

return M
