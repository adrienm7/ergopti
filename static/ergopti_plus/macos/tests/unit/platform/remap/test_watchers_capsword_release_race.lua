--- tests/unit/platform/remap/test_watchers_capsword_release_race.lua

--- ==============================================================================
--- MODULE: CapsWord Pointer Watcher Transaction Tests
--- DESCRIPTION:
--- Proves that the pointer watcher owns only a read-only exact-token probe. Every
--- mutation goes through platform.remap.ke_variables, whose logical revision
--- prevents a late probe from clearing a newer CapsWord activation. LED changes
--- occur only after the serialized write settles and remain lease-generation
--- gated through watcher stop/restart races.
--- ==============================================================================

local helpers = require("tests.helpers")

local TOKEN_A = "0123456789abcdef0123456789abcdef"
local TOKEN_B = "fedcba9876543210fedcba9876543210"
local SCOPED_A = "ergopti_capsword_" .. TOKEN_A
local SCOPED_B = "ergopti_capsword_" .. TOKEN_B


-- =========================================
-- =========================================
-- ======= 1/ Controllable Harness =========
-- =========================================
-- =========================================

--- Builds a fresh watcher with separate read-probe and serialized-writer spies.
--- @param options table|nil Failure injection and initial logical state.
--- @return table harness Controllable subject and all observable side effects.
local function fresh_harness(options)
	options = options or {}
	package.loaded["platform.remap.watchers"] = nil
	package.loaded["adapters.shell_runner"] = nil
	-- TaskLifecycle captures `hs` at require time, so each harness must bind a
	-- fresh instance to the task constructor below rather than its predecessor.
	package.loaded["adapters.task_lifecycle"] = nil

	local h = {
		clock = 1000,
		tasks = {},
		writers = {},
		conditional_calls = {},
		timers = {},
		pointer_callbacks = {},
		capslock = {},
		watcher_stops = 0,
		task_attempts = 0,
		hook_call_count = 0,
		hook_removal_attempts = 0,
		eventtap_stop_attempts = 0,
		timer_cancel_attempts = {},
		revision = options.revision or 0,
		pending_activation = options.pending_activation == true,
	}

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
		supersede_capsword_activation = function(callback)
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
		set_if_revision = function(name, value, expected_revision, callback)
			h.conditional_calls[#h.conditional_calls + 1] = {
				name = name,
				value = value,
				expected_revision = expected_revision,
			}
			if expected_revision ~= h.revision then
				callback(false, "stale-revision", h.revision)
				return false, h.revision
			end
			h.revision = h.revision + 1
			local write = {
				kind = "conditional",
				name = name,
				value = value,
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
		task = {
			new = function(command, callback, args)
				h.task_attempts = h.task_attempts + 1
				local index = #h.tasks + 1
				if options.task_new_nil then return nil end
				if options.task_new_throws then error("injected probe constructor failure") end
				local fake = { terminated = false }
				function fake:start()
					if options.task_start_throws then error("injected probe start failure") end
					return options.task_start_false ~= true
				end
				function fake:terminate()
					fake.terminate_attempts = (fake.terminate_attempts or 0) + 1
					if h.fail_teardown_once and fake.terminate_attempts == 1 then
						error("injected task terminate failure")
					end
					fake.terminated = true
				end
				h.tasks[index] = {
					command = command,
					callback = callback,
					args = args,
					fake = fake,
				}
				return fake
			end,
		},
		timer = {
			secondsSinceEpoch = function() return h.clock end,
		},
	}

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
-- ======= 2/ One Read, One Writer =========
-- =========================================
-- =========================================

