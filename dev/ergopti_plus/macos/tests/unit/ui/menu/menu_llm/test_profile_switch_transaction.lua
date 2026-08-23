--- tests/unit/ui/menu/menu_llm/test_profile_switch_transaction.lua

-- =============================================================================
-- MODULE: Transactional Profile Switch Regression
-- DESCRIPTION:
-- Proves that a direct profile selection is one recoverable transaction across
-- state, the LLM runtime, preferences, and the rendered menu.
-- =============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"infra.logger",
	"infra.i18n",
	"infra.dialog_util",
	"infra.notifications",
	"ui.menu.menu_llm.profile_label",
	"modules.llm",
	"ui.menu.menu_llm.model_switcher",
}

local function copy_state(value)
	local out = {}
	for key, item in pairs(value or {}) do out[key] = item end
	return out
end

local function restore_modules(saved)
	for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
end

local function with_fixture(spec, body)
	spec = spec or {}
	local saved = {}
	for _, name in ipairs(MODULES) do saved[name] = package.loaded[name] end

	local ok, err = xpcall(function()
		local errors = {}
		local dialog_call_count = 0
		local notification_call_count = 0
		local logger = helpers.make_logger_stub()
		logger.error = function(_, message, ...)
			errors[#errors + 1] = string.format(message, ...)
		end
		logger.callback = function(module_name, label, fn, ...)
			local results = table.pack(xpcall(fn, debug.traceback, ...))
			if not results[1] then
				logger.error(module_name, "Callback '%s' raised: %s.", label, tostring(results[2]))
			end
			return table.unpack(results, 1, results.n)
		end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.i18n"] = {get = function(key) return key end}
		package.loaded["infra.dialog_util"] = {
			block_alert = function()
				dialog_call_count = dialog_call_count + 1
				local choice = type(spec.dialog_choices) == "table"
					and spec.dialog_choices[dialog_call_count]
					or spec.dialog_choice
				if choice == "throw" then error("dialog injected failure") end
				return choice or "button.cancel"
			end,
		}
		package.loaded["infra.notifications"] = {notify = function()
			notification_call_count = notification_call_count + 1
			if spec.notification_mode == "throw" then
				error("notification injected failure")
			end
			return true
		end}
		package.loaded["ui.menu.menu_llm.profile_label"] = {
			format = function(label) return label end,
		}

		local occurrences = {}
		local failures = spec.failures or {}
		local nil_success = spec.nil_success or {}
		local function matching_failure(name)
			occurrences[name] = (occurrences[name] or 0) + 1
			for _, failure in ipairs(failures) do
				if failure.name == name and failure.occurrence == occurrences[name] then
					return failure
				end
			end
			return nil
		end
		local function run_boundary(name, mutate)
			local failure = matching_failure(name)
			if not (failure and failure.mutate == false) then mutate() end
			if failure then
				if failure.mode == "throw" then error(name .. " injected failure") end
				if failure.mode == "nil" then return nil end
				return false
			end
			if nil_success[name] then return nil end
			return true
		end

		local state = {
			llm_backend = "ollama",
			llm_enabled = true,
			llm_active_profile = "basic",
			llm_model = "A",
			llm_model_power = 1,
			llm_model_mlx = "mlx-A",
			llm_model_ollama = "A",
		}
		local runtime = {
			profile = spec.runtime_profile or "basic",
			model = "actual:A",
			display_model = "A",
		}
		local persisted = copy_state(state)
		local rendered = copy_state(state)
		local switcher
		local nested_result
		local reentered = false
		local calls = {
			profiles = {},
			save_profiles = {},
			menu_profiles = {},
			model_names = {},
			display_names = {},
			requirements = 0,
		}

		local core_llm = {
			DEFAULT_STATE = {llm_num_predictions = 1},
			get_active_profile = function()
				return {id = runtime.profile}
			end,
			set_active_profile = function(value)
				calls.profiles[#calls.profiles + 1] = value
				return run_boundary("runtime", function()
					runtime.profile = value
					if spec.reenter_boundary == "runtime" and value == "advanced"
						and not reentered then
						reentered = true
						nested_result = switcher.set_llm_profile("raw")
					end
				end)
			end,
		}
		package.loaded["modules.llm"] = core_llm
		package.loaded["ui.menu.menu_llm.model_switcher"] = nil

		local pending = {}
		local manager = {
			check_requirements = function(_, on_success, on_fail)
				calls.requirements = calls.requirements + 1
				if spec.defer_requirements then
					pending.success = on_success
					pending.failure = on_fail
					return true
				end
				return on_success()
			end,
			get_presets = function() return {} end,
			get_model_info = function()
				return {
					params = spec.model_params or 1,
					type = spec.model_type or "chat",
				}
			end,
			get_actual_model_name = function(name) return "actual:" .. tostring(name) end,
		}
		local keymap = {
			set_llm_enabled = function() return true end,
			set_llm_model = function(value)
				calls.model_names[#calls.model_names + 1] = value
				runtime.model = value
				return true
			end,
			set_llm_display_model_name = function(value)
				calls.display_names[#calls.display_names + 1] = value
				runtime.display_model = value
				return true
			end,
		}
		local function save_prefs()
			calls.save_profiles[#calls.save_profiles + 1] = state.llm_active_profile
			return run_boundary("save", function()
				persisted = copy_state(state)
				if spec.reenter_boundary == "save"
					and state.llm_active_profile == "advanced" and not reentered then
					reentered = true
					nested_result = switcher.set_llm_profile("raw")
					persisted = copy_state(state)
				end
			end)
		end
		local function update_menu()
			calls.menu_profiles[#calls.menu_profiles + 1] = state.llm_active_profile
			return run_boundary("menu", function() rendered = copy_state(state) end)
		end

		switcher = require("ui.menu.menu_llm.model_switcher").new({
			state = state,
			models_mgr = manager,
			keymap = keymap,
			save_prefs = save_prefs,
			update_menu = update_menu,
		})
		body({
			switcher = switcher,
			state = state,
			runtime = runtime,
			persisted = function() return persisted end,
			rendered = function() return rendered end,
			calls = calls,
			errors = errors,
			pending = pending,
			dialog_calls = function() return dialog_call_count end,
			notification_calls = function() return notification_call_count end,
			nested_result = function() return nested_result end,
		})
	end, debug.traceback)

	restore_modules(saved)
	if not ok then error(err, 0) end
end

local function assert_old_profile(fixture, runtime_profile)
	helpers.assert_eq(fixture.state.llm_active_profile, "basic")
	helpers.assert_eq(fixture.runtime.profile, runtime_profile or "basic")
	helpers.assert_eq(fixture.persisted().llm_active_profile, "basic")
	helpers.assert_eq(fixture.rendered().llm_active_profile, "basic")
end

local function compensation_failures(boundary, mode)
	local trigger = boundary == "menu" and "menu" or "save"
	local failures = {
		{name = trigger, occurrence = 1, mode = "false"},
	}
	for occurrence = 2, 4 do
		failures[#failures + 1] = {
			name = boundary,
			occurrence = occurrence,
			mode = mode,
			mutate = false,
		}
	end
	return failures
end

helpers.describe("HS-028 direct profile selection is one recoverable transaction", function()
	for _, boundary in ipairs({ "runtime", "save" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("HS-012 refuses nested profile selection during " .. boundary
				.. " mutate-then-" .. mode, function()
				with_fixture({
					reenter_boundary = boundary,
					failures = {{name = boundary, occurrence = 1, mode = mode}},
				}, function(fixture)
					helpers.assert_eq(fixture.switcher.set_llm_profile("advanced"), false)
					helpers.assert_eq(fixture.nested_result(), false)
					assert_old_profile(fixture)
				end)
			end)
		end
	end

	local forward_failures = {
		{name = "runtime", mode = "false"},
		{name = "runtime", mode = "nil"},
		{name = "runtime", mode = "throw"},
		{name = "save", mode = "false"},
		{name = "save", mode = "throw"},
		{name = "menu", mode = "false"},
		{name = "menu", mode = "throw"},
	}
	for _, failure in ipairs(forward_failures) do
		helpers.it(string.format("HS-028 rolls back profile %s %s", failure.name, failure.mode), function()
			with_fixture({
				failures = {{name = failure.name, occurrence = 1, mode = failure.mode}},
			}, function(fixture)
				helpers.assert_eq(fixture.switcher.set_llm_profile("advanced"), false)
				assert_old_profile(fixture)
				helpers.assert_true(#fixture.errors >= 1,
					"a failed profile boundary must leave a contextual file-log diagnostic")
			end)
		end)
	end

	helpers.it("HS-028 snapshots state and runtime profile identities independently", function()
		with_fixture({
			runtime_profile = "raw",
			failures = {{name = "save", occurrence = 1, mode = "false"}},
		}, function(fixture)
			helpers.assert_eq(fixture.switcher.set_llm_profile("advanced"), false)
			assert_old_profile(fixture, "raw")
			helpers.assert_eq(fixture.calls.profiles, {"advanced", "raw"},
				"rollback must restore the observed runtime profile, not assume state was identical")
		end)
	end)

	local compensation_cases = {
		{boundary = "runtime", mode = "throw"},
		{boundary = "save", mode = "false"},
		{boundary = "save", mode = "throw"},
		{boundary = "menu", mode = "false"},
		{boundary = "menu", mode = "throw"},
	}
	for _, case in ipairs(compensation_cases) do
		helpers.it(string.format(
			"HS-028 retains %s compensation debt after %s", case.boundary, case.mode), function()
			with_fixture({
				failures = compensation_failures(case.boundary, case.mode),
			}, function(fixture)
				helpers.assert_eq(fixture.switcher.set_llm_profile("advanced"), false)
				helpers.assert_eq(fixture.state.llm_active_profile, "basic")
				if case.boundary == "runtime" then
					helpers.assert_eq(fixture.runtime.profile, "advanced")
				elseif case.boundary == "save" then
					helpers.assert_eq(fixture.persisted().llm_active_profile, "advanced")
				else
					helpers.assert_eq(fixture.rendered().llm_active_profile, "advanced")
				end

				helpers.assert_eq(fixture.switcher.switch_model("B"), false)
				helpers.assert_eq(fixture.calls.requirements, 0,
					"a model action must not dispatch while profile recovery is unsettled")
				helpers.assert_eq(fixture.calls.model_names, {})

				helpers.assert_eq(fixture.switcher.set_llm_profile("raw"), false)
				for _, value in ipairs(fixture.calls.profiles) do
					helpers.assert_true(value ~= "raw",
						"a new profile must not publish while retained recovery still refuses")
				end

				helpers.assert_eq(fixture.switcher.set_llm_profile("raw"), true)
				helpers.assert_eq(fixture.state.llm_active_profile, "raw")
				helpers.assert_eq(fixture.runtime.profile, "raw")
				helpers.assert_eq(fixture.persisted().llm_active_profile, "raw")
				helpers.assert_eq(fixture.rendered().llm_active_profile, "raw")
				helpers.assert_eq(fixture.calls.save_profiles[#fixture.calls.save_profiles - 1], "basic",
					"recovery must durably settle the old profile before saving the successor")
				helpers.assert_eq(fixture.calls.save_profiles[#fixture.calls.save_profiles], "raw")
			end)
		end)
	end

	helpers.it("HS-028 blocks No Model while profile recovery is unsettled", function()
		with_fixture({
			failures = {
				{name = "save", occurrence = 1, mode = "false"},
				{name = "save", occurrence = 2, mode = "false", mutate = false},
				{name = "save", occurrence = 3, mode = "false", mutate = false},
			},
		}, function(fixture)
			helpers.assert_eq(fixture.switcher.set_llm_profile("advanced"), false)
			helpers.assert_eq(fixture.switcher.disable_model(), false)
			helpers.assert_eq(fixture.state.llm_model, "A")
			helpers.assert_eq(fixture.calls.model_names, {},
				"No Model must not clear runtime identity over unsettled profile recovery")
		end)
	end)

	helpers.it("HS-028 rechecks profile debt in a pending model continuation", function()
		with_fixture({
			defer_requirements = true,
			failures = {
				{name = "save", occurrence = 1, mode = "false"},
				{name = "save", occurrence = 2, mode = "false", mutate = false},
				{name = "save", occurrence = 3, mode = "false", mutate = false},
			},
		}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			helpers.assert_true(type(fixture.pending.success) == "function")
			helpers.assert_eq(fixture.switcher.set_llm_profile("advanced"), false)
			helpers.assert_eq(fixture.pending.success(), false)
			helpers.assert_eq(fixture.state.llm_model, "A")
			helpers.assert_eq(fixture.calls.model_names, {},
				"a pending callback must recheck debt before publishing model runtime state")
		end)
	end)

	helpers.it("HS-028 rejects nil from the runtime identity setter", function()
		with_fixture({nil_success = {runtime = true}}, function(fixture)
			helpers.assert_eq(fixture.switcher.set_llm_profile("advanced"), false)
			assert_old_profile(fixture)
		end)
	end)

	helpers.it("HS-028 treats nil menu result as refusal and rolls back exactly", function()
		with_fixture({
			failures = {{name = "menu", occurrence = 1, mode = "nil"}},
		}, function(fixture)
			helpers.assert_eq(fixture.switcher.set_llm_profile("advanced"), false)
			assert_old_profile(fixture)
			helpers.assert_eq(fixture.calls.profiles, {"advanced", "basic"})
			helpers.assert_eq(fixture.calls.save_profiles, {"advanced", "basic"})
			helpers.assert_eq(fixture.calls.menu_profiles, {"advanced", "basic"})
		end)
	end)

	helpers.it("HS-028 commits each profile boundary exactly once on success", function()
		with_fixture({}, function(fixture)
			helpers.assert_eq(fixture.switcher.set_llm_profile("advanced"), true)
			helpers.assert_eq(fixture.state.llm_active_profile, "advanced")
			helpers.assert_eq(fixture.runtime.profile, "advanced")
			helpers.assert_eq(fixture.persisted().llm_active_profile, "advanced")
			helpers.assert_eq(fixture.rendered().llm_active_profile, "advanced")
			helpers.assert_eq(fixture.calls.profiles, {"advanced"})
			helpers.assert_eq(fixture.calls.save_profiles, {"advanced"})
			helpers.assert_eq(fixture.calls.menu_profiles, {"advanced"})
		end)
	end)
end)

helpers.describe("HS-031 recommended profiles share the profile transaction owner", function()
	local forward_failures = {
		{name = "runtime", mode = "false"},
		{name = "runtime", mode = "nil"},
		{name = "runtime", mode = "throw"},
		{name = "save", mode = "false"},
		{name = "menu", mode = "false"},
		{name = "menu", mode = "throw"},
	}
	for _, failure in ipairs(forward_failures) do
		helpers.it(string.format(
			"HS-031 rolls back recommended profile %s %s", failure.name, failure.mode), function()
			with_fixture({
				dialog_choice = "button.confirm",
				model_params = 3,
				failures = {{name = failure.name, occurrence = 1, mode = failure.mode}},
			}, function(fixture)
				helpers.assert_eq(fixture.switcher.apply_recommended_prompt_profile("chat-3b"), false)
				assert_old_profile(fixture)
				helpers.assert_true(#fixture.errors >= 1,
					"a failed recommendation boundary must leave a contextual file-log diagnostic")
			end)
		end)
	end

	helpers.it("HS-031 commits an accepted recommendation through every boundary once", function()
		with_fixture({dialog_choice = "button.confirm", model_params = 3}, function(fixture)
			helpers.assert_eq(fixture.switcher.apply_recommended_prompt_profile("chat-3b"), true)
			helpers.assert_eq(fixture.state.llm_active_profile, "advanced")
			helpers.assert_eq(fixture.runtime.profile, "advanced")
			helpers.assert_eq(fixture.persisted().llm_active_profile, "advanced")
			helpers.assert_eq(fixture.rendered().llm_active_profile, "advanced")
			helpers.assert_eq(fixture.calls.profiles, {"advanced"})
			helpers.assert_eq(fixture.calls.save_profiles, {"advanced"})
			helpers.assert_eq(fixture.calls.menu_profiles, {"advanced"})
		end)
	end)

	helpers.it("HS-031 treats recommendation dialog refusal as a successful no-op", function()
		with_fixture({dialog_choice = "button.cancel", model_params = 3}, function(fixture)
			helpers.assert_eq(fixture.switcher.apply_recommended_prompt_profile("chat-3b"), true)
			assert_old_profile(fixture)
			helpers.assert_eq(fixture.calls.profiles, {})
			helpers.assert_eq(fixture.calls.save_profiles, {})
			helpers.assert_eq(fixture.calls.menu_profiles, {})
		end)
	end)

	helpers.it("HS-031 reports a throwing recommendation dialog as failure", function()
		with_fixture({dialog_choice = "throw", model_params = 3}, function(fixture)
			helpers.assert_eq(fixture.switcher.apply_recommended_prompt_profile("chat-3b"), false)
			assert_old_profile(fixture)
			helpers.assert_true(#fixture.errors >= 1)
		end)
	end)

	helpers.it("HS-031 routes a silent completion recommendation through the same rollback", function()
		with_fixture({
			model_type = "completion",
			failures = {{name = "save", occurrence = 1, mode = "false"}},
		}, function(fixture)
			helpers.assert_eq(fixture.switcher.apply_recommended_prompt_profile("custom-completion"), false)
			assert_old_profile(fixture)
			helpers.assert_eq(fixture.calls.profiles, {"raw", "basic"})
		end)
	end)

	helpers.it("HS-031 retains shared compensation debt after a recommendation fails", function()
		with_fixture({
			dialog_choice = "button.confirm",
			model_params = 3,
			failures = compensation_failures("runtime", "throw"),
		}, function(fixture)
			helpers.assert_eq(fixture.switcher.apply_recommended_prompt_profile("chat-3b"), false)
			helpers.assert_eq(fixture.runtime.profile, "advanced",
				"the refused runtime compensation must remain represented as recovery debt")
			helpers.assert_eq(fixture.switcher.set_llm_profile("raw"), false)
			helpers.assert_eq(fixture.switcher.set_llm_profile("raw"), false)
			helpers.assert_eq(fixture.switcher.set_llm_profile("raw"), true)
			helpers.assert_eq(fixture.state.llm_active_profile, "raw")
			helpers.assert_eq(fixture.runtime.profile, "raw")
			helpers.assert_eq(fixture.persisted().llm_active_profile, "raw")
			helpers.assert_eq(fixture.rendered().llm_active_profile, "raw")
		end)
	end)

	helpers.it("HS-031 settles retained debt before a later dialog cancellation", function()
		with_fixture({
			dialog_choices = {"button.confirm", "button.cancel"},
			model_params = 3,
			failures = compensation_failures("runtime", "throw"),
		}, function(fixture)
			helpers.assert_eq(fixture.switcher.apply_recommended_prompt_profile("chat-3b"), false)
			helpers.assert_eq(fixture.runtime.profile, "advanced")
			helpers.assert_eq(fixture.dialog_calls(), 1)

			helpers.assert_eq(fixture.switcher.apply_recommended_prompt_profile("chat-3b"), false)
			helpers.assert_eq(fixture.switcher.apply_recommended_prompt_profile("chat-3b"), false)
			helpers.assert_eq(fixture.dialog_calls(), 1,
				"unsettled debt must refuse before presenting a new decision")

			helpers.assert_eq(fixture.switcher.apply_recommended_prompt_profile("chat-3b"), true)
			helpers.assert_eq(fixture.dialog_calls(), 2)
			assert_old_profile(fixture)
		end)
	end)
end)

helpers.describe("HS-016 profile warning callback observability", function()
	helpers.it("HS-016 logs a throwing warning sink after the profile commits", function()
		with_fixture({notification_mode = "throw"}, function(fixture)
			helpers.assert_eq(fixture.switcher.set_llm_profile("batch_advanced"), true)
			helpers.assert_eq(fixture.state.llm_active_profile, "batch_advanced")
			helpers.assert_eq(fixture.runtime.profile, "batch_advanced")
			helpers.assert_eq(fixture.persisted().llm_active_profile, "batch_advanced")
			helpers.assert_eq(fixture.rendered().llm_active_profile, "batch_advanced")
			helpers.assert_eq(fixture.notification_calls(), 1)
			local found_context = false
			for _, message in ipairs(fixture.errors) do
				if message:find("Profile power warning notification", 1, true)
					and message:find("notification injected failure", 1, true) then
					found_context = true
					break
				end
			end
			helpers.assert_true(found_context,
				"the warning callback traceback must reach the file logger")
		end)
	end)
end)

return true
