--- infra/field_check_local_servers.lua

--- ==============================================================================
--- MODULE: Field Check, Local AI Servers
--- DESCRIPTION:
--- The field run's read-only look at every local server of
--- _shared/modules/llm/local_servers.json: the catalogue the driver loaded, then
--- one detection sweep (the AI menu's own: process, settings file, listening
--- port, then the models endpoint) and, per server, where it was looked for and
--- what answered. Nothing is installed, started, chosen or saved.
---
--- FEATURES & RATIONALE:
--- 1. The catalogue step fails when a declared server has no usable discovery
---    descriptor: such a server is never probed on this Mac, which only the
---    driver's own reading of the shared list can show.
--- 2. One step per declared server, so a server added to the shared list is
---    reported by the next field run with no change here.
--- 3. A server that is not running is information, never a failure: the Mac
---    under test runs whichever servers its owner installed.
--- ==============================================================================

local Report = require("field_check_report")
local Logger = require("infra.logger")

local M = {}

local LOG = "field_check.local_servers"
local PASS, FAIL, INFO = Report.STATE_PASS, Report.STATE_FAIL, Report.STATE_INFO

--- The value of one server's step: its verdict, where its port came from and,
--- when it answered, how many models it lists.
--- @param view table|nil From api_remote.local_server_views().
--- @return string value
function M.server_value(view)
	if type(view) ~= "table" then return "not_swept" end
	local parts = { view.status == "up" and "up" or tostring(view.reason or view.status or "unknown") }
	if view.port_source ~= nil then parts[#parts + 1] = tostring(view.port_source) end
	if view.status == "up" then parts[#parts + 1] = tostring(type(view.models) == "table" and #view.models or 0) end
	return table.concat(parts, ":")
end

--- Runs the check.
--- ports.local_server_catalogue() -> { order, discovery, published };
--- ports.local_servers_detect(on_done(views|nil)) runs one sweep.
--- @param ports table
--- @param report table
--- @param finish function
function M.local_servers(ports, report, finish)
	local catalogue = ports.local_server_catalogue()
	local undescribed = 0
	for _, id in ipairs(catalogue.order) do
		if catalogue.discovery[id] == nil then
			undescribed = undescribed + 1
			Logger.evidence(LOG, "Local server '%s' has no usable discovery descriptor.", id)
		end
	end
	if catalogue.published ~= true then
		report.step("servers_catalogue", FAIL, "unpublished")
	elseif undescribed > 0 then
		report.step("servers_catalogue", FAIL, "undescribed_" .. undescribed)
	else
		report.step("servers_catalogue", PASS, #catalogue.order)
	end
	ports.local_servers_detect(function(views)
		if type(views) ~= "table" then
			report.step("servers_sweep", FAIL, "refused")
			return finish()
		end
		report.step("servers_sweep", PASS)
		local by_id, found = {}, 0
		for _, view in ipairs(views) do by_id[view.id] = view end
		for _, id in ipairs(catalogue.order) do
			local view = by_id[id]
			if view and view.status == "up" then found = found + 1 end
			Logger.evidence(LOG, "Local server '%s': %s (port %s from %s).", id, M.server_value(view),
				tostring(view and view.port), tostring(view and view.port_source))
			report.step("server_" .. id, INFO, M.server_value(view))
		end
		report.step("servers_found", INFO, found)
		finish()
	end)
end

return M
