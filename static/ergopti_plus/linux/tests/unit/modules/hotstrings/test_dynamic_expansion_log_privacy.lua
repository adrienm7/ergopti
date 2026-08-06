--- tests/unit/modules/hotstrings/test_dynamic_expansion_log_privacy.lua
---
--- ==============================================================================
--- MODULE: Regression — the dynamic-expansion log printed the resolved value
---         (dynamic-expansion-log-leak)
--- DESCRIPTION:
--- Two lines wrote a user's personal_info value into the driver's own log, in
--- full, on every expansion:
---
---   1. _shared/lua/dynamic_hotstrings/init.lua — "Buffer match: suffix='%s' →
---      result='%s'", at DEBUG, in code BOTH Lua drivers run.
---   2. linux/modules/dynamic_hotstrings/manager.lua — "Dynamic expansion: '%s'
---      → '%s'", at INFO.
---
--- ROOT CAUSE ENCODED: DEBUG is not a safeguard here. The shared logger's default
--- minimum level is 10 — debug included — so neither line needed anything
--- switched on. Reasoning about severity without checking the default is how a
--- "verbose only" line turns out to be an always-on one. For "@i★" the value
--- printed is the user's IBAN.
---
--- These tests drive the REAL functions with a recording logger and read back
--- every line they produced. Asserting on the format string instead would pass
--- against any code that still interpolates the value.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Real-shaped, nobody's data. Distinctive enough that a substring search cannot
-- match it by accident.
local SECRET = "FR7630006000011234567890189"




-- =========================================
-- =========================================
-- ======= 1/ Recording logger =============
-- =========================================
-- =========================================

--- Installs a logger that keeps every formatted line, runs `body`, restores.
---
--- Records ALL eight variants rather than the one under test: a fix that moved
--- the value from Logger.debug to Logger.trace would otherwise read as green.
--- @param body function Receives the lines table.
local function with_recording_logger(body)
	local lines = {}
	local function record(_, fmt, ...)
		local ok, formatted = pcall(string.format, fmt, ...)
		lines[#lines + 1] = ok and formatted or tostring(fmt)
	end
	local recorder = {
		debug = record, trace = record, done    = record,
		info  = record, start = record, success = record,
		warn  = record, error = record,
		set_level = function() end, set_sink = function() end,
		ring_buffer_snapshot = function() return {} end,
	}
	local previous = package.loaded["logger.shim"]
	package.loaded["logger.shim"] = recorder
	-- Drop the modules under test so they re-require the recorder rather than
	-- keeping the no-op stub they captured at first load.
	package.loaded["dynamic_hotstrings"] = nil
	package.loaded["modules.dynamic_hotstrings.manager"] = nil
	local ok, err = pcall(body, lines)
	package.loaded["logger.shim"] = previous
	package.loaded["dynamic_hotstrings"] = nil
	package.loaded["modules.dynamic_hotstrings.manager"] = nil
	if not ok then error(err, 0) end
end

--- Every recorded line joined, so the secret is hunted across ALL of them.
local function joined(lines)
	return table.concat(lines, "\n")
end




-- =========================================
-- =========================================
-- ======= 2/ The shared engine ============
-- =========================================
-- =========================================

helpers.describe("dynamic expansion log privacy", function()

	helpers.it("the shared engine's buffer-match line carries no resolved value", function()
		with_recording_logger(function(lines)
			local Engine = require("dynamic_hotstrings")
			Engine.add_rule("@i", "personal_info", function() return SECRET end)
			local match = Engine.match_buffer("@i", "dynamic", nil)

			helpers.assert_true(match ~= nil,
				"the rule must match — a test where nothing matched asserts nothing about what a match logs")
			helpers.assert_eq(match.result, SECRET,
				"and the RESULT must still be the real value: redacting what gets typed would break the feature, not fix the log")
			helpers.assert_true(not joined(lines):find(SECRET, 1, true),
				"the resolved value must appear in no log line. It did, at DEBUG, in shared code both Lua drivers run — and the shared logger's default level is 10, so DEBUG was on")
		end)
	end)

	helpers.it("but the length survives, because that is the diagnostic", function()
		with_recording_logger(function(lines)
			local Engine = require("dynamic_hotstrings")
			Engine.add_rule("@i", "personal_info", function() return SECRET end)
			Engine.match_buffer("@i", "dynamic", nil)

			local text = joined(lines)
			helpers.assert_true(text:find("@i", 1, true) ~= nil,
				"the suffix must still be printed — without it the line cannot be attributed to a rule and is worth nothing")
			helpers.assert_true(text:find(tostring(#SECRET), 1, true) ~= nil,
				string.format("the length (%d) must be printed: it is what tells you WHICH field answered when a rule misfires, and dropping it trades a privacy fix for a blind spot", #SECRET))
		end)
	end)

	helpers.it("a resolver that returns nothing logs nothing about it", function()
		with_recording_logger(function(lines)
			local Engine = require("dynamic_hotstrings")
			Engine.add_rule("@x", "personal_info", function() return "" end)
			local match = Engine.match_buffer("@x", "dynamic", nil)
			helpers.assert_true(match == nil,
				"an empty resolution is not a match")
			helpers.assert_true(not joined(lines):find(SECRET, 1, true),
				"and nothing from a previous test leaked into this one's recorder")
		end)
	end)

end)
