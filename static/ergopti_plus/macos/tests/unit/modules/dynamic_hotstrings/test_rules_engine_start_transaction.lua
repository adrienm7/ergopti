--- tests/unit/modules/dynamic_hotstrings/test_rules_engine_start_transaction.lua

--- ==============================================================================
--- MODULE: Dynamic Rules Engine Start Transaction
--- DESCRIPTION:
--- Drives failures after callback publication and after registry mutation through
--- the real RulesEngine lifecycle. Callback registration has no inverse API, so
--- failed generations must remain inert forever; registry state and shared rules
--- must roll back exactly, and a later retry must be the sole active generation.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ====================================
-- ====================================
-- ======= 1/ Controlled Keymap =======
-- ====================================
-- ====================================

local function copy_map(source)
	local out = {}
	for key, value in pairs(source) do out[key] = value end
	return out
end

local function load_fixture()
	package.loaded["dynamic_hotstrings"] = nil
	package.loaded["modules.dynamic_hotstrings.rules_engine"] = nil

	local SharedEngine = helpers.load_with_stubs("dynamic_hotstrings")
	SharedEngine.reset_rules()
	local RulesEngine = require("modules.dynamic_hotstrings.rules_engine")

	local controls = {
		preview_failure = nil,
		reporter_failure = nil,
		sort_result = nil,
	}
	local install_reporter = SharedEngine.set_resolver_error_reporter
	SharedEngine.set_resolver_error_reporter = function(reporter)
		if reporter ~= nil and controls.reporter_failure == "throw" then
			error("REPORTER_REGISTRATION_FAILURE", 0)
		end
		if reporter ~= nil and controls.reporter_failure == "false" then return false end
		return install_reporter(reporter)
	end
	local state = {
		current_group = nil,
		groups = {},
		hooks = {},
		mappings = {},
		interceptors = {},
		providers = {},
		injections = 0,
	}

	local keymap = {}

	function keymap.invalidate_hotstring_preview() return true end
	function keymap.is_section_enabled() return true end
	function keymap.is_group_enabled(name)
		return state.groups[name] ~= nil and state.groups[name].enabled == true
	end
	function keymap.set_group_context(name)
		state.current_group = name
	end
	function keymap.register_lua_group(name, description, sections)
		state.groups[name] = {
			description = description,
			sections = sections,
			enabled = true,
		}
	end
	function keymap.add(trigger, replacement, options)
		state.mappings[#state.mappings + 1] = {
			trigger = trigger,
			replacement = replacement,
			options = options,
			group = state.current_group,
		}
	end
	function keymap.set_post_load_hook(name, callback)
		state.hooks[name] = callback
	end
	function keymap.sort_mappings()
		return controls.sort_result
	end
	function keymap.register_interceptor(callback)
		state.interceptors[#state.interceptors + 1] = callback
	end
	function keymap.register_preview_provider(callback)
		-- Registration may publish before its terminal reports failure. This is the
		-- hard case because there is deliberately no unregister API in keymap.
		state.providers[#state.providers + 1] = callback
		if controls.preview_failure == "throw" then error("PREVIEW_REGISTRATION_FAILURE") end
		if controls.preview_failure == "false" then return false end
	end
	function keymap.inject_dynamic()
		state.injections = state.injections + 1
		return true
	end
	function keymap.registry_transaction(_label, mutation)
		local snapshot = {
			current_group = state.current_group,
			groups = copy_map(state.groups),
			hooks = copy_map(state.hooks),
			mapping_count = #state.mappings,
		}
		local ok, committed = xpcall(mutation, debug.traceback)
		if ok and committed == true then return true end
		state.current_group = snapshot.current_group
		state.groups = snapshot.groups
		state.hooks = snapshot.hooks
		while #state.mappings > snapshot.mapping_count do
			table.remove(state.mappings)
		end
		return false
	end

	RulesEngine.inject_data({
		phone_number = "0612345678",
		phone_number_clean = "06 12 34 56 78",
	}, "★")

	return {
		controls = controls,
		keymap = keymap,
		RulesEngine = RulesEngine,
		SharedEngine = SharedEngine,
		state = state,
	}
end

local function trigger_event()
	return {
		getFlags = function() return { cmd = false, ctrl = false } end,
		getCharacters = function() return "★" end,
	}
end

local function assert_failed_start_is_empty(fixture)
	helpers.assert_eq(#fixture.SharedEngine.get_rules(), 0,
		"failed start must restore the pre-start shared-rule set")
	helpers.assert_eq(#fixture.state.mappings, 0,
		"failed start must not retain prefix mappings")
	helpers.assert_eq(fixture.state.groups.dynamichotstrings, nil,
		"failed start must not retain group ownership")
	helpers.assert_eq(fixture.state.hooks.dynamichotstrings, nil,
		"failed start must not retain the post-load hook")
end





-- =========================================
-- =========================================
-- ======= 2/ Behavioral Regressions =======
-- =========================================
-- =========================================

helpers.describe("rules_engine.start owns one atomic generation", function()
	for _, failure_mode in ipairs({ "throw", "false" }) do
		helpers.it("deactivates a preview registration that reports " .. failure_mode, function()
			local fixture = load_fixture()
			fixture.controls.preview_failure = failure_mode

			local ok, started = pcall(fixture.RulesEngine.start, fixture.keymap)
			helpers.assert_true(ok,
				"a registration exception must become a logged false terminal, never escape start()")
			helpers.assert_eq(started, false,
				"an explicit registration refusal must not be mistaken for commitment")
			assert_failed_start_is_empty(fixture)

			local stale_interceptor = fixture.state.interceptors[1]
			local stale_provider = fixture.state.providers[1]
			helpers.assert_type(stale_interceptor, "function",
				"the test must exercise an interceptor published before the late failure")
			helpers.assert_type(stale_provider, "function",
				"the test must exercise a provider published before reporting failure")
			helpers.assert_eq(stale_provider("td"), nil,
				"an uncommitted provider must be inert immediately")
			helpers.assert_eq(stale_interceptor(trigger_event(), "td"), nil,
				"an uncommitted interceptor must never consume a key")

			fixture.controls.preview_failure = nil
			helpers.assert_true(fixture.RulesEngine.start(fixture.keymap),
				"a clean retry after rollback must commit")
			helpers.assert_eq(#fixture.SharedEngine.get_rules(), 3,
				"retry must install one canonical date-rule set")
			helpers.assert_true(#fixture.state.mappings > 0,
				"retry must install the personal prefix mappings")
			helpers.assert_not_nil(fixture.state.groups.dynamichotstrings,
				"retry must publish the dynamic group")
			helpers.assert_type(fixture.state.hooks.dynamichotstrings, "function",
				"retry must publish its post-load hook")
			helpers.assert_eq(stale_provider("td"), nil,
				"the failed generation must stay inert after a newer generation commits")
			helpers.assert_eq(stale_interceptor(trigger_event(), "td"), nil,
				"the failed interceptor must stay inert after retry")
			helpers.assert_eq(fixture.state.injections, 0,
				"no failed-generation callback may inject output")
			local live_preview = fixture.state.providers[#fixture.state.providers]("td")
			helpers.assert_type(live_preview, "string",
				"the committed generation must remain functional")
			helpers.assert_true(fixture.RulesEngine.stop())
			helpers.assert_eq(fixture.state.providers[#fixture.state.providers]("td"), nil,
				"stop must revoke the committed generation")
		end)
	end

	helpers.it("rolls back registry writes when the final sort explicitly refuses", function()
		local fixture = load_fixture()
		fixture.controls.sort_result = false

		helpers.assert_eq(fixture.RulesEngine.start(fixture.keymap), false,
			"a false registry terminal must fail the whole start")
		assert_failed_start_is_empty(fixture)
		local stale_provider = fixture.state.providers[1]
		helpers.assert_type(stale_provider, "function",
			"callbacks must already be staged when the registry fails late")
		helpers.assert_eq(stale_provider("td"), nil,
			"a callback from a rolled-back registry generation must be inert")

		fixture.controls.sort_result = nil
		helpers.assert_true(fixture.RulesEngine.start(fixture.keymap))
		helpers.assert_eq(#fixture.SharedEngine.get_rules(), 3)
		helpers.assert_eq(stale_provider("td"), nil,
			"late-registry failure must not revive after retry")
		helpers.assert_type(fixture.state.providers[#fixture.state.providers]("td"), "string")
		helpers.assert_true(fixture.RulesEngine.stop())
	end)

	for _, failure_mode in ipairs({ "throw", "false" }) do
		helpers.it("rolls back registry ownership when reporter installation returns " .. failure_mode, function()
			local fixture = load_fixture()
			fixture.controls.reporter_failure = failure_mode

			helpers.assert_eq(fixture.RulesEngine.start(fixture.keymap), false,
				"the off-HID reporter is part of the same start commitment")
			assert_failed_start_is_empty(fixture)
			local stale_provider = fixture.state.providers[1]
			helpers.assert_type(stale_provider, "function")
			helpers.assert_eq(stale_provider("td"), nil,
				"a reporter failure must leave every staged callback inert")

			fixture.controls.reporter_failure = nil
			helpers.assert_true(fixture.RulesEngine.start(fixture.keymap),
				"retry must acquire registry, reporter, and callback ownership together")
			helpers.assert_eq(#fixture.SharedEngine.get_rules(), 3)
			helpers.assert_type(fixture.state.providers[#fixture.state.providers]("td"), "string")
			helpers.assert_eq(stale_provider("td"), nil)
			helpers.assert_true(fixture.RulesEngine.stop())
		end)
	end
end)

return true
