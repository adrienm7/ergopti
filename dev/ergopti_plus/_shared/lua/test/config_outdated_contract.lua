--- _shared/lua/test/config_outdated_contract.lua

--- ==============================================================================
--- MODULE: Outdated Configuration Entry Contract
--- DESCRIPTION:
--- Pins the shared outdated-entry rule every Lua reader of config.toml applies,
--- run by the macOS and Linux suites: one WARNING per entry and reason, never a
--- raise while reporting, partition keeping and marking exactly the known
--- entries, cleanup scans that record every report and never leak, and the
--- manifest value check with its platform, enum and owner-rule branches.
--- ==============================================================================

local M = {}

--- Registers the contract cases.
--- @param helpers table The driver's test helpers.
function M.register(helpers)
	local Outdated = require("config_outdated")

	--- A sink recording each WARNING.
	--- @return table sink
	--- @return table lines
	local function recorder()
		local lines = {}
		return { warn = function(_, fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end }, lines
	end

	helpers.describe("shared outdated-entry rule (config-outdated-contract)", function()
		helpers.it("warns once per entry and reason, and again for another stale value", function()
			Outdated.reset_for_tests()
			local sink, lines = recorder()
			helpers.assert_eq(Outdated.report({ "shortcuts", "keys", "at_hash" }, "gone", sink), true)
			helpers.assert_eq(Outdated.report("shortcuts.keys.at_hash", "gone", sink), false,
				"a segment path and its dotted spelling are one entry")
			helpers.assert_eq(Outdated.report({ "shortcuts", "keys", "at_hash" }, "other", sink), true,
				"the same key holding another stale value is another entry to name")
			helpers.assert_eq(#lines, 2)
			helpers.assert_true(lines[1]:find("'shortcuts.keys.at_hash'", 1, true) ~= nil, lines[1])
			helpers.assert_true(lines[1]:find("offered for cleanup", 1, true) ~= nil, lines[1])
		end)

		helpers.it("never raises on a key a hand edit can write, and never promises to cut a quoted one", function()
			Outdated.reset_for_tests()
			local sink, lines = recorder()
			helpers.assert_eq(Outdated.report({ "shortcuts", "keys", "" }, "empty", sink), true)
			helpers.assert_eq(Outdated.report({ "shortcuts", "keys", 1 }, "list", sink), true)
			helpers.assert_true(lines[1]:find("'shortcuts.keys.\"\"'", 1, true) ~= nil, lines[1])
			helpers.assert_true(lines[1]:find("by hand", 1, true) ~= nil, lines[1])
			helpers.assert_true(lines[2]:find("by hand", 1, true) ~= nil, lines[2])
			helpers.assert_throws(function() Outdated.report({}, "no path") end,
				"a missing path stays a programmer error")
		end)

		helpers.it("partitions known entries, marks exactly them and reports the rest", function()
			Outdated.reset_for_tests()
			local marked = {}
			local kept, outdated = Outdated.partition({ "gestures", "modes" },
				{ swipe_2_left = "x1", tap_3 = "x9", [""] = "x1" },
				function(_, value)
					if value == "x1" then return true end
					return false, "retired mode"
				end,
				function(...) marked[#marked + 1] = table.concat({ ... }, ".") end)
			helpers.assert_eq(kept, { swipe_2_left = "x1" })
			helpers.assert_eq(outdated, { "", "tap_3" })
			helpers.assert_eq(marked, { "gestures.modes.swipe_2_left" })
			local list_kept = Outdated.partition({ "hotstrings", "groups" }, { "a", "b" },
				function() return true end)
			helpers.assert_eq(list_kept, {}, "an older build's list is outdated as a whole")
		end)

		helpers.it("reads a table of settings and reports any other shape", function()
			Outdated.reset_for_tests()
			local reports = Outdated.collect_reports(function()
				helpers.assert_eq(Outdated.settings_table(nil, { "shortcuts" }), nil)
				helpers.assert_eq(Outdated.settings_table({ a = 1 }, { "shortcuts" }), { a = 1 })
				helpers.assert_eq(Outdated.settings_table("x", { "shortcuts", "keyboard" }), nil)
				helpers.assert_eq(Outdated.settings_table({ 1, 2 }, { "shortcuts", "tap_keys" }), nil)
			end)
			helpers.assert_eq(reports, { ["shortcuts.keyboard"] = true, ["shortcuts.tap_keys"] = true })
		end)

		helpers.it("records every report of a scan, even one already logged, and closes on error", function()
			Outdated.reset_for_tests()
			Outdated.report("script.stale", "logged before the scan", recorder())
			local reports = Outdated.collect_reports(function()
				Outdated.report("script.stale", "logged before the scan", recorder())
			end)
			helpers.assert_eq(reports, { ["script.stale"] = true })
			local ok, err = pcall(Outdated.collect_reports, function()
				Outdated.report("script.leaked", "during a failing scan", recorder())
				error("collector failed")
			end)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find("collector failed", 1, true) ~= nil, tostring(err))
			local later = Outdated.collect_reports(function() end)
			helpers.assert_eq(later, {}, "a failed scan is closed and leaks nothing into the next one")
		end)

		helpers.it("checks a value against its manifest entry, platform, type, enum and owner rule", function()
			local fits = Outdated.manifest_value_fits
			helpers.assert_eq(select(1, fits(nil, true)), false)
			helpers.assert_eq(select(1, fits({ type = "boolean", platforms = { "ahk" } }, true, "hs")), false,
				"another driver's setting is not this driver's")
			helpers.assert_eq(select(1, fits({ type = "boolean", platforms = { "hs" } }, true, "hs")), true)
			helpers.assert_eq(select(1, fits({ type = "boolean" }, "yes")), false)
			helpers.assert_eq(select(1, fits({ type = "number" }, "4.5")), false)
			helpers.assert_eq(select(1, fits({ type = "enum", enum_values = { "auto", true } }, true)), true,
				"a non-string enum value matches by identity")
			helpers.assert_eq(select(1, fits({ type = "enum", enum_values = { "auto", true } }, "true")), false)
			local accepts = function(value) return tonumber(value) ~= nil, "not numeric" end
			helpers.assert_eq(select(1, fits({ type = "number" }, "4.5", nil, accepts)), true,
				"the owner's rule replaces the declared Lua type")
			helpers.assert_eq(select(1, fits({ type = "number", platforms = { "ahk" } }, 4.5, "hs", accepts)), false,
				"the owner's rule never admits another driver's setting")
		end)
	end)
end

return M
