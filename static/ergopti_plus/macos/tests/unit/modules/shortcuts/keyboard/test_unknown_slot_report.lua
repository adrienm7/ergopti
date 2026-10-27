--- tests/unit/modules/shortcuts/keyboard/test_unknown_slot_report.lua

--- ==============================================================================
--- MODULE: An Unknown Keyboard Slot Is Reported And Offered For Cleanup
--- DESCRIPTION:
--- A key under [shortcuts.keyboard] that no slot owns (an id an older build
--- used, a typo) is outdated configuration: named once and offered by the
--- config cleanup, never skipped without a word.
---
--- ROOT CAUSE ENCODED:
--- The owner walked the stored assignments and consumed only the slots it owns;
--- any other key was ignored with no log line, and because the section is a
--- declared dynamic namespace the unused-key scan never listed it either, so a
--- binding lost to a renamed id was invisible.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"adapters.storage",
	"infra.preferences",
	"infra.config_paths",
	"adapters.hotkey_registrar",
	"adapters.file_system",
	"infra.paths",
	"infra.logger",
	"modules.gestures.actions",
	"modules.shortcuts.keyboard_shortcuts",
}

-- The only ids the stubbed catalogue offers; the manifest is the real one.
local OFFERED = { lookup = true, none = true, llm_generate_prediction = true }

--- Runs `scenario` against the real keyboard-shortcut owner over stubbed
--- settings, registrar and catalogue, then restores every displaced module.
--- @param store table Initial canonical assignment map, mutated by conditional writes.
--- @param scenario function(subject, observed)
--- @return table observed { bound = {chord...} }
local function with_subject(store, scenario)
	local prior = {}
	for _, name in ipairs(MODULES) do prior[name] = package.loaded[name] end

	local observed = { bound = {} }
	package.loaded["adapters.hotkey_registrar"] = {
		bind = function(chord)
			observed.bound[#observed.bound + 1] = chord
			return { id = #observed.bound }
		end,
		unbind = function() return true end,
		setEnabled = function() return true end,
	}
	package.loaded["adapters.file_system"] = {
		read = function() return '{"keys":[{"id":"a","label":"A"},{"id":"space","label":"Space"}]}' end,
	}
	package.loaded["infra.paths"] = { shared = function() return "catalogue.json" end }
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.gestures.actions"] = {
		is_assignable = function(action_id) return OFFERED[action_id] == true end,
		execute_single = function() return true end,
	}
	package.loaded["adapters.storage"] = nil
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil

	require("tests.support.keyboard_config_fixture").install(store)

	local subject
	local ok, err = xpcall(function()
		subject = require("modules.shortcuts.keyboard_shortcuts")
		scenario(subject, observed)
	end, debug.traceback)

	if subject and type(subject.stop) == "function" then pcall(subject.stop) end
	for _, name in ipairs(MODULES) do package.loaded[name] = prior[name] end
	if not ok then error(err, 0) end
	return observed
end

local ConfigOutdated = require("config_outdated")

helpers.describe("keyboard shortcuts: unknown slot ids (unknown-slot-report)", function()
	helpers.it("(unknown-slot-report) names an unowned id and keeps an owned id quiet", function()
		ConfigOutdated.reset_for_tests()
		local store = {
			["no_such_slot"] = "lookup",
			["hs_ctrl_space"] = "lookup",
		}
		local reported = ConfigOutdated.collect_reports(function()
			with_subject(store, function(subject)
				helpers.assert_eq(subject.start(), true)
			end)
		end)
		helpers.assert_true(reported["shortcuts.keyboard.no_such_slot"] == true,
			"the unknown id must be offered by the cleanup")
		helpers.assert_nil(reported["shortcuts.keyboard.hs_ctrl_space"], "an owned slot is not outdated")
	end)

	helpers.it("(unknown-slot-report) leaves the stored value in the file", function()
		local store = { ["no_such_slot"] = "lookup" }
		with_subject(store, function(subject) helpers.assert_eq(subject.start(), true) end)
		helpers.assert_eq(store["no_such_slot"], "lookup", "reporting never rewrites config.toml")
	end)
end)

return true
