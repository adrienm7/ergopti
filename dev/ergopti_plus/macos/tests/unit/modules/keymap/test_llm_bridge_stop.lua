--- tests/unit/modules/keymap/test_llm_bridge_stop.lua

--- ==============================================================================
--- MODULE: LLM Bridge M.stop() Regression Tests
--- DESCRIPTION:
--- Guards the escape-trap lifecycle in modules/keymap/llm_bridge.lua with a
--- self-contained dependency fixture that cannot inherit another test's partial
--- tooltip or prediction-engine double.
---
--- ROOT CAUSE ENCODED:
--- arm_escape_trap() created a persistent hs.eventtap that intercepted Escape.
--- No M.stop() existed, so the tap continued to fire after the keymap module
--- was stopped (e.g. during a Hammerspoon reload). The orphaned tap consumed
--- Escape in every subsequent application until a full HS restart.
---
--- The fix verifies both start and stop against :isEnabled(). A failed start
--- never becomes published ownership, while a failed stop retains the only
--- handle so a later lifecycle attempt can retry it.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ========================================
-- ========================================
-- ======= 1/ Isolated Test Fixture =======
-- ========================================
-- ========================================

local function noop() end
local function return_true() return true end
local function return_false() return false end
local function return_empty_table() return {} end

--- Copies every populated package cache slot by identity.
--- @return table snapshot Exact package.loaded snapshot.
local function snapshot_package_loaded()
	local snapshot = {}
	for name, module in pairs(package.loaded) do snapshot[name] = module end
	return snapshot
end

--- Restores package.loaded exactly, removing modules created by the fixture.
--- @param snapshot table Snapshot returned by snapshot_package_loaded().
local function restore_package_loaded(snapshot)
	for name in pairs(package.loaded) do
		if snapshot[name] == nil then package.loaded[name] = nil end
	end
	for name, module in pairs(snapshot) do package.loaded[name] = module end
end

--- Builds the complete tooltip surface consumed by the bridge and its engine.
--- @param fixture table Mutable callback capture owned by one scenario.
--- @return table tooltip Strict tooltip double.
local function make_tooltip(fixture)
	return {
		setup = return_true,
		set_timeout = return_true,
		set_llm_timeout = return_true,
		set_colorization_enabled = return_true,
		hide = return_true,
		hide_forced = return_true,
		hide_forced_silent = return_true,
		is_visible = return_false,
		set_on_show_callback = function(callback)
			fixture.show_callback = callback
			return true
		end,
		set_runtime_guard = return_true,
		show = return_true,
		show_stacked = return_true,
		show_loading = return_true,
		show_predictions = return_true,
		navigate = return_false,
		set_navigate_callback = function(callback)
			fixture.navigate_callback = callback
			return true
		end,
		set_accept_callback = function(callback)
			fixture.accept_callback = callback
			return true
		end,
		set_cancel_callback = function(callback)
			fixture.cancel_callback = callback
			return true
		end,
		set_enter_validates = return_true,
		get_current_index = function() return 1 end,
		is_llm_visible = return_false,
		is_hotstring_visible = return_false,
		has_visible_hotstring_lease = return_false,
		make_diff_styled = function(text) return text end,
		reset_llm_timer = return_true,
		set_chain_start = return_true,
		mark_chain_complete = return_true,
		tint = return_empty_table,
		set_accent_color = return_true,
	}
end

