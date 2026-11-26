--- tests/unit/modules/keystats/privacy/test_focus_guard_input_latency.lua

--- ==============================================================================
--- MODULE: Focus Guard Input Latency Regression Tests
--- DESCRIPTION:
--- A physical key asks the focus guard whether text may be collected before the
--- hook forwards it. Field report, Arch Linux, KDE Plasma Wayland, 2026-11-25:
--- in Brave and Discord (Chromium, Electron) every key waited for a fresh
--- accessibility answer, which took the whole 20 ms barrier budget
--- (focus_barrier_timeout_ms): "Slow input.char 21.44 ms own" and an
--- input.dispatch of about 21 ms on each keystroke. Decided 2026-11-25: a key
--- never waits; it reads the last receipt the worker's own focus events sent.
--- The real watcher runs here over a worker that is alive but silent or slow.
--- Waiting is measured exactly: the watcher's pause, which every barrier calls
--- while it waits, and the queries a key sends. A password field the worker
--- reported stays latched and closes text automation without any wait.
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
local PASSWORD_ROLE = 40

--- Builds the real watcher over a live worker and the real guard around it.
--- @param options table { joins = boolean } Whether a window context joins.
--- @return table state { guard, requests, pauses, frame, answers, protected }
local function fixture(options)
	local state = { requests = {}, sequence = 0, queue = {}, epoch = 0, pauses = 0, answers = true, protected = false }
	local function frame(kind, request, role)
		state.sequence = state.sequence + 1
		local message = { kind = kind, sequence = state.sequence, at_ms = Monotonic.now_ms(),
			request = request or state.requests[#state.requests] or 0 }
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
		if state.answers then frame("snapshot", request) end
		return true
	end
	local operation = { started = true }
	function operation:is_running() return true end
	function operation:is_settled() return true end
	function operation:on_settled() end
	function operation:cancel() return true end
	local watch = Watch.new({ create_transport = function() return transport end,
		start_process = function() return operation end,
		-- Each call is one step of a barrier's wait.
		pause = function() state.pauses = state.pauses + 1; require("luv").sleep(1) end })
	state.guard = Guard.new({
		watch = watch, retry_ms = 1000, now_ms = Monotonic.now_ms,
		detector = {
			invalidateFocus = function() state.epoch = state.epoch + 1; return state.epoch end,
			currentEpoch = function() return state.epoch end,
			publishFocus = function(role, epoch, protected)
				return epoch == state.epoch and role ~= PASSWORD_ROLE and protected ~= true
			end,
			isSecureField = function() return false end,
		},
		keystats = { set_secure_field = function() end, is_context_protected = function() return state.protected end },
		-- KDE Wayland has no window query: no context capture is dispatched.
		capture_context_async = function(_, _, callback)
			if not options.joins then return nil end
			callback({ app_id = "brave", title = "Ordinary", native_identity = "window:1" })
			return { is_settled = function() return true end, cancel = function() return true end }
		end,
		publish_context = function() return true, state.protected end,
		window_policy = function()
			if state.protected then return false, "protected_context" end
			return true
		end,
	})
	helpers.assert_true(watch.start(), "the watcher must start over the live worker")
	frame("ready")
	frame("snapshot")
	helpers.assert_true(watch.pump(), "the worker's ready receipt must be admitted")
	return state
end

--- Joins the ordinary field's context while the worker still answers, then
--- leaves the worker silent or slow for the keys that follow.
--- @param state table
local function join_field(state)
	state.guard.prime()
	helpers.assert_true(state.guard.refresh(true), "the joined context must be published")
	state.answers = false
end

--- Times PRESSES admissions, as on_physical asks them, counting barrier waits.
--- @param state table
--- @return table measured { worst_ms, pauses, requests, answers }
local function time_presses(state)
	local measured = { worst_ms = 0, pauses = state.pauses, requests = #state.requests, answers = {} }
	for index = 1, PRESSES do
		local started = Monotonic.now_ms()
		local allowed, mode, reason = state.guard.text_automation()
		local elapsed = Monotonic.now_ms() - started
		if elapsed > measured.worst_ms then measured.worst_ms = elapsed end
		measured.answers[index] = { allowed = allowed, mode = mode, reason = reason }
	end
	measured.pauses = state.pauses - measured.pauses
	measured.requests = #state.requests - measured.requests
	return measured
end

--- Asserts that no press waited: no barrier step, no query, inside the budget.
--- @param measured table From time_presses.
--- @param label string
local function assert_no_wait(measured, label)
	helpers.assert_eq(measured.pauses, 0, label .. ": a key never waits for the worker")
	helpers.assert_eq(measured.requests, 0, label .. ": a key sends the worker no query")
	helpers.assert_true(measured.worst_ms < DISPATCH_BUDGET_MS, string.format(
		"%s: one admission took %.2f ms, over the %d ms input.dispatch budget", label, measured.worst_ms, DISPATCH_BUDGET_MS))
end

helpers.describe("focus guard: physical key latency", function()
	helpers.it("(focus-key-no-wait) admits a joined field from the last receipt while the worker is silent", function()
		local state = fixture({ joins = true })
		join_field(state)
		local measured = time_presses(state)
		assert_no_wait(measured, "silent worker")
		for index, answer in ipairs(measured.answers) do
			helpers.assert_eq(answer.mode .. "/" .. answer.reason, "field/field_admitted",
				"press " .. index .. " stays in the field mode")
		end
	end)

	helpers.it("(focus-key-no-wait) never waits for a slow worker's answer either", function()
		local state = fixture({ joins = true })
		join_field(state)
		-- Slow: the worker answers each query, but only after the barrier budget.
		local measured = time_presses(state)
		for _, request in ipairs(state.requests) do state.frame("snapshot", request) end
		assert_no_wait(measured, "slow worker")
		helpers.assert_eq(measured.answers[PRESSES].mode, "field", "the last receipt keeps the field mode")
	end)

	helpers.it("(focus-key-no-wait) still applies the private-window and password-application policy", function()
		local state = fixture({ joins = true })
		join_field(state)
		state.protected = true
		local measured = time_presses(state)
		assert_no_wait(measured, "protected context")
		for index, answer in ipairs(measured.answers) do
			helpers.assert_eq(answer.allowed, false, "press " .. index .. " is closed by the policy")
		end
	end)

	helpers.it("(focus-key-no-wait) a latched password field blocks text automation until focus provably leaves", function()
		local state = fixture({ joins = true })
		join_field(state)
		-- The worker's listener reports the move to a password field by itself.
		state.frame("unknown")
		state.frame("snapshot", nil, PASSWORD_ROLE)
		local measured = time_presses(state)
		assert_no_wait(measured, "password field")
		for index, answer in ipairs(measured.answers) do
			helpers.assert_eq(answer.mode .. "/" .. answer.reason, "closed/password_field",
				"press " .. index .. " is closed by the password field")
		end
		-- An inconclusive answer is not proof that the focus left the field.
		state.frame("unknown")
		local allowed, mode, reason = state.guard.text_automation()
		helpers.assert_eq(allowed, false, "the password latch survives an unknown answer")
		helpers.assert_eq(mode .. "/" .. reason, "closed/password_field", "the latch is named")
		-- An ordinary field reported by the worker is: the latch lets go.
		state.frame("snapshot", nil, 61)
		local released = state.guard.text_automation()
		helpers.assert_true(released, "another field reported by the worker releases the latch")
	end)

	helpers.it("reads a silent worker without waiting while no context is joined", function()
		local state = fixture({ joins = false })
		state.answers = false
		state.guard.prime()
		local measured = time_presses(state)
		assert_no_wait(measured, "window mode")
		for index, answer in ipairs(measured.answers) do
			helpers.assert_eq(answer.mode .. "/" .. answer.reason, "window/no_focus_answer",
				"press " .. index .. " keeps the window mode's reason")
		end
	end)

	helpers.it("still closes the window mode on a late password-field answer", function()
		local state = fixture({ joins = false })
		state.answers = false
		state.guard.prime()
		state.guard.text_automation()
		-- The worker answers the outstanding request: a password field.
		state.frame("snapshot", state.requests[#state.requests], PASSWORD_ROLE)
		local allowed, mode, reason = state.guard.text_automation()
		helpers.assert_eq(allowed, false, "a password field closes the window mode")
		helpers.assert_eq(mode .. "/" .. reason, "closed/password_field", "the password field is named")
		local again_allowed = state.guard.text_automation()
		helpers.assert_eq(again_allowed, false, "the password latch holds on the next key")
	end)
end)