helpers.describe("watchers CapsWord uses one exact serialized writer", function()
	helpers.it("CapsWord watcher: queries the scoped variable read-only and clears through ke_variables", function()
		local h = fresh_harness()
		helpers.assert_true(h.watcher ~= nil, "the eventtap must start")
		pointer(h)
		helpers.assert_eq(#h.tasks, 1, "one read-only probe must start")
		helpers.assert_eq(h.tasks[1].args[1], "--get-variable")
		helpers.assert_eq(h.tasks[1].args[2], SCOPED_A)

		h.tasks[1].callback(0, "1", "")
		helpers.assert_eq(#h.tasks, 1,
			"an active result must not spawn a second direct karabiner_cli writer")
		helpers.assert_eq(#h.writers, 1, "the common serializer must own the clear")
		helpers.assert_eq(h.writers[1].kind, "conditional")
		helpers.assert_eq(h.writers[1].name, "capsword")
		helpers.assert_eq(h.writers[1].value, 0)
		helpers.assert_eq(#h.capslock, 0, "accepted is not written; the LED must wait")

		settle(h, 1, true)
		helpers.assert_eq(h.capslock[1], false, "a settled clear switches CapsLock off")
		local corrections = timers_at(h, 0.15)
		helpers.assert_eq(#corrections, 1, "a settled clear arms one LED correction")
		corrections[1].callback()
		helpers.assert_eq(h.capslock[2], false, "the correction repeats the settled LED state")

		pointer(h)
		helpers.assert_eq(#h.tasks, 2, "settlement releases the pointer probe guard")
	end)

	helpers.it("CapsWord watcher: does not touch personal CapsLock when the scoped variable is inactive", function()
		local h = fresh_harness()
		pointer(h)
		h.tasks[1].callback(0, "0", "")
		helpers.assert_eq(#h.writers, 0, "an inactive scoped variable needs no write")
		helpers.assert_eq(#h.capslock, 0, "personal CapsLock state remains untouched")
		pointer(h)
		helpers.assert_eq(#h.tasks, 2, "the inactive result still releases the guard")
	end)

	helpers.it("CapsWord watcher: supersedes an in-flight local activation before launching a probe", function()
		local h = fresh_harness({ pending_activation = true })
		pointer(h)
		helpers.assert_eq(#h.tasks, 0,
			"a known local activation must be cleared through the writer without a stale read")
		helpers.assert_eq(#h.writers, 1)
		helpers.assert_eq(h.writers[1].kind, "supersede")
		helpers.assert_eq(#h.capslock, 0, "the LED waits for actual write completion")
		settle(h, 1, true)
		helpers.assert_eq(h.capslock[1], false)
	end)

	helpers.it("CapsWord watcher: a failed serialized clear never changes the LED", function()
		local h = fresh_harness()
		pointer(h)
		h.tasks[1].callback(0, "1", "")
		settle(h, 1, false, "writer-fenced")
		helpers.assert_eq(#h.capslock, 0,
			"failure means the engine state is unknown; an LED side effect would lie")
	end)
end)


-- =========================================
-- =========================================
-- ======= 3/ Revision and Lifecycle Races ==
-- =========================================
-- =========================================

helpers.describe("watchers CapsWord fences stale asynchronous callbacks", function()
	helpers.it("CapsWord watcher: does not let an old probe clear a newer local activation", function()
		local h = fresh_harness()
		pointer(h)
		h.revision = h.revision + 1
		h.pending_activation = true
		h.tasks[1].callback(0, "1", "")

		helpers.assert_eq(#h.conditional_calls, 1, "the probe must present its captured revision")
		helpers.assert_eq(h.conditional_calls[1].expected_revision, 0)
		helpers.assert_eq(#h.writers, 0, "the stale conditional clear must be rejected")
		helpers.assert_eq(#h.capslock, 0, "the newer activation remains visible")
	end)

	helpers.it("CapsWord watcher: ignores a clear settlement delivered after watcher stop", function()
		local h = fresh_harness()
		pointer(h)
		h.tasks[1].callback(0, "1", "")
		h.watchers.stop_gesture_watcher(h.watcher)
		settle(h, 1, true)
		helpers.assert_eq(#h.capslock, 0, "a stopped lease owns no later LED callback")
	end)

	helpers.it("CapsWord watcher: cancels delayed LED correction when a newer revision appears", function()
		local h = fresh_harness()
		pointer(h)
		h.tasks[1].callback(0, "1", "")
		settle(h, 1, true)
		local correction = timers_at(h, 0.15)[1]
		helpers.assert_true(correction ~= nil, "the correction timer must be observable")
		h.revision = h.revision + 1
		correction.callback()
		helpers.assert_eq(#h.capslock, 1,
			"the delayed callback must not overwrite the newer activation's LED")
	end)

	helpers.it("CapsWord watcher: a timed-out probe cannot unlock or clear its successor", function()
		local h = fresh_harness()
		pointer(h)
		local first = h.tasks[1]
		local first_watchdog = timers_at(h, 1.5)[1]
		helpers.assert_true(first_watchdog ~= nil, "each probe must have a watchdog")
		first_watchdog.callback()
		helpers.assert_true(first.fake.terminated, "timeout terminates only the exact probe")

		pointer(h)
		helpers.assert_eq(#h.tasks, 2, "a successor probe can start after timeout")
		first.callback(0, "1", "")
		pointer(h)
		helpers.assert_eq(#h.tasks, 2,
			"the stale completion must not release the successor's pending guard")
		helpers.assert_eq(#h.writers, 0, "the stale completion has no write authority")
	end)

	helpers.it("CapsWord watcher: stopped lease A callbacks cannot act on restarted lease B", function()
		local h = fresh_harness()
		local pointer_a = h.pointer_callbacks[1]
		local touch_a = h.hook_calls[1]
		h.watchers.stop_gesture_watcher(h.watcher)
		local watcher_b = h.watchers.start_gesture_watcher(h.gestures, TOKEN_B)
		helpers.assert_true(watcher_b ~= nil, "lease B must start")

		h.clock = h.clock + 1
		pointer_a({})
		touch_a()
		helpers.assert_eq(#h.tasks, 0, "queued lease A callbacks are inert")

		pointer(h, 2)
		helpers.assert_eq(#h.tasks, 1, "lease B callback remains live")
		helpers.assert_eq(h.tasks[1].args[2], SCOPED_B,
			"lease B queries only its own exact runtime variable")
	end)
end)


-- =========================================
-- =========================================
-- ======= 4/ Fail-Closed Resource Start ====
-- =========================================
-- =========================================

helpers.describe("watchers CapsWord resource failures are fail-closed", function()
	helpers.it("CapsWord watcher: failed teardown retains every exact resource for retry", function()
		local h = fresh_harness()
		pointer(h)
		h.tasks[1].callback(0, "1", "")
		settle(h, 1, true)
		local led_timer = timers_at(h, 0.15)[1]
		helpers.assert_true(led_timer ~= nil, "setup must own a delayed LED timer")

		pointer(h)
		local live_task = h.tasks[2].fake
		local live_watchdog = timers_at(h, 1.5)[2]
		helpers.assert_true(live_watchdog ~= nil, "setup must own a live probe watchdog")
		h.fail_teardown_once = true

		helpers.assert_eq(h.watchers.stop_gesture_watcher(h.watcher), false,
			"one failed native resource must keep the teardown unsettled")
		helpers.assert_eq(h.eventtap_stop_attempts, 1)
		helpers.assert_eq(live_task.terminate_attempts, 1)
		helpers.assert_eq(h.timer_cancel_attempts[led_timer], 1)
		helpers.assert_eq(h.timer_cancel_attempts[live_watchdog], 1)
		helpers.assert_eq(h.hook_removal_attempts, 1)

		helpers.assert_eq(h.watchers.stop_gesture_watcher(h.watcher), true,
			"the same exact resources must settle on retry")
		helpers.assert_eq(h.eventtap_stop_attempts, 2)
		helpers.assert_eq(live_task.terminate_attempts, 2)
		helpers.assert_true(live_task.terminated)
		helpers.assert_eq(h.timer_cancel_attempts[led_timer], 2)
		helpers.assert_eq(h.timer_cancel_attempts[live_watchdog], 2)
		helpers.assert_eq(h.hook_removal_attempts, 2)
	end)

	helpers.it("CapsWord watcher: probe constructor failure releases the guard for a retry", function()
		local h = fresh_harness({ task_new_throws = true })
		pointer(h)
		pointer(h)
		helpers.assert_eq(h.task_attempts, 2,
			"both events must reach the throwing constructor, proving the guard reopened")
	end)

	helpers.it("CapsWord watcher: probe start refusal terminates each exact task and permits retries", function()
		local h = fresh_harness({ task_start_false = true })
		pointer(h)
		pointer(h)
		helpers.assert_eq(#h.tasks, 2, "both pointer events must reach task construction")
		helpers.assert_true(h.tasks[1].fake.terminated and h.tasks[2].fake.terminated,
			"each refused probe is reclaimed by exact handle")
	end)

	helpers.it("CapsWord watcher: uncommitted watchdog cannot publish a live probe", function()
		local h = fresh_harness({ timer_uncommitted = true })
		pointer(h)
		helpers.assert_eq(#h.tasks, 1)
		helpers.assert_true(h.tasks[1].fake.terminated,
			"a task without an exactly committed watchdog must be reclaimed")
		pointer(h)
		helpers.assert_eq(#h.tasks, 2,
			"the rejected watchdog must release the pending guard for retry")
		helpers.assert_true(h.tasks[2].fake.terminated)
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
		helpers.assert_eq(h.task_attempts, 0,
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
