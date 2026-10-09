--- _shared/lua/healthcheck/cleanup.lua

--- ==============================================================================
--- MODULE: Diagnostic Cleanup Receipts
--- DESCRIPTION:
--- Keeps cancelled actors reachable until their own native settlement receipts.
--- Refresh and export observe cleanup separately from the sticky business result.
--- ==============================================================================

local M = {}

--- Reobserves current and archived actors without changing a business result.
--- @param session table Diagnostics session with its exact probe owners.
function M.refresh(session)
	if session.probes and session.probes.refresh_cleanup then session.probes.refresh_cleanup() end
	local history = session.probe_history or {}
	local rows = {}
	for _, cohort in ipairs(history) do
		if cohort.run and cohort.run.refresh_cleanup then cohort.run.refresh_cleanup() end
		if cohort.run and cohort.run.has_pending_cleanup and cohort.run.has_pending_cleanup() == false then
			cohort.run = nil
		end
		rows[#rows + 1] = { probes = cohort.probes }
	end
	session.snapshot.retired_probes = rows
end

--- Requests cancellation, retaining the actor and its exact observed result.
--- @param session table Diagnostics session.
function M.cancel(session)
	local run = session.probes
	if run then
		run.cancel()
		if run.refresh_cleanup then run.refresh_cleanup() end
	end
	-- Refreshed cohorts keep their exact actors until physical settlement too.
	for _, cohort in ipairs(session.probe_history or {}) do
		if cohort.run then
			cohort.run.cancel()
			if cohort.run.refresh_cleanup then cohort.run.refresh_cleanup() end
		end
	end
	for id, result in pairs(session.snapshot.probes) do
		if result.state == "pending" then
			local observed = run and run.results and run.results[id]
			session.snapshot.probes[id] = observed or { state = "cancelled", cleanup = "pending" }
			if session.snapshot.probes[id].cleanup == nil then session.snapshot.probes[id].cleanup = "pending" end
		end
	end
	M.refresh(session)
end

--- Archives a cancelled cohort before the host replaces its snapshot.
--- @param session table Diagnostics session.
function M.archive(session)
	if not session.probes then return end
	M.cancel(session)
	session.probe_history = session.probe_history or {}
	session.probe_history[#session.probe_history + 1] = { run = session.probes, probes = session.snapshot.probes }
	session.probes = nil
	M.refresh(session)
end

return M
