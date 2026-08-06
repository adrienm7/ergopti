--- tests/unit/meta/test_notifier_adapter.lua

--- ==============================================================================
--- MODULE: The Driver Can Speak To The Desktop
--- DESCRIPTION:
--- The Linux implementation of the Notifier port.
---
--- WHAT WAS MISSING:
--- The port has existed since the driver did, macOS and Windows both implement
--- it, and the strings every caller would use are already translated into all
--- twenty-one locales. What was absent was the handful of lines that reach the
--- desktop — so every message the other two drivers show their users, this one
--- kept to its log file.
---
--- WHAT THE CASES BELOW ARE ABOUT:
--- Not "it posts a notification" — they never touch a desktop, because a test
--- that did would put a bubble on the maintainer\'s screen every run and still
--- prove nothing about the code. They are about the three ways a notifier is
--- quietly wrong: it drops the message when the desktop cannot show it, it
--- mangles text the shell then interprets, and it blocks a keystroke path on a
--- service that may not be running.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the notifier over a recording shell runner.
--- @param opts table|nil { has_notify_send = boolean, run_fails = boolean }
--- @param body function Receives the notifier and the commands issued.
local function with_shell(opts, body)
	opts = opts or {}
	local shell_name = "adapters.shell_runner"
	local notifier_name = "adapters.notifier"
	local previous_shell = package.loaded[shell_name]
	local previous_notifier = package.loaded[notifier_name]

	local commands = {}
	package.loaded[shell_name] = {
		quote = function(value) return "'" .. tostring(value):gsub("'", "'" .. [[\]] .. "''") .. "'" end,
		has_command = function() return opts.has_notify_send ~= false end,
		run = function(command)
			commands[#commands + 1] = command
			return not opts.run_fails
		end,
		exec = function() return "" end,
		exec_line = function() return "" end,
	}
	package.loaded[notifier_name] = nil

	local ok, err = pcall(function() body(require(notifier_name), commands) end)

	package.loaded[shell_name] = previous_shell
	package.loaded[notifier_name] = previous_notifier
	helpers.assert_true(ok, "the notifier must not throw: " .. tostring(err))
end




-- =================================================================
-- =================================================================
-- ======= 1/ It reaches the desktop ===============================
-- =================================================================
-- =================================================================

helpers.describe("notifier: sending", function()

	helpers.it("issues a notify-send carrying the message", function()
		with_shell(nil, function(notifier, commands)
			notifier.send("Le clavier a été rechargé.")
			helpers.assert_eq(#commands, 1, "exactly one notification must be posted")
			helpers.assert_true(commands[1]:find("notify-send", 1, true) ~= nil)
			helpers.assert_true(commands[1]:find("rechargé", 1, true) ~= nil,
				"the message itself must reach the command, or the notification is "
					.. "an empty bubble")
		end)
	end)

	helpers.it("does not block the caller", function()
		with_shell(nil, function(notifier, commands)
			notifier.send("bonjour")
			helpers.assert_true(commands[1]:find("&", 1, true) ~= nil,
				"this can be reached from the keystroke path, and notify-send waits "
					.. "for the notification daemon to acknowledge — a desktop service "
					.. "that may be slow, or absent, or wedged")
		end)
	end)

	helpers.it("distinguishes the severity levels", function()
		with_shell(nil, function(notifier, commands)
			notifier.send("tout va bien", { level = "info" })
			notifier.send("attention", { level = "warning" })
			helpers.assert_eq(#commands, 2)
			helpers.assert_true(commands[1] ~= commands[2],
				"four levels that all produce the same notification make the level "
					.. "argument decoration rather than information")
		end)
	end)

	helpers.it("shows an unknown level rather than dropping it", function()
		with_shell(nil, function(notifier, commands)
			notifier.send("quelque chose", { level = "catastrophic" })
			helpers.assert_eq(#commands, 1,
				"a caller passing a level this adapter does not know still has "
					.. "something to say, and silence is the worst answer available")
		end)
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ And when it cannot ===================================
-- =================================================================
-- =================================================================

helpers.describe("notifier: no notification daemon", function()

	helpers.it("does not raise when notify-send is absent", function()
		with_shell({ has_notify_send = false }, function(notifier, commands)
			notifier.send("bonjour")
			helpers.assert_eq(#commands, 0,
				"a headless machine or a minimal install has no notify-send, and "
					.. "shelling out to a missing binary once per notification is a "
					.. "subprocess spawned to fail")
		end)
	end)

	helpers.it("refuses an empty message instead of showing a blank bubble", function()
		with_shell(nil, function(notifier, commands)
			notifier.send("")
			notifier.send(nil)
			helpers.assert_eq(#commands, 0,
				"an empty notification tells the user something happened and nothing "
					.. "about what, which is worse than no notification at all")
		end)
	end)

	helpers.it("keeps trying after a failure instead of giving up", function()
		with_shell({ run_fails = true }, function(notifier, commands)
			notifier.send("premier")
			notifier.send("second")
			helpers.assert_eq(#commands, 2,
				"one failed notification must not latch the adapter off. The port "
					.. "contract says failures are non-fatal, and a notification daemon "
					.. "that was restarting when the first message arrived would "
					.. "otherwise silence every message for the rest of the session.")
		end)
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ And something actually calls it ======================
-- =================================================================
-- =================================================================

helpers.describe("notifier: it is used, not merely present", function()

	helpers.it("has a production caller", function()
		-- This driver already shipped a notifier once, and it was DELETED under
		-- ADR-008 for having no callers: an adapter file made the tree answer
		-- "does Linux notify?" affirmatively by inspection while the answer in
		-- practice was no. Adding one back without wiring it would repeat exactly
		-- that, and the port matrix gate cannot see the difference — presence is
		-- all it checks.
		local callers = 0
		for _, relative in ipairs({ "ergopti_hotstrings.lua" }) do
			local handle = io.open(helpers.driver_root() .. "/" .. relative, "r")
			if handle then
				local source = handle:read("*a") or ""
				handle:close()
				for _ in source:gmatch("notifier%.send") do callers = callers + 1 end
			end
		end
		helpers.assert_true(callers > 0,
			"an adapter with no caller is a claim rather than an implementation, "
				.. "which is the precise reason the previous one was removed")
	end)

end)

