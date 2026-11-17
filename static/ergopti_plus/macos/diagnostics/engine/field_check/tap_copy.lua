--- diagnostics/engine/field_check/tap_copy.lua

--- ==============================================================================
--- MODULE: Field Check, Tap-Hold Copy
--- DESCRIPTION:
--- The field run's account of the copy a tap-hold key sends (Left Shift tapped
--- = Cmd+C by default) on the Mac it runs on, the only place that shows
--- whether a copy reaches a real application: the lone tap window Karabiner
--- was given, whether the pasteboard counter the copy check relies on can be
--- read, and what happened to every watched copy tap since the driver started
--- (modules/keymap/tap_copy.lua statistics).
---
--- FEATURES & RATIONALE:
--- 1. Nothing is typed and the clipboard is never written: the run reads what
---    the user's own taps did, so it can never copy over the user's clipboard.
--- 2. One step per question a missed copy raises: was the window deployed,
---    can the counter be read, how many copies were sent, verified, landed only
---    on the retry or never, and how many taps sent no Cmd+C, held past the
---    timeout or cancelled within it, with their press durations.
--- 3. A copy that never landed, even once sent again, fails the check; the
---    rest is information for the report.
--- ==============================================================================

local Report = require("diagnostics.engine.field_check.report")
local CopyCheck = require("tap_hold.engine.copy_check")

local M = {}

local PASS, FAIL, INFO, SKIP = Report.STATE_PASS, Report.STATE_FAIL, Report.STATE_INFO, Report.STATE_SKIP

-- The most recent press durations a step value carries: a value is at most
-- Report.MAX_VALUE_LENGTH characters of the closed grammar (no comma).
local DURATIONS_SHOWN = 5

--- Joins the most recent press durations for a report value.
--- @param list table|nil Milliseconds.
--- @return string
local function durations(list)
	if type(list) ~= "table" or #list == 0 then return "none" end
	local parts = {}
	for index = math.max(1, #list - DURATIONS_SHOWN + 1), #list do parts[#parts + 1] = tostring(list[index]) end
	return table.concat(parts, "+")
end

--- Runs the check.
--- ports.tap_copy_facts() -> {
---   window_ms = number|nil, the configured lone tap window,
---   keys = { { id, deployed_ms, eligible } }, the keys whose tap is copy,
---   change_count = number|nil, the pasteboard counter read now,
---   stats = table|nil, the watch statistics (nil when the keymap is not running),
--- }
--- @param ports table
--- @param report table field_check_report report.
--- @param finish function
function M.tap_copy(ports, report, finish)
	local facts = ports.tap_copy_facts()
	if type(facts.stats) ~= "table" then
		report.step("copy_watch", FAIL, "keymap_not_started")
		return finish()
	end
	report.step("copy_watch", PASS)

	local keys = facts.keys or {}
	if #keys == 0 then
		report.step("copy_window", SKIP, "no_copy_tap")
	elseif facts.deployed == false then
		-- No configuration was generated this session (the owned runtime not
		-- admitted yet): there is no deployed delay to compare, which the owned_*
		-- and lease steps already report (field report 2026-11-06).
		report.step("copy_window", SKIP, "not_deployed")
	else
		local window = facts.window_ms
		local short = nil
		local described = {}
		for _, key in ipairs(keys) do
			described[#described + 1] = tostring(key.id) .. ":" .. tostring(key.deployed_ms)
			if key.eligible and type(window) == "number" and window > 0
				and (type(key.deployed_ms) ~= "number" or key.deployed_ms < window) then
				short = short or key.id
			end
		end
		local value = "w" .. tostring(window) .. ":" .. table.concat(described, "+")
		if short then
			report.step("copy_window", FAIL, "short:" .. value)
		else
			report.step("copy_window", PASS, value)
		end
	end

	if type(facts.change_count) == "number" then
		report.step("copy_counter", PASS, tostring(facts.change_count))
	else
		report.step("copy_counter", FAIL, "unreadable")
	end

	local stats = facts.stats
	local outcomes = stats.outcomes or {}
	local lost = (outcomes[CopyCheck.NOT_COPIED] or 0) + (outcomes[CopyCheck.RETRY_REFUSED] or 0)
	report.step("copies_sent", INFO, tostring(stats.sent or 0) .. ":held_" .. durations(stats.held_ms))
	report.step("copies_verified", INFO, tostring(outcomes[CopyCheck.COPIED] or 0))
	report.step("copies_on_retry", INFO, tostring(outcomes[CopyCheck.COPIED_ON_RETRY] or 0))
	report.step("copies_unchecked", INFO, tostring(outcomes[CopyCheck.COUNTER_UNREADABLE] or 0))
	report.step("taps_without_copy", INFO, "past_" .. tostring(stats.missing_past or 0)
		.. ":within_" .. tostring(stats.missing_within or 0) .. ":held_" .. durations(stats.missing_held_ms))
	if lost > 0 then
		report.step("copies_lost", FAIL, tostring(lost))
	else
		report.step("copies_lost", PASS, "0")
	end
	finish()
end

return M
