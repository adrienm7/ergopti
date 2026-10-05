--- ui/menu/unused_keys_cleanup.lua

--- ==============================================================================
--- MODULE: Unused Configuration Keys (macOS)
--- DESCRIPTION:
--- Wires the shared config_unused_keys engine to the macOS readers of
--- hammerspoon/config.toml and the shared cleanup WebView, for the tray row
--- « Nettoyer config.toml » under Configuration.
---
--- FEATURES & RATIONALE:
--- 1. The driver's rule, from its readers. A key is used when a canonical
---    readers of this file takes it: config_overrides ([script] / [features]
---    scalars, applied to hs.settings at boot), Preferences.load (the menu
---    state), shortcut assignments and the setup wizard's import of an existing file. Each marks what
---    it reads through the walk it applies, so the cleanup cannot drift from
---    them.
--- 2. Same semantics as Windows: a verified byte-exact backup first, a refusal
---    that leaves the file untouched on any failure, and a report of the backup
---    path.
--- 3. The preference save baseline follows the cleanup, so the next menu change
---    is not refused as an external edit.
--- 4. Warned is offered. After boot, each entry the cleanup would offer is
---    named once in the log, as the Windows loader does at startup.
--- ==============================================================================

local M = {}
local Engine = require("config_unused_keys")
local ConfigOutdated = require("config_outdated")





-- =================================
-- =================================
-- ======= 1/ Driver Readers =======
-- =================================
-- =================================

--- Runs every macOS reader of config.toml over a decoded file, marking what
--- each one consumes.
--- @param decoded table Decoded config.toml.
--- @param mark function mark(...segments).
function M.collect(decoded, mark, shapes)
	require("infra.config_overrides").mark_config_reads(decoded, mark)
	require("infra.preferences").mark_config_reads(decoded, mark, shapes)
	require("modules.shortcuts.tap_keys").mark_config_reads(decoded, mark)
	require("modules.shortcuts.keyboard_shortcuts").mark_config_reads(decoded, mark)
	require("ui.onboarding").config_values(decoded, mark)
end

--- Lists the unused keys of a config file under the macOS rule.
--- @param path string Absolute path to config.toml.
--- @param file_adapter table|nil File adapter; the macOS FileSystem by default.
--- @return table scan `{ status, keys }`.
function M.find(path, file_adapter)
	return Engine.find({
		path = path,
		collect = M.collect,
		whole_unread_roots = true,
		file_adapter = file_adapter or require("adapters.file_system"),
	})
end

--- Names once each entry of config.toml no macOS reader uses, as the Windows
--- loader does at startup: the WARNING behind every entry « Nettoyer
--- config.toml » offers. An entry its owner already reported keeps the owner's
--- own warning. An unreadable or malformed file names nothing here: its
--- readers already refuse it loudly.
--- @param path string Absolute path to config.toml.
--- @param file_adapter table|nil File adapter; the macOS FileSystem by default.
--- @return number named Entries this call named.
function M.warn_unused(path, file_adapter)
	local scan
	local reported = ConfigOutdated.collect_reports(function() scan = M.find(path, file_adapter) end)
	if scan.status ~= "ok" then return 0 end
	local named = 0
	for _, key in ipairs(scan.keys) do
		if not reported[table.concat(key.path, ".")] then
			ConfigOutdated.report(key.path, "no reader of this build uses it")
			named = named + 1
		end
	end
	return named
end





-- ==============================
-- ==============================
-- ======= 2/ Menu Action =======
-- ==============================
-- ==============================

--- Opens the shared cleanup page with trusted macOS ownership and file ports.
--- @param deps table|nil Test seams: path, host, preferences and file_adapter.
--- @return boolean opened
function M.run_from_menu(deps)
	deps = type(deps) == "table" and deps or {}
	local preferences = deps.preferences or require("infra.preferences")
	local path = deps.path or require("ui.menu.menu_paths").get("ConfigTomlPath")
	local host = deps.host or require("ui.config_cleanup")
	return host.open({
		path = path, collect = M.collect,
		whole_unread_roots = true,
		file_adapter = deps.file_adapter or require("adapters.file_system"),
		on_removed = function(result)
			return preferences.adopt_cleanup(path, result.previous, result.content)
		end,
	})
end

return M
