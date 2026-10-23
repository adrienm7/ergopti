--- _shared/lua/llm/config_guard.lua

--- ==============================================================================
--- MODULE: AI Menu Configuration Guard
--- DESCRIPTION:
--- Names why the AI submenus that write config.toml (servers, API entries,
--- profiles) cannot be used, and fences their retained clicks. The manifest
--- rows (the switch, the restore command) already grey with the cause the
--- renderer names; these parents are built from native data, so they get the
--- same cause here instead of an unexplained dead click.
---
--- FEATURES & RATIONALE:
--- 1. One cause per state: a configuration saved by a newer version names
---    `menu.read_only.newer_schema`, as the manifest rows do; any other refusal
---    to write names the generic `menu.llm.save_unavailable`.
--- 2. Retained callbacks recheck: a submenu stays on screen while the file can
---    change under it (a reload that reads a newer file), so every action of
---    a protected tree asks again at click time and refuses with a log line.
--- 3. Pure and shared: the config path, the migration owner and the row field
---    names are passed in, so macOS (`fn`/`menu`) and Linux (`action`/`items`)
---    use one rule and every branch is tested without a live desktop.
--- ==============================================================================

local M = {}

M.NEWER_REASON_KEY = "menu.read_only.newer_schema"
M.GENERIC_REASON_KEY = "menu.llm.save_unavailable"

-- Guards against a cyclic menu table.
local MAX_DEPTH = 8





-- ===============================
-- ===============================
-- ======= 1/ The Cause ==========
-- ===============================
-- ===============================

--- Returns the locale key naming why config.toml cannot be written, or nil.
--- @param path string|nil Absolute config.toml path.
--- @param migrate table Owner with read_only_reason(path) and read_only_status(path).
--- @return string|nil reason_key
function M.reason_key(path, migrate)
	if type(path) ~= "string" or path == "" then return M.GENERIC_REASON_KEY end
	if migrate.read_only_reason(path) == nil then return nil end
	if migrate.read_only_status(path) == "newer" then return M.NEWER_REASON_KEY end
	return M.GENERIC_REASON_KEY
end





-- ==================================
-- ==================================
-- ======= 2/ Retained Clicks =======
-- ==================================
-- ==================================

--- Wraps every action of a menu tree, in place, so the click asks the cause
--- again. In place: a caller that keeps the table by identity keeps it.
--- @param items table|nil Rows of the driver's dialect.
--- @param current_reason function Returns the current reason key, or nil when writable.
--- @param dialect table { action = field, children = field, refused = function(reason) }.
--- @param depth number|nil Current nesting depth.
function M.protect(items, current_reason, dialect, depth)
	depth = depth or 1
	if type(items) ~= "table" or depth > MAX_DEPTH then return end
	for _, item in ipairs(items) do
		if type(item) == "table" then
			local action = item[dialect.action]
			if type(action) == "function" then
				item[dialect.action] = function(...)
					local reason = current_reason()
					if reason ~= nil then
						dialect.refused(reason)
						return false
					end
					return action(...)
				end
			end
			M.protect(item[dialect.children], current_reason, dialect, depth + 1)
		end
	end
end

return M