--- Builds the prediction-engine surface consumed by the bridge.
--- @return table engine Strict prediction-engine double.
local function make_prediction_engine()
	local enabled = false
	return {
		set_preview_ai_enabled = noop,
		set_preview_ai_color = noop,
		set_llm_enabled = function(value) enabled = value == true end,
		get_llm_enabled = function() return enabled end,
		set_llm_model = noop,
		set_llm_display_model_name = noop,
		set_llm_backend_name = noop,
		set_llm_context_length = noop,
		set_llm_temperature = noop,
		set_llm_num_predictions = noop,
		set_llm_pred_indent = noop,
		set_llm_show_info_bar = noop,
		set_llm_sequential_mode = noop,
		set_llm_auto_raise_temp = noop,
		set_llm_streaming = noop,
		set_llm_streaming_multi = noop,
		set_llm_instant_on_word_end = noop,
		set_llm_disabled_apps = noop,
		set_llm_url_bar_filter_enabled = noop,
		set_llm_secure_field_filter_enabled = noop,
		set_llm_val_modifiers = noop,
		set_llm_nav_modifiers = noop,
		set_llm_min_words = noop,
		set_llm_max_words = noop,
		set_llm_debounce = noop,
		perform_check = noop,
		reset = return_true,
		consume = function() return nil, {} end,
		arm_chain = noop,
		set_runtime_guard = noop,
		init = return_true,
		start_timer = return_true,
		start_timer_word_end = return_true,
		stop_timer = return_true,
		handle_chain_signal = return_false,
		is_visible = return_false,
		is_chain_pending = return_false,
		get_predictions = return_empty_table,
		get_current_index = function() return 1 end,
		navigate = return_false,
		normalize_mods = return_empty_table,
		get_navigation_mods = return_empty_table,
		get_validation_mods = return_empty_table,
	}
end

--- Runs one bridge scenario with exact dependency and global restoration.
--- @param callback function Scenario receiving the isolated fixture.
--- @param options table|nil Optional preloaded tooltip or provenance double.
--- @return ... Scenario results.
local function with_bridge_fixture(callback, options)
	options = options or {}
	local baseline_loaded = snapshot_package_loaded()
	local baseline_hs = rawget(_G, "hs")

	if options.preloaded_tooltip ~= nil then
		package.loaded["ui.tooltip"] = options.preloaded_tooltip
	end
	local pre_fixture_loaded = snapshot_package_loaded()
	local pre_fixture_hs = rawget(_G, "hs")

	local outcome = table.pack(xpcall(function()
		local fixture = {}
		fixture.tooltip = make_tooltip(fixture)
		fixture.engine = make_prediction_engine()
		package.loaded["ui.tooltip"] = fixture.tooltip
		package.loaded["modules.llm.prediction_engine"] = fixture.engine
		package.loaded["infra.logger"] = nil
		package.loaded["adapters.event_provenance"] = options.event_provenance
		fixture.bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
		fixture.hs = rawget(_G, "hs")
		fixture.logger = package.loaded["infra.logger"]
		return callback(fixture)
	end, debug.traceback))

	restore_package_loaded(pre_fixture_loaded)
	_G.hs = pre_fixture_hs
	local preloaded_restored = options.preloaded_tooltip == nil
		or package.loaded["ui.tooltip"] == options.preloaded_tooltip
	restore_package_loaded(baseline_loaded)
	_G.hs = baseline_hs

	if not preloaded_restored then
		error("bridge fixture did not restore the preloaded tooltip identity", 0)
	end
	if not outcome[1] then error(outcome[2], 0) end
	return (table.unpack or unpack)(outcome, 2, outcome.n)
end





-- ====================================================
-- ====================================================
-- ======= 2/ M.stop() existence & basic safety =======
-- ====================================================
-- ====================================================

helpers.describe("llm_bridge M.stop(): existence (escape-trap-ghost-tap)", function()
	helpers.it("M.stop is a function (escape-trap-ghost-tap)", function()
		with_bridge_fixture(function(fixture)
			helpers.assert_eq(type(fixture.bridge.stop), "function",
				"llm_bridge must export M.stop() (escape-trap-ghost-tap)")
		end)
	end)

	helpers.it("M.stop() does not raise before the trap is armed (escape-trap-ghost-tap)", function()
		with_bridge_fixture(function(fixture)
			-- A defensive stop before start must leave the bridge usable
			helpers.assert_eq(fixture.bridge.stop(), true)
			helpers.assert_eq(type(fixture.bridge.init), "function",
				"a stop with no escape trap armed must leave the bridge usable")
		end)
	end)

	helpers.it("M.stop() is idempotent — safe to call twice (escape-trap-ghost-tap)", function()
		with_bridge_fixture(function(fixture)
			local ok1, result1 = pcall(fixture.bridge.stop)
			local ok2, result2 = pcall(fixture.bridge.stop)
			helpers.assert_true(ok1 and ok2, "M.stop() must be safe to call multiple times in a row")
			helpers.assert_eq(result1, true)
			helpers.assert_eq(result2, true)
		end)
	end)
end)





