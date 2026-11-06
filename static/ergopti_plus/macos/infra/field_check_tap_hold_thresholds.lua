--- infra/field_check_tap_hold_thresholds.lua

--- ==============================================================================
--- MODULE: Field Check, Deployed Tap-Hold Thresholds
--- DESCRIPTION:
--- The field run's check that the Karabiner configuration really deployed on
--- this Mac carries the tap-hold delays the shared model asks for (PAR-15): a
--- key with its own delay keeps it, every other key follows the global delay.
--- The unit tests pin the generator; only the deployed file shows that nothing
--- between the generator and Karabiner (the merge into the user's file, the
--- owned deploy, a stale deploy) changed a threshold.
---
--- FEATURES & RATIONALE:
--- 1. Managed Rules Only: only the rules whose description carries the managed
---    tag are read, so the user's own rules never count as a mismatch.
--- 2. Every Tap Manipulator: each managed manipulator with `to_if_alone` on a
---    tap-hold key must carry the expected `to_if_alone_timeout`, and its
---    held-down threshold, when present, the same value.
--- 3. Named Results: the report carries counts and the first mismatching key id,
---    never a rule text.
--- ==============================================================================

local Report = require("field_check_report")

local M = {}

local PASS, FAIL, INFO, SKIP = Report.STATE_PASS, Report.STATE_FAIL, Report.STATE_INFO, Report.STATE_SKIP

local TAP_PARAMETER = "basic.to_if_alone_timeout_milliseconds"
local HELD_PARAMETER = "basic.to_if_held_down_threshold_milliseconds"

--- Compares the managed tap manipulators of a decoded configuration with the
--- expected delays.
--- @param config table Decoded karabiner.json.
--- @param expected table Map key_code -> { id, ms } of every tap-hold key.
--- @param tag string The managed tag every managed rule description opens with.
--- @return table result { checked, mismatches = { { id, expected, actual } } }.
function M.compare(config, expected, tag)
	assert(type(expected) == "table", "the expected delays are required")
	assert(type(tag) == "string" and tag ~= "", "the managed tag is required")
	local result = { checked = 0, mismatches = {} }
	local marker = "[" .. tag .. ":"
	for _, profile in ipairs(type(config) == "table" and type(config.profiles) == "table" and config.profiles or {}) do
		local complex = type(profile) == "table" and profile.complex_modifications
		for _, rule in ipairs(type(complex) == "table" and type(complex.rules) == "table" and complex.rules or {}) do
			if type(rule) == "table" and type(rule.description) == "string"
				and rule.description:sub(1, #marker) == marker and type(rule.manipulators) == "table" then
				for _, manipulator in ipairs(rule.manipulators) do
					local from = type(manipulator) == "table" and manipulator.from
					local key = type(from) == "table" and expected[from.key_code]
					if key and type(manipulator.to_if_alone) == "table" then
						result.checked = result.checked + 1
						local parameters = type(manipulator.parameters) == "table" and manipulator.parameters or {}
						local actual = parameters[TAP_PARAMETER]
						local held = parameters[HELD_PARAMETER]
						if actual ~= key.ms or (held ~= nil and held ~= key.ms) then
							result.mismatches[#result.mismatches + 1] = {
								id = key.id, expected = key.ms, actual = actual ~= key.ms and actual or held,
							}
						end
					end
				end
			end
		end
	end
	return result
end

--- The field check.
--- ports.tap_hold_threshold_facts() -> { enabled, config (decoded table or nil),
--- reason (why config is nil: owned_runtime_not_ready, not_deployed, unreadable
--- or not_json), expected (as M.compare), tag }.
function M.tap_hold_thresholds(ports, report, finish)
	local facts = ports.tap_hold_threshold_facts()
	if facts.enabled ~= true then
		report.step("thresholds_config", SKIP, "integration_off")
		return finish()
	end
	-- No deployed file while the owned runtime waits for its install or start:
	-- the owned_* steps fail for that; nothing here can be judged.
	if facts.reason == "owned_runtime_not_ready" then
		report.step("thresholds_config", SKIP, facts.reason)
		return finish()
	end
	if type(facts.config) ~= "table" then
		report.step("thresholds_config", FAIL, facts.reason or "unreadable")
		return finish()
	end
	report.step("thresholds_config", PASS)
	local result = M.compare(facts.config, facts.expected, facts.tag)
	report.step("thresholds_checked", INFO, result.checked)
	if result.checked == 0 then
		report.step("thresholds_match", SKIP, "no_managed_tap_hold")
		return finish()
	end
	local first = result.mismatches[1]
	if first then
		report.step("thresholds_match", FAIL, "mismatch_" .. #result.mismatches .. ":" .. tostring(first.id)
			.. ":" .. tostring(first.actual) .. "_not_" .. tostring(first.expected))
	else
		report.step("thresholds_match", PASS)
	end
	finish()
end

return M
