--- tests/unit/menu/ui/shortcuts/test_chatgpt_url_transaction.lua
local helpers = require("tests.helpers")
local Transaction = require("menu.ui.llm_chatgpt_url_transaction")

helpers.describe("ChatGPT URL preference transaction", function()
	local function fixture()
		local world = { state = { chatgpt_url = "old" }, runtime = "old", admitted = true, save = true }
		local shortcuts = {
			get_chatgpt_url = function() return world.runtime end,
			set_chatgpt_url = function(value)
				if world.refuse_restore and value == "old" then return false end
				world.runtime = value
				return true
			end,
		}
		world.owner = Transaction.new({ state = world.state, shortcuts = shortcuts,
			paused = function() return false end,
			admission = function(_, callback) if not world.admitted then return false end return callback() end,
			save_prefs = function() return world.save end,
		})
		return world
	end
	helpers.it("does not mutate before global writer admission", function()
		local f = fixture(); f.admitted = false
		helpers.assert_eq(f.owner.set("new"), false)
		helpers.assert_eq(f.state.chatgpt_url, "old")
		helpers.assert_eq(f.runtime, "old")
	end)
	helpers.it("restores the exact prior URL when the save refuses", function()
		local f = fixture(); f.save = false
		helpers.assert_eq(f.owner.set("new"), false)
		helpers.assert_eq(f.state.chatgpt_url, "old")
		helpers.assert_eq(f.runtime, "old")
		helpers.assert_eq(f.owner.pending(), false)
	end)
	helpers.it("can edit and restore an absent saved value independently of runtime", function()
		local f = fixture(); f.state.chatgpt_url = nil; f.save = false
		helpers.assert_eq(f.owner.set("new"), false)
		helpers.assert_nil(f.state.chatgpt_url)
		helpers.assert_eq(f.runtime, "old")
		helpers.assert_eq(f.owner.pending(), false)
	end)
	helpers.it("retains a refused inverse and does not overwrite a different URL", function()
		local f = fixture(); f.save = false; f.refuse_restore = true
		helpers.assert_eq(f.owner.set("new"), false)
		helpers.assert_eq(f.owner.pending(), true)
		f.runtime = "other"
		helpers.assert_eq(f.owner.retry_restore(), false)
		helpers.assert_eq(f.runtime, "other")
		helpers.assert_eq(f.owner.pending(), true)
		f.runtime = "new"; f.refuse_restore = false
		helpers.assert_eq(f.owner.retry_restore(), true)
		helpers.assert_eq(f.runtime, "old")
		helpers.assert_eq(f.owner.pending(), false)
	end)
end)

helpers.describe("ChatGPT URL persisted baseline", function()
	helpers.it("loads empty TOML and restores an independently observed runtime on failed save", function()
		helpers.with_stub_scope({ "settings.engine.preferences.preferences", "menu.ui.builder.state", "settings.ui.menu.preferences_transaction" }, function()
			local Preferences = helpers.load_with_stubs("settings.engine.preferences.preferences")
			local MenuState = helpers.load_with_stubs("menu.ui.builder.state")
			local Save = require("settings.ui.menu.preferences_transaction")
			require("tests.support.toml_output_fixture").with_output(function(path)
				local file = assert(io.open(path, "wb"))
				assert(file:write('[shortcuts]\nchatgpt_url = ""\n'))
				file:close()
				local loaded, status = Preferences.load(path)
				helpers.assert_eq(status, "ok")
				helpers.assert_eq(loaded.chatgpt_url, "")
				local state = { hotstrings = {}, shortcuts = false, chatgpt_url = loaded.chatgpt_url }
				local runtime = "https://chat.openai.com"
				local shortcuts = {
					pause_bindings = function() return true end,
					set_chatgpt_url = function(value)
						runtime = value == "" and "https://chat.openai.com" or value
						return true
					end,
					get_chatgpt_url = function() return runtime end,
				}
				local modules, owner = { shortcuts_mod = shortcuts }
				MenuState.sync_state_to_modules(state, loaded, false,
					{ keymap = {}, hotstring_editor = {}, core_mods = modules })
				helpers.assert_eq(state.chatgpt_url, "")
				helpers.assert_eq(runtime, "https://chat.openai.com")
				-- A separately observed live owner can differ from the saved spelling.
				runtime = "https://independently-active.example/"
				local save = Save.bind({ save = function() return false end }, {
					path = path, state = state, hotfiles = {}, core_modules = modules,
					initial_state = state, initial_preferences = state,
					restore_runtime = function(snapshot)
						if owner.pending() and owner.restore_runtime() ~= true then return false end
						local rollback_modules = owner.rollback_modules(modules)
						local ok = MenuState.sync_state_to_modules(state, snapshot, false,
							{ keymap = {}, hotstring_editor = {}, core_mods = rollback_modules })
						if ok ~= true then return false end
						return owner.restore_runtime()
					end,
				})
				owner = Transaction.new({ state = state, shortcuts = shortcuts,
					paused = function() return false end,
					admission = function(_, callback) return callback() end, save_prefs = save })
				helpers.assert_eq(owner.set("https://new.example/"), false)
				helpers.assert_eq(state.chatgpt_url, "")
				helpers.assert_eq(runtime, "https://independently-active.example/")
				helpers.assert_eq(owner.pending(), false)
			end)
		end)
	end)
end)
