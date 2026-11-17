--- tests/unit/diagnostics/engine/field_run/test_guided.lua

--- ==============================================================================
--- MODULE: Field Run Guided Steps Tests
--- DESCRIPTION:
--- The guided steps of the developer field run (diagnostics/engine/field_run/guided.lua)
--- prompt one gesture through the collector and record its outcome. These
--- cases drive the runner over an in-memory world: an observed gesture takes
--- the check's verdict, a count meant to stay steady that rose fails, no
--- gesture is needs_person with its bound, a person's skip or answer is
--- recorded by name, a failed evidence check overrides a pass answer, and the
--- prompt never outlives its step. The shipped declaration is validated too.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

local MODULES = { "core.logger.engine.logger", "diagnostics.engine.field_run.guided" }
local PROMPT, ANSWER = "/run/prompt.json", "/run/answer.json"

local function load()
	package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
	package.loaded["diagnostics.engine.field_run.guided"] = nil
	return require("diagnostics.engine.field_run.guided")
end

--- A world with files, a manual clock and a scripted check.
--- @param reports table Successive check reports; the last one repeats.
local function world(reports)
	local state = { files = {}, now = 0, timers = {}, checks = 0, prompts = {} }
	state.ports = {
		write = function(path, text)
			state.files[path] = text
			if path == PROMPT then state.prompts[#state.prompts + 1] = Json.decode(text) end
			return true
		end,
		read = function(path)
			if state.files[path] == nil then return nil, "absent" end
			return state.files[path], "ok"
		end,
		remove = function(path) state.files[path] = nil; return true end,
		after = function(seconds, fn)
			local handle = { at = state.now + seconds * 1000, fn = fn }
			state.timers[#state.timers + 1] = handle
			return handle
		end,
		cancel = function(handle) handle.cancelled = true end,
		now_ms = function() return state.now end,
	}
	state.ctx = {
		prompt_path = PROMPT, answer_path = ANSWER, request_id = "r1", schema = 1, poll_seconds = 3,
		active = function() return state.inactive ~= true end,
		ports = state.ports,
		run_check = function(check, callback)
			state.checks = state.checks + 1
			state.check_name = check
			local report = reports[math.min(state.checks, #reports)]
			callback(report.verdict or "pass", report.codes or {}, report)
		end,
	}
	function state.advance(ms)
		local limit = state.now + ms
		while true do
			local due, index = nil, nil
			for i, handle in ipairs(state.timers) do
				if not handle.cancelled and handle.at <= limit and (due == nil or handle.at < due.at) then
					due, index = handle, i
				end
			end
			if not due then break end
			table.remove(state.timers, index)
			state.now = math.max(state.now, due.at)
			due.fn()
		end
		state.now = limit
	end
	function state.answer(step, answer)
		state.files[ANSWER] = Json.encode({ step = step, answer = answer })
	end
	return state
end

local function report(steps, verdict)
	local list = {}
	for id, value in pairs(steps) do
		list[#list + 1] = { id = id, state = type(value) == "table" and value[1] or "info",
			value = type(value) == "table" and value[2] or value }
	end
	return { steps = list, verdict = verdict }
end

local OBSERVE = {
	id = "guided_capslock_chord", kind = "guided", mode = "observe", check = "capslock_chord",
	["until"] = { condition = "rises", steps = { "capslock_chord_presses" } },
	gesture_seconds = 30, deadline_seconds = 60, gesture = "Press Ctrl+Caps Lock once.",
}

local function run(Guided, step, state)
	local outcome = {}
	Guided.run(step, state.ctx, function(verdict, codes, result)
		outcome.count = (outcome.count or 0) + 1
		outcome.verdict, outcome.codes, outcome.report = verdict, codes, result
	end)
	return outcome
end





helpers.describe("field run guided: observed gestures", function()
	helpers.it("prompts the gesture once, then takes the check's verdict when the count rose", function()
		helpers.with_stub_scope(MODULES, function()
			local Guided = load()
			local state = world({
				report({ capslock_chord_presses = "2" }),
				report({ capslock_chord_presses = "2" }),
				report({ capslock_chord_presses = "3", capslock_chord_delivered = { "pass", "delivered:1" } }),
			})
			local outcome = run(Guided, OBSERVE, state)
			helpers.assert_eq(#state.prompts, 1, "one prompt before the first poll")
			helpers.assert_eq(state.prompts[1].step, OBSERVE.id)
			helpers.assert_eq(state.prompts[1].gesture, OBSERVE.gesture)
			helpers.assert_eq(state.prompts[1].seconds, 30)
			helpers.assert_eq(state.prompts[1].answers, { "skip" })
			helpers.assert_nil(outcome.verdict, "a baseline is not an observation")
			state.advance(3000)
			helpers.assert_nil(outcome.verdict, "an unchanged count is no gesture")
			state.advance(3000)
			helpers.assert_eq(outcome.verdict, "pass")
			helpers.assert_eq(outcome.codes[1], "gesture_observed")
			helpers.assert_eq(outcome.count, 1)
			helpers.assert_eq(state.check_name, "capslock_chord")
			helpers.assert_nil(state.files[PROMPT], "the prompt is removed once settled")
			state.advance(60000)
			helpers.assert_eq(outcome.count, 1, "settles exactly once")
		end)
	end)

	helpers.it("counts a report step that turned to a failure as the outcome", function()
		helpers.with_stub_scope(MODULES, function()
			local Guided = load()
			local step = { id = "guided_three_finger_swipes", kind = "guided", mode = "observe", check = "gesture_frames",
				["until"] = { condition = "rises", steps = { "gesture_frames_stamped" } },
				gesture_seconds = 30, deadline_seconds = 60, gesture = "Swipe." }
			local state = world({
				report({ gesture_frames_stamped = { "skip", "no_touch" } }),
				report({ gesture_frames_stamped = { "fail", "unstamped:4" } }, "fail"),
			})
			local outcome = run(Guided, step, state)
			state.advance(3000)
			helpers.assert_eq(outcome.verdict, "fail", "the check's own failure is the verdict")
		end)
	end)

	helpers.it("fails when a count meant to stay steady rose with the gesture", function()
		helpers.with_stub_scope(MODULES, function()
			local Guided = load()
			local step = { id = "guided_network_toggle", kind = "guided", mode = "observe", check = "raw_telemetry",
				["until"] = { condition = "rises", steps = { "network_internet_down", "network_internet_up" },
					steady = { "network_vpn_connected" } },
				gesture_seconds = 60, deadline_seconds = 90, gesture = "Wi-Fi off and on." }
			local state = world({
				report({ network_internet_down = "1", network_internet_up = "1", network_vpn_connected = "0" }),
				report({ network_internet_down = "2", network_internet_up = "1", network_vpn_connected = "0" }),
				report({ network_internet_down = "2", network_internet_up = "2", network_vpn_connected = "1" }),
			})
			local outcome = run(Guided, step, state)
			state.advance(3000)
			helpers.assert_nil(outcome.verdict, "every until count must rise")
			state.advance(3000)
			helpers.assert_eq(outcome.verdict, "fail")
			helpers.assert_true(table.concat(outcome.codes, ","):find("rose_network_vpn_connected", 1, true) ~= nil)
		end)
	end)

	helpers.it("is needs_person with its bound when no gesture came, never a pass", function()
		helpers.with_stub_scope(MODULES, function()
			local Guided = load()
			local state = world({ report({ capslock_chord_presses = "0" }) })
			local outcome = run(Guided, OBSERVE, state)
			state.advance(29000)
			helpers.assert_nil(outcome.verdict)
			state.advance(3000)
			helpers.assert_eq(outcome.verdict, "needs_person")
			helpers.assert_eq(outcome.codes, { "gesture_not_observed_30s" })
			helpers.assert_type(outcome.report, "table", "the last reading is kept as evidence")
			helpers.assert_nil(state.files[PROMPT])
		end)
	end)

	helpers.it("records the person's skip by name and drops an answer for another step", function()
		helpers.with_stub_scope(MODULES, function()
			local Guided = load()
			local state = world({ report({ capslock_chord_presses = "0" }) })
			state.answer(OBSERVE.id, "pass")
			local outcome = run(Guided, OBSERVE, state)
			helpers.assert_nil(state.files[ANSWER], "a stale answer never answers a new step")
			state.answer("guided_other", "skip")
			state.advance(3000)
			helpers.assert_nil(outcome.verdict, "another step's answer is dropped")
			state.answer(OBSERVE.id, "skip")
			state.advance(3000)
			helpers.assert_eq(outcome.verdict, "skip")
			helpers.assert_eq(outcome.codes, { "skipped_by_person" })
		end)
	end)

	helpers.it("stops polling once the run is abandoned", function()
		helpers.with_stub_scope(MODULES, function()
			local Guided = load()
			local state = world({ report({ capslock_chord_presses = "0" }) })
			local outcome = run(Guided, OBSERVE, state)
			state.inactive = true
			state.advance(60000)
			helpers.assert_nil(outcome.verdict, "an abandoned step records nothing")
			helpers.assert_eq(state.checks, 1, "no check after the run was abandoned")
			helpers.assert_nil(state.files[PROMPT])
		end)
	end)
end)

helpers.describe("field run guided: attested gestures", function()
	local ATTEST = { id = "guided_menus", kind = "guided", mode = "attest", check = "menu_build",
		gesture_seconds = 60, deadline_seconds = 90, gesture = "Clear and restore each category." }

	helpers.it("records the person's answer with the check's evidence", function()
		helpers.with_stub_scope(MODULES, function()
			local Guided = load()
			local state = world({ report({ menu_rebuild = { "pass", "ok" } }, "pass") })
			local outcome = run(Guided, ATTEST, state)
			helpers.assert_eq(state.prompts[1].answers, { "pass", "fail", "skip" })
			helpers.assert_eq(state.checks, 0, "nothing is read before the answer")
			state.answer(ATTEST.id, "fail")
			state.advance(3000)
			helpers.assert_eq(outcome.verdict, "fail")
			helpers.assert_eq(outcome.codes[1], "attested_fail")
			helpers.assert_eq(state.checks, 1)
		end)
	end)

	helpers.it("fails a pass answer whose evidence check failed", function()
		helpers.with_stub_scope(MODULES, function()
			local Guided = load()
			local state = world({ report({ menu_rebuild = { "fail", "raised" } }, "fail") })
			local outcome = run(Guided, ATTEST, state)
			state.answer(ATTEST.id, "pass")
			state.advance(3000)
			helpers.assert_eq(outcome.verdict, "fail")
			helpers.assert_eq(outcome.codes[#outcome.codes], "evidence_fail")
		end)
	end)

	helpers.it("is needs_person with no_answer when the person never answered", function()
		helpers.with_stub_scope(MODULES, function()
			local Guided = load()
			local state = world({ report({}) })
			local outcome = run(Guided, ATTEST, state)
			state.advance(63000)
			helpers.assert_eq(outcome.verdict, "needs_person")
			helpers.assert_eq(outcome.codes, { "no_answer_60s" })
		end)
	end)
end)

helpers.describe("field run guided: declaration", function()
	helpers.it("validates every shipped guided step and refuses malformed ones", function()
		helpers.with_stub_scope(MODULES, function()
			local Guided = load()
			local file = assert(io.open(helpers.driver_root() .. "diagnostics/data/field_run.json", "rb"))
			local spec = Json.decode(file:read("*a"))
			file:close()
			Guided.validate_section(spec.guided)
			local count = 0
			for _, step in ipairs(spec.steps) do
				if step.kind == "guided" then
					count = count + 1
					Guided.validate_step(step)
					if step.check then
						helpers.assert_not_nil(require("diagnostics.engine.field_check.checks").checks[step.check],
							step.id .. " names an unknown check")
					end
				end
			end
			helpers.assert_true(count > 0, "the shipped run has guided steps")
			local function refused(changes)
				local step = { id = "x", kind = "guided", mode = "observe", check = "lease", gesture = "Do it.",
					gesture_seconds = 30, deadline_seconds = 60,
					["until"] = { condition = "rises", steps = { "lease_failures" } } }
				for key, value in pairs(changes) do step[key] = value end
				return not pcall(Guided.validate_step, step)
			end
			helpers.assert_true(not refused({}), "the reference step is valid")
			helpers.assert_true(refused({ mode = "ask" }))
			helpers.assert_true(refused({ gesture = " " }))
			helpers.assert_true(refused({ gesture_seconds = 5 }))
			helpers.assert_true(refused({ deadline_seconds = 40 }), "the deadline keeps a margin for the last check")
			helpers.assert_true(refused({ check = false }))
			helpers.assert_true(refused({ ["until"] = { condition = "falls", steps = { "x" } } }))
			helpers.assert_true(refused({ ["until"] = { condition = "rises", steps = {} } }))
			helpers.assert_true(refused({ mode = "attest" }), "an attested step observes nothing")
		end)
	end)

	helpers.it("reads the leading count of a report value", function()
		helpers.with_stub_scope(MODULES, function()
			local Guided = load()
			helpers.assert_eq(Guided.leading_number("12"), 12)
			helpers.assert_eq(Guided.leading_number("4:mouseMoved"), 4)
			helpers.assert_eq(Guided.leading_number("delivered:2"), 2)
			helpers.assert_eq(Guided.leading_number(7), 7)
			helpers.assert_nil(Guided.leading_number("no_touch"))
			helpers.assert_nil(Guided.leading_number(nil))
		end)
	end)
end)
