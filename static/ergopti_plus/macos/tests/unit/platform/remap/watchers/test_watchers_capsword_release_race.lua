--- tests/unit/platform/remap/watchers/test_watchers_capsword_release_race.lua

--- ==============================================================================
--- MODULE: CapsWord Pointer Watcher Transaction Tests
--- DESCRIPTION:
--- Proves that a pointer event cancels only a CapsWord the driver knows about
--- (its own activation or an observed Karabiner control signal) through the
--- serialized writer in platform.remap.ke_variables, and never runs karabiner_cli:
--- it has no option to read a variable. LED changes occur only after the
--- serialized write settles and remain lease-generation gated through watcher
--- stop/restart races.
--- ==============================================================================

local helpers = require("tests.helpers")

local TOKEN_A = "0123456789abcdef0123456789abcdef"
local TOKEN_B = "fedcba9876543210fedcba9876543210"


-- =========================================
-- =========================================
-- ======= 1/ Controllable Harness =========
-- =========================================
-- =========================================

--- Builds a fresh watcher with a subprocess spy and a serialized-writer spy.
--- @param options table|nil Failure injection and initial logical state.
--- @return table harness Controllable subject and all observable side effects.
local function fresh_harness(options)
	options = options or {}
	package.loaded["platform.remap.watchers"] = nil
	-- The control owner needs only its deferred diagnostic port in these native
	-- watcher doubles; callbacks never post synthetic keyboard input here.
	package.loaded["modules.keymap.control_sentinels"] = nil
	package.loaded["adapters.synthetic_input"] = {
		defer_after_callback = function(_label, callback) callback(); return true end,
	}
	package.loaded["adapters.shell_runner"] = nil
	-- TaskLifecycle captures `hs` at require time; reload it so any task the
	-- watcher could construct reaches the spy below instead of a stale stub.
	package.loaded["adapters.task_lifecycle"] = nil

	local h = {
		clock = 1000,
		tasks = {},
		writers = {},
		supersede_calls = 0,
		timers = {},
		pointer_callbacks = {},
		capslock = {},
		watcher_stops = 0,
		task_attempts = 0,
		hook_call_count = 0,
		hook_removal_attempts = 0,
		eventtap_stop_attempts = 0,
		timer_cancel_attempts = {},
		logged_errors = {},
		logged_warnings = {},
		revision = options.revision or 0,
		pending_activation = options.pending_activation == true,
		observations = {}, current_token = TOKEN_A, lease_active = true,
	}
	local logger = helpers.make_logger_stub()
	logger.error = function(_module, format_string, ...)
		h.logged_errors[#h.logged_errors + 1] = string.format(format_string, ...)
	end
	logger.warn = function(_module, format_string, ...)
		h.logged_warnings[#h.logged_warnings + 1] = string.format(format_string, ...)
	end
	logger.pcall = function(module, fn, ...)
		local results = table.pack(pcall(fn, ...))
		if not results[1] then
			logger.error(module, "Exception: %s", tostring(results[2]))
		end
		return table.unpack(results, 1, results.n)
	end
	package.loaded["infra.logger"] = logger

	package.loaded["adapters.timer_scheduler"] = {
		now_ns = function() return h.clock * 1000000000 end,
		after = function(delay, callback)
			local handle = { delay = delay, callback = callback, fired = false, cancelled = false }
			h.timers[#h.timers + 1] = handle
			if options.timer_unavailable then handle.fired = true end
			return handle, options.timer_uncommitted ~= true
		end,
		cancel = function(handle)
			if not handle then return true end
			h.timer_cancel_attempts[handle] = (h.timer_cancel_attempts[handle] or 0) + 1
			if h.fail_teardown_once and h.timer_cancel_attempts[handle] == 1 then return false end
			handle.cancelled = true
			return true
		end,
	}
	package.loaded["adapters.key_state"] = {
		set_capslock = function(value) h.capslock[#h.capslock + 1] = value end,
	}
	package.loaded["platform.remap.ke_variables"] = {
		capsword_revision = function() return h.revision end,
		observe_capsword_state = function(value, token)
			if not h.lease_active or token ~= h.current_token then return false, h.revision end
			h.observations[#h.observations + 1] = { value = value, token = token }
			h.revision = h.revision + 1
			h.pending_activation = value == 1
			return true, h.revision
		end,
		supersede_capsword_activation = function(callback)
			h.supersede_calls = h.supersede_calls + 1
			if options.supersede_throws then error("injected supersede failure") end
			if not h.pending_activation then return false, h.revision end
			h.pending_activation = false
			h.revision = h.revision + 1
			local write = {
				kind = "supersede",
				name = "capsword",
				value = 0,
				revision = h.revision,
				callback = callback,
			}
			h.writers[#h.writers + 1] = write
			return true, write.revision
		end,
	}

	local hook_calls = {}
	h.gestures = {
		set_any_touch_hook = function(callback)
			h.hook_call_count = h.hook_call_count + 1
			if callback == nil then
				h.hook_removal_attempts = h.hook_removal_attempts + 1
				if h.fail_teardown_once and h.hook_removal_attempts == 1 then
					error("injected hook removal failure")
				end
			end
			h.last_hook = callback
			if callback ~= nil then hook_calls[#hook_calls + 1] = callback end
			if options.hook_throws and callback ~= nil then error("injected hook failure") end
		end,
	}
	h.hook_calls = hook_calls

	local hs_overrides = {
		eventtap = {
			new = function(_types, callback)
				if options.eventtap_new_throws then error("injected eventtap constructor failure") end
				h.pointer_callbacks[#h.pointer_callbacks + 1] = callback
				return {
					start = function()
						if options.eventtap_start_throws then error("injected eventtap start failure") end
						return options.eventtap_start_false ~= true
					end,
					stop = function()
						h.watcher_stops = h.watcher_stops + 1
						h.eventtap_stop_attempts = h.eventtap_stop_attempts + 1
						if h.fail_teardown_once and h.eventtap_stop_attempts == 1 then
							error("injected eventtap stop failure")
						end
					end,
				}
			end,
			event = { types = {
				mouseMoved = 1,
				scrollWheel = 2,
				gesture = 3,
				leftMouseDown = 4,
				rightMouseDown = 5,
				otherMouseDown = 6,
			} },
		},
		-- Spy only: the watcher must never construct a task.
		task = {
			new = function(command, _callback, args)
				h.task_attempts = h.task_attempts + 1
				h.tasks[#h.tasks + 1] = { command = command, args = args }
				return { start = function() return true end, terminate = function(self) return self end }
			end,
		},
		timer = {
			secondsSinceEpoch = function() return h.clock end,
		},
	}

	h.sentinels = require("modules.keymap.control_sentinels")
	local register_listener = h.sentinels.set_listener
	h.sentinels.set_listener = function(name, callback)
		if callback then h.signal_listener = callback end
		return register_listener(name, callback)
	end
	h.watchers = helpers.load_with_stubs("platform.remap.watchers", hs_overrides)
	h.watcher = h.watchers.start_gesture_watcher(h.gestures, TOKEN_A)
	return h
end

--- Fires one current pointer callback beyond the production throttle interval.
--- @param h table Harness.
--- @param index number|nil Watcher callback index.
local function pointer(h, index)
	h.clock = h.clock + 1
	local callback = h.pointer_callbacks[index or #h.pointer_callbacks]
	helpers.assert_true(type(callback) == "function", "a running watcher must expose its pointer callback")
	callback({})
end

--- Settles one captured serialized write exactly like ke_variables does.
--- @param h table Harness.
--- @param index number Write index.
--- @param ok boolean Settlement result.
--- @param reason string|nil Stable reason.
local function settle(h, index, ok, reason)
	local write = h.writers[index]
	helpers.assert_true(type(write) == "table", "the serialized write must exist")
	write.callback(ok, reason or (ok and "written" or "failed"), write.revision)
end

--- Finds timer handles by their named delay without relying on allocation order.
--- @param h table Harness.
--- @param delay number Exact delay.
--- @return table handles Matching timers.
local function timers_at(h, delay)
	local found = {}
	for _, handle in ipairs(h.timers) do
		if handle.delay == delay then found[#found + 1] = handle end
	end
	return found
end


-- =========================================
-- =========================================
-- ======= 2/ Known CapsWord Clear =========
-- =========================================
-- =========================================

helpers.describe("CapsWord native activation reaches the pointer owner", function()
	helpers.it("clears a Karabiner activation only after the exact writer acknowledges", function()
		local h = fresh_harness()
		h.sentinels.claim_key(90, true, { ctrl = true, alt = true, shift = true })
		helpers.assert_eq(h.observations, { { value = 1, token = TOKEN_A } })
		pointer(h)
		helpers.assert_eq(#h.tasks, 0, "known Karabiner activation never calls the unsupported read option")
		helpers.assert_eq(#h.writers, 1)
		helpers.assert_eq(h.capslock, {}, "LED belongs to the acknowledged clear, not queued intent")
		local clear = h.writers[1]
		clear.callback(true, nil, clear.revision)
		helpers.assert_eq(h.capslock, { false })
		helpers.assert_true(h.watchers.stop_gesture_watcher(h.watcher))
	end)

	helpers.it("rejects bare, unrelated, retired-listener and foreign-lease activation signals", function()
		local h = fresh_harness()
		h.sentinels.claim_key(90, true, {})
		h.sentinels.claim_key(90, true, { ctrl = true, alt = true })
		h.sentinels.claim_key(90, true, { shift = true })
		helpers.assert_eq(#h.observations, 0)
		local old_listener = h.signal_listener
		h.current_token = TOKEN_B
		h.sentinels.claim_key(90, true, { ctrl = true, alt = true, shift = true })
		helpers.assert_eq(#h.observations, 0)
		h.current_token = TOKEN_A
		helpers.assert_true(h.watchers.stop_gesture_watcher(h.watcher))
		old_listener("capsword_activated")
		helpers.assert_eq(#h.observations, 0, "a stopped callback remains inert even when its original token returns")
		helpers.assert_eq(#h.writers, 0)
	end)

	helpers.it("does not clear the LED for an old writer after a newer native activation", function()
		local h = fresh_harness()
		h.sentinels.claim_key(90, true, { ctrl = true, alt = true, shift = true })
		pointer(h)
		local old_clear = h.writers[1]
		h.sentinels.claim_key(90, true, { ctrl = true, alt = true, shift = true })
		old_clear.callback(true, nil, old_clear.revision)
		helpers.assert_eq(h.capslock, {})
		h.clock = h.clock + 1
		pointer(h)
		local current_clear = h.writers[2]
		current_clear.callback(true, nil, current_clear.revision)
		helpers.assert_eq(h.capslock, { false })
		helpers.assert_true(h.watchers.stop_gesture_watcher(h.watcher))
	end)
end)

helpers.describe("watchers CapsWord clears only a known activation", function()
	helpers.it("(capsword-no-cli-reader) a pointer event without a known activation runs nothing", function()
		-- karabiner_cli has no --get-variable option: the old probe failed with
		-- exit 2 on every Mac and warned at every boot.
		local h = fresh_harness()
		for _ = 1, 5 do pointer(h) end
		helpers.assert_eq(h.task_attempts, 0, "the pointer watcher must never spawn karabiner_cli")
		helpers.assert_eq(h.supersede_calls, 5, "each throttled pointer event asks the writer once")
		helpers.assert_eq(#h.writers, 0, "no known activation needs no write")
		helpers.assert_eq(#h.capslock, 0, "personal CapsLock state remains untouched")
		helpers.assert_eq(#h.logged_warnings, 0, "a permanent limitation is not a warning")
		helpers.assert_eq(#h.logged_errors, 0)
	end)

	helpers.it("CapsWord watcher: supersedes a local activation through the writer", function()
		local h = fresh_harness({ pending_activation = true })
		pointer(h)
		helpers.assert_eq(h.task_attempts, 0)
		helpers.assert_eq(#h.writers, 1)
		helpers.assert_eq(h.writers[1].kind, "supersede")
		helpers.assert_eq(#h.capslock, 0, "the LED waits for actual write completion")
		settle(h, 1, true)
		helpers.assert_eq(h.capslock[1], false, "a settled clear switches CapsLock off")
		local corrections = timers_at(h, 0.15)
		helpers.assert_eq(#corrections, 1, "a settled clear arms one LED correction")
		corrections[1].callback()
		helpers.assert_eq(h.capslock[2], false, "the correction repeats the settled LED state")
	end)

	helpers.it("CapsWord watcher: a clear in flight holds the guard until it settles", function()
		local h = fresh_harness({ pending_activation = true })
		pointer(h)
		h.pending_activation = true
		pointer(h)
		helpers.assert_eq(h.supersede_calls, 1, "pointer events wait for the accepted clear")
		settle(h, 1, true)
		pointer(h)
		helpers.assert_eq(h.supersede_calls, 2, "settlement releases the guard")
		helpers.assert_eq(#h.writers, 2, "a newer activation is cleared in turn")
	end)

	helpers.it("CapsWord watcher: a failed serialized clear never changes the LED", function()
		local h = fresh_harness({ pending_activation = true })
		pointer(h)
		settle(h, 1, false, "writer-fenced")
		helpers.assert_eq(#h.capslock, 0,
			"failure means the engine state is unknown; an LED side effect would lie")
		pointer(h)
		helpers.assert_eq(h.supersede_calls, 2, "a failed settlement releases the guard")
	end)

	helpers.it("CapsWord watcher: a raising writer is reported and releases the guard", function()
		local h = fresh_harness({ supersede_throws = true })
		pointer(h)
		pointer(h)
		helpers.assert_eq(h.supersede_calls, 2, "the guard reopened after the raise")
		helpers.assert_eq(#h.logged_errors, 2)
		helpers.assert_contains(h.logged_errors[1], "injected supersede failure")
	end)
end)


-- =========================================
-- =========================================
-- ======= 3/ Revision and Lifecycle Races ==
-- =========================================
-- =========================================

helpers.describe("watchers CapsWord fences stale asynchronous callbacks", function()
	helpers.it("CapsWord watcher: ignores a clear settlement delivered after watcher stop", function()
		local h = fresh_harness({ pending_activation = true })
		pointer(h)
		h.watchers.stop_gesture_watcher(h.watcher)
		settle(h, 1, true)
		helpers.assert_eq(#h.capslock, 0, "a stopped lease owns no later LED callback")
	end)

	helpers.it("CapsWord watcher: cancels delayed LED correction when a newer revision appears", function()
		local h = fresh_harness({ pending_activation = true })
		pointer(h)
		settle(h, 1, true)
		local correction = timers_at(h, 0.15)[1]
		helpers.assert_true(correction ~= nil, "the correction timer must be observable")
		h.revision = h.revision + 1
		correction.callback()
		helpers.assert_eq(#h.capslock, 1,
			"the delayed callback must not overwrite the newer activation's LED")
	end)

	helpers.it("CapsWord watcher: stopped lease A callbacks cannot act on restarted lease B", function()
		local h = fresh_harness({ pending_activation = true })
		local pointer_a = h.pointer_callbacks[1]
		local touch_a = h.hook_calls[1]
		h.watchers.stop_gesture_watcher(h.watcher)
		local watcher_b = h.watchers.start_gesture_watcher(h.gestures, TOKEN_B)
		helpers.assert_true(watcher_b ~= nil, "lease B must start")

		h.clock = h.clock + 1
		pointer_a({})
		touch_a()
		helpers.assert_eq(h.supersede_calls, 0, "queued lease A callbacks are inert")

		pointer(h, 2)
		helpers.assert_eq(h.supersede_calls, 1, "lease B callback remains live")
		helpers.assert_eq(#h.writers, 1)
	end)
end)


-- =========================================
-- =========================================
-- ======= 4/ Fail-Closed Resource Start ====
-- =========================================
-- =========================================

helpers.describe("watchers CapsWord resource failures are fail-closed", function()
	helpers.it("CapsWord watcher: failed teardown retains every exact resource for retry", function()
		local h = fresh_harness({ pending_activation = true })
		pointer(h)
		settle(h, 1, true)
		local led_timer = timers_at(h, 0.15)[1]
		helpers.assert_true(led_timer ~= nil, "setup must own a delayed LED timer")
		h.fail_teardown_once = true

		helpers.assert_eq(h.watchers.stop_gesture_watcher(h.watcher), false,
			"one failed native resource must keep the teardown unsettled")
		helpers.assert_eq(h.eventtap_stop_attempts, 1)
		helpers.assert_eq(h.timer_cancel_attempts[led_timer], 1)
		helpers.assert_eq(h.hook_removal_attempts, 1)

		helpers.assert_eq(h.watchers.stop_gesture_watcher(h.watcher), true,
			"the same exact resources must settle on retry")
		helpers.assert_eq(h.eventtap_stop_attempts, 2)
		helpers.assert_eq(h.timer_cancel_attempts[led_timer], 2)
		helpers.assert_eq(h.hook_removal_attempts, 2)
	end)

	helpers.it("CapsWord watcher: eventtap constructor failure returns nil without installing a hook", function()
		local h = fresh_harness({ eventtap_new_throws = true })
		helpers.assert_nil(h.watcher, "a missing eventtap is not reported as running")
		helpers.assert_eq(#h.hook_calls, 0, "the touch hook must not create a half-watcher")
	end)

	helpers.it("CapsWord watcher: eventtap start refusal stops the partial tap and installs no hook", function()
		local h = fresh_harness({ eventtap_start_false = true })
		helpers.assert_nil(h.watcher, "a refused eventtap is not reported as running")
		helpers.assert_eq(h.watcher_stops, 1, "the exact partial tap is reclaimed")
		helpers.assert_eq(#h.hook_calls, 0, "no touch-only half-feature remains")
		h.clock = h.clock + 1
		h.pointer_callbacks[1]({})
		helpers.assert_eq(h.supersede_calls, 0,
			"a callback already queued by the refused tap is lifecycle-fenced")
	end)

	helpers.it("CapsWord watcher: touch-hook failure stops the eventtap and removes any partial hook", function()
		local h = fresh_harness({ hook_throws = true })
		helpers.assert_nil(h.watcher, "both inputs are required for a managed watcher")
		helpers.assert_eq(h.watcher_stops, 1, "the running eventtap is stopped on hook failure")
		helpers.assert_eq(h.hook_call_count, 2,
			"cleanup must call the hook API again after registration throws")
		helpers.assert_nil(h.last_hook,
			"cleanup attempts to remove a hook that raised after partial installation")
	end)
end)
