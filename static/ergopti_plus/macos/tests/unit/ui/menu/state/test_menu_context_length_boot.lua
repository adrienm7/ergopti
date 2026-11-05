--- tests/unit/ui/menu/state/test_menu_context_length_boot.lua
--- Loaded context limits must agree with runtime and preserve refused TOML.
local helpers = require("tests.helpers")
local OutputFixture = require("tests.support.toml_output_fixture")
local Pipeline = require("tests.support.prediction_pipeline")

helpers.describe("boot projection of persisted AI context length", function()
	for _, case in ipairs({ { value = "5000", refused = true }, { value = '"5000"', refused = false, ignored = true },
		{ value = "4000", refused = false }, { value = '"4000"', refused = false, ignored = true } }) do
		helpers.it("loads " .. case.value .. " without misreporting the live value", function()
			helpers.with_stub_scope({ "infra.preferences", "ui.menu.menu_state", "adapters.storage" }, function()
				local pipeline = Pipeline.load()
				local engine = pipeline.engine
				helpers.assert_eq(engine.set_llm_context_length(1500), true)
				local stored = {}
				package.loaded["adapters.storage"] = { set = function(key, value) stored[key] = value; return true end }
				local Preferences = helpers.load_with_stubs("infra.preferences")
				local MenuState = helpers.load_with_stubs("ui.menu.menu_state")
				local Session = require("ui.menu.session_demotions")
				OutputFixture.with_output(function(path)
					local source = "[llm.generation]\ncontext_length = " .. case.value .. "\ntemperature = 0.35\n"
					local file = assert(io.open(path, "wb")); assert(file:write(source)); file:close()
					local saved, status = Preferences.load(path)
					helpers.assert_eq(status, "ok")
					local state = { hotstrings = {}, llm_model = "model", llm_enabled = false, llm_context_length = 1500 }
					Preferences.merge_saved_data(state, saved)
					local temperatures = {}
					local keymap = {
						set_llm_model = function() return true end,
						set_llm_context_length = engine.set_llm_context_length,
						get_llm_runtime_setting = engine.get_llm_runtime_setting,
						set_llm_temperature = function(value) temperatures[#temperatures + 1] = value end,
					}
					local committed, report = MenuState.sync_state_to_modules(state, saved, false, {
						keymap = keymap, apply_llm_enabled = function() return true end,
						hotstring_editor = {}, core_mods = {},
					})
					local expected = (case.refused or case.ignored) and 1500 or 4000
					if case.ignored then helpers.assert_nil(saved.llm_context_length, "quoted values are filtered by the TOML loader") end
					helpers.assert_eq(select(2, engine.get_llm_runtime_setting("llm_context_length")), expected)
					helpers.assert_eq(state.llm_context_length, expected, "menu must show the proved live value")
					helpers.assert_eq(stored.llm_context_length, expected, "derived storage must not restore the refused value")
					helpers.assert_eq(temperatures, { 0.35 }, "an unrelated saved setting still applies")
					local session = Session.new()
					for _, record in ipairs(report.demotions) do session.record(record) end
					local expected_saved = case.refused and saved.llm_context_length or expected
					helpers.assert_eq(session.persisted_view(state).llm_context_length, expected_saved)
					helpers.assert_eq(committed, not case.refused)
					if case.refused then
						local named = false
						for _, record in ipairs(pipeline.logs) do
							if record.level == "error" and record.message:find("5000", 1, true)
								and record.message:find("1500", 1, true) then named = true end
						end
						helpers.assert_true(named, "diagnostic must identify the refused and active values")
					end
					local file_after = assert(io.open(path, "rb")); local after = file_after:read("*a"); file_after:close()
					helpers.assert_eq(after, source, "boot must not rewrite the user's TOML")
				end)
			end)
		end)
	end
	helpers.it("coerces a numeric string passed by an existing preference owner", function()
		helpers.with_stub_scope({ "ui.menu.menu_state", "adapters.storage" }, function()
			local pipeline = Pipeline.load()
			local engine = pipeline.engine
			local stored = {}
			package.loaded["adapters.storage"] = { set = function(key, value) stored[key] = value; return true end }
			local MenuState = helpers.load_with_stubs("ui.menu.menu_state")
			local state = { hotstrings = {}, llm_model = "model", llm_enabled = false, llm_context_length = "4000" }
			local keymap = { set_llm_model = function() return true end,
				set_llm_context_length = engine.set_llm_context_length,
				get_llm_runtime_setting = engine.get_llm_runtime_setting }
			local deps = { keymap = keymap, apply_llm_enabled = function() return true end,
				hotstring_editor = {}, core_mods = {} }
			helpers.assert_eq(MenuState.sync_state_to_modules(state, {}, false, deps), true)
			helpers.assert_eq(select(2, engine.get_llm_runtime_setting("llm_context_length")), 4000)
			helpers.assert_eq(tostring(state.llm_context_length), "4000")
			state.llm_context_length = "5000"
			local ok, report = MenuState.sync_state_to_modules(state, {}, false, deps)
			helpers.assert_eq(ok, false)
			helpers.assert_eq(state.llm_context_length, 4000)
			helpers.assert_eq(stored.llm_context_length, 4000)
			helpers.assert_eq(report.demotions[1].persisted, "5000")
		end)
	end)

	helpers.it("does not mirror a refused value when its runtime posture is unprovable", function()
		helpers.with_stub_scope({ "ui.menu.menu_state", "adapters.storage" }, function()
			local stored = {}
			package.loaded["adapters.storage"] = { set = function(key, value) stored[key] = value; return true end }
			local MenuState = helpers.load_with_stubs("ui.menu.menu_state")
			local state = { hotstrings = {}, llm_model = "model", llm_enabled = false, llm_context_length = 5000 }
			local committed, report = MenuState.sync_state_to_modules(state, {}, false, {
				keymap = { set_llm_model = function() return true end,
					set_llm_context_length = function() return false end,
					get_llm_runtime_setting = function() error("unavailable") end },
				apply_llm_enabled = function() return true end, hotstring_editor = {}, core_mods = {},
			})
			helpers.assert_eq(committed, false)
			helpers.assert_eq(#report.unsettled, 1)
			helpers.assert_nil(stored.llm_context_length)
		end)
	end)

end)
