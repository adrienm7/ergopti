--- tests/unit/ui/menu/menu_llm/test_profile_intent_ordering.lua

-- =============================================================================
-- MODULE: Model/Profile Intent Ordering Regression
-- DESCRIPTION:
-- Proves that a pending model selection cannot overwrite a newer explicit
-- profile choice when its automatic recommendation runs at completion time.
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
	if type(spec) == "function" then
		body = spec
		spec = {}
	end
	spec = spec or {}
	local saved = {}
	for _, name in ipairs(MODULES) do saved[name] = package.loaded[name] end
	local dialog_calls = 0

	local ok, err = xpcall(function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = {get = function(key) return key end}
		package.loaded["infra.dialog_util"] = {
			block_alert = function()
				dialog_calls = dialog_calls + 1
				return "button.confirm"
			end,
		}
		package.loaded["infra.notifications"] = {notify = function() return true end}
		package.loaded["ui.menu.menu_llm.profile_label"] = {
			format = function(label) return label end,
		}

		local state = {
			llm_backend = "mlx",
			llm_enabled = true,
			llm_active_profile = "basic",
			llm_model = "A",
			llm_model_power = 1,
			llm_model_mlx = "A",
			llm_model_ollama = "ollama-A",
		}
		local runtime = {
			profile = "basic",
			model = "actual:A",
			display_model = "A",
		}
		local calls = {
			profiles = {},
			models = {},
			display_models = {},
			prediction_states = {},
			save_snapshots = {},
			menu_snapshots = {},
		}

		package.loaded["modules.llm"] = {
			DEFAULT_STATE = {llm_num_predictions = 1},
			get_active_profile = function()
				return {id = runtime.profile}
			end,
			set_active_profile = function(value)
				calls.profiles[#calls.profiles + 1] = value
				runtime.profile = value
				return true
			end,
		}
		package.loaded["ui.menu.menu_llm.model_switcher"] = nil

		local pending = {}
		local manager = {
			check_requirements = function(model_name, on_success, on_failure, opts)
				pending[model_name] = {
					success = on_success,
					failure = on_failure,
					opts = opts,
				}
				return true
			end,
			get_presets = function() return {} end,
			get_model_info = function(model_name)
				if model_name == "starcoder2-3b" then
					return {type = "completion", params = 3}
				end
				if model_name == "chat-B" then return {type = "chat", params = 8} end
				return {params = 1}
			end,
			get_actual_model_name = function(name)
				return "actual:" .. tostring(name)
			end,
		}
		local keymap = {
			set_llm_enabled = function(value)
				calls.prediction_states[#calls.prediction_states + 1] = value
				return true
			end,
			set_llm_model = function(value)
				calls.models[#calls.models + 1] = value
				runtime.model = value
				return true
			end,
			set_llm_display_model_name = function(value)
				calls.display_models[#calls.display_models + 1] = value
				runtime.display_model = value
				return true
			end,
		}
		local function save_prefs()
			calls.save_snapshots[#calls.save_snapshots + 1] = copy_state(state)
			if spec.refuse_explicit_profile_save
				and state.llm_active_profile == "advanced" then
				return false
			end
			return true
		end
		local function update_menu()
			calls.menu_snapshots[#calls.menu_snapshots + 1] = copy_state(state)
			if spec.refuse_explicit_profile_menu
				and state.llm_active_profile == "advanced" then
				return false
			end
			return true
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
			calls = calls,
			pending = pending,
			dialog_calls = function() return dialog_calls end,
		})
	end, debug.traceback)

	restore_modules(saved)
	if not ok then error(err, 0) end
end

helpers.describe("HS-029 model/profile intent ordering", function()
	helpers.it("HS-029 preserves a newer explicit profile while the pending model commits", function()
		with_fixture(function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("starcoder2-3b"), true)
			helpers.assert_true(type(fixture.pending["starcoder2-3b"].success) == "function")
			helpers.assert_eq(fixture.calls.prediction_states, {false})
			helpers.assert_eq(fixture.calls.models, {},
				"the model must remain unpublished while requirements are pending")

			helpers.assert_eq(fixture.switcher.set_llm_profile("advanced"), true)
			helpers.assert_eq(fixture.state.llm_active_profile, "advanced")
			helpers.assert_eq(fixture.runtime.profile, "advanced")

			helpers.assert_eq(fixture.pending["starcoder2-3b"].success(), true)
			helpers.assert_eq(fixture.state.llm_model, "starcoder2-3b")
			helpers.assert_eq(fixture.state.llm_model_mlx, "starcoder2-3b")
			helpers.assert_eq(fixture.runtime.model, "actual:starcoder2-3b")
			helpers.assert_eq(fixture.runtime.display_model, "starcoder2-3b")
			helpers.assert_eq(fixture.calls.models, {"actual:starcoder2-3b"})
			helpers.assert_eq(fixture.calls.display_models, {"starcoder2-3b"})
			helpers.assert_eq(fixture.state.llm_active_profile, "advanced",
				"a late recommendation must not overwrite the newer explicit intent")
			helpers.assert_eq(fixture.runtime.profile, "advanced")
			helpers.assert_eq(fixture.calls.profiles, {"advanced"},
				"the stale automatic recommendation must not reach the runtime setter")
			helpers.assert_eq(#fixture.calls.save_snapshots, 2,
				"only the explicit profile and model commits should persist")
			helpers.assert_eq(fixture.calls.save_snapshots[1].llm_active_profile, "advanced")
			helpers.assert_eq(fixture.calls.save_snapshots[2].llm_model, "starcoder2-3b")
			helpers.assert_eq(fixture.calls.save_snapshots[2].llm_active_profile, "advanced")
			helpers.assert_eq(#fixture.calls.menu_snapshots, 2,
				"the stale recommendation must not render an intermediate profile")
			helpers.assert_eq(fixture.calls.menu_snapshots[2].llm_model, "starcoder2-3b")
			helpers.assert_eq(fixture.calls.menu_snapshots[2].llm_active_profile, "advanced")
			helpers.assert_eq(fixture.calls.prediction_states, {false, true},
				"MLX must stay locked until the model request reaches its terminal callback")
		end)
	end)

	helpers.it("HS-029 still applies the recommendation when no newer profile commits", function()
		with_fixture(function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("starcoder2-3b"), true)
			helpers.assert_eq(fixture.calls.prediction_states, {false})

			helpers.assert_eq(fixture.pending["starcoder2-3b"].success(), true)
			helpers.assert_eq(fixture.state.llm_model, "starcoder2-3b")
			helpers.assert_eq(fixture.runtime.model, "actual:starcoder2-3b")
			helpers.assert_eq(fixture.state.llm_active_profile, "raw")
			helpers.assert_eq(fixture.runtime.profile, "raw")
			helpers.assert_eq(fixture.calls.profiles, {"raw"},
				"the ordering guard must not disable current recommendations")
			helpers.assert_eq(#fixture.calls.save_snapshots, 2)
			helpers.assert_eq(fixture.calls.save_snapshots[1].llm_active_profile, "basic")
			helpers.assert_eq(fixture.calls.save_snapshots[2].llm_active_profile, "raw")
			helpers.assert_eq(#fixture.calls.menu_snapshots, 2)
			helpers.assert_eq(fixture.calls.prediction_states, {false, true})
		end)
	end)

	helpers.it("HS-029 ignores a failed explicit profile attempt when ordering recommendations", function()
		with_fixture({refuse_explicit_profile_save = true}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("starcoder2-3b"), true)
			helpers.assert_eq(fixture.switcher.set_llm_profile("advanced"), false)
			helpers.assert_eq(fixture.state.llm_active_profile, "basic")
			helpers.assert_eq(fixture.runtime.profile, "basic")

			helpers.assert_eq(fixture.pending["starcoder2-3b"].success(), true)
			helpers.assert_eq(fixture.state.llm_model, "starcoder2-3b")
			helpers.assert_eq(fixture.state.llm_active_profile, "raw",
				"a rolled-back profile attempt must not invalidate the recommendation")
			helpers.assert_eq(fixture.runtime.profile, "raw")
			helpers.assert_eq(fixture.calls.profiles, {"advanced", "basic", "raw"})
			helpers.assert_eq(fixture.calls.prediction_states, {false, true})
		end)
	end)

	helpers.it("HS-029 waits for the profile menu boundary before advancing intent", function()
		with_fixture({refuse_explicit_profile_menu = true}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("starcoder2-3b"), true)
			helpers.assert_eq(fixture.switcher.set_llm_profile("advanced"), false)
			helpers.assert_eq(fixture.state.llm_active_profile, "basic")
			helpers.assert_eq(fixture.runtime.profile, "basic")

			helpers.assert_eq(fixture.pending["starcoder2-3b"].success(), true)
			helpers.assert_eq(fixture.state.llm_model, "starcoder2-3b")
			helpers.assert_eq(fixture.state.llm_active_profile, "raw",
				"a menu-refused profile attempt must not suppress the current recommendation")
			helpers.assert_eq(fixture.runtime.profile, "raw")
			helpers.assert_eq(fixture.calls.profiles, {"advanced", "basic", "raw"})
			helpers.assert_eq(fixture.calls.prediction_states, {false, true})
		end)
	end)

	helpers.it("HS-029 skips a stale chat-profile dialog after explicit profile intent", function()
		with_fixture(function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("chat-B"), true)
			helpers.assert_eq(fixture.switcher.set_llm_profile("advanced"), true)
			helpers.assert_eq(fixture.pending["chat-B"].success(), true)
			helpers.assert_eq(fixture.state.llm_model, "chat-B")
			helpers.assert_eq(fixture.state.llm_active_profile, "advanced")
			helpers.assert_eq(fixture.runtime.profile, "advanced")
			helpers.assert_eq(fixture.dialog_calls(), 0,
				"an older automatic recommendation must not prompt after newer explicit intent")
			helpers.assert_eq(fixture.calls.prediction_states, {false, true})
		end)
	end)
end)

return true
