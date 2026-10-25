--- tests/unit/modules/shortcuts/system_actions/test_input_source_conflict.lua

--- ==============================================================================
--- MODULE: Input-Source Shortcut Conflict (input-source-conflict)
--- DESCRIPTION:
--- Decides whether macOS's input-source shortcuts (symbolic hotkeys 60 and 61)
--- still own a keyboard slot's chord, from the AppleSymbolicHotKeys dictionary
--- plutil converts, and warns with a button to the setting when they do.
---
--- ROOT CAUSE ENCODED:
--- Ctrl+Space generates an AI prediction by default, and it is also macOS's
--- default "Select the previous input source". The system takes the press
--- before Hammerspoon, so the binding silently did nothing. An entry the
--- preference file does not list is the ENABLED macOS default, which is the
--- state of a Mac where the user never opened that pane.
--- ==============================================================================

local helpers = require("tests.helpers")

local SUBJECT = "modules.shortcuts.input_source_conflict"

--- Loads the module over a recording ShellRunner whose spawn answers `reply`.
--- @param reply table|nil { exit, stdout, stderr } handed to the completion.
--- @return table conflict, table spawned
local function fresh(reply, path_status)
	local spawned = {}
	local saved = package.loaded["adapters.shell_runner"]
	local saved_fs = package.loaded["adapters.file_system"]
	local saved_logger = package.loaded["infra.logger"]
	local logger = helpers.make_logger_stub()
	local errors = {}
	logger.error = function(_, template, ...)
		errors[#errors + 1] = string.format(template, ...)
	end
	package.loaded["infra.logger"] = logger
	package.loaded["adapters.file_system"] = {
		path_status = function() return path_status or "present", "injected inspection failure" end,
	}
	package.loaded["adapters.shell_runner"] = {
		spawn = function(executable, args, on_done)
			spawned[#spawned + 1] = { executable = executable, args = args }
			return {
				start = function()
					if reply then on_done(reply.exit, reply.stdout, reply.stderr) end
					return true
				end,
			}
		end,
	}
	package.loaded[SUBJECT] = nil
	local ok, conflict = pcall(helpers.load_with_stubs, SUBJECT)
	package.loaded["adapters.shell_runner"] = saved
	package.loaded["adapters.file_system"] = saved_fs
	package.loaded["infra.logger"] = saved_logger
	if not ok then error(conflict, 0) end
	-- This is a macOS account even when the Lua harness runs on Windows.
	local check = conflict.check
	conflict.check = function(...)
		local getenv = os.getenv
		os.getenv = function(name)
			if name == "HOME" then return "/Users/shortcut-test" end
			return getenv(name)
		end
		local checked, result = pcall(check, ...)
		os.getenv = getenv
		if not checked then error(result, 0) end
		return result
	end
	return conflict, spawned, errors
end

helpers.describe("input-source shortcut conflict (input-source-conflict)", function()
	helpers.it("treats a Mac that never changed the shortcuts as owning Ctrl+Space", function()
		local conflict = fresh()
		helpers.assert_eq(table.concat(conflict.conflicting_ids(nil, { "ctrl" }, "space"), ","), "60",
			"an absent entry is the enabled macOS default")
		helpers.assert_eq(table.concat(conflict.conflicting_ids(nil, { "ctrl", "alt" }, "space"), ","), "61")
		helpers.assert_eq(#conflict.conflicting_ids(nil, { "cmd" }, "space"), 0,
			"Cmd+Space is Spotlight, not an input-source shortcut")
		helpers.assert_eq(#conflict.conflicting_ids(nil, { "ctrl" }, "a"), 0, "only Space chords are checked")
	end)

	helpers.it("follows what the user set in the preference file", function()
		local conflict = fresh()
		local off = { ["60"] = { enabled = false, value = { parameters = { 32, 49, 262144 } } } }
		helpers.assert_eq(#conflict.conflicting_ids(off, { "ctrl" }, "space"), 0,
			"a disabled shortcut no longer owns the chord")
		local moved = { ["60"] = { enabled = 1, value = { parameters = { 32, 49, 786432 } } } }
		helpers.assert_eq(#conflict.conflicting_ids(moved, { "ctrl" }, "space"), 0,
			"a shortcut moved to another chord no longer owns Ctrl+Space")
		local kept = { ["60"] = { enabled = 1, value = { parameters = { 32, 49, 262144 } } } }
		helpers.assert_eq(table.concat(conflict.conflicting_ids(kept, { "ctrl" }, "space"), ","), "60",
			"an integer 'enabled' is read like a boolean")
	end)

	helpers.it("reads the dictionary through plutil and reports the conflict", function()
		local json = '{"AppleSymbolicHotKeys":{"60":{"enabled":true,"value":{"parameters":[32,49,262144],"type":"standard"}}}}'
		local conflict, spawned = fresh({ exit = 0, stdout = json, stderr = "" })
		local ids
		helpers.assert_eq(conflict.check({ "ctrl" }, "space", function(found) ids = found end), true)
		helpers.assert_eq(spawned[1].executable, "/usr/bin/plutil")
		helpers.assert_eq(spawned[1].args[1], "-convert")
		helpers.assert_eq(spawned[1].args[2], "json")
		helpers.assert_eq(table.concat(ids or {}, ","), "60")
	end)

	helpers.it("reads disabled custom shortcuts from the converted preference document (input-source-read-refusal)", function()
		local json = '{"AppleSymbolicHotKeys":{"60":{"enabled":false}}}'
		local conflict = fresh({ exit = 0, stdout = json, stderr = "" })
		local ids
		conflict.check({ "ctrl" }, "space", function(found) ids = found end)
		helpers.assert_eq(ids, {}, "the nested disabled entry must not be replaced by the enabled default")
	end)

	helpers.it("reads an absent dictionary as the macOS defaults", function()
		local conflict = fresh({ exit = 0, stdout = "{}", stderr = "" })
		local ids
		conflict.check({ "ctrl" }, "space", function(found) ids = found end)
		helpers.assert_eq(table.concat(ids or {}, ","), "60")
	end)

	helpers.it("uses defaults only after proving the preference file absent (input-source-read-refusal)", function()
		local conflict, spawned = fresh(nil, "absent")
		local ids
		helpers.assert_true(conflict.check({ "ctrl" }, "space", function(found) ids = found end))
		helpers.assert_eq(#spawned, 0)
		helpers.assert_eq(table.concat(ids or {}, ","), "60")
	end)

	helpers.it("reports no conflict result when path inspection fails (input-source-read-refusal)", function()
		local conflict, spawned, errors = fresh(nil, "error")
		local ids
		helpers.assert_eq(conflict.check({ "ctrl" }, "space", function(found) ids = found end), false)
		helpers.assert_eq(#spawned, 0)
		helpers.assert_nil(ids)
		helpers.assert_eq(#errors, 1, "an inspection failure must be visible")
	end)

	helpers.it("never invents a default conflict after a failed preference read (input-source-read-refusal)", function()
		local conflict, _, errors = fresh({ exit = 1, stdout = "", stderr = "Permission denied" })
		local ids
		conflict.check({ "ctrl" }, "space", function(found) ids = found end)
		helpers.assert_nil(ids,
			"a failed preference read cannot prove that the default shortcut is enabled")
		helpers.assert_eq(#errors, 1, "the refusal must be logged as a read failure")
		helpers.assert_true(errors[1]:find("Permission denied", 1, true) ~= nil)
	end)

	helpers.it("does not reinterpret malformed preferences as defaults (input-source-read-refusal)", function()
		for _, stdout in ipairs({ "not json", '{"AppleSymbolicHotKeys":false}' }) do
			local conflict, _, errors = fresh({ exit = 0, stdout = stdout, stderr = "" })
			local ids
			conflict.check({ "ctrl" }, "space", function(found) ids = found end)
			helpers.assert_nil(ids)
			helpers.assert_eq(#errors, 1, "a malformed preference must be an error, not a conflict answer")
		end
	end)

	helpers.it("spawns nothing for a chord no input-source shortcut can use", function()
		local conflict, spawned = fresh({ exit = 0, stdout = "{}", stderr = "" })
		local ids
		conflict.check({ "ctrl" }, "a", function(found) ids = found end)
		helpers.assert_eq(#spawned, 0)
		helpers.assert_eq(#ids, 0)
	end)
end)

return true
