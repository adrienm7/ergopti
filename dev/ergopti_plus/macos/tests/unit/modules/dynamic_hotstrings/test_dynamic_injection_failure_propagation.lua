--- tests/unit/modules/dynamic_hotstrings/test_dynamic_injection_failure_propagation.lua

--- ==============================================================================
--- MODULE: Dynamic injection failure propagation
--- DESCRIPTION:
--- A replacement transaction can reject construction by returning false without
--- throwing. The shared keymap choke point and both dynamic-hotstring consumers
--- must preserve that status; treating `pcall == true` as injection success eats
--- the user's magic key while producing no replacement.
--- ==============================================================================

local helpers = require("tests.helpers")


local function noop() end


local function refresh_personal_data(_, publisher)
	return publisher() == true
end


local function api(overrides)
	return setmetatable(overrides or {}, {
		__index = function(target, key)
			rawset(target, key, noop)
			return noop
		end,
	})
end


local function reset_driver_modules()
	for name in pairs(package.loaded) do
		if type(name) == "string"
			and (name:find("^modules%.") or name:find("^adapters%.")
				or name:find("^infra%.") or name:find("^ui%.")) then
			package.loaded[name] = nil
		end
	end
	package.loaded["dynamic_hotstrings"] = nil
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	return hs_stub
end


