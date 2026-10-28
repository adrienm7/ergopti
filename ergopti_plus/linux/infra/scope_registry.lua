--- infra/scope_registry.lua

--- ==============================================================================
--- MODULE: Scope Owner Registry (Linux)
--- DESCRIPTION:
--- The one place that answers « is any configuration scope write still
--- pending? ». Each scope module registers a probe over the owner it already
--- keeps, and the tray's Quit asks the registry, as the macOS global writer
--- fence does for every category.
---
--- FEATURES & RATIONALE:
--- 1. Existing Owners Only: a probe reads the `pending()` of the transaction a
---    module already retains; no owner gains state for the registry's sake.
--- 2. Named And Replaceable: a probe is keyed by its scope name, so a module
---    loaded again (tests, a fresh owner) replaces its own probe, never adds a
---    second one.
--- 3. A Broken Probe Never Traps The User: a probe that raises is logged and
---    read as not pending, because refusing Quit forever on a defect is worse
---    than the write it failed to report.
--- ==============================================================================

local Logger = require("logger.shim")

local M = {}

local LOG = "infra.scope_registry"

local probes = {}

--- Registers the pending probe of one scope.
--- @param name string Scope name, for the log and for replacement.
--- @param probe function Returns true while that scope's write or rollback is pending.
function M.register(name, probe)
	assert(type(name) == "string" and name ~= "", "a scope probe needs a name")
	assert(type(probe) == "function", "a scope probe needs a function")
	probes[name] = probe
end

--- Lists every registered scope, pending or not.
--- @return table names Sorted scope names.
function M.names()
	return require("table_util").sorted_keys(probes)
end

--- Lists the scopes whose write or rollback is still pending.
--- @return table names Sorted scope names.
function M.pending_names()
	local names = {}
	for name, probe in pairs(probes) do
		local ok, pending = pcall(probe)
		if not ok then
			Logger.error(LOG, "The pending probe of scope '%s' raised: %s.", name, tostring(pending))
		elseif pending == true then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	return names
end

--- Whether any registered scope still has a pending write or rollback.
--- @return boolean pending
function M.pending()
	return #M.pending_names() > 0
end

--- Test seam: forgets every probe.
function M._reset_for_test()
	probes = {}
end

return M
