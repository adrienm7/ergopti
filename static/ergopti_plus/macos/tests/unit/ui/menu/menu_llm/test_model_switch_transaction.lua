--- tests/unit/ui/menu/menu_llm/test_model_switch_transaction.lua

-- =============================================================================
-- MODULE: Transactional Model Switch Regression
-- DESCRIPTION:
-- Proves that a current model switch publishes state only after every runtime
-- and durable boundary commits, and that failed compensation remains retryable.
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
		local logger = helpers.make_logger_stub()
		logger.error = function(_, message, ...)
			errors[#errors + 1] = string.format(message, ...)
		end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.i18n"] = {get = function(key) return key end}
		package.loaded["infra.dialog_util"] = {
			block_alert = function() return "button.confirm" end,
		}
		package.loaded["infra.notifications"] = {notify = function() return true end}
		package.loaded["ui.menu.menu_llm.profile_label"] = {
			format = function(label) return label end,
		}

		local occurrences = {}
		local failures = spec.failures or {}
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
				return false
			end
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
			core_model = "actual:A",
			keymap_model = "actual:A",
			display_model = "A",
			profile = "basic",
		}
		local persisted = copy_state(state)
		local rendered = copy_state(state)
		local calls = {
			core_models = {}, keymap_models = {}, display_models = {},
			profiles = {}, saves = 0, menus = 0,
		}

		local core_llm = {
			DEFAULT_STATE = {llm_num_predictions = 1},
			get_active_profile = function()
				return {id = runtime.profile}
			end,
			set_llm_model_mlx = function(value)
				calls.core_models[#calls.core_models + 1] = value
				return run_boundary("core_model", function() runtime.core_model = value end)
			end,
			set_llm_model_ollama = function(value)
				calls.core_models[#calls.core_models + 1] = value
				return run_boundary("core_model", function() runtime.core_model = value end)
			end,
			set_active_profile = function(value)
				calls.profiles[#calls.profiles + 1] = value
				return run_boundary("profile", function() runtime.profile = value end)
			end,
		}
		package.loaded["modules.llm"] = core_llm
		package.loaded["ui.menu.menu_llm.model_switcher"] = nil

		local model_info = spec.completion_model and {type = "completion"} or {params = 1}
		local manager = {
			check_requirements = function(_, on_success) return on_success() end,
			get_presets = function() return {} end,
			get_model_info = function() return model_info end,
			get_actual_model_name = function(name) return "actual:" .. tostring(name) end,
		}
		local keymap = {
			set_llm_enabled = function() return true end,
			set_llm_model = function(value)
				calls.keymap_models[#calls.keymap_models + 1] = value
				if state.llm_backend == "mlx" then
					core_llm.set_llm_model_mlx(value)
				else
					core_llm.set_llm_model_ollama(value)
				end
				return run_boundary("runtime_model", function() runtime.keymap_model = value end)
			end,
			set_llm_display_model_name = function(value)
				calls.display_models[#calls.display_models + 1] = value
				return run_boundary("display_model", function() runtime.display_model = value end)
			end,
		}
		local function save_prefs()
			calls.saves = calls.saves + 1
			return run_boundary("save", function() persisted = copy_state(state) end)
		end
		local function update_menu()
			calls.menus = calls.menus + 1
			return run_boundary("menu", function() rendered = copy_state(state) end)
		end

		local switcher = require("ui.menu.menu_llm.model_switcher").new({
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
		})
	end, debug.traceback)

	restore_modules(saved)
	if not ok then error(err, 0) end
end

local function assert_old_identity(fixture)
	helpers.assert_eq(fixture.state.llm_model, "A")
	helpers.assert_eq(fixture.state.llm_model_power, 1)
	helpers.assert_eq(fixture.state.llm_model_ollama, "A")
	helpers.assert_eq(fixture.state.llm_active_profile, "basic")
	helpers.assert_eq(fixture.runtime.core_model, "actual:A")
	helpers.assert_eq(fixture.runtime.keymap_model, "actual:A")
	helpers.assert_eq(fixture.runtime.display_model, "A")
	helpers.assert_eq(fixture.runtime.profile, "basic")
	helpers.assert_eq(fixture.persisted().llm_model, "A")
	helpers.assert_eq(fixture.persisted().llm_model_ollama, "A")
	helpers.assert_eq(fixture.persisted().llm_active_profile, "basic")
	helpers.assert_eq(fixture.rendered().llm_model, "A")
end

helpers.describe("HS-027 model switch is one recoverable transaction", function()
	local boundary_modes = {
		core_model = {"throw"},
		runtime_model = {"false", "throw"},
		display_model = {"false", "throw"},
		save = {"false", "throw"},
		menu = {"false", "throw"},
		profile = {"false", "throw"},
	}
	for boundary, modes in pairs(boundary_modes) do
		for _, mode in ipairs(modes) do
			helpers.it(string.format("HS-027 rolls back %s %s", boundary, mode), function()
				with_fixture({
					completion_model = boundary == "profile",
					failures = {{name = boundary, occurrence = 1, mode = mode}},
				}, function(fixture)
					helpers.assert_eq(fixture.switcher.switch_model("B"), false)
					assert_old_identity(fixture)
					if boundary == "profile" then
						helpers.assert_eq(fixture.calls.profiles[1], "raw",
							"the completion recommendation must reach the injected runtime refusal")
						helpers.assert_eq(fixture.calls.profiles[#fixture.calls.profiles], "basic",
							"the parent rollback must restore the prior profile identity")
					end
					helpers.assert_true(#fixture.errors >= 1,
						"the failed boundary must leave a contextual file-log diagnostic")
				end)
			end)
		end
	end

	helpers.it("HS-027 retains failed compensation and settles it before retry", function()
		with_fixture({
		failures = {
				{name = "display_model", occurrence = 1, mode = "false"},
				{name = "runtime_model", occurrence = 2, mode = "false", mutate = false},
			},
		}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), false)
			helpers.assert_eq(fixture.runtime.core_model, "actual:A",
				"the nested core owner must already be restored by the failed keymap call")
			helpers.assert_eq(fixture.runtime.keymap_model, "actual:B",
				"a refused outer runtime compensation must remain observable as recovery debt")
			helpers.assert_eq(fixture.switcher.switch_model("C"), true)
			helpers.assert_eq(fixture.calls.core_models,
				{"actual:B", "actual:A", "actual:A", "actual:C"},
				"retry must settle the exact old identity before publishing C")
			helpers.assert_eq(fixture.calls.keymap_models,
				{"actual:B", "actual:A", "actual:A", "actual:C"},
				"refused runtime compensation must retry the exact old identity before C")
			helpers.assert_eq(fixture.calls.display_models,
				{"B", "A", "C"},
				"already-settled display compensation must not replay with retained debt")
			helpers.assert_eq(fixture.state.llm_model, "C")
			helpers.assert_eq(fixture.runtime.core_model, "actual:C")
			helpers.assert_eq(fixture.persisted().llm_model, "C")
			helpers.assert_eq(fixture.rendered().llm_model, "C")
		end)
	end)

	helpers.it("HS-027 blocks direct profile publication while model debt is unsettled", function()
		with_fixture({
			failures = {
				{name = "display_model", occurrence = 1, mode = "false"},
				{name = "runtime_model", occurrence = 2, mode = "false", mutate = false},
				{name = "runtime_model", occurrence = 3, mode = "false", mutate = false},
			},
		}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), false)
			local saves_before = fixture.calls.saves
			local menus_before = fixture.calls.menus
			helpers.assert_eq(fixture.switcher.set_llm_profile("advanced"), false)
			helpers.assert_eq(fixture.state.llm_active_profile, "basic")
			helpers.assert_eq(fixture.runtime.profile, "basic")
			helpers.assert_eq(fixture.calls.saves, saves_before,
				"a profile action cannot persist over unsettled model recovery")
			helpers.assert_eq(fixture.calls.menus, menus_before,
				"a profile action cannot render over unsettled model recovery")
		end)
	end)

	helpers.it("HS-027 commits every model identity exactly once on success", function()
		with_fixture({}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			helpers.assert_eq(fixture.state.llm_model, "B")
			helpers.assert_eq(fixture.state.llm_model_ollama, "B")
			helpers.assert_eq(fixture.runtime.core_model, "actual:B")
			helpers.assert_eq(fixture.runtime.keymap_model, "actual:B")
			helpers.assert_eq(fixture.runtime.display_model, "B")
			helpers.assert_eq(fixture.persisted().llm_model, "B")
			helpers.assert_eq(fixture.rendered().llm_model, "B")
			helpers.assert_eq(fixture.calls.core_models, {"actual:B"})
			helpers.assert_eq(fixture.calls.keymap_models, {"actual:B"})
			helpers.assert_eq(fixture.calls.display_models, {"B"})
			helpers.assert_eq(fixture.calls.saves, 1)
			helpers.assert_eq(fixture.calls.menus, 1)
		end)
	end)

	local no_model_boundary_modes = {
		core_model = {"throw"},
		runtime_model = {"false", "throw"},
		display_model = {"false", "throw"},
		save = {"false", "throw"},
		menu = {"false", "throw"},
	}
	for boundary, modes in pairs(no_model_boundary_modes) do
		for _, mode in ipairs(modes) do
			helpers.it(string.format("HS-027 rolls back No Model %s %s", boundary, mode), function()
				with_fixture({
					failures = {{name = boundary, occurrence = 1, mode = mode}},
				}, function(fixture)
					helpers.assert_eq(fixture.switcher.disable_model(), false)
					assert_old_identity(fixture)
					helpers.assert_true(#fixture.errors >= 1,
						"a refused No Model boundary must be file-logged")
				end)
			end)
		end
	end

	for _, mode in ipairs({"false", "throw"}) do
		helpers.it(string.format(
			"HS-027 retains No Model %s compensation debt until exact retry", mode), function()
			with_fixture({
				failures = {
					{name = "display_model", occurrence = 1, mode = "false"},
					{name = "runtime_model", occurrence = 2, mode = mode, mutate = false},
				},
			}, function(fixture)
				helpers.assert_eq(fixture.switcher.disable_model(), false)
				helpers.assert_eq(fixture.state.llm_model, "A")
				helpers.assert_eq(fixture.runtime.core_model, "actual:A",
					"the nested core identity restores before the outer refusal")
				helpers.assert_eq(fixture.runtime.keymap_model, "",
					"the refused outer compensation must remain owned as debt")

				helpers.assert_eq(fixture.switcher.disable_model(), true)
				helpers.assert_eq(fixture.calls.keymap_models,
					{"", "actual:A", "actual:A", ""},
					"retry must settle exact A before committing No Model")
				helpers.assert_eq(fixture.state.llm_model, "")
				helpers.assert_eq(fixture.runtime.core_model, "")
				helpers.assert_eq(fixture.runtime.keymap_model, "")
				helpers.assert_eq(fixture.persisted().llm_model, "")
				helpers.assert_eq(fixture.rendered().llm_model, "")
			end)
		end)
	end

	helpers.it("HS-027 commits No Model exactly once on success", function()
		with_fixture({}, function(fixture)
			helpers.assert_eq(fixture.switcher.disable_model(), true)
			helpers.assert_eq(fixture.state.llm_model, "")
			helpers.assert_nil(fixture.state.llm_model_power)
			helpers.assert_eq(fixture.state.llm_model_ollama, "A",
				"No Model must retain the backend-specific restoration choice")
			helpers.assert_eq(fixture.runtime.core_model, "")
			helpers.assert_eq(fixture.runtime.keymap_model, "")
			helpers.assert_eq(fixture.runtime.display_model, "")
			helpers.assert_eq(fixture.persisted().llm_model, "")
			helpers.assert_eq(fixture.rendered().llm_model, "")
			helpers.assert_eq(fixture.calls.keymap_models, {""})
			helpers.assert_eq(fixture.calls.core_models, {""})
			helpers.assert_eq(fixture.calls.display_models, {""})
			helpers.assert_eq(fixture.calls.saves, 1)
			helpers.assert_eq(fixture.calls.menus, 1)
		end)
	end)
end)

return true
