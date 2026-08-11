--- tests/unit/platform/remap/test_activation_layout_barrier.lua

--- ==============================================================================
--- MODULE: Exact-Lease Activation Layout Barrier Regression Tests
--- DESCRIPTION:
--- Drives the real remap orchestrator with a token-aware lease double. Proves
--- that a layout notification observed after a config build invalidates that
--- exact generation at both asynchronous activation boundaries: before READY
--- and after RESUME but before RESUMED. The originating resume, enable, or
--- failed-disable rollback intent must survive the fence and complete exactly
--- once with a fresh token built from the post-TIS layout.
--- ==============================================================================

local helpers = require("tests.helpers")

local TOKENS = {
	"00112233445566778899aabbccddeeff",
	"102132435465768798a9babbdcddedef",
	"2031425364758697a8b9cacbdcedfe0f",
}

local STUB_MODULES = {
	"infra.logger",
	"infra.config_paths",
	"infra.timings",
	"platform.remap.defaults",
	"platform.remap.config",
	"platform.remap.generator",
	"platform.remap.ke_lifecycle",
	"platform.remap.lease_controller",
	"platform.remap.watchers",
	"adapters.hotkey_registrar",
	"adapters.timer_scheduler",
	"modules.keylogger.kc_bridge",
	"modules.gestures.engine",
	"modules.shortcuts",
	"hs.caffeinate.watcher",
	"hs",
	"tests.stubs.hs",
	"platform.remap",
}


--- Returns whether a flat list contains one exact value.
--- @param values table Values to scan.
--- @param expected any Exact value to find.
--- @return boolean found
local function contains(values, expected)
	for _, value in ipairs(values) do
		if value == expected then return true end
	end
	return false
end


--- Counts exact occurrences in a flat list.
--- @param values table Values to scan.
--- @param expected any Exact value to count.
--- @return integer count
local function count_value(values, expected)
	local count = 0
	for _, value in ipairs(values) do
		if value == expected then count = count + 1 end
	end
	return count
end


