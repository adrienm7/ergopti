--- ui/app_cloner_python_offer.lua

--- ==============================================================================
--- MODULE: App Cloner Python Offer
--- DESCRIPTION:
--- Opens App Cloner with the managed Python and its pinned PyObjC: when they
--- are installed the launch carries the interpreter's versionless link, and
--- when they are not the user is asked once per click to install them first
--- (modules/llm/managed_pyobjc.lua). Declining, or a failed install, still
--- opens App Cloner, which says itself what it lacks.
---
--- FEATURES & RATIONALE:
--- 1. Asked, Never Silent: the install downloads about a megabyte of signed
---    wheels and, the first time, Ergopti's managed Python, so it waits for the
---    click on « Install ».
--- 2. Reported: the installing notice and a failure's reason reach the user; a
---    failure's dialog is deferred to the timer scheduler, since the result
---    arrives from a task callback where no modal dialog may run.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")
local i18n   = require("core.i18n.engine.i18n")

local LOG = "app_cloner_python_offer"

--- The environment variable App Cloner reads its interpreter from.
M.ENV = "ERGOPTI_CLONER_PYTHON"

-- The system folders that follow the managed Python's on App Cloner's PATH:
-- its launcher starts as `/usr/bin/env python3`, which must find the managed
-- link first, and its scripts call the system tools by name.
local SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"

--- The launch environment that runs App Cloner on the managed Python.
--- @param link string The versionless managed Python link.
--- @return table environment `KEY=VALUE` entries.
function M.environment(link)
	assert(type(link) == "string" and link:match("^/.+/python3$"), "the managed Python link must be an absolute python3")
	return { M.ENV .. "=" .. link, "PATH=" .. link:match("^(.+)/python3$") .. ":" .. SYSTEM_PATH }
end

--- Shows a failed install on the timer scheduler, then calls next.
--- @param reason string Stable refusal reason.
--- @param next_step function Continuation.
local function report_failure(reason, next_step)
	local committed = require("core.timing.engine.deferred_work").after(0, function()
		local shown, err = pcall(function()
			require("infra.dialog_util").block_alert(i18n.get("apps.cloner.python_offer.title"),
				i18n.format("apps.cloner.python_offer.failed", tostring(reason)), i18n.get("common.ok"))
		end)
		if not shown then Logger.error(LOG, "The App Cloner Python failure dialog failed: %s.", tostring(err)) end
		next_step()
	end, "app_cloner_python_offer.failure")
	if committed ~= true then
		Logger.error(LOG, "The App Cloner Python failure could not be shown (%s).", tostring(reason))
		next_step()
	end
end

--- Opens App Cloner, installing the managed PyObjC first when the user agrees.
--- @param owner table modules/llm/managed_pyobjc owner { ready, link, install }.
--- @param launch function fn(environment) opening App Cloner with extra `KEY=VALUE` entries.
function M.open(owner, launch)
	assert(type(owner) == "table" and type(launch) == "function", "app_cloner_python_offer.open needs an owner and a launch")
	if owner.ready() then
		return launch(M.environment(owner.link()))
	end
	local install = i18n.get("apps.cloner.python_offer.install")
	local clicked = require("infra.dialog_util").block_alert(i18n.get("apps.cloner.python_offer.title"),
		i18n.get("apps.cloner.python_offer.body"), install, i18n.get("common.later"), "informational")
	if clicked ~= install then
		Logger.info(LOG, "Managed PyObjC install declined; App Cloner opens without it.")
		return launch({})
	end
	Logger.info(LOG, "Managed PyObjC install accepted for App Cloner.")
	local notified = pcall(function()
		return require("infra.notifications").notify(i18n.get("apps.cloner.python_offer.installing"), nil, "info")
	end)
	if not notified then Logger.error(LOG, "The App Cloner Python install notice failed.") end
	owner.install(function(ok, value)
		if ok then return launch(M.environment(value)) end
		report_failure(value, function() launch({}) end)
	end)
end

return M
