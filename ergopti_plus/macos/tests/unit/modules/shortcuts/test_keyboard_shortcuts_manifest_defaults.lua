--- tests/unit/modules/shortcuts/test_keyboard_shortcuts_manifest_defaults.lua

--- ==============================================================================
--- MODULE: Keyboard Shortcuts Seed the Manifest's Bindings
--- DESCRIPTION:
--- The shipped keyboard-slot bindings use the manifest's neutral defaults.
--- Ctrl+Space remains native until an explicit action is stored. A stored value
--- overrides the default, "none" included, so clearing an existing assignment
--- remains effective after restart.
---
--- ROOT CAUSE ENCODED:
--- The only way to ask for a prediction was the AI menu's own trigger shortcut,
--- a second binding system. It is replaced by an ordinary keyboard slot, and
--- this owner had no defaults at all (an empty table in the code), so the slot
--- could not ship bound.
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

helpers.describe("keyboard shortcuts: the manifest's shipped bindings", function()
	helpers.it("keeps Ctrl+Space native on a fresh install", function()
		local observed = with_subject({}, function(subject)
			helpers.assert_eq(subject.start(), true, "the shipped bindings must start")
			helpers.assert_eq(subject.get_action("hs_ctrl_space"), "none",
				"the neutral manifest default must be the live choice")
		end)
		helpers.assert_eq(#observed.bound, 0, "no absent shortcut may acquire a native owner")
	end)

	helpers.it("binds an explicitly saved Ctrl+Space action", function()
		local observed = with_subject({ ["hs_ctrl_space"] = "llm_generate_prediction" },
			function(subject)
				helpers.assert_eq(subject.start(), true)
				helpers.assert_eq(subject.get_action("hs_ctrl_space"), "llm_generate_prediction")
			end)
		helpers.assert_eq(#observed.bound, 1, "the explicitly assigned chord owns a native hotkey")
		helpers.assert_true(tostring(observed.bound[1]):lower():find("space", 1, true) ~= nil,
			"the native hotkey must be the Space chord, got " .. tostring(observed.bound[1]))
	end)

	helpers.it("keeps a binding the user cleared cleared after a restart", function()
		local store = { ["hs_ctrl_space"] = "none" }
		local observed = with_subject(store, function(subject)
			helpers.assert_eq(subject.start(), true)
			helpers.assert_eq(subject.get_action("hs_ctrl_space"), "none",
				"a stored 'none' must override the manifest default")
		end)
		helpers.assert_eq(#observed.bound, 0, "a cleared slot must not own a native hotkey")
	end)

	helpers.it("clears an explicit assignment and keeps it native after reload", function()
		local store = { ["hs_ctrl_space"] = "llm_generate_prediction" }
		with_subject(store, function(subject)
			helpers.assert_eq(subject.start(), true)
			helpers.assert_eq(subject.get_action("hs_ctrl_space"), "llm_generate_prediction")
			helpers.assert_eq(subject.set_action("hs_ctrl_space", "none"), true)
		end)
		helpers.assert_eq(store["hs_ctrl_space"], "none",
			"choosing None persists explicit personal intent across reload")
		local restarted = with_subject(store, function(subject)
			helpers.assert_eq(subject.start(), true)
			helpers.assert_eq(subject.get_action("hs_ctrl_space"), "none")
		end)
		helpers.assert_eq(#restarted.bound, 0, "the cleared shortcut remains native after reload")
	end)
end)

return true
