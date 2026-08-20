--- infra/startup_transaction.lua

--- ==============================================================================
--- MODULE: Ordered Startup Transaction
--- DESCRIPTION:
--- Starts related input subsystems in a fixed order and rolls back every native
--- owner when one step raises or refuses activation.
---
--- FEATURES & RATIONALE:
--- 1. Exact Commit Contract: Required steps succeed only on literal `true`.
--- 2. Optional Capability: A step may explicitly use nil to mean unavailable.
--- 3. Mutation-Safe Rollback: The failing step is cleaned before prior owners.
--- 4. Failure Visibility: Every refusal, exception, and cleanup debt is logged.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "infra.startup_transaction"





-- ======================================
-- ======================================
-- ======= 1/ Transaction Helpers =======
-- ======================================
-- ======================================

--- Validates the complete transaction before the first start callback runs.
--- @param steps table[] Ordered startup descriptors.
--- @return boolean valid True only when every descriptor is safe to execute.
local function validate_steps(steps)
	if type(steps) ~= "table" or #steps == 0 then
		Logger.error(LOG, "Startup transaction requires at least one step.")
		return false
	end

	local names = {}
	for index, step in ipairs(steps) do
		if type(step) ~= "table" or type(step.name) ~= "string" or step.name == ""
			or type(step.start) ~= "function" or type(step.stop) ~= "function" then
			Logger.error(LOG, "Startup step %d is malformed.", index)
			return false
		end
		if names[step.name] then
			Logger.error(LOG, "Startup step name '%s' is duplicated.", step.name)
			return false
		end
		if step.allow_unavailable ~= nil and type(step.allow_unavailable) ~= "boolean" then
			Logger.error(LOG, "Startup step '%s' has an invalid availability contract.", step.name)
			return false
		end
		names[step.name] = true
	end
	return true
end

--- Runs one cleanup callback and reports whether ownership was settled.
--- @param step table Startup descriptor containing name and stop callback.
--- @return boolean settled True only on the exact cleanup commit value.
local function settle_step(step)
	local ok, result_or_err = xpcall(step.stop, debug.traceback)
	if not ok or result_or_err ~= true then
		Logger.error(LOG, "Startup rollback for '%s' did not settle: %s.",
			step.name, tostring(result_or_err))
		return false
	end
	return true
end

--- Rolls back the failing step, then every committed predecessor in reverse.
--- @param failed_step table Descriptor whose start callback refused or raised.
--- @param committed table[] Successfully started descriptors.
--- @return boolean settled True only when every cleanup committed.
local function rollback(failed_step, committed)
	local settled = settle_step(failed_step)
	for index = #committed, 1, -1 do
		if not settle_step(committed[index]) then settled = false end
	end
	return settled
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Starts every descriptor as one all-or-nothing transaction.
--- A nil result is accepted only for a step explicitly declaring that its
--- platform capability is optional; such a step owns nothing and is not rolled
--- back if a later step fails.
--- @param steps table[] Ordered `{name,start,stop,allow_unavailable?}` entries.
--- @return boolean committed True only when every required step committed.
function M.run(steps)
	if not validate_steps(steps) then return false end

	local committed = {}
	for _, step in ipairs(steps) do
		local ok, result_or_err = xpcall(step.start, debug.traceback)
		local unavailable = ok and result_or_err == nil and step.allow_unavailable == true
		if ok and result_or_err == true then
			committed[#committed + 1] = step
		elseif not unavailable then
			Logger.error(LOG, "Startup step '%s' did not commit: %s.",
				step.name, tostring(result_or_err))
			rollback(step, committed)
			return false
		end
	end

	return true
end

return M
