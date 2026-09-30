--- tests/unit/ui/test_onboarding_tap_holds_import.lua

--- ==============================================================================
--- MODULE: Regression — the wizard's Tap-Holds answer imports the checked keys
--- DESCRIPTION:
--- The first-run wizard's Tap-Holds page asked nothing on macOS: the switch
--- lives in config_karabiner.toml, where a config.toml answer is never read,
--- so the page showed a note and a Yes imported no key.
---
--- ROOT CAUSE ENCODED:
--- the page had no per-key checklist and the host had no route to the remap
--- owner. The checked keys now reach it: a running bridge takes them in its
--- settings transaction, and before it starts (the first run) or for a folder
--- the wizard moves the configuration to, the owner saves them to that folder's
--- file. No tap-hold key reaches config.toml, an unchecked key or a No imports
--- nothing, and the reload waits for the import.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.onboarding_finish_fixture")
local with_finish = Fixture.with_finish

--- A finish payload answering the Tap-Holds page and one config.toml question.
--- @param keys table Key id -> checked.
--- @param config_dir string|nil Folder typed on the config page.
--- @return table answers
local function answers(keys, config_dir)
	local operations = { { path = "llm.enabled", value = true } }
	for _, key in ipairs({ "caps_lock", "tab", "left_command" }) do
		if keys[key] ~= nil then
			operations[#operations + 1] = { path = "tap_holds.keys." .. key, value = keys[key] }
		end
	end
	return { locale = "en", config_dir = config_dir or "", operations = operations }
end

--- Asserts that config.toml received only the configuration answer.
--- @param state table Fixture state.
local function assert_only_config_rows(state)
	helpers.assert_eq(#state.writes, 1)
	helpers.assert_eq(state.writes[1].rows, { { section = "llm", key = "enabled", value = true } },
		"no tap-hold key reaches config.toml")
end





-- ===============================================
-- ===============================================
-- ======= 1/ The Checked Keys Reach Remap =======
-- ===============================================
-- ===============================================

helpers.describe("the wizard's Tap-Holds answer imports the checked keys", function()
	helpers.it("saves them to the folder's remap file before the bridge starts (first run)", function()
		with_finish({ answers = answers({ caps_lock = true, tab = false, left_command = true }) }, function(state)
			assert_only_config_rows(state)
			helpers.assert_eq(#state.imports, 0, "no running bridge to take them")
			helpers.assert_eq(state.saves, { { keys = { "caps_lock", "left_command" },
				path = Fixture.KARABINER_CONFIG_PATH } }, "only the checked keys, in the folder's own file")
			helpers.assert_eq(state.notifications, 1)
			helpers.assert_eq(state.deferred, 1, "then the reload starts the bridge on them")
			helpers.assert_eq(#state.alerts, 0)
		end)
	end)

	helpers.it("hands them to the running bridge and reloads only once it answered", function()
		with_finish({ answers = answers({ caps_lock = true }), remap = { initialized = true, hold_import = true } },
			function(state)
				assert_only_config_rows(state)
				helpers.assert_eq(state.imports, { { "caps_lock" } })
				helpers.assert_eq(#state.saves, 0, "a running bridge's file is never written behind it")
				helpers.assert_eq(state.deferred, 0, "no reload while the Karabiner transaction runs")
				state.import_callbacks[1](true, "ready", 1)
				helpers.assert_eq(state.notifications, 1)
				helpers.assert_eq(state.deferred, 1)
				helpers.assert_eq(#state.alerts, 0)
			end)
	end)

	helpers.it("saves them to the new folder's file when the wizard moves the configuration", function()
		local menu_paths = {
			persist_config_dir_for_wizard = function() return true end,
			get = function() return "/virtual/moved/hammerspoon/config.toml" end,
		}
		with_finish({ answers = answers({ tab = true }, "/virtual/moved"), remap = { initialized = true },
			menu_paths = menu_paths }, function(state)
			helpers.assert_eq(state.writes[1].path, "/virtual/moved/hammerspoon/config.toml")
			helpers.assert_eq(#state.imports, 0,
				"the running bridge holds the previous folder's settings and would copy them over")
			helpers.assert_eq(state.saves, { { keys = { "tab" }, path = Fixture.KARABINER_CONFIG_PATH } })
		end)
	end)
end)





-- ===============================================
-- ===============================================
-- ======= 2/ Nothing Else Is Written ============
-- ===============================================
-- ===============================================

helpers.describe("the wizard imports nothing it was not asked to", function()
	helpers.it("writes nothing for a No or an unchecked list", function()
		for _, remap in ipairs({ { initialized = false }, { initialized = true } }) do
			with_finish({ answers = answers({ caps_lock = false, tab = false }), remap = remap }, function(state)
				assert_only_config_rows(state)
				helpers.assert_eq(#state.imports, 0)
				helpers.assert_eq(#state.saves, 0)
				helpers.assert_eq(state.deferred, 1, "the reload does not wait for an import that never started")
			end)
		end
	end)

	helpers.it("says so when the import is refused, and still applies the saved answers", function()
		for _, remap in ipairs({ { initialized = true, import_ok = false }, { initialized = false, save_ok = false } }) do
			with_finish({ answers = answers({ caps_lock = true }), remap = remap }, function(state)
				assert_only_config_rows(state)
				helpers.assert_eq(#state.alerts, 1)
				helpers.assert_eq(state.alerts[1].body, "onboarding.error.tap_holds_import")
				helpers.assert_eq(state.deferred, 1, "the other answers are saved and apply at the reload")
			end)
		end
	end)
end)
