--- tests/unit/onboarding/test_failed_finish_restores_choices.lua

--- ==============================================================================
--- MODULE: Regression — a failed Finish keeps the previous folder and language
---         (onboarding-finish-compensation)
--- DESCRIPTION:
--- Finish published the chosen configuration folder to paths.toml and the
--- language to the settings before the destination was versioned and the
--- answers written. When that last step refused (a config.toml from a newer
--- build, a refused or raising writer) the wizard reported the failure but left
--- the new folder and language published: later saves went to a folder whose
--- answers were never written, and the running session kept the old options
--- (macOS MC-001). A refused Finish now restores both, unless something else
--- changed them in between.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.onboarding.finish_fixture")

local OLD_DIR = "/old-config/"
local NEW_DIR = "/new-config/"

local ANSWERS = {
	locale = "de", config_dir = NEW_DIR,
	operations = { { path = "gestures.enabled", value = false } },
}

--- Runs Finish against a folder resolver that starts in OLD_DIR.
--- @param opts table Fixture options without menu_paths/config_dir/answers.
--- @param scenario function scenario(state, folder)
--- @param on_write function|nil Called inside the writer, before it answers.
local function finish(opts, scenario, on_write)
	local folder = { current = OLD_DIR, writes = {} }
	opts.answers = ANSWERS
	opts.config_dir = function() return folder.current end
	opts.menu_paths = {
		persist_config_dir_for_wizard = function(directory)
			folder.writes[#folder.writes + 1] = directory
			folder.current = directory
			return true
		end,
		get = function() return folder.current .. "config.toml" end,
	}
	if on_write then
		local mode = opts.write or "true"
		opts.native_writer = function()
			on_write(folder)
			if mode == "false" then return false, "rename failed" end
			if mode == "throw" then error("disk on fire") end
			return true
		end
	end
	Fixture.with_finish(opts, function(state) scenario(state, folder) end)
end

--- Asserts the refused Finish left the previous choices in force.
--- @param state table Fixture state.
--- @param folder table Folder resolver record.
local function assert_restored(state, folder)
	helpers.assert_eq(folder.current, OLD_DIR, "the previous configuration folder is in force again")
	helpers.assert_eq(table.concat(folder.writes, ","), NEW_DIR .. "," .. OLD_DIR)
	helpers.assert_eq(state.active_locale, "en", "the previous language is active again")
	helpers.assert_eq(table.concat(state.persisted_locales, ","), "de,en")
	helpers.assert_eq(#state.alerts, 1, "the failure is reported")
	helpers.assert_eq(state.deferred, 0, "nothing reloads on a refused Finish")
end





-- ==========================================
-- ==========================================
-- ======= 1/ Refused Finish Restores =======
-- ==========================================
-- ==========================================

helpers.describe("a refused Finish restores the folder and language (onboarding-finish-compensation)", function()
	helpers.it("succeeds on the new folder and language (control)", function()
		finish({}, function(state, folder)
			helpers.assert_eq(folder.current, NEW_DIR)
			helpers.assert_eq(table.concat(folder.writes, ","), NEW_DIR)
			helpers.assert_eq(table.concat(state.persisted_locales, ","), "de")
			helpers.assert_eq(#state.alerts, 0)
			helpers.assert_eq(state.deferred, 1, "one reload applies the answers")
		end)
	end)

	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("restores both when the writer answers " .. mode, function()
			finish({ write = mode }, assert_restored)
		end)
	end

	helpers.it("restores both when the destination is from a newer build", function()
		finish({ read = function() return "[_meta]\nschema_version = 999\n", "ok" end }, function(state, folder)
			helpers.assert_eq(#state.writes, 0, "a newer config.toml is never rewritten")
			assert_restored(state, folder)
		end)
	end)

	helpers.it("restores the folder and the active language when the language is refused", function()
		finish({ locale = "false" }, function(state, folder)
			helpers.assert_eq(folder.current, OLD_DIR)
			helpers.assert_eq(state.active_locale, "en")
			helpers.assert_eq(#state.writes, 0)
			helpers.assert_eq(#state.alerts, 1)
		end)
	end)

	helpers.it("never restores over a folder something else published meanwhile", function()
		finish({ write = "false" }, function(state, folder)
			helpers.assert_eq(folder.current, "/elsewhere/", "a newer choice survives")
			helpers.assert_eq(table.concat(folder.writes, ","), NEW_DIR)
			helpers.assert_eq(#state.alerts, 1)
		end, function(folder) folder.current = "/elsewhere/" end)
	end)
end)
