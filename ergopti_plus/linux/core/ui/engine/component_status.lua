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
---    field log answers "why" without the screen the user saw. It is a
---    warning: an ERROR opens the error window (diagnostics/ui/error_dialog),
---    a WebKit window a missing lgi or WebKitGTK cannot draw, over a problem
---    the notice and the tray row already explain. Every CI start without lgi
---    failed the zero-error start scenarios on it (2026-11-25).
--- 3. The tray rows are declared in the shared menu (menu.toml top_level
---    component_status, one linux_component_problems row per code) and drawn
---    by the shared renderer (menu/ui/builder/component_status_rows.lua): this
---    module only answers which problems hold.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")

local LOG = "core.ui.engine.component_status"




-- =====================================
-- =====================================
-- ======= 1/ State ====================
-- =====================================
-- =====================================

-- Reported problems in report order: { code, title, body, active }.
local _problems = {}
-- The same problems by code, so a second report of one is refused.
local _by_code = {}




-- =====================================
-- =====================================
-- ======= 2/ Report ===================
-- =====================================
-- =====================================

--- Records a problem, logs its diagnosis line and posts a persistent notice.
--- @param problem table { code, title, body, active? }: code is a stable token
---   ([a-z0-9_]+) with its own linux_component_problems row in menu.toml, which
---   names it in the tray; title and body the translated explanation; active,
---   when given, answers whether the problem still holds, so a state that
---   recovers on its own (a layout read later) leaves the tray once it does.
--- @param deps table|nil { notifier }: the notifier, optional (no session bus).
--- @return boolean recorded false when the code was already reported.
function M.report(problem, deps)
	assert(type(problem) == "table", "component_status.report: a problem table is required")
	for _, field in ipairs({ "code", "title", "body" }) do
		assert(type(problem[field]) == "string" and problem[field] ~= "",
			"component_status.report: " .. field .. " is required")
	end
	assert(problem.code:match("^[a-z0-9_]+$"), "component_status.report: invalid code " .. problem.code)
	assert(problem.active == nil or type(problem.active) == "function", "component_status.report: active must be a function")
	if _by_code[problem.code] then
		Logger.debug(LOG, "Problem %s already reported; kept as it is.", problem.code)
		return false
	end
	local entry = { code = problem.code, title = problem.title, body = problem.body, active = problem.active }
	_problems[#_problems + 1] = entry
	_by_code[entry.code] = entry
	Logger.warn(LOG, "[diagnosis] code=%s — %s", entry.code, entry.body)
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
		copies[index] = { code = entry.code, title = entry.title, body = entry.body }
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
-- ======= 3/ Current problems =========
-- =====================================
-- =====================================

--- The problems that still hold, oldest first, as copies: the tray's
--- component_status rows.
--- @return table { code, title, body } entries.
function M.current()
	local holding = {}
	for _, entry in ipairs(_problems) do
		local holds = true
		if entry.active then
			local ok, value = pcall(entry.active)
			-- A predicate that fails keeps the row: hiding a problem needs proof.
			holds = not ok or value ~= false
			if not ok then Logger.error(LOG, "Problem %s could not be re-checked (%s).", entry.code, tostring(value)) end
		end
		if holds then holding[#holding + 1] = { code = entry.code, title = entry.title, body = entry.body } end
	end
	return holding
end

return M