local function logger_capture()
	local capture = { errors = {}, successes = {} }
	local logger = helpers.make_logger_stub()
	logger.error = function(_, format, ...)
		capture.errors[#capture.errors + 1] = string.format(format, ...)
	end
	logger.info = function(_, format, ...)
		capture.successes[#capture.successes + 1] = string.format(format, ...)
	end
	package.loaded["infra.logger"] = logger
	return capture
end


local function fake_event(chars)
	return {
		getFlags = function() return {} end,
		getKeyCode = function() return 0 end,
		getCharacters = function() return chars end,
	}
end


helpers.describe("keymap.inject_dynamic: replacement status is preserved", function()
	helpers.it("returns the real expander false without mutating the buffer", function()
		reset_driver_modules()
		logger_capture()

		local state = {
			buffer = "typed",
			interceptors = {},
			preview_providers = {},
			ignored_window_titles = {},
			ignored_window_patterns = {},
		}
		local expander_calls = 0
		package.loaded["modules.keymap.state"] = {
			new = function() return state end,
		}
		package.loaded["modules.keymap.registry"] = api({
			init = function() return true end,
			is_repeat_feature_enabled = function() return false end,
			set_repeat_feature_enabled = noop,
		})
		package.loaded["modules.keymap.expander"] = api({
			init = function() return true end,
			perform_text_replacement = function()
				expander_calls = expander_calls + 1
				return false
			end,
		})
		package.loaded["modules.keymap.llm_bridge"] = api({ init = function() return true end })
		package.loaded["modules.keymap.terminator_replay"] = api()
		package.loaded["modules.keymap.utils"] = api()
		package.loaded["adapters.event_provenance"] = api()
		local epoch = {}
		package.loaded["adapters.synthetic_input"] = api({
			current_action_epoch = function() return epoch end,
		})
		package.loaded["infra.text_utils"] = require("text_utils")
		package.loaded["infra.perf"] = api({ is_enabled = function() return false end })
		package.loaded["infra.hotpath_profiler"] = api({ now = function() return 0 end })
		package.loaded["infra.manifest_reader"] = {
			default_for = function(key)
				if key == "hotstrings.trigger_char" then return "\u{2605}" end
				if key == "hotstrings.expansion_delay" then return 0 end
				return false
			end,
		}
		package.loaded["infra.keycodes"] = {
			ESCAPE = 53,
			BACKSPACE = 51,
			RETURN = 36,
		}

		local keymap = require("modules.keymap.init")
		local result = keymap.inject_dynamic(2, "replacement", function()
			return 11, "replacement", "replacement"
		end, "dynamic", true)

		helpers.assert_eq(result, false,
			"inject_dynamic must return perform_text_replacement's acceptance status")
		helpers.assert_eq(expander_calls, 1)
		helpers.assert_eq(state.buffer, "typed",
			"the keymap buffer must not advance after a rejected replacement")
	end)

	helpers.it("rejects malformed cursor context before calling the expander", function()
		reset_driver_modules()
		local logs = logger_capture()

		local state = {
			buffer = "prefix\191",
			llm_buffer = "prefix\191",
			start_is_word_boundary = true,
			interceptors = {},
			preview_providers = {},
			ignored_window_titles = {},
			ignored_window_patterns = {},
		}
		local expander_calls = 0
		local reset_calls = 0
		package.loaded["modules.keymap.state"] = {
			new = function() return state end,
		}
		package.loaded["modules.keymap.registry"] = api({
			init = function() return true end,
			is_repeat_feature_enabled = function() return false end,
			set_repeat_feature_enabled = noop,
		})
		package.loaded["modules.keymap.expander"] = api({
			init = function() return true end,
			perform_text_replacement = function()
				expander_calls = expander_calls + 1
				return true
			end,
		})
		package.loaded["modules.keymap.llm_bridge"] = api({
			init = function() return true end,
			reset_predictions = function()
				reset_calls = reset_calls + 1
				return true
			end,
		})
		package.loaded["modules.keymap.terminator_replay"] = api()
		package.loaded["modules.keymap.utils"] = api()
		package.loaded["adapters.event_provenance"] = api()
		package.loaded["adapters.synthetic_input"] = api({
			current_action_epoch = function() return {} end,
		})
		package.loaded["infra.text_utils"] = require("text_utils")
		package.loaded["infra.perf"] = api({ is_enabled = function() return false end })
		package.loaded["infra.hotpath_profiler"] = api({ now = function() return 0 end })
		package.loaded["infra.manifest_reader"] = {
			default_for = function(key)
				if key == "hotstrings.trigger_char" then return "\u{2605}" end
				if key == "hotstrings.expansion_delay" then return 0 end
				return false
			end,
		}
		package.loaded["infra.keycodes"] = {
			ESCAPE = 53,
			BACKSPACE = 51,
			RETURN = 36,
		}

		local keymap = require("modules.keymap.init")
		local result = keymap.inject_dynamic(1, "X", noop, "dynamic", true)

		helpers.assert_eq(result, false)
		helpers.assert_eq(expander_calls, 0,
			"the expander must not see a replacement built from invalid cursor context")
		helpers.assert_eq(reset_calls, 1)
		helpers.assert_eq(state.buffer, "")
		helpers.assert_eq(state.llm_buffer, "")
		helpers.assert_eq(state.start_is_word_boundary, false)
		helpers.assert_true(#logs.errors > 0,
			"the fail-closed invalidation must remain visible without logging typed content")
	end)
end)


helpers.describe("rules_engine: rejected dynamic replacement does not eat the trigger", function()
	helpers.it("passes the magic key through and does not log completion", function()
		reset_driver_modules()
		local logs = logger_capture()
		package.loaded["modules.keymap.utils"] = { emit_text = function() error("must not emit") end }
		package.loaded["modules.keylogger"] = {}
		package.loaded["adapters.synthetic_input"] = api()

		local rules = require("modules.dynamic_hotstrings.rules_engine")
		local interceptor
		local inject_calls = 0
		local fake_keymap = {
			add = noop,
			is_section_enabled = function() return true end,
			is_group_enabled = function() return true end,
			set_group_context = noop,
			sort_mappings = noop,
			register_lua_group = noop,
			set_post_load_hook = noop,
			register_interceptor = function(callback) interceptor = callback end,
			register_preview_provider = noop,
			registry_transaction = function(_, mutation) return mutation() == true end,
			inject_dynamic = function()
				inject_calls = inject_calls + 1
				return false
			end,
		}
		rules.inject_data({ date_format = "%d/%m/%Y", date_sections = { "date" } }, "\u{2605}")
		rules.start(fake_keymap)

		helpers.assert_type(interceptor, "function")
		local successes_before = #logs.successes
		local errors_before = #logs.errors
		local result = interceptor(fake_event("\u{2605}"), "td")

		helpers.assert_nil(result,
			"when no replacement batch exists, the user's magic key must pass through")
		helpers.assert_eq(inject_calls, 1,
			"the matching rule must have reached the failing injection seam")
		helpers.assert_eq(#logs.successes, successes_before,
			"a returned false must not be logged as completed injection")
		helpers.assert_true(#logs.errors > errors_before,
			"the rejected injection must be visible in the file logger")
	end)


	helpers.it("cancels every fallback event built before an emitter throws", function()
		reset_driver_modules()
		logger_capture()
		package.loaded["modules.keymap.utils"] = {
			emit_text = function() error("forced fallback emitter failure") end,
		}
		package.loaded["modules.keylogger"] = {}

		local synthetic = require("adapters.synthetic_input")
		local rules = require("modules.dynamic_hotstrings.rules_engine")
		local interceptor
		local fake_keymap = {
			add = noop,
			is_section_enabled = function() return true end,
			is_group_enabled = function() return true end,
			set_group_context = noop,
			sort_mappings = noop,
			register_lua_group = noop,
			set_post_load_hook = noop,
			register_interceptor = function(callback) interceptor = callback end,
			register_preview_provider = noop,
			registry_transaction = function(_, mutation) return mutation() == true end,
			suppress_rescan = noop,
			arm_synthetic = function()
				return synthetic.begin("test.rules_fallback", "replacement")
			end,
			with_synthetic_transaction = synthetic.with_transaction,
			finish_synthetic = synthetic.seal,
			cancel_synthetic = synthetic.cancel,
		}
		rules.inject_data({ date_format = "%d/%m/%Y", date_sections = { "date" } }, "\u{2605}")
		rules.start(fake_keymap)

		synthetic.enter_callback()
		local result = interceptor(fake_event("\u{2605}"), "td")
		local consume, events = synthetic.leave_callback(false)

		helpers.assert_nil(result,
			"the physical trigger must pass through after fallback construction fails")
		helpers.assert_eq(consume, false)
		helpers.assert_nil(events,
			"a failed fallback must cancel its already-built Backspace prefix")
		helpers.assert_eq(synthetic.stats().active_transactions, 0,
			"fallback cancellation must not strand a transaction")
	end)
end)


helpers.describe("personal_info: rejected private replacement does not eat the trigger", function()
	helpers.it("passes the magic key through and does not log completion", function()
		local hs_stub = reset_driver_modules()
		local logs = logger_capture()
		package.loaded["modules.keylogger"] = {}
		package.loaded["adapters.synthetic_input"] = api()

		local personal = require("modules.dynamic_hotstrings.personal_info")
		local interceptor
		local inject_calls = 0
		local fake_keymap = {
			register_interceptor = function(callback) interceptor = callback end,
			register_preview_provider = noop,
			classify_trigger = function() return false, false, false end,
			inject_dynamic = function()
				inject_calls = inject_calls + 1
				return false
			end,
		}

		local toml_path = os.tmpname()
		local file = assert(io.open(toml_path, "w"))
		file:write('[info]\nfirst_name = "Alice"\n\n[letters]\np = "first_name"\n')
		file:close()
		personal.start("", fake_keymap, toml_path, refresh_personal_data)
		personal.enable()
		os.remove(toml_path)

		helpers.assert_type(interceptor, "function")
		local successes_before = #logs.successes
		local errors_before = #logs.errors
		interceptor(fake_event("@"), "")
		interceptor(fake_event("p"), "@")
		local result = interceptor(fake_event(personal.get_trigger_char()), "@p")
		hs_stub.timer.__fire_all()

		helpers.assert_nil(result,
			"when private data was not injected, the closing magic key must pass through")
		helpers.assert_eq(inject_calls, 1,
			"the resolved private field must have reached the failing injection seam")
		helpers.assert_eq(#logs.successes, successes_before,
			"private output that never landed must not be logged as completed")
		helpers.assert_true(#logs.errors > errors_before,
			"the rejected private injection must be visible in the file logger")
	end)


	helpers.it("cancels private fallback deletes when field construction throws", function()
		reset_driver_modules()
		logger_capture()
		package.loaded["modules.keylogger"] = {}

		local synthetic = require("adapters.synthetic_input")
		local personal = require("modules.dynamic_hotstrings.personal_info")
		local interceptor
		local fake_keymap = {
			register_interceptor = function(callback) interceptor = callback end,
			register_preview_provider = noop,
			classify_trigger = function() return false, false, false end,
			suppress_rescan = noop,
			arm_synthetic = function()
				return synthetic.begin("test.personal_fallback", "replacement")
			end,
			with_synthetic_transaction = synthetic.with_transaction,
			finish_synthetic = synthetic.seal,
			cancel_synthetic = synthetic.cancel,
		}

		local toml_path = os.tmpname()
		local file = assert(io.open(toml_path, "w"))
		file:write('[info]\nfirst_name = "Alice"\n\n[letters]\np = "first_name"\n')
		file:close()
		personal.start("", fake_keymap, toml_path, refresh_personal_data)
		personal.enable()
		os.remove(toml_path)

		interceptor(fake_event("@"), "")
		interceptor(fake_event("p"), "@")
		local original_emit_text = synthetic.emit_key_strokes
		synthetic.emit_key_strokes = function()
			error("forced private field construction failure")
		end
		synthetic.enter_callback()
		local call_ok, result = pcall(interceptor,
			fake_event(personal.get_trigger_char()), "@p")
		local leave_ok, consume, events = pcall(synthetic.leave_callback, false)
		synthetic.emit_key_strokes = original_emit_text

		helpers.assert_true(call_ok, "the interceptor must contain the fallback failure")
		helpers.assert_true(leave_ok, "the fallback must leave a valid empty collector")
		helpers.assert_nil(result,
			"the closing physical trigger must pass through after private fallback failure")
		helpers.assert_eq(consume, false)
		helpers.assert_nil(events,
			"a failed private fallback must cancel its already-built delete prefix")
		helpers.assert_eq(synthetic.stats().active_transactions, 0,
			"private fallback cancellation must not strand a transaction")
	end)
end)
