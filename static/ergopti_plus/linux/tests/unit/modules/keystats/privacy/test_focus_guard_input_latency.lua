--- tests/unit/modules/keystats/privacy/test_focus_guard_input_latency.lua

--- ==============================================================================
--- MODULE: Focus Guard Input Latency Regression Tests
--- DESCRIPTION:
--- A physical key asks the focus guard whether text may be collected before the
--- hook forwards it. With no joined field context, the case of every desktop
--- without a window query (KDE Wayland), a worker that let the admission budget
--- (20 ms) pass made the guard wait it again on each press and each release:
--- the 22 ms input.dispatch the field log of an X270 showed on every keystroke.
--- The real watcher runs here over a worker that is alive but slow: after one
--- missed budget, keys read its answers without waiting, keep the window mode's
--- reason, and a late password-field answer still closes the window mode. A
--- joined context still waits for a fresh answer on each press.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
local Monotonic = require("core.logger.engine.monotonic")
local Timings = require("core.timing.engine.timings")
local Segments = require("metrics.engine.perf.hotpath_segments")
local Watch = require("platform.focus.atspi_focus_watch")
local Guard = require("modules.keystats.focus_guard")

-- The budget of one keyboard event: the HotPath threshold of input.dispatch.
local DISPATCH_BUDGET_MS = Segments.threshold_ms("input.dispatch", Timings.ms("logger", "hotpath_slow_ms"))
-- Physical presses timed per scenario.
local PRESSES = 10

--- Builds the real watcher over a live worker and the real guard around it.
--- @param options table { answers = boolean, joins = boolean }
--- @return table state { guard, requests }
local function fixture(options)
	local state = { requests = {}, sequence = 0, queue = {}, epoch = 0 }
	local function frame(kind, request, role)
		state.sequence = state.sequence + 1
		local message = { kind = kind, sequence = state.sequence, request = request or 0, at_ms = Monotonic.now_ms() }
		if kind == "snapshot" then message.role, message.active_scope, message.bus, message.path = role or 61, true, ":1.4", "/field" end
		state.queue[#state.queue + 1] = Json.encode(message) .. "\n"
	end
	state.frame = frame
	local transport = {}
	function transport.command() return "luajit", {} end
	function transport.close() return true end
	function transport.cleanup() return true end
	function transport.read()
		if #state.queue > 0 then return table.remove(state.queue, 1) end
		return nil, "again"
	end
	function transport.request(request)
		state.requests[#state.requests + 1] = request
		if options.answers then frame("snapshot", request) end
		return true
	end
	local operation = { started = true }
	function operation:is_running() return true end
	function operation:is_settled() return true end
	function operation:on_settled() end
	function operation:cancel() return true end
	local watch = Watch.new({ create_transport = function() return transport end,
		start_process = function() return operation end })
	state.guard = Guard.new({
		watch = watch, retry_ms = 1000, now_ms = Monotonic.now_ms,
		detector = {
			invalidateFocus = function() state.epoch = state.epoch + 1; return state.epoch end,
			currentEpoch = function() return state.epoch end,
			publishFocus = function(_, epoch) return epoch == state.epoch end,
			isSecureField = function() return false end,
		},
		keystats = { set_secure_field = function() end, is_context_protected = function() return false end },
		-- KDE Wayland has no window query: no context capture is dispatched.
		capture_context_async = function(_, _, callback)
			if not options.joins then return nil end
			callback({ app_id = "editor", title = "Ordinary", native_identity = "window:1" })
			return { is_settled = function() return true end, cancel = function() return true end }
		end,
		publish_context = function() return true, false end,
		window_policy = function() return true end,
	})
	helpers.assert_true(watch.start(), "the watcher must start over the live worker")
	frame("ready")
	frame("snapshot")
	helpers.assert_true(watch.pump(), "the worker's ready receipt must be admitted")
	return state
end

--- Times PRESSES admissions, as on_physical asks them.
--- @param guard table
--- @return number worst_ms, table answers Each press's { allowed, mode, reason }.
local function time_presses(guard)
	local worst, answers = 0, {}
	for index = 1, PRESSES do
		local started = Monotonic.now_ms()
		local allowed, mode, reason = guard.text_automation()
		local elapsed = Monotonic.now_ms() - started
		if elapsed > worst then worst = elapsed end
		answers[index] = { allowed = allowed, mode = mode, reason = reason }
	end
	return worst, answers
end

helpers.describe("focus guard: physical key latency", function()
	helpers.it("reads a slow worker's answers without waiting while no context is joined", function()
		local state = fixture({ answers = false, joins = false })
		state.guard.prime()
		-- The first key learns that the worker lets the budget pass.
		local first_allowed, first_mode, first_reason = state.guard.text_automation()
		helpers.assert_true(first_allowed, "an unanswered window is the window mode")
		helpers.assert_eq(first_mode .. "/" .. first_reason, "window/no_focus_answer", "the first key's mode and reason")
		local before = #state.requests
		local worst, answers = time_presses(state.guard)
		helpers.assert_true(worst < DISPATCH_BUDGET_MS, string.format(
			"one admission took %.2f ms, over the %d ms input.dispatch budget", worst, DISPATCH_BUDGET_MS))
		for index, answer in ipairs(answers) do
			helpers.assert_eq(answer.mode .. "/" .. answer.reason, "window/no_focus_answer",
				"press " .. index .. " keeps the window mode's reason")
		end
		helpers.assert_true(#state.requests - before <= 1, "one request stays outstanding, never one per key")
	end)

	helpers.it("still closes the window mode on a late password-field answer", function()
		local state = fixture({ answers = false, joins = false })
		state.guard.prime()
		state.guard.text_automation()
		state.guard.text_automation()
		-- The worker answers the outstanding request: a password field.
		state.frame("snapshot", state.requests[#state.requests], 40)
		local allowed, mode, reason = state.guard.text_automation()
		helpers.assert_eq(allowed, false, "a password field closes the window mode")
		helpers.assert_eq(mode .. "/" .. reason, "closed/password_field", "the password field is named")
		local again_allowed = state.guard.text_automation()
		helpers.assert_eq(again_allowed, false, "the password latch holds on the next key")
	end)

	helpers.it("still asks the worker for a fresh answer on each press once a context is joined", function()
		local state = fixture({ answers = true, joins = true })
		state.guard.prime()
		helpers.assert_true(state.guard.refresh(true), "the joined context must be published")
		local before = #state.requests
		local _, answers = time_presses(state.guard)
		helpers.assert_eq(answers[PRESSES].mode, "field", "a fresh ordinary field is the field mode")
		helpers.assert_eq(#state.requests - before, PRESSES, "each press waits for its own fresh receipt")
	end)
end)
