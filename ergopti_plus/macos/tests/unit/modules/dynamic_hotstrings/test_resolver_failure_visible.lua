--- tests/unit/modules/dynamic_hotstrings/test_resolver_failure_visible.lua

--- ==============================================================================
--- MODULE: Dynamic Resolver Failure Visibility Regression
--- DESCRIPTION:
--- Drives two same-suffix rules through the real shared matcher and macOS shim.
--- A throwing resolver must schedule one off-HID diagnostic and allow its
--- healthy sibling to provide both preview and action output.
--- ==============================================================================

local helpers = require("tests.helpers")

local MAGIC = utf8.char(0x2605)


--- Builds the physical trigger event consumed by the rules interceptor.
--- @return table event
local function magic_event()
	return {
		getFlags = function() return { cmd = false, ctrl = false } end,
		getCharacters = function() return MAGIC end,
	}
end

--- Runs the failure scenario while restoring every process-global module.
local function run_scenario()
	local dependency_names = {
		"adapters.timer_scheduler",
		"dynamic_hotstrings",
		"infra.logger",
		"logger.shim",
		"modules.diagnostics.hid_diagnostic_mailbox",
		"modules.dynamic_hotstrings.rules_engine",
		"modules.keylogger",
	}
	local previous = {}
	for _, name in ipairs(dependency_names) do previous[name] = package.loaded[name] end

	local after_calls = 0
	local pump_arm_calls = 0
	local diagnostic_pump = nil
	local errors = {}
	local resolver_calls = 0
	local fallback_calls = 0
	local injected = {}
	local provider = nil
	local interceptor = nil
	local visible_token = nil
	local Logger = helpers.make_logger_stub()
	Logger.error = function(_log, format_string, ...)
		errors[#errors + 1] = string.format(format_string, ...)
	end
	package.loaded["infra.logger"] = Logger
	package.loaded["logger.shim"] = Logger
	-- The resolver test owns only the dynamic-rules consumer. Loading the full
	-- keylogger now arms its independent KC bridge poller during init, which would
	-- consume this fixture's sole repeating-timer counter before the mailbox does
	package.loaded["modules.keylogger"] = { notify_synthetic = function() end }
	package.loaded["adapters.timer_scheduler"] = {
		after = function()
			after_calls = after_calls + 1
			error("resolver diagnostics must not allocate a one-shot timer", 0)
		end,
		every = function(_interval, fn)
			pump_arm_calls = pump_arm_calls + 1
			diagnostic_pump = fn
			return { kind = "diagnostic-pump" }, true
		end,
		cancel = function() return true end,
	}

	local fake_keymap = {
		is_group_enabled = function() return true end,
		is_section_enabled = function() return true end,
		register_lua_group = function() end,
		set_post_load_hook = function() end,
		register_interceptor = function(fn) interceptor = fn end,
		register_preview_provider = function(fn) provider = fn end,
		registry_transaction = function(_label, mutation) return mutation() end,
		invalidate_hotstring_preview = function() return true end,
		owns_visible_magic_action = function(token, buffer)
			return token == visible_token and buffer == "zz"
		end,
		inject_dynamic = function(_delete_count, result)
			injected[#injected + 1] = result
			return true
		end,
	}

	local ok, err = xpcall(function()
		package.loaded["dynamic_hotstrings"] = nil
		package.loaded["modules.dynamic_hotstrings.rules_engine"] = nil
		local RulesEngine = helpers.load_with_stubs("modules.dynamic_hotstrings.rules_engine")
		local Mailbox = require("modules.diagnostics.hid_diagnostic_mailbox")
		local SharedEngine = require("dynamic_hotstrings")
		helpers.assert_true(Mailbox.start())
		helpers.assert_eq(pump_arm_calls, 1)
		helpers.assert_true(RulesEngine.start(fake_keymap))
		helpers.assert_true(RulesEngine.add_rule("zz", "broken", function()
			resolver_calls = resolver_calls + 1
			error(setmetatable({}, {
				__tostring = function() error("PRIVATE_RESOLVER_FAILURE", 0) end,
			}), 0)
		end))
		helpers.assert_true(RulesEngine.add_rule("zz", "fallback", function()
			fallback_calls = fallback_calls + 1
			return "SIBLING"
		end))
		helpers.assert_eq(type(provider), "function")
		helpers.assert_eq(type(interceptor), "function")

		local shown, token = provider("zz")
		helpers.assert_eq(shown, "SIBLING",
			"one failed resolver must not suppress a healthy same-suffix sibling")
		helpers.assert_eq(type(token), "table")
		helpers.assert_eq(#errors, 0,
			"resolver diagnostics must not perform file logging in the HID callback")
		helpers.assert_eq(after_calls, 0,
			"the first failure must reuse the lifecycle pump, not arm a timer")

		diagnostic_pump()
		helpers.assert_eq(#errors, 1)
		helpers.assert_true(errors[1]:find("Dynamic resolver raised", 1, true) ~= nil)
		helpers.assert_true(errors[1]:find("content withheld", 1, true) ~= nil)
		helpers.assert_true(errors[1]:find("PRIVATE_RESOLVER_FAILURE", 1, true) == nil,
			"a resolver exception can itself carry personal data and must stay out of logs")
		helpers.assert_true(errors[1]:find("broken", 1, true) == nil,
			"dynamic section identifiers must not cross the HID mailbox")

		visible_token = token
		local consumed = interceptor(magic_event(), "zz", {
			chars = MAGIC,
			flags = { cmd = false, ctrl = false },
		})
		helpers.assert_eq(consumed, "consume")
		helpers.assert_eq(injected[1], shown,
			"the healthy sibling must remain the exact committed action output")

		visible_token = nil
		shown = provider("zz")
		helpers.assert_eq(shown, "SIBLING")
		helpers.assert_eq(resolver_calls, 2,
			"the one-shot diagnostic must not quarantine a potentially transient resolver")
		helpers.assert_eq(fallback_calls, 2)
		diagnostic_pump()
		helpers.assert_eq(after_calls, 0,
			"the same broken rule must allocate no diagnostic timer")
		helpers.assert_eq(#errors, 1,
			"the same broken rule must log exactly once per registration")

		helpers.assert_true(RulesEngine.stop())
		local after_before_failed_start = after_calls
		local errors_before_failed_start = #errors
		local failing_keymap = {}
		for key, value in pairs(fake_keymap) do failing_keymap[key] = value end
		failing_keymap.register_preview_provider = function()
			error("simulated provider registration crash", 0)
		end
		local start_ok, start_err = pcall(RulesEngine.start, failing_keymap)
		helpers.assert_true(start_ok,
			"the transactional start boundary must contain a late registration exception")
		helpers.assert_eq(start_err, false,
			"the failure probe must return an explicit refusal after rollback")
		local errors_before_direct_fallback = #errors

		SharedEngine.add_rule("xx", "failed_start_probe", function()
			error("post-start resolver crash", 0)
		end)
		SharedEngine.match_buffer("xx", "dynamichotstrings", function() return true end)
		helpers.assert_eq(after_calls, after_before_failed_start,
			"a failed start must not leave the Hammerspoon reporter installed globally")
		helpers.assert_true(errors_before_direct_fallback > errors_before_failed_start,
			"the failed start itself must remain visible without exposing its payload")
		helpers.assert_eq(#errors, errors_before_direct_fallback + 1,
			"without a live platform owner the shared engine must use its direct fallback")
		helpers.assert_true(errors[#errors]:find("content withheld", 1, true) ~= nil)
		helpers.assert_true(errors[#errors]:find("post-start resolver crash", 1, true) == nil)
		helpers.assert_true(Mailbox.stop())
	end, debug.traceback)

	if package.loaded["modules.dynamic_hotstrings.rules_engine"] then
		pcall(package.loaded["modules.dynamic_hotstrings.rules_engine"].stop)
	end
	if package.loaded["modules.diagnostics.hid_diagnostic_mailbox"] then
		pcall(package.loaded["modules.diagnostics.hid_diagnostic_mailbox"].stop)
	end
	for _, name in ipairs(dependency_names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end





-- ========================================
-- ========================================
-- ======= 1/ Behavioral Regression =======
-- ========================================
-- ========================================

helpers.describe("dynamic resolver failure visibility", function()
	helpers.it("(dynamic-resolver-error-once) logs off-HID and preserves sibling fallback", function()
		run_scenario()
	end)
end)

return true
