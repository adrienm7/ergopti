--- core/ui/engine/component_status.lua

--- ==============================================================================
--- MODULE: Component Status (Linux)
--- DESCRIPTION:
--- The one owner of "a part of Ergopti+ is not working, and why": a component
--- the windows need is absent, or the keyboard core cannot type. Each problem
--- is reported once and then stays visible until the daemon exits.
---
--- FEATURES & RATIONALE:
--- 1. A transient notification was the only surface. On KDE Plasma 6 it
---    vanished unless hovered and never reached the history (field report,
---    Arch Linux, 2026-11-25): the user saw "nothing works" and no reason.
---    The notification is now persistent, and the tray menu carries a red row
---    naming the problem whose click shows the full explanation, as macOS
---    shows a red dot on its Tap-Holds title.
--- 2. One diagnosis line per problem in the log, with a stable code, so a
---    field log answers "why" without the screen the user saw.
--- 3. The tray rows are drawn by the tray adapter outside the shared renderer,
---    like the degraded menu: they report the failure of components that
---    renderer and its windows may depend on.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")

local LOG = "core.ui.engine.component_status"

--- The red dot every problem row starts with (menu.toml health_dot "unreachable").
M.DOT = "🔴"




-- =====================================
-- =====================================
-- ======= 1/ State ====================
-- =====================================
-- =====================================

-- Reported problems in report order: { code, label, title, body }.
local _problems = {}
-- The same problems by code, so a second report of one is refused.
local _by_code = {}




-- =====================================
-- =====================================
-- ======= 2/ Report ===================
-- =====================================
-- =====================================

--- Records a problem, logs its diagnosis line and posts a persistent notice.
--- @param problem table { code, label, title, body }: code is a stable token
---   ([a-z0-9_]+); label the short tray row text; title and body the translated
---   explanation.
--- @param deps table|nil { notifier }: the notifier, optional (no session bus).
--- @return boolean recorded false when the code was already reported.
function M.report(problem, deps)
	assert(type(problem) == "table", "component_status.report: a problem table is required")
	for _, field in ipairs({ "code", "label", "title", "body" }) do
		assert(type(problem[field]) == "string" and problem[field] ~= "",
			"component_status.report: " .. field .. " is required")
	end
	assert(problem.code:match("^[a-z0-9_]+$"), "component_status.report: invalid code " .. problem.code)
	if _by_code[problem.code] then
		Logger.debug(LOG, "Problem %s already reported; kept as it is.", problem.code)
		return false
	end
	local entry = { code = problem.code, label = problem.label, title = problem.title, body = problem.body }
	_problems[#_problems + 1] = entry
	_by_code[entry.code] = entry
	Logger.error(LOG, "[diagnosis] code=%s — %s", entry.code, entry.body)
	local notifier = type(deps) == "table" and deps.notifier or nil
	if notifier and type(notifier.send) == "function" then
		local ok, err = pcall(notifier.send, entry.body, { title = entry.title, level = "error", persistent = true })
		if not ok then Logger.error(LOG, "Notice for %s could not be posted (%s); the tray row remains.", entry.code, tostring(err)) end
	end
	return true
end

--- The reported problems, oldest first, as copies.
--- @return table
function M.problems()
	local copies = {}
	for index, entry in ipairs(_problems) do
		copies[index] = { code = entry.code, label = entry.label, title = entry.title, body = entry.body }
	end
	return copies
end

--- Whether a problem with this code was reported.
--- @param code string
--- @return boolean
function M.has(code)
	return _by_code[code] ~= nil
end




-- =====================================
-- =====================================
-- ======= 3/ Tray rows ================
-- =====================================
-- =====================================

--- The rows the tray menu starts with: one red row per problem, then a
--- separator; none when nothing is wrong.
--- @param show function Called with (title, body) when a row is clicked.
--- @return table Rows in the tray adapter's shape.
function M.tray_rows(show)
	assert(type(show) == "function", "component_status.tray_rows: a show function is required")
	local rows = {}
	for _, entry in ipairs(_problems) do
		rows[#rows + 1] = {
			title = M.DOT .. " " .. entry.label,
			fn = function() show(entry.title, entry.body) end,
		}
	end
	if #rows > 0 then rows[#rows + 1] = { separator = true } end
	return rows
end

return M
