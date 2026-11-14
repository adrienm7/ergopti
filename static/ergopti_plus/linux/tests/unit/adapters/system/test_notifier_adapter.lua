--- tests/unit/adapters/system/test_notifier_adapter.lua

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
--- @param opts table|nil { has_notify_send = boolean, run_fails = boolean,
---   start_refused = boolean, exit = table|nil (the child's scripted result) }
--- @param body function Receives the notifier, the commands issued (each argv
---   rendered as one quoted line) and the log lines.
local function with_shell(opts, body)
	opts = opts or {}
	local shell_name = "core.process.adapters.shell_runner"
	local notifier_name = "adapters.notifier"
	local logger_name = "core.logger.engine.shim"
	local previous_shell = package.loaded[shell_name]
	local previous_notifier = package.loaded[notifier_name]
	local previous_logger = package.loaded[logger_name]

	local commands, logs = {}, {}
	local function quote(value) return "'" .. tostring(value):gsub("'", "'" .. [[\]] .. "''") .. "'" end
	package.loaded[shell_name] = {
		quote = quote,
		has_command = function() return opts.has_notify_send ~= false end,
		run = function() error("the notifier must not run notify-send through a shell line") end,
		run_async = function(executable, args, options, callback)
			local words = { executable }
			for index, arg in ipairs(args) do
				-- Options are rendered bare and operands quoted, as a reader would type them.
				words[#words + 1] = (index <= 4) and arg or quote(arg)
			end
			commands[#commands + 1] = table.concat(words, " ")
			helpers.assert_true(type(options) == "table" and type(options.timeout_ms) == "number",
				"notify-send runs under the registry deadline")
			if opts.start_refused then return nil, "spawn failed: ENOENT" end
			local result = opts.exit or (opts.run_fails and { ok = false, code = 1, error = "exit code 1" })
				or { ok = true, code = 0 }
			callback(result)
			return { cancel = function() return true end, on_settled = function() return true end }
		end,
		exec = function() return "" end,
		exec_line = function() return "" end,
	}
	local logger = {}
	for _, level in ipairs({ "debug", "info", "warn", "error", "success", "start", "done", "trace" }) do
		logger[level] = function(_, fmt, ...)
			local ok, text = pcall(string.format, tostring(fmt), ...)
			logs[#logs + 1] = { level = level, text = ok and text or tostring(fmt) }
		end
	end
	package.loaded[logger_name] = setmetatable(logger, { __index = previous_logger })
	package.loaded[notifier_name] = nil

	local ok, err = pcall(function() body(require(notifier_name), commands, logs) end)

	package.loaded[shell_name] = previous_shell
	package.loaded[notifier_name] = previous_notifier
	package.loaded[logger_name] = previous_logger
	helpers.assert_true(ok, "the notifier must not throw: " .. tostring(err))
end




-- =================================================================
-- =================================================================
-- ======= 1/ It reaches the desktop ===============================
-- =================================================================
-- =================================================================

helpers.describe("notifier: sending", function()
	helpers.it("reports whether the notification command was admitted", function()
		with_shell(nil, function(notifier)
			helpers.assert_eq(notifier.send("bonjour"), true)
		end)
		with_shell({ start_refused = true }, function(notifier)
			helpers.assert_eq(notifier.send("bonjour"), false)
		end)
		with_shell({ has_notify_send = false }, function(notifier)
			helpers.assert_eq(notifier.send("bonjour"), false)
		end)
	end)

	helpers.it("delivers the private message to an available notification service", function()
		with_shell(nil, function(notifier, commands)
			helpers.assert_true(notifier.send("private diagnostic", { private = true }))
			helpers.assert_true(commands[1]:find("private diagnostic", 1, true) ~= nil,
				"privacy controls the fallback log, not the requested notice")
		end)
	end)

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

	helpers.it("(nui-006-notification-ttl) keeps the notice up for the registry's duration", function()
		with_shell(nil, function(notifier, commands)
			notifier.send("bonjour")
			local ttl = require("core.timing.engine.timings").ms("ui", "notification_ttl_ms")
			helpers.assert_true(commands[1]:find("--expire-time=" .. string.format("%d", ttl), 1, true) ~= nil,
				"one declaration in _shared/core/timing/data/constants.toml, shared with macOS")
		end)
		local source = assert(helpers.read_module_source("adapters.notifier"))
		helpers.assert_true(source:find("TIMEOUT_MS = 5000", 1, true) == nil, "no typed copy of the duration")
	end)

	helpers.it("does not block the caller", function()
		with_shell(nil, function(notifier, commands)
			notifier.send("bonjour")
			helpers.assert_eq(#commands, 1,
				"this can be reached from the keystroke path, and notify-send waits "
					.. "for the notification daemon to acknowledge — a desktop service "
					.. "that may be slow, or absent, or wedged: it runs through run_async")
		end)
	end)

	helpers.it("(nui-003-notify-send-failure) logs a notify-send that runs and fails, and keeps the notice", function()
		for _, exit in ipairs({ { ok = false, code = 1, error = "exit code 1" }, { ok = false, error = "timeout", timed_out = true } }) do
			with_shell({ exit = exit }, function(notifier, _, logs)
				helpers.assert_true(notifier.send("Le clavier a été rechargé.", { title = "Ergopti+" }),
					"notify-send started; its failure comes from its exit")
				local failed, kept = false, false
				for _, line in ipairs(logs) do
					if line.level == "error" and line.text:find("notify-send failed (" .. exit.error .. ")", 1, true) then failed = true end
					if line.level == "info" and line.text:find("Le clavier a été rechargé.", 1, true) then kept = true end
				end
				helpers.assert_true(failed, "a lost notice is reported, not counted as shown")
				helpers.assert_true(kept, "its text reaches the log fallback")
			end)
		end
		with_shell({ exit = { ok = false, code = 1, error = "exit code 1" } }, function(notifier, _, logs)
			notifier.send("/home/ana/secret.txt", { private = true })
			for _, line in ipairs(logs) do
				helpers.assert_true(line.text:find("secret", 1, true) == nil, "a private notice stays out of the log")
			end
		end)
		with_shell({ start_refused = true }, function(notifier, _, logs)
			helpers.assert_eq(notifier.send("bonjour"), false)
			local kept = false
			for _, line in ipairs(logs) do if line.text:find("bonjour", 1, true) then kept = true end end
			helpers.assert_true(kept, "a notify-send that cannot start keeps the notice in the log")
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

	for index, pair in ipairs({
		{ "--help", "Literal title" }, { "-u", "Short title" },
		{ "Ordinary title", "--help" }, { "Ordinary title", "--urgency=critical" },
		{ "Ordinary title", "--expire-time=1" }, { "Ordinary title", "--app-name=another-app" },
		{ "Ordinary title", "--" }, { "Ordinary title", "-?" },
	}) do
		helpers.it("separates literal notification operands from native options " .. index .. " (notification-option-receipts)", function()
			with_shell(nil, function(notifier, commands)
				helpers.assert_true(notifier.send(pair[2], { title = pair[1] }))
				helpers.assert_eq(#commands, 1)
				local boundary = commands[1]:find(" -- ", 1, true)
				helpers.assert_true(boundary ~= nil, "shell quoting alone cannot prevent native option parsing")
				local operands = commands[1]:sub(boundary + 4)
				helpers.assert_true(operands:find("'" .. pair[1] .. "' '" .. pair[2] .. "'", 1, true) == 1,
					"both caller operands must follow the native option boundary in order")
			end)
		end)
	end

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
