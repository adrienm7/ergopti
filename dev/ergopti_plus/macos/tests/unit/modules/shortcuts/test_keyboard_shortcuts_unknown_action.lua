--- tests/unit/modules/shortcuts/test_keyboard_shortcuts_unknown_action.lua

--- ==============================================================================
--- MODULE: Keyboard Shortcuts Refuse Unknown Actions
--- DESCRIPTION:
--- A keyboard slot only ever holds an id the action catalogue offers: set_action
--- refuses any other, and a stored one is left unbound at start with a warning
--- that names it.
---
--- ROOT CAUSES ENCODED:
--- 1. set_action stored any string, so an id no handler runs was persisted and
---    bound, and the chord then did nothing on every press.
--- 2. Once set_action refused such an id, the start-time loader still copied
---    every stored value into the live table and bound its chord: a hand-edited
---    setting, or an id an update retired, kept firing a no-op with nothing in
---    the log. Windows drops such an id at load with a warning; this loader now
---    applies the same catalogue check.
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

-- The only ids the stubbed catalogue offers. The real catalogue's contents have
-- their own test (tests/unit/modules/gestures/test_action_catalogue_parity.lua).
local OFFERED = { lookup = true, none = true }

--- Runs `scenario` against the real keyboard-shortcut owner over stubbed
--- settings, registrar and catalogue, then restores every displaced module.
--- @param store table Initial canonical assignment map, mutated by conditional writes.
--- @param scenario function(subject, observed)
--- @return table observed { bound = {chord...}, warnings = {message...} }
local function with_subject(store, scenario)
	local prior = {}
	for _, name in ipairs(MODULES) do prior[name] = package.loaded[name] end

	local observed = { bound = {}, warnings = {} }
	local logger = helpers.make_logger_stub()
	logger.warn = function(_, fmt, ...) observed.warnings[#observed.warnings + 1] = string.format(fmt, ...) end

	package.loaded["adapters.hotkey_registrar"] = {
		bind = function(chord)
			observed.bound[#observed.bound + 1] = chord
			return { id = #observed.bound }
		end,
		unbind = function() return true end,
	}
	package.loaded["adapters.file_system"] = {
		read = function() return '{"keys":[{"id":"a","label":"A"},{"id":"b","label":"B"}]}' end,
	}
	package.loaded["infra.paths"] = { shared = function() return "catalogue.json" end }
	package.loaded["infra.logger"] = logger
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

--- True when one of the warnings names `id`.
--- @param warnings table
--- @param id string
--- @return boolean
local function names(warnings, id)
	for _, message in ipairs(warnings) do
		if message:find(id, 1, true) then return true end
	end
	return false
end





-- ==========================================
-- ==========================================
-- ======= 1/ Unknown Ids Are Refused =======
-- ==========================================
-- ==========================================

helpers.describe("keyboard shortcuts: unknown action ids", function()
	helpers.it("set_action refuses an id the catalogue does not offer", function()
		local store = { ["cmd_a"] = "lookup" }
		local observed = with_subject(store, function(subject)
			helpers.assert_eq(subject.start(), true, "a valid assignment must start")
			helpers.assert_eq(subject.set_action("cmd_a", "no_such_action"), false,
				"an id no handler runs must be refused, as Windows refuses it")
			helpers.assert_eq(subject.get_action("cmd_a"), "lookup", "a refused id must not replace the binding")
		end)
		helpers.assert_eq(store["cmd_a"], "lookup", "nothing may be persisted")
		helpers.assert_true(names(observed.warnings, "no_such_action"), "the refused id must be named in a warning")
	end)

	helpers.it("leaves a stored id the catalogue does not offer unbound, and says so", function()
		local store = {
			["cmd_a"] = "lookup",
			["cmd_b"] = "no_such_action",
		}
		local observed = with_subject(store, function(subject)
			helpers.assert_eq(subject.start(), true, "a valid assignment must still start")
			helpers.assert_eq(subject.get_action("cmd_a"), "lookup", "a catalogue id still loads")
			helpers.assert_eq(subject.get_action("cmd_b"), "none",
				"an id the catalogue does not offer must not be bound")
		end)
		helpers.assert_eq(#observed.bound, 1, "only the valid slot may own a native hotkey")
		helpers.assert_true(names(observed.warnings, "no_such_action"), "the ignored id must be named in a warning")
	end)

	helpers.it("starts over a plain [shortcuts] keyboard value and leaves it unmarked (config-outdated-shortcut-shape)", function()
		-- walk_assignments asserted a table: an older build's `keyboard = "x"`
		-- made start() fail with an ERROR, rolling back the whole shortcut
		-- layer, and made the cleanup report the file as unreadable.
		require("config_outdated").reset_for_tests()
		local stale = "[shortcuts]\nkeyboard = \"x\"\n"
		local observed = with_subject({}, function(subject)
			package.loaded["adapters.file_system"].read_with_status = function() return stale, "ok" end
			helpers.assert_eq(subject.start(), true, "an outdated value never stops the layer")
			local marked = {}
			subject.mark_config_reads(require("toml_codec").decode(stale),
				function(...) marked[#marked + 1] = table.concat({ ... }, ".") end)
			helpers.assert_eq(marked, {}, "left unmarked, so the cleanup offers it")
		end)
		helpers.assert_true(names(observed.warnings, "'shortcuts.keyboard'"), "the outdated value is named once")
	end)
end)

return true
