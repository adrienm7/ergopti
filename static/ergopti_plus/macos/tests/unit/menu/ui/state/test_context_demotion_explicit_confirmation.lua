--- tests/unit/menu/ui/state/test_context_demotion_explicit_confirmation.lua
--- An explicit correction of a refused boot value must commit or roll back.
local helpers = require("tests.helpers")
local OutputFixture = require("tests.support.settings.toml_output_fixture")

helpers.describe("explicit confirmation of a demoted context length", function()
	for _, outcome in ipairs({ "success", "save_refused", "menu_refused" }) do
		helpers.it("preserves the original setting until the transaction commits: " .. outcome, function()
			helpers.with_stub_scope({ "settings.engine.preferences.preferences", "core.fs.adapters.file_system", "core.fs.adapters.storage",
				"core.ui.engine.dialog_util", "core.i18n.engine.i18n", "ai.engine", "ai.ui.menu.settings_manager" }, function()
				local Preferences = helpers.load_with_stubs("settings.engine.preferences.preferences")
				local FileSystem = require("core.fs.adapters.file_system")
				local Session = require("menu.ui.transactions.session_demotions")
				local Transaction = require("settings.ui.menu.preferences_transaction")
				local session = Session.new()
				session.record({ feature = "ai", key = "llm_context_length", persisted = 5000, demoted = 1500 })
				session.record({ feature = "ai", key = "llm_max_words", persisted = 20, demoted = 10 })
				local state = { hotstrings = {}, llm_context_length = 1500, llm_max_words = 10 }
				local runtime, native = 1500, 1500
				package.loaded["core.fs.adapters.storage"] = {
					read_exact = function() return true, native end,
					set = function(_, value) native = value; return true end,
					delete_exact = function() native = nil; return true end,
				}
				package.loaded["ai.engine"] = { DEFAULT_STATE = { llm_context_length = 1500 } }
				package.loaded["core.i18n.engine.i18n"] = { get = function(key) return key end }
				package.loaded["core.ui.engine.dialog_util"] = { text_prompt = function() return "button.ok", "1500" end }
				local Settings = helpers.load_with_stubs("ai.ui.menu.settings_manager")
				OutputFixture.with_output(function(path)
					local original = "[llm.generation]\ncontext_length = 5000\nmax_words = 20\n"
					local file = assert(io.open(path, "wb")); assert(file:write(original)); file:close()
					local _, status = Preferences.load(path); helpers.assert_eq(status, "ok")
					local calls = 0
					local original_write = FileSystem.write_if_unchanged
					FileSystem.write_if_unchanged = function(...)
						if outcome == "save_refused" then return false end
						return original_write(...)
					end
					local save = Transaction.bind(Preferences, {
						path = path, state = state, initial_state = Transaction.clone(state),
						initial_preferences = Transaction.clone(state), hotfiles = {}, core_modules = {},
						snapshot_view = session.persisted_view,
						restore_runtime = function() return true end,
						on_commit = function(_, snapshot) session.settle(snapshot) end,
					})
					local manager = Settings.new({
						state = state, demotions = session,
						keymap = { set_llm_context_length = function(value) runtime = value; return true end,
							get_llm_runtime_setting = function() return true, runtime end },
						save_prefs = function() return save() end,
						update_menu = function() calls = calls + 1; return outcome ~= "menu_refused" or calls > 1 end,
					})
					local ok, accepted = pcall(manager.set_context_length)
					FileSystem.write_if_unchanged = original_write
					helpers.assert_true(ok, tostring(accepted))
					helpers.assert_eq(accepted, outcome == "success")
					local saved, read_status = Preferences.load(path)
					helpers.assert_eq(read_status, "ok")
					helpers.assert_eq(saved.llm_context_length, outcome == "success" and 1500 or 5000)
					helpers.assert_eq(saved.llm_max_words, 20, "another demoted AI setting stays preserved")
					helpers.assert_eq(#session.list(), outcome == "success" and 1 or 2)
					helpers.assert_eq(state.llm_context_length, 1500)
					helpers.assert_eq(runtime, 1500)
					helpers.assert_eq(native, 1500)
				end)
			end)
		end)
	end
end)