--- Runs one scenario while restoring every process-global test mutation.
--- @param options table Harness state overrides.
--- @param body function Test body receiving (remap, calls).
local function with_remap(options, body)
	options = options or {}
	local previous_getenv = os.getenv
	local previous_hs = _G.hs
	local previous_modules = {}
	for _, name in ipairs(STUB_MODULES) do previous_modules[name] = package.loaded[name] end
	local previous_hs_modules = {}
	for name, value in pairs(package.loaded) do
		if type(name) == "string" and name:match("^hs%.") then
			previous_hs_modules[name] = value
		end
	end

	local initial_phase = options.initial_phase or "prepared"
	local calls = {
		phase = initial_phase,
		current_token = TOKENS[1],
		status_token = TOKENS[1],
		token_index = 1,
		layout_revision = "layout-a",
		resolved_revision = "layout-a",
		resolve_count = 0,
		script_paused = options.paused == true,
		builds = {},
		deploy_tokens = {},
		start_callbacks = {},
		resume_callbacks = {},
		stop_callbacks = {},
		stale_callbacks = {},
		resume_tokens = {},
		stop_exact_tokens = {},
		stop_reasons = {},
		hs_timers = {},
		adapter_timers = {},
		saved_enabled = {},
		logs = {},
		public_stop_deferred = false,
		exact_stop_deferred = nil,
		remaining_layout_timer_failures = options.layout_timer_failures or 0,
		layout_timer_arm_attempts = 0,
	}

	local function publish(phase, token)
		calls.phase = phase
		calls.status_token = token
		if calls.phase_listener then calls.phase_listener(phase, token) end
	end

	local function retain_stale_callback(callback)
		if type(callback) == "function" then
			calls.stale_callbacks[#calls.stale_callbacks + 1] = callback
		end
	end

	local function settle_token_callbacks(field, token, ok, reason)
		local pending = calls[field]
		calls[field] = {}
		for _, item in ipairs(pending) do
			if item.token == token then
				retain_stale_callback(item.callback)
				item.callback(ok == true, reason)
			else
				calls[field][#calls[field] + 1] = item
			end
		end
	end

	local ok, err = xpcall(function()
		local logger = helpers.make_logger_stub()
		for _, level in ipairs({ "debug", "info", "warn", "error", "success" }) do
			logger[level] = function(_, message, ...)
				local rendered_ok, rendered = pcall(string.format, tostring(message), ...)
				calls.logs[#calls.logs + 1] = {
					level = level,
					message = rendered_ok and rendered or tostring(message),
				}
			end
		end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.config_paths"] = {
			get = function() return "tests/unit/platform/remap/activation-layout-barrier.toml" end,
		}
		package.loaded["infra.timings"] = {
			sec = function(category, key)
				helpers.assert_eq(category, "debounce")
				helpers.assert_eq(key, "layout_tis_settle_ms")
				return 0.5
			end,
		}
		package.loaded["platform.remap.defaults"] = {
			tap_hold_timeout_ms = 200,
			sticky_timeout_ms = 1000,
			simultaneous_threshold_ms = 50,
			combo_symmetric = false,
		}
		package.loaded["platform.remap.config"] = {
			load_available_actions = function() return { { id = "none" } } end,
			load_tap_hold_keys = function() return { { id = "left_shift" } } end,
			load_mod_combos = function() return { { id = "left_shift+right_shift" } } end,
			compute_non_canonical_combos = function() return {} end,
			load_user_config = function()
				return {
					enabled = options.enabled ~= false,
					tap_hold_config = {},
					mod_combos_config = {},
					tap_hold_timeout_ms = 200,
					sticky_timeout_ms = 1000,
					simultaneous_threshold_ms = 50,
					combo_symmetric = false,
				}
			end,
			save_user_config = function(state)
				calls.saved_enabled[#calls.saved_enabled + 1] = state.enabled == true
				return true
			end,
			resolve_layout_actions = function()
				calls.resolve_count = calls.resolve_count + 1
				calls.resolved_revision = calls.layout_revision
				return 1
			end,
		}
		package.loaded["platform.remap.generator"] = {
			build_karabiner_json = function(...)
				local token = select(7, ...)
				calls.builds[#calls.builds + 1] = {
					token = token,
					layout = calls.resolved_revision,
				}
				return { token = token }, nil, {}, {}
			end,
			merge_and_deploy_config = function(generated)
				calls.deploy_tokens[#calls.deploy_tokens + 1] = generated.token
				return true, "ok"
			end,
			KE_PHYSICAL_KC_LOG = nil,
		}
		package.loaded["platform.remap.ke_lifecycle"] = {
			open_gui = function() return true end,
			stop = function() return true end,
			notify_ready = function() return true end,
		}

		package.loaded["platform.remap.lease_controller"] = {
			init = function(listener)
				calls.phase_listener = listener
				return true
			end,
			status = function()
				return calls.phase, {
					phase = calls.phase,
					token = calls.status_token,
					activation_blocked = false,
				}
			end,
			token = function()
				if calls.current_token == nil then
					if calls.phase ~= "idle" and calls.phase ~= "failed" then return nil end
					calls.token_index = calls.token_index + 1
					calls.current_token = TOKENS[calls.token_index]
					helpers.assert_type(calls.current_token, "string",
						"test exhausted its fresh-token catalogue")
					publish("prepared", calls.current_token)
				end
				return calls.current_token
			end,
			start = function() error("fresh generations must start PAUSED") end,
			start_paused = function(on_done)
				local token = calls.current_token
				if calls.phase == "paused" and calls.status_token == token then
					on_done(true, "already-paused")
					return true
				end
				if calls.phase ~= "prepared" and calls.phase ~= "starting" then
					on_done(false, "invalid-phase")
					return false
				end
				publish("starting", token)
				calls.start_callbacks[#calls.start_callbacks + 1] = {
					token = token,
					callback = on_done,
				}
				return true
			end,
			resume_prepared = function(token, on_done)
				helpers.assert_eq(token, calls.current_token,
					"RESUME must name the exact current generation")
				calls.resume_tokens[#calls.resume_tokens + 1] = token
				publish("resuming", token)
				calls.resume_callbacks[#calls.resume_callbacks + 1] = {
					token = token,
					callback = on_done,
				}
				return true
			end,
			resume = function(on_done)
				local token = calls.current_token
				calls.resume_tokens[#calls.resume_tokens + 1] = token
				publish("resuming", token)
				calls.resume_callbacks[#calls.resume_callbacks + 1] = {
					token = token,
					callback = on_done,
				}
				return true
			end,
			pause = function(on_done)
				if calls.phase == "paused" then
					if on_done then on_done(true, "already-paused") end
					return true
				end
				if on_done then on_done(false, "invalid-phase") end
				return false
			end,
			stop_exact = function(token, reason, on_done)
				calls.stop_exact_tokens[#calls.stop_exact_tokens + 1] = token
				calls.stop_reasons[#calls.stop_reasons + 1] = reason
				if calls.phase == "stopping" and calls.status_token == token then return true end
				if token ~= calls.current_token then
					if on_done then on_done(true, "generation-gone") end
					return true
				end
				publish("stopping", token)
				settle_token_callbacks("start_callbacks", token, false, "lease-stopping")
				settle_token_callbacks("resume_callbacks", token, false, "lease-stopping")
				if options.defer_exact_stop then
					calls.exact_stop_deferred = { token = token, callback = on_done }
					return true
				end
				calls.current_token = nil
				publish("idle", nil)
				if on_done then on_done(true, "stopped") end
				return true
			end,
			stop = function(reason, on_done)
				calls.stop_reasons[#calls.stop_reasons + 1] = reason
				if options.defer_disable_stop and not calls.public_stop_deferred then
					calls.public_stop_deferred = true
					local token = calls.current_token
					calls.current_token = nil
					publish("stopping", token)
					calls.stop_callbacks[#calls.stop_callbacks + 1] = {
						token = token,
						callback = on_done,
					}
					return true
				end
				local token = calls.current_token
				if token then
					publish("stopping", token)
					settle_token_callbacks("start_callbacks", token, false, "lease-stopping")
					settle_token_callbacks("resume_callbacks", token, false, "lease-stopping")
				end
				calls.current_token = nil
				publish("idle", nil)
				if on_done then on_done(true, "stopped") end
				return true
			end,
			refresh_liveness = function() return true end,
		}

		local function make_handle(kind)
			return { kind = kind, enabled = true }
		end
		package.loaded["platform.remap.watchers"] = {
			start_gesture_watcher = function() return make_handle("gesture") end,
			stop_gesture_watcher = function(handle)
				if handle then handle.enabled = false end
				return true
			end,
			start_cycle_windows_hotkey = function() return make_handle("cycle") end,
			start_alt_tab_windows_hotkey = function() return make_handle("windows") end,
			start_alt_tab_monitor_hotkey = function() return make_handle("monitor") end,
			start_alt_tab_apps_hotkey = function() return make_handle("apps") end,
			stop_alt_tab_apps_tracker = function() return true end,
			start_input_source_watcher = function(callback)
				calls.input_source_callback = callback
				return true
			end,
			stop_input_source_watcher = function() return true end,
		}
		package.loaded["adapters.hotkey_registrar"] = {
			unbind = function(handle)
				if handle then handle.enabled = false end
				return true
			end,
		}
		package.loaded["modules.keylogger.kc_bridge"] = {
			clear_managed_set = function() return true end,
			refresh_managed_set = function() return true end,
		}
		package.loaded["modules.gestures.engine"] = {}
		package.loaded["modules.shortcuts"] = {
			is_paused = function() return calls.script_paused end,
			rebind_for_layout = function() return true end,
		}
		package.loaded["hs.caffeinate.watcher"] = {
			systemDidWake = 7,
			screensDidUnlock = 8,
			new = function()
				return {
					start = function(self) return self end,
					stop = function() return true end,
				}
			end,
		}

		local function make_timer(delay, callback, owner)
			local timer = {
				delay = delay,
				callback = callback,
				running = true,
				fired = false,
				owner = owner,
			}
			function timer:stop()
				self.running = false
				return self
			end
			function timer:fire(force)
				if (not self.running or self.fired) and force ~= true then return false end
				self.running = false
				self.fired = true
				self.callback()
				return true
			end
			return timer
		end

		package.loaded["adapters.timer_scheduler"] = {
			after = function(delay, callback)
				local timer = make_timer(delay, callback, "adapter")
				calls.adapter_timers[#calls.adapter_timers + 1] = timer
				return timer
			end,
			cancel = function(timer)
				if timer then timer:stop() end
				return true
			end,
		}

		os.getenv = function(name)
			if name == "ERGOPTI_REMAP_GUARDIAN_STATUS" then return "ready" end
			return previous_getenv(name)
		end

		package.loaded["hs"] = nil
		package.loaded["tests.stubs.hs"] = nil
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		hs_stub.execute = function() return "", true end
		hs_stub.keycodes = {
			inputSourceChanged = function() end,
			currentLayout = function() return calls.layout_revision end,
			map = { f17 = 64 },
		}
		hs_stub.timer = {
			doAfter = function(delay, callback)
				if delay ~= 2.0 and calls.remaining_layout_timer_failures > 0 then
					calls.remaining_layout_timer_failures = calls.remaining_layout_timer_failures - 1
					calls.layout_timer_arm_attempts = calls.layout_timer_arm_attempts + 1
					return nil
				end
				local timer = make_timer(delay, callback, "hs")
				calls.hs_timers[#calls.hs_timers + 1] = timer
				return timer
			end,
			doEvery = function() return { stop = function() return true end } end,
			secondsSinceEpoch = function() return 1000 end,
			absoluteTime = function() return 0 end,
			usleep = function() end,
		}
		_G.hs = hs_stub
		package.loaded["hs"] = hs_stub
		package.loaded["platform.remap"] = nil
		local remap = require("platform.remap")
		remap.init({
			expand_path = function(path) return path end,
			read = function() return nil end,
		})

		function calls.change_layout(layout)
			calls.layout_revision = layout
			helpers.assert_type(calls.input_source_callback, "function",
				"input-source watcher callback was not retained")
			calls.input_source_callback(layout)
		end

		function calls.deliver_ready(token)
			for index, item in ipairs(calls.start_callbacks) do
				if item.token == token then
					table.remove(calls.start_callbacks, index)
					calls.current_token = token
					publish("paused", token)
					item.callback(true, "ready-paused")
					return true
				end
			end
			return false
		end

		function calls.deliver_all_ready(token)
			local matching = {}
			local remaining = {}
			for _, item in ipairs(calls.start_callbacks) do
				if item.token == token then
					matching[#matching + 1] = item
				else
					remaining[#remaining + 1] = item
				end
			end
			if #matching == 0 then return false end
			calls.start_callbacks = remaining
			calls.current_token = token
			publish("paused", token)
			for _, item in ipairs(matching) do item.callback(true, "ready-paused") end
			return true
		end

		function calls.deliver_resumed(token)
			for index, item in ipairs(calls.resume_callbacks) do
				if item.token == token then
					table.remove(calls.resume_callbacks, index)
					calls.current_token = token
					publish("active", token)
					item.callback(true, "resumed")
					return true
				end
			end
			return false
		end

		function calls.fail_disable_stop(reason)
			local pending = table.remove(calls.stop_callbacks, 1)
			helpers.assert_type(pending, "table", "no retained disable STOP callback")
			calls.current_token = nil
			publish("failed", pending.token)
			calls.status_token = nil
			pending.callback(false, reason or "synthetic-stop-failure")
		end

		function calls.deliver_exact_stopped()
			local pending = calls.exact_stop_deferred
			helpers.assert_type(pending, "table", "no retained exact STOP callback")
			calls.exact_stop_deferred = nil
			calls.current_token = nil
			publish("idle", nil)
			if pending.callback then pending.callback(true, "stopped") end
			return true
		end

		function calls.force_stale_successes()
			local callbacks = calls.stale_callbacks
			calls.stale_callbacks = {}
			for _, callback in ipairs(callbacks) do callback(true, "late-stale-success") end
		end

		function calls.fire_next_async_timer()
			for _, timers in ipairs({ calls.hs_timers, calls.adapter_timers }) do
				for _, timer in ipairs(timers) do
					if timer.running and timer.delay ~= 2.0 then return timer:fire() end
				end
			end
			return false
		end

		function calls.drain_until(predicate)
			for _ = 1, 20 do
				if predicate() then return true end
				if not calls.fire_next_async_timer() then break end
			end
			return predicate()
		end

		body(remap, calls)
	end, debug.traceback)

	os.getenv = previous_getenv
	_G.hs = previous_hs
	for name in pairs(package.loaded) do
		if type(name) == "string" and name:match("^hs%.") then package.loaded[name] = nil end
	end
	for name, value in pairs(previous_hs_modules) do package.loaded[name] = value end
	for _, name in ipairs(STUB_MODULES) do package.loaded[name] = previous_modules[name] end
	if not ok then error(err, 0) end
end


--- Completes the fresh post-layout generation and proves one final result.
--- @param calls table Harness observations and drivers.
--- @param stale_token string Exact invalidated token.
--- @param expected_layout string Settled layout revision.
--- @param results table Public callback results.
--- @param expected_ok boolean Expected public result after recovery.
--- @return table replacement Fresh build descriptor.
local function complete_replacement(calls, stale_token, expected_layout, results, expected_ok)
	local built = calls.drain_until(function() return #calls.builds >= 2 end)
	helpers.assert_true(built,
		"the retained activation intent must rebuild automatically after TIS settles")
	local replacement = calls.builds[#calls.builds]
	helpers.assert_true(replacement.token ~= stale_token,
		"a layout-invalidated generation must never reuse its fenced token")
	helpers.assert_eq(replacement.layout, expected_layout,
		"the replacement must consume the post-TIS layout")

	if calls.phase == "starting" then
		helpers.assert_true(calls.deliver_ready(replacement.token),
			"the fresh worker must retain a READY callback")
	end
	helpers.assert_eq(count_value(calls.resume_tokens, replacement.token), 1,
		"the fresh token must receive exactly one RESUME")
	helpers.assert_true(calls.deliver_resumed(replacement.token),
		"the fresh token must retain its RESUMED callback")
	helpers.assert_eq(#results, 1, "the originating user intent must settle exactly once")
	helpers.assert_eq(results[1].ok, expected_ok)
	helpers.assert_eq(calls.phase, "active")
	helpers.assert_eq(calls.status_token, replacement.token)
	return replacement
end


--- Drives an event arriving after build but before READY.
--- @param calls table Harness observations and drivers.
--- @param results table Public callback results.
--- @param expected_ok boolean Expected final public result.
--- @return table replacement Fresh build descriptor.
local function race_before_ready(calls, results, expected_ok)
	helpers.assert_true(#calls.builds >= 1, "the activation must build layout A before the race")
	local stale = calls.builds[#calls.builds]
	helpers.assert_eq(stale.layout, "layout-a")
	calls.change_layout("layout-b")

	-- A correct implementation may fence immediately at notification time or at
	-- READY. Drive READY only when the old worker still owns that boundary.
	if calls.phase == "starting" then
		helpers.assert_true(calls.deliver_ready(stale.token),
			"the stale worker must retain its READY callback until fenced")
	end
	helpers.assert_eq(count_value(calls.resume_tokens, stale.token), 0,
		"layout A must never receive RESUME after layout B was observed")
	helpers.assert_true(contains(calls.stop_exact_tokens, stale.token),
		"the exact layout-A token must be fenced before retry")
	helpers.assert_eq(#results, 0,
		"fencing an internal stale attempt must not fail the originating user intent")
	calls.force_stale_successes()
	helpers.assert_eq(#results, 0,
		"a forced late callback from token A must remain unable to settle the intent")
	return complete_replacement(calls, stale.token, "layout-b", results, expected_ok)
end





-- ===============================================================
-- ===============================================================
-- ======= 1/ Layout-Fenced Activation Intent Preservation =======
-- ===============================================================
-- ===============================================================

helpers.describe("Karabiner activation layout barrier", function()
	helpers.it("retries Resume when layout changes between build and READY", function()
		with_remap({ enabled = true, paused = true, initial_phase = "prepared" }, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			race_before_ready(calls, results, true)
		end)
	end)

	helpers.it("preserves every joined Resume callback across the same layout fence", function()
		with_remap({ enabled = true, paused = true, initial_phase = "prepared" }, function(remap, calls)
			local first_results = {}
			local second_results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				first_results[#first_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_true(remap.resume(function(ok, reason)
				second_results[#second_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#calls.builds, 2,
				"the fixture must join two regenerations at the shared READY boundary")
			local stale = calls.builds[1]

			calls.change_layout("layout-b")
			if calls.phase == "starting" then
				helpers.assert_true(calls.deliver_ready(stale.token))
			end
			helpers.assert_eq(#first_results, 0,
				"the first joined caller must remain pending behind the internal fence")
			helpers.assert_eq(#second_results, 0,
				"the second joined caller must remain pending behind the internal fence")
			calls.force_stale_successes()
			helpers.assert_eq(#first_results, 0)
			helpers.assert_eq(#second_results, 0)

			helpers.assert_true(calls.drain_until(function() return #calls.builds >= 3 end),
				"joined callers must share one automatic post-TIS replacement")
			local replacement = calls.builds[#calls.builds]
			helpers.assert_true(replacement.token ~= stale.token)
			helpers.assert_eq(replacement.layout, "layout-b")
			helpers.assert_true(calls.deliver_ready(replacement.token))
			helpers.assert_true(calls.deliver_resumed(replacement.token))
			helpers.assert_eq(#first_results, 1)
			helpers.assert_true(first_results[1].ok)
			helpers.assert_eq(#second_results, 1)
			helpers.assert_true(second_results[1].ok)
			helpers.assert_eq(#calls.builds, 3,
				"the shared retry must not duplicate the replacement build")
		end)
	end)

	helpers.it("preserves joined Resume callbacks when layout changes during RESUMING", function()
		with_remap({ enabled = true, paused = true, initial_phase = "prepared" }, function(remap, calls)
			local first_results = {}
			local second_results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				first_results[#first_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_true(remap.resume(function(ok, reason)
				second_results[#second_results + 1] = { ok = ok, reason = reason }
			end))
			local stale = calls.builds[1]
			helpers.assert_true(calls.deliver_all_ready(stale.token),
				"both start callbacks must join one activation transaction")
			helpers.assert_eq(count_value(calls.resume_tokens, stale.token), 1,
				"joined READY callers must share exactly one RESUME")
			helpers.assert_eq(calls.phase, "resuming")

			calls.change_layout("layout-b")
			helpers.assert_true(contains(calls.stop_exact_tokens, stale.token))
			helpers.assert_eq(#first_results, 0)
			helpers.assert_eq(#second_results, 0,
				"every joined activation callback must remain behind the layout fence")
			calls.force_stale_successes()
			helpers.assert_eq(#first_results, 0)
			helpers.assert_eq(#second_results, 0)

			helpers.assert_true(calls.drain_until(function() return #calls.builds >= 3 end))
			local replacement = calls.builds[#calls.builds]
			helpers.assert_eq(replacement.layout, "layout-b")
			helpers.assert_true(replacement.token ~= stale.token)
			helpers.assert_true(calls.deliver_all_ready(replacement.token))
			helpers.assert_true(calls.deliver_resumed(replacement.token))
			helpers.assert_eq(#first_results, 1)
			helpers.assert_true(first_results[1].ok)
			helpers.assert_eq(#second_results, 1)
			helpers.assert_true(second_results[1].ok)
			helpers.assert_eq(count_value(calls.resume_tokens, replacement.token), 1)
		end)
	end)

	helpers.it("preserves compatible public and Resume intents across one layout fence", function()
		with_remap({ enabled = true, paused = false, initial_phase = "prepared" }, function(remap, calls)
			local public_results = {}
			local resume_results = {}
			helpers.assert_true(remap.regenerate(function(ok, reason)
				public_results[#public_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_true(remap.resume(function(ok, reason)
				resume_results[#resume_results + 1] = { ok = ok, reason = reason }
			end))
			local stale = calls.builds[1]
			helpers.assert_true(calls.deliver_all_ready(stale.token))
			helpers.assert_eq(count_value(calls.resume_tokens, stale.token), 1)

			calls.change_layout("layout-b")
			helpers.assert_true(contains(calls.stop_exact_tokens, stale.token))
			helpers.assert_eq(#public_results, 0)
			helpers.assert_eq(#resume_results, 0,
				"compatible ACTIVE intents must share the retained replacement")
			calls.force_stale_successes()
			helpers.assert_eq(#public_results, 0)
			helpers.assert_eq(#resume_results, 0)

			helpers.assert_true(calls.drain_until(function() return #calls.builds >= 3 end))
			local replacement = calls.builds[#calls.builds]
			helpers.assert_eq(replacement.layout, "layout-b")
			helpers.assert_true(replacement.token ~= stale.token)
			helpers.assert_true(calls.deliver_all_ready(replacement.token))
			helpers.assert_true(calls.deliver_resumed(replacement.token))
			helpers.assert_eq(#public_results, 1)
			helpers.assert_true(public_results[1].ok)
			helpers.assert_eq(#resume_results, 1)
			helpers.assert_true(resume_results[1].ok)
		end)
	end)

	helpers.it("revalidates each joined success after a callback changes layout", function()
		with_remap({ enabled = true, paused = false, initial_phase = "prepared" }, function(remap, calls)
			local first_results = {}
			local second_results = {}
			helpers.assert_true(remap.regenerate(function(ok, reason)
				first_results[#first_results + 1] = { ok = ok, reason = reason }
				if ok then calls.change_layout("layout-b") end
			end))
			helpers.assert_true(remap.regenerate(function(ok, reason)
				second_results[#second_results + 1] = { ok = ok, reason = reason }
			end))
			local stale = calls.builds[1]
			helpers.assert_true(calls.deliver_all_ready(stale.token))
			helpers.assert_eq(count_value(calls.resume_tokens, stale.token), 1)
			helpers.assert_true(calls.deliver_resumed(stale.token))

			helpers.assert_eq(#first_results, 1)
			helpers.assert_true(first_results[1].ok,
				"the first callback observed a valid ACTIVE token before changing layout")
			helpers.assert_eq(#second_results, 0,
				"a captured success must be revalidated after an earlier callback changes layout")
			helpers.assert_true(contains(calls.stop_exact_tokens, stale.token))
			helpers.assert_eq(calls.phase, "idle")
			calls.force_stale_successes()
			helpers.assert_eq(#second_results, 0)

			helpers.assert_true(calls.drain_until(function() return #calls.builds >= 3 end))
			local replacement = calls.builds[#calls.builds]
			helpers.assert_eq(replacement.layout, "layout-b")
			helpers.assert_true(replacement.token ~= stale.token)
			helpers.assert_true(calls.deliver_all_ready(replacement.token))
			helpers.assert_true(calls.deliver_resumed(replacement.token))
			helpers.assert_eq(#first_results, 1)
			helpers.assert_eq(#second_results, 1)
			helpers.assert_true(second_results[1].ok)
			helpers.assert_eq(calls.phase, "active")
		end)
	end)

	helpers.it("fences Resume when layout changes between RESUME and RESUMED", function()
		with_remap({ enabled = true, paused = true, initial_phase = "paused" }, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			local stale = calls.builds[#calls.builds]
			helpers.assert_eq(stale.layout, "layout-a")
			helpers.assert_eq(count_value(calls.resume_tokens, stale.token), 1,
				"fixture must reach the RESUMING boundary")

			calls.change_layout("layout-b")
			helpers.assert_true(contains(calls.stop_exact_tokens, stale.token),
				"a layout event during RESUMING must fence that exact token immediately")
			helpers.assert_eq(#results, 0,
				"the internal fence must preserve the public Resume intent")
			calls.force_stale_successes()
			helpers.assert_eq(#results, 0,
				"late RESUMED from token A must not publish success")
			complete_replacement(calls, stale.token, "layout-b", results, true)
		end)
	end)

	helpers.it("waits for asynchronous STOPPED before rebuilding the settled layout", function()
		with_remap({
			enabled = true,
			paused = true,
			initial_phase = "paused",
			defer_exact_stop = true,
		}, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			local stale = calls.builds[1]
			calls.change_layout("layout-b")
			helpers.assert_eq(calls.phase, "stopping",
				"an accepted exact STOP is not yet proof that the old token is fenced")
			helpers.assert_eq(#results, 0)

			helpers.assert_true(calls.fire_next_async_timer(),
				"the post-TIS barrier timer must be observable while STOPPED is pending")
			helpers.assert_eq(#calls.builds, 1,
				"the replacement must not build while the invalidated token may still emit")
			calls.force_stale_successes()
			helpers.assert_eq(#results, 0)

			calls.deliver_exact_stopped()
			complete_replacement(calls, stale.token, "layout-b", results, true)
		end)
	end)

	helpers.it("defers an ACTIVE public regeneration until TIS settles", function()
		with_remap({ enabled = true, paused = false, initial_phase = "prepared" }, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.regenerate())
			local active_token = calls.builds[1].token
			helpers.assert_true(calls.deliver_all_ready(active_token))
			helpers.assert_true(calls.deliver_resumed(active_token))
			calls.resolve_count = 0
			calls.builds = {}
			calls.deploy_tokens = {}
			calls.change_layout("layout-b")
			local settle_timer = calls.hs_timers[#calls.hs_timers]
			helpers.assert_true(remap.regenerate(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(calls.resolve_count, 0,
				"a pre-settle public request must not read the old TIS map")
			helpers.assert_eq(#calls.builds, 0)
			helpers.assert_eq(#calls.deploy_tokens, 0)
			helpers.assert_eq(#results, 0)

			settle_timer:fire()
			helpers.assert_eq(calls.resolve_count, 1)
			helpers.assert_eq(#calls.builds, 1)
			helpers.assert_eq(calls.builds[1].layout, "layout-b")
			helpers.assert_eq(#calls.deploy_tokens, 1)
			helpers.assert_eq(#results, 1)
			helpers.assert_true(results[1].ok, tostring(results[1].reason))
			for _ = 1, 10 do
				if not calls.fire_next_async_timer() then break end
			end
			helpers.assert_eq(#calls.builds, 1,
				"consuming the retained layout record must not redeploy the same serial")
			helpers.assert_eq(#results, 1)
		end)
	end)

	helpers.it("defers a PREPARED cold-start regeneration until TIS settles", function()
		with_remap({ enabled = true, paused = false, initial_phase = "prepared" }, function(remap, calls)
			local results = {}
			calls.change_layout("layout-b")
			helpers.assert_true(remap.regenerate(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(calls.resolve_count, 0)
			helpers.assert_eq(#calls.builds, 0)
			helpers.assert_eq(#calls.deploy_tokens, 0)
			helpers.assert_eq(#results, 0)

			helpers.assert_true(calls.drain_until(function() return #calls.builds == 1 end))
			local replacement = calls.builds[1]
			helpers.assert_eq(replacement.layout, "layout-b")
			helpers.assert_eq(calls.resolve_count, 1)
			helpers.assert_true(calls.deliver_all_ready(replacement.token))
			helpers.assert_true(calls.deliver_resumed(replacement.token))
			helpers.assert_eq(#results, 1)
			helpers.assert_true(results[1].ok)
		end)
	end)

	helpers.it("keeps PREPARED fail-closed after the layout timer budget exhausts", function()
		with_remap({
			enabled = true,
			paused = false,
			initial_phase = "prepared",
			layout_timer_failures = 4,
		}, function(remap, calls)
			local exhausted_results = {}
			calls.change_layout("layout-b")
			helpers.assert_eq(calls.layout_timer_arm_attempts, 4,
				"the initial arm and three bounded retries must all fail")
			helpers.assert_true(not remap.regenerate(function(ok, reason)
				exhausted_results[#exhausted_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#exhausted_results, 1)
			helpers.assert_true(exhausted_results[1].ok == false)
			helpers.assert_eq(exhausted_results[1].reason, "layout-refresh-exhausted")
			helpers.assert_eq(calls.resolve_count, 0)
			helpers.assert_eq(#calls.builds, 0)
			helpers.assert_eq(#calls.deploy_tokens, 0)

			local recovered_results = {}
			calls.change_layout("layout-c")
			helpers.assert_true(remap.regenerate(function(ok, reason)
				recovered_results[#recovered_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#calls.builds, 0)
			helpers.assert_true(calls.drain_until(function() return #calls.builds == 1 end))
			local replacement = calls.builds[1]
			helpers.assert_eq(replacement.layout, "layout-c")
			helpers.assert_true(calls.deliver_all_ready(replacement.token))
			helpers.assert_true(calls.deliver_resumed(replacement.token))
			helpers.assert_eq(#recovered_results, 1)
			helpers.assert_true(recovered_results[1].ok)
			helpers.assert_eq(#exhausted_results, 1)
		end)
	end)

	helpers.it("keeps ACTIVE fail-closed after the layout timer budget exhausts", function()
		with_remap({
			enabled = true,
			paused = false,
			initial_phase = "prepared",
			layout_timer_failures = 4,
		}, function(remap, calls)
			helpers.assert_true(remap.regenerate())
			local active_token = calls.builds[1].token
			helpers.assert_true(calls.deliver_all_ready(active_token))
			helpers.assert_true(calls.deliver_resumed(active_token))
			calls.resolve_count = 0
			calls.builds = {}
			calls.deploy_tokens = {}

			local exhausted_results = {}
			calls.change_layout("layout-b")
			helpers.assert_eq(calls.layout_timer_arm_attempts, 4)
			helpers.assert_true(not remap.regenerate(function(ok, reason)
				exhausted_results[#exhausted_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#exhausted_results, 1)
			helpers.assert_eq(exhausted_results[1].reason, "layout-refresh-exhausted")
			helpers.assert_eq(calls.resolve_count, 0)
			helpers.assert_eq(#calls.builds, 0)
			helpers.assert_eq(#calls.deploy_tokens, 0)

			local recovered_results = {}
			calls.change_layout("layout-c")
			helpers.assert_true(remap.regenerate(function(ok, reason)
				recovered_results[#recovered_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_true(calls.drain_until(function() return #calls.builds == 1 end))
			helpers.assert_eq(calls.builds[1].layout, "layout-c")
			helpers.assert_eq(#recovered_results, 1)
			helpers.assert_true(recovered_results[1].ok)
			helpers.assert_eq(#exhausted_results, 1)
		end)
	end)

	helpers.it("retries Enable when layout changes before READY", function()
		with_remap({ enabled = false, paused = false, initial_phase = "prepared" }, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.set_enabled(true, function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_true(remap.get_enabled() == false,
				"Enable must not commit before a layout-current ACTIVE token exists")
			race_before_ready(calls, results, true)
			helpers.assert_true(remap.get_enabled(),
				"the preserved Enable intent must commit after the fresh token activates")
		end)
	end)

	helpers.it("retries failed-Disable rollback when layout changes before READY", function()
		with_remap({
			enabled = true,
			paused = false,
			initial_phase = "active",
			defer_disable_stop = true,
		}, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.set_enabled(false, function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			calls.fail_disable_stop("synthetic-disable-stop-failure")
			helpers.assert_eq(#calls.builds, 1,
				"failed Disable must start exactly one rollback generation before the race")
			race_before_ready(calls, results, false)
			helpers.assert_true(remap.get_enabled(),
				"failed Disable rollback must restore the enabled intent on the fresh token")
		end)
	end)

	helpers.it("coalesces retained layout B into C and deploys only the newest event", function()
		with_remap({ enabled = true, paused = true, initial_phase = "paused" }, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			local stale = calls.builds[1]
			helpers.assert_eq(stale.layout, "layout-a")

			calls.change_layout("layout-b")
			helpers.assert_true(contains(calls.stop_exact_tokens, stale.token),
				"the first physical event must retain the intent behind an exact fence")
			helpers.assert_eq(#results, 0)
			local layout_b_timer = calls.hs_timers[#calls.hs_timers]
			helpers.assert_type(layout_b_timer, "table")
			helpers.assert_true(layout_b_timer.running)

			calls.change_layout("layout-c")
			local layout_c_timer = calls.hs_timers[#calls.hs_timers]
			helpers.assert_true(layout_c_timer ~= layout_b_timer,
				"the second physical event must replace the retained B timer")
			helpers.assert_true(not layout_b_timer.running,
				"the superseded B timer must be cancelled before C can settle")
			layout_b_timer:fire(true)
			helpers.assert_eq(#calls.builds, 1,
				"a forcibly delivered stale B callback must not build layout B")
			helpers.assert_eq(#calls.deploy_tokens, 1,
				"a forcibly delivered stale B callback must not deploy layout B")
			calls.force_stale_successes()
			helpers.assert_eq(#results, 0,
				"late token-A success must not settle the retained Resume intent")

			local replacement = complete_replacement(
				calls,
				stale.token,
				"layout-c",
				results,
				true
			)
			helpers.assert_eq(#calls.builds, 2,
				"coalesced physical events must produce only the original and newest builds")
			for _, build in ipairs(calls.builds) do
				helpers.assert_true(build.layout ~= "layout-b",
					"superseded layout B must never reach the generator")
			end
			helpers.assert_eq(#calls.deploy_tokens, 2)
			helpers.assert_eq(calls.deploy_tokens[1], stale.token)
			helpers.assert_eq(calls.deploy_tokens[2], replacement.token,
				"only the layout-C replacement token may be deployed after the race")

			for _ = 1, 10 do
				if not calls.fire_next_async_timer() then break end
			end
			helpers.assert_eq(#calls.builds, 2,
				"final replay must consume C without a duplicate regeneration")
			helpers.assert_eq(#calls.deploy_tokens, 2)
			helpers.assert_eq(#results, 1,
				"coalescing and final replay must settle the public callback exactly once")
		end)
	end)

	helpers.it("cancels a retained Resume exactly once when the user pauses", function()
		with_remap({ enabled = true, paused = true, initial_phase = "paused" }, function(remap, calls)
			local resume_results = {}
			local pause_results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				resume_results[#resume_results + 1] = { ok = ok, reason = reason }
			end))
			local stale = calls.builds[1]

			calls.change_layout("layout-b")
			helpers.assert_true(contains(calls.stop_exact_tokens, stale.token))
			helpers.assert_eq(#resume_results, 0,
				"the layout fence itself must retain rather than fail Resume")
			helpers.assert_true(remap.pause(function(ok, reason)
				pause_results[#pause_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#resume_results, 1,
				"the explicit Pause must cancel the retained Resume exactly once")
			helpers.assert_true(resume_results[1].ok == false)
			helpers.assert_eq(resume_results[1].reason, "script-pause-requested")
			helpers.assert_eq(#pause_results, 1)
			helpers.assert_true(pause_results[1].ok)
			helpers.assert_eq(calls.phase, "idle")

			calls.force_stale_successes()
			for _ = 1, 10 do
				if not calls.fire_next_async_timer() then break end
			end
			calls.force_stale_successes()
			helpers.assert_eq(#resume_results, 1,
				"late callbacks and settled layout replay must not resettle cancelled Resume")
			helpers.assert_eq(#calls.builds, 1,
				"Pause cancellation must prevent every post-layout activation retry")
			helpers.assert_eq(#calls.deploy_tokens, 1,
				"Pause cancellation must not deploy a replacement generation")
			helpers.assert_eq(calls.token_index, 1,
				"Pause cancellation must not allocate a replacement lease token")
		end)
	end)

	helpers.it("lets Pause cancel a layout-invalidated Resume before READY", function()
		with_remap({ enabled = true, paused = true, initial_phase = "prepared" }, function(remap, calls)
			local resume_results = {}
			local pause_results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				resume_results[#resume_results + 1] = { ok = ok, reason = reason }
			end))
			local stale = calls.builds[1]
			helpers.assert_eq(calls.phase, "starting")

			calls.change_layout("layout-b")
			helpers.assert_true(contains(calls.stop_exact_tokens, stale.token),
				"the STARTING generation must be retained and fenced before READY")
			helpers.assert_eq(#resume_results, 0)
			helpers.assert_true(remap.pause(function(ok, reason)
				pause_results[#pause_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#resume_results, 1)
			helpers.assert_true(resume_results[1].ok == false)
			helpers.assert_eq(resume_results[1].reason, "script-pause-requested")
			helpers.assert_eq(#pause_results, 1)
			helpers.assert_true(pause_results[1].ok)

			calls.force_stale_successes()
			for _ = 1, 10 do
				if not calls.fire_next_async_timer() then break end
			end
			calls.force_stale_successes()
			helpers.assert_eq(#resume_results, 1)
			helpers.assert_eq(#calls.builds, 1,
				"the older Resume intent must never rebuild after the newer Pause")
			helpers.assert_eq(#calls.deploy_tokens, 1)
			helpers.assert_eq(calls.token_index, 1)
		end)
	end)
end)