-- ==============================================================
-- ==============================================================
-- ======= 3/ escape trap stopped when M.stop() is called =======
-- ==============================================================
-- ==============================================================

helpers.describe("llm_bridge M.stop(): stops the escape trap (escape-trap-ghost-tap)", function()
	helpers.it("M.stop() calls :stop() on the eventtap created by arm_escape_trap() (escape-trap-ghost-tap)", function()
		local original_tooltip = package.loaded["ui.tooltip"]
		local original_hs = rawget(_G, "hs")
		local partial_calls = 0
		local partial_tooltip = {
			set_on_show_callback = function() partial_calls = partial_calls + 1 end,
		}
		local trap_stopped = false

		with_bridge_fixture(function(fixture)
			local trap_enabled = false
			local mock_trap = {
				start = function(self) trap_enabled = true; return self end,
				stop = function(self) trap_stopped = true; trap_enabled = false; return self end,
				isEnabled = function() return trap_enabled end,
			}
			fixture.hs.eventtap.new = function() return mock_trap end

			helpers.assert_eq(type(fixture.show_callback), "function",
				"the isolated tooltip must receive arm_escape_trap")
			helpers.assert_eq(fixture.show_callback(), true)
			helpers.assert_eq(fixture.bridge.stop(), true)
		end, { preloaded_tooltip = partial_tooltip })

		helpers.assert_eq(partial_calls, 0,
			"a partial tooltip left by another test must never satisfy this fixture")
		helpers.assert_eq(package.loaded["ui.tooltip"], original_tooltip,
			"the fixture must restore the caller's package cache")
		helpers.assert_eq(rawget(_G, "hs"), original_hs,
			"the fixture must restore the caller's Hammerspoon global")
		helpers.assert_true(trap_stopped,
			"M.stop() must call :stop() on the escape trap eventtap (escape-trap-ghost-tap)")
	end)

	helpers.it("restores package.loaded and _G.hs when a scenario assertion raises (escape-trap-ghost-tap)", function()
		local original_tooltip = package.loaded["ui.tooltip"]
		local original_engine = package.loaded["modules.llm.prediction_engine"]
		local original_hs = rawget(_G, "hs")
		local partial_tooltip = { hide = noop }
		local ok, err = pcall(function()
			with_bridge_fixture(function()
				error("EXPECTED_FIXTURE_ASSERTION")
			end, { preloaded_tooltip = partial_tooltip })
		end)

		helpers.assert_eq(ok, false, "the sentinel scenario must actually raise")
		helpers.assert_true(tostring(err):find("EXPECTED_FIXTURE_ASSERTION", 1, true) ~= nil,
			"the fixture must preserve the original assertion failure")
		helpers.assert_eq(package.loaded["ui.tooltip"], original_tooltip)
		helpers.assert_eq(package.loaded["modules.llm.prediction_engine"], original_engine)
		helpers.assert_eq(rawget(_G, "hs"), original_hs)
	end)

	helpers.it("retries after a transient start failure instead of publishing a dead trap (escape-trap-ghost-tap)", function()
		with_bridge_fixture(function(fixture)
			local created, starts = 0, 0
			fixture.hs.eventtap.new = function()
				created = created + 1
				local ordinal = created
				local enabled = false
				return {
					start = function(self)
						starts = starts + 1
						if ordinal == 1 then error("START_FAIL") end
						enabled = true
						return self
					end,
					stop = function(self) enabled = false; return self end,
					isEnabled = function() return enabled end,
				}
			end

			helpers.assert_eq(type(fixture.show_callback), "function")
			helpers.assert_eq(fixture.show_callback(), false,
				"a thrown native start cannot own visible tooltip interaction")
			helpers.assert_eq(fixture.show_callback(), true,
				"a later show must retry and commit after the transient failure")
			helpers.assert_eq(created, 2,
				"the failed disabled candidate must not block a fresh eventtap")
			helpers.assert_eq(starts, 2)
			helpers.assert_eq(fixture.bridge.stop(), true)
		end)
	end)

	helpers.it("retains and retries the handle when stop raises (escape-trap-ghost-tap)", function()
		with_bridge_fixture(function(fixture)
			local enabled, stop_calls = false, 0
			fixture.hs.eventtap.new = function()
				return {
					start = function(self) enabled = true; return self end,
					stop = function(self)
						stop_calls = stop_calls + 1
						if stop_calls == 1 then error("STOP_FAIL") end
						enabled = false
						return self
					end,
					isEnabled = function() return enabled end,
				}
			end

			helpers.assert_eq(fixture.show_callback(), true)
			helpers.assert_eq(fixture.bridge.stop(), false,
				"a thrown native stop must remain an incomplete lifecycle step")
			helpers.assert_eq(enabled, true)
			helpers.assert_eq(fixture.bridge.stop(), true,
				"the retained handle must make the next teardown attempt effective")
			helpers.assert_eq(enabled, false)
			helpers.assert_eq(stop_calls, 2)
			helpers.assert_eq(fixture.bridge.stop(), true)
			helpers.assert_eq(stop_calls, 2,
				"verified teardown releases the handle and becomes idempotent")
		end)
	end)

	helpers.it("retains the handle when stop returns but the tap remains enabled (escape-trap-ghost-tap)", function()
		with_bridge_fixture(function(fixture)
			local enabled, stop_calls = false, 0
			fixture.hs.eventtap.new = function()
				return {
					start = function(self) enabled = true; return self end,
					stop = function(self)
						stop_calls = stop_calls + 1
						if stop_calls > 1 then enabled = false end
						return self
					end,
					isEnabled = function() return enabled end,
				}
			end

			helpers.assert_eq(fixture.show_callback(), true)
			helpers.assert_eq(fixture.bridge.stop(), false)
			helpers.assert_eq(enabled, true,
				"a no-op stop must be detected through native state")
			helpers.assert_eq(fixture.bridge.stop(), true)
			helpers.assert_eq(stop_calls, 2)
		end)
	end)

	helpers.it("contains and file-logs a throw at the first Escape callback line (escape-trap-ghost-tap)", function()
		local throwing_provenance = {
			STATUS_UNREADABLE = "unreadable",
			classify_with_fence = function() error("CLASSIFY_THROW") end,
		}
		with_bridge_fixture(function(fixture)
			local event_callback
			local error_count = 0
			local enabled = false
			local original_logger_error = fixture.logger.error
			fixture.logger.error = function(...)
				error_count = error_count + 1
				return original_logger_error(...)
			end
			fixture.hs.eventtap.new = function(_, callback)
				event_callback = callback
				return {
					start = function(self) enabled = true; return self end,
					stop = function(self) enabled = false; return self end,
					isEnabled = function() return enabled end,
				}
			end

			helpers.assert_eq(fixture.show_callback(), true)
			local callback_ok, consumed = pcall(event_callback, {})
			helpers.assert_true(callback_ok, "the Quartz callback boundary must contain the throw")
			helpers.assert_eq(consumed, false, "a failed classifier must pass the physical key through")
			helpers.assert_true(error_count >= 1,
				"the swallowed Hammerspoon callback error must reach the file logger")
			helpers.assert_eq(fixture.bridge.stop(), true)
		end, { event_provenance = throwing_provenance })
	end)
end)
