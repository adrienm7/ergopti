--- infra/field_run_guided.lua

--- ==============================================================================
--- MODULE: Developer Field Run, Guided Steps
--- DESCRIPTION:
--- The field run's steps that need one gesture of the person at the Mac (TODO,
--- To confirm on the Mac): a Wi-Fi switch, a window moved, Ctrl+Caps Lock
--- pressed, a menu row looked at. The step publishes the exact gesture in a
--- prompt file the collector prints in its terminal, waits for it under its
--- own bound, and records what happened. The contract (the prompt and answer
--- files, the poll period, each step's gesture) is data/field_run.json.
---
--- FEATURES & RATIONALE:
--- 1. Observed, not asked, whenever the app can see the outcome. An "observe"
---    step reads a field check once before the prompt (the baseline), then again
---    every poll until each named report step rose above its baseline (a count
---    such as capslock_chord_presses) or turned to a failure. The verdict is
---    then the check's own; a count named "steady" that rose fails the step.
--- 2. Asked only when the outcome is what a person sees (a menu row, a page in
---    dark mode, a tap typed on the internal keyboard, which Karabiner takes
---    below the event system): an "attest" step waits for the person's
---    pass, fail or skip answer that the collector writes, and still runs its
---    named check for evidence. A failed check overrides a pass answer.
--- 3. Nothing is silently skipped: no gesture within the bound is needs_person
---    with gesture_not_observed_<n>s (or no_answer_<n>s), and a person's skip is
---    skip with skipped_by_person. Each settles once and removes its prompt.
--- 4. Ports only: no file system, timer or Hammerspoon call of its own, so the
---    portable suite drives it over the field run's in-memory world.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local Json = require("json")

local LOG = "field_run"

--- How a guided step learns its outcome.
M.MODES = { observe = true, attest = true }

--- The answers the collector may write.
M.ANSWERS = { pass = true, fail = true, skip = true }

--- The observe conditions: every named report step rose above its baseline.
M.CONDITION_RISES = "rises"

-- A gesture needs at least this long to be read and done.
M.MIN_GESTURE_SECONDS = 10

-- Seconds the step's deadline keeps beyond the gesture bound for the last check.
M.CHECK_MARGIN_SECONDS = 20





-- ==============================
-- ==============================
-- ======= 1/ Declaration =======
-- ==============================
-- ==============================

local function is_integer(value)
	return type(value) == "number" and value == math.floor(value)
end

local function is_name_list(list)
	if type(list) ~= "table" or #list == 0 then return false end
	for _, name in ipairs(list) do
		if type(name) ~= "string" or not name:match("^[a-z][a-z0-9_]*$") then return false end
	end
	return true
end

--- Validates the guided section of the declaration.
--- @param guided any spec.guided
function M.validate_section(guided)
	if type(guided) ~= "table" then error("field run: the guided section is missing", 3) end
	for _, key in ipairs({ "prompt", "answer" }) do
		if type(guided[key]) ~= "string" or not guided[key]:match("^[%w_.]+$") then
			error("field run: guided." .. key .. " must be a plain file name", 3)
		end
	end
	if not is_integer(guided.poll_seconds) or guided.poll_seconds < 1 then
		error("field run: guided.poll_seconds must be a positive integer", 3)
	end
end

--- Validates one guided step; a malformed one stops the declaration.
--- @param step table Step declaration.
function M.validate_step(step)
	local where = "field run: guided step " .. tostring(step.id)
	if not M.MODES[step.mode] then error(where .. " has an unknown mode", 3) end
	if type(step.gesture) ~= "string" or not step.gesture:match("%S") then
		error(where .. " says no gesture", 3)
	end
	if not is_integer(step.gesture_seconds) or step.gesture_seconds < M.MIN_GESTURE_SECONDS
		or step.deadline_seconds < step.gesture_seconds + M.CHECK_MARGIN_SECONDS then
		error(where .. " needs gesture_seconds of at least " .. M.MIN_GESTURE_SECONDS
			.. " and a deadline " .. M.CHECK_MARGIN_SECONDS .. " s beyond it", 3)
	end
	if step.check ~= nil and type(step.check) ~= "string" then error(where .. " names a check that is not a name", 3) end
	if step.mode == "observe" then
		local condition = step["until"]
		if type(step.check) ~= "string" then error(where .. " observes no check", 3) end
		if type(condition) ~= "table" or condition.condition ~= M.CONDITION_RISES or not is_name_list(condition.steps) then
			error(where .. " needs until = { condition = \"rises\", steps = [...] }", 3)
		end
		if condition.steady ~= nil and not is_name_list(condition.steady) then
			error(where .. " has a steady list that is not a list of report steps", 3)
		end
	elseif step["until"] ~= nil then
		error(where .. " attests and so observes nothing", 3)
	end
end





-- ===============================
-- ===============================
-- ======= 2/ Observations =======
-- ===============================
-- ===============================

--- The leading count of a report value ("12", "4:mouseMoved", "delivered:2").
--- @param value any
--- @return number|nil
function M.leading_number(value)
	if type(value) == "number" then return value end
	local digits = tostring(value or ""):match("^(%d+)")
	if digits then return tonumber(digits) end
	digits = tostring(value or ""):match("^[%a_]+:(%d+)")
	return digits and tonumber(digits) or nil
end

--- Indexes a check result's report steps by id.
--- @param report any The result of infra.field_check (steps = { {id, state, value} }).
--- @return table steps id → { state, value }
function M.steps_of(report)
	local steps = {}
	local list = type(report) == "table" and report.steps or nil
	for _, item in ipairs(type(list) == "table" and list or {}) do
		if type(item) == "table" and type(item.id) == "string" then steps[item.id] = item end
	end
	return steps
end

local function rose(before, now)
	local base = before and M.leading_number(before.value) or 0
	local current = now and M.leading_number(now.value) or nil
	return current ~= nil and current > (base or 0)
end

--- Whether the gesture happened, read from a baseline and a current report.
--- @param condition table step.until
--- @param baseline table steps_of(baseline report)
--- @param current table steps_of(current report)
--- @return boolean observed
--- @return table codes Closed codes: rose_<steady step> for each steady count that rose.
function M.observe(condition, baseline, current)
	local all_rose, turned_failed = true, false
	for _, id in ipairs(condition.steps) do
		local now = current[id]
		if now and now.state == "fail" and not (baseline[id] and baseline[id].state == "fail") then
			turned_failed = true
		elseif not rose(baseline[id], now) then
			all_rose = false
		end
	end
	local codes = {}
	for _, id in ipairs(condition.steady or {}) do
		if rose(baseline[id], current[id]) then codes[#codes + 1] = "rose_" .. id end
	end
	return all_rose or turned_failed, codes
end





-- ==========================
-- ==========================
-- ======= 3/ Running =======
-- ==========================
-- ==========================

--- Runs one guided step.
--- @param step table The validated step declaration.
--- @param ctx table { prompt_path, answer_path, request_id, schema, poll_seconds, active = fn():boolean,
---   ports = { write, read, remove, after, cancel, now_ms }, run_check = fn(check, cb(verdict, codes, report)) }
--- @param finish function fn(verdict, codes, report), called once.
function M.run(step, ctx, finish)
	local ports = ctx.ports
	local settled, timer = false, nil
	local deadline_ms = ports.now_ms() + step.gesture_seconds * 1000
	local last_report = nil

	local function settle(verdict, codes, report)
		if settled then return end
		settled = true
		if timer then pcall(ports.cancel, timer); timer = nil end
		pcall(ports.remove, ctx.prompt_path)
		pcall(ports.remove, ctx.answer_path)
		Logger.info(LOG, "Guided step '%s' settled: %s (%s).", step.id, verdict, table.concat(codes, ","))
		finish(verdict, codes, report or last_report)
	end

	--- The person's answer for this step, or nil; a foreign or malformed answer is dropped.
	local function take_answer()
		local text, status = ports.read(ctx.answer_path)
		if status ~= "ok" or type(text) ~= "string" then return nil end
		pcall(ports.remove, ctx.answer_path)
		local ok, answer = pcall(Json.decode, text)
		if not ok or type(answer) ~= "table" or answer.step ~= step.id or not M.ANSWERS[answer.answer] then
			Logger.warn(LOG, "Guided step '%s' dropped an answer for another step or outside pass, fail, skip.", step.id)
			return nil
		end
		return answer.answer
	end

	local function check(callback)
		ctx.run_check(step.check, function(verdict, codes, report)
			last_report = report
			callback(verdict, codes, report)
		end)
	end

	local function publish_prompt()
		local answers = step.mode == "attest" and { "pass", "fail", "skip" } or { "skip" }
		local written = ports.write(ctx.prompt_path, Json.encode({
			schema = ctx.schema, request_id = ctx.request_id, step = step.id, mode = step.mode,
			gesture = step.gesture, seconds = step.gesture_seconds, answers = Json.array(answers),
		}) .. "\n")
		if written ~= true then
			settle("fail", { "prompt_unwritten" })
			return false
		end
		Logger.info(LOG, "Guided step '%s' waits up to %d s for the person's gesture.", step.id, step.gesture_seconds)
		return true
	end

	local function schedule(fn)
		timer = ports.after(ctx.poll_seconds, function()
			timer = nil
			if settled then return end
			if not ctx.active() then
				settled = true
				pcall(ports.remove, ctx.prompt_path)
				return
			end
			fn()
		end)
	end

	local function timed_out()
		return ports.now_ms() >= deadline_ms
	end

	local function attest_loop()
		local answer = take_answer()
		if answer == nil then
			if timed_out() then return settle("needs_person", { "no_answer_" .. step.gesture_seconds .. "s" }) end
			return schedule(attest_loop)
		end
		if answer == "skip" then return settle("skip", { "skipped_by_person" }) end
		if step.check == nil then return settle(answer, { "attested_" .. answer }) end
		check(function(verdict, codes, report)
			if settled then return end
			local all = { "attested_" .. answer }
			for _, code in ipairs(type(codes) == "table" and codes or {}) do all[#all + 1] = code end
			if verdict ~= "pass" then
				all[#all + 1] = "evidence_" .. tostring(verdict)
				return settle("fail", all, report)
			end
			settle(answer, all, report)
		end)
	end

	local function observe_loop(baseline)
		if take_answer() == "skip" then return settle("skip", { "skipped_by_person" }) end
		check(function(verdict, codes, report)
			if settled then return end
			local observed, steady = M.observe(step["until"], baseline, M.steps_of(report))
			if observed then
				local all = { "gesture_observed" }
				for _, code in ipairs(type(codes) == "table" and codes or {}) do all[#all + 1] = code end
				for _, code in ipairs(steady) do all[#all + 1] = code end
				return settle(#steady > 0 and "fail" or verdict, all, report)
			end
			if timed_out() then
				return settle("needs_person", { "gesture_not_observed_" .. step.gesture_seconds .. "s" }, report)
			end
			schedule(function() observe_loop(baseline) end)
		end)
	end

	-- A stale answer from an earlier step must not answer this one
	pcall(ports.remove, ctx.answer_path)
	if step.mode == "attest" then
		if publish_prompt() then schedule(attest_loop) end
		return
	end
	check(function(_, _, report)
		if settled then return end
		local baseline = M.steps_of(report)
		if publish_prompt() then schedule(function() observe_loop(baseline) end) end
	end)
end

return M
