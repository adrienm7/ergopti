--- tests/unit/modules/gestures/actions/test_user_actions.lua

--- ==============================================================================
--- MODULE: run_command and open_path (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/action_parameters/user_action_vectors.json
--- through the gesture validator, then runs both actions against recording
--- process, notification, clipboard and typing owners: the hidden command,
--- its bounds, its failure notice and its output, the session's terminal, a
--- missing path and the xdg-open then gio opener, and the two editors.
---
--- ROOT CAUSE ENCODED:
--- No action could run a shell command line or open a chosen file or folder:
--- each needed a script instead. The command text is user configuration and
--- must never reach the log.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("core.text.engine.json")

local CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/action_parameters/user_action_vectors.json"
local ACTION_OF_KIND = { command = "run_command", path = "open_path" }
local SECRET = "curl -H 'Authorization: Bearer s3cr3t-T0KEN' https://example.invalid"

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the user action corpus is not valid JSON")
end

helpers.describe("user actions replay the shared parameter corpus (Linux)", function()
	local Gestures = helpers.load_module("modules.gestures.manager")
	local corpus = read_corpus()

	helpers.it("run_command and open_path are declared, run_apple_shortcut is macOS only (user-actions)", function()
		helpers.assert_eq(Gestures.get_action_parameter_spec("run_command"), "command")
		helpers.assert_eq(Gestures.get_action_parameter_spec("open_path"), "path")
		helpers.assert_eq(Gestures.get_action_parameter_spec("run_apple_shortcut"), nil)
	end)

	for _, vector in ipairs(corpus.vectors) do
		local action = ACTION_OF_KIND[vector.kind]
		if action then
			helpers.it("user action vector '" .. vector.kind .. ":" .. vector.id .. "' (user-actions)", function()
				helpers.assert_eq(Gestures.validate_action_parameter(action, vector.value), vector.valid ~= false, vector.id)
			end)
		end
	end
end)

-- The modules each fixture loads fresh, and the owners it replaces.
local OWNED = {
	"modules.gestures.user_actions", "core.logger.engine.shim", "core.i18n.engine.i18n", "core.process.adapters.shell_runner",
	"adapters.application_notifier", "adapters.clipboard", "core.fs.adapters.file_system", "modules.shortcuts.manager",
}

--- Runs body with every owner of the user actions recorded.
--- @param body function fn(User, world)
local function with_world(body)
	local saved = {}
	for index, name in ipairs(OWNED) do saved[index] = package.loaded[name] end
	local ok, err = pcall(function()
		local world = { logs = {}, notices = {}, async = {}, shell = {}, clipboard = {}, typed = {}, installed = {},
			present = {} }
		local logger = helpers.make_logger_stub()
		for _, level in ipairs({ "debug", "trace", "done", "info", "start", "success", "warn", "error" }) do
			logger[level] = function(_, fmt, ...) world.logs[#world.logs + 1] = string.format(tostring(fmt), ...) end
		end
		package.loaded["core.logger.engine.shim"] = logger
		package.loaded["core.i18n.engine.i18n"] = { get = function(key) return key .. "|{1}|{2}" end }
		package.loaded["adapters.application_notifier"] = { send = function(text)
			world.notices[#world.notices + 1] = (text:gsub("|{%d}", ""))
			return true
		end }
		package.loaded["adapters.clipboard"] = { write = function(text) world.clipboard[#world.clipboard + 1] = text; return true end }
		package.loaded["modules.shortcuts.manager"] = {
			capture_text_destination = function() return { current = function() return true end, cached = function() return true end } end,
			insert_text = function(text) world.typed[#world.typed + 1] = text; return true end,
		}
		package.loaded["core.fs.adapters.file_system"] = { exists = function(path) return world.present[path] == true end }
		package.loaded["core.process.adapters.shell_runner"] = {
			quote = require("core.text.engine.utils_core").shell_quote,
			has_command = function(binary) return world.installed[binary] == true end,
			run = function(command) world.shell[#world.shell + 1] = command; return true end,
			run_async = function(executable, args, options, callback)
				local handle = { executable = executable, args = args, options = options, callback = callback }
				local listeners = {}
				function handle.on_settled(callback) listeners[#listeners + 1] = callback; return true end
				function handle.settle() for _, callback in ipairs(listeners) do callback() end end
				function handle.cancel() handle.cancelled = true; return true end
				world.async[#world.async + 1] = handle
				return handle
			end,
		}
		package.loaded["modules.gestures.user_actions"] = nil
		body(require("modules.gestures.user_actions"), world)
	end)
	for index, name in ipairs(OWNED) do package.loaded[name] = saved[index] end
	if not ok then error(err, 0) end
end

--- Fails when a log line quotes the command.
--- @param world table
local function assert_command_never_logged(world)
	for _, line in ipairs(world.logs) do
		helpers.assert_true(not line:find("s3cr3t", 1, true), "a log line quotes the command: " .. line)
	end
end

helpers.describe("run_command runs the user's line hidden or in a terminal (Linux)", function()
	helpers.it("runs it through a login /bin/sh, bounded, and copies its output (user-actions)", function()
		with_world(function(User, world)
			helpers.assert_eq(User.run_command({ command = SECRET, mode = "hidden", output = "copy" }, 500), true)
			local run = world.async[1]
			helpers.assert_eq(run.executable, "/bin/sh")
			helpers.assert_eq(run.args, { "-l", "-c", SECRET })
			helpers.assert_eq(run.options, {
				timeout_ms = require("core.timing.engine.timings").ms("gestures", "run_command_timeout_ms"),
				max_output_bytes = require("core.timing.engine.timings").count("limits", "user_action_output_bytes"),
			})
			run.callback({ ok = true, code = 0, stdout = "token\n", stderr = "" })
			helpers.assert_eq(world.clipboard, { "token" })
			helpers.assert_eq(User.busy(), false)
			assert_command_never_logged(world)
		end)
	end)

	helpers.it("types its output, refusing one longer than the send_text limit (user-actions)", function()
		with_world(function(User, world)
			User.run_command({ command = "date", mode = "hidden", output = "type" }, 5)
			world.async[1].callback({ ok = true, code = 0, stdout = "12345\n", stderr = "" })
			User.run_command({ command = "date", mode = "hidden", output = "type" }, 5)
			world.async[2].callback({ ok = true, code = 0, stdout = "123456", stderr = "" })
			helpers.assert_eq(world.typed, { "12345" })
			helpers.assert_eq(world.notices, { "user_actions.output_too_long_to_type|5" })
		end)
	end)

	helpers.it("notifies a failure with its first stderr line, the deadline and the bound (user-actions)", function()
		with_world(function(User, world)
			for _ = 1, 3 do User.run_command({ command = SECRET, mode = "hidden", output = "none" }, 500) end
			world.async[1].callback({ ok = false, code = 6, stdout = "", stderr = "\ncurl: (6) s3cr3t host\n" })
			world.async[2].callback({ ok = false, timed_out = true, error = "timeout" })
			world.async[3].callback({ ok = false, overflow = true, error = "output over 65536 bytes" })
			helpers.assert_eq(world.notices, { "user_actions.command_failed_detail|6|curl: (6) s3cr3t host",
				"user_actions.command_timeout|30", "user_actions.command_output_too_large|65536" })
			assert_command_never_logged(world)
		end)
	end)

	helpers.it("does not type asynchronous output into a later focused application", function()
		with_world(function(User, world)
			local focused = "original"
			local manager = package.loaded["modules.shortcuts.manager"]
			manager.capture_text_destination = function()
				local captured = focused
				return { current = function() return focused == captured end, cached = function() return focused == captured end }
			end
			manager.insert_text = function(text, publication)
				if publication == nil or publication.current() then world.typed[#world.typed + 1] = text; return true end
				return false
			end
			helpers.assert_true(User.run_command({ command = "echo test", mode = "hidden", output = "type" }, 500))
			focused = "another application"
			world.async[1].callback({ ok = true, stdout = "private result" })
			helpers.assert_eq(world.typed, {})
		end)
	end)

	helpers.it("does not start a typed-output command without an admitted destination", function()
		with_world(function(User, world)
			package.loaded["modules.shortcuts.manager"].capture_text_destination = function() return nil end
			helpers.assert_eq(User.run_command({ command = "echo test", mode = "hidden", output = "type" }, 500), false)
			helpers.assert_eq(#world.async, 0)
		end)
	end)

	helpers.it("pausing stops the hidden commands and refuses new ones (user-actions)", function()
		with_world(function(User, world)
			User.run_command({ command = "sleep 99", mode = "hidden", output = "none" }, 500)
			helpers.assert_eq(User.busy(), true)
			helpers.assert_eq(User.set_paused(true), true)
			helpers.assert_eq(world.async[1].cancelled, true)
			helpers.assert_eq(User.busy(), false)
			helpers.assert_eq(User.run_command({ command = "true", mode = "hidden", output = "none" }, 500), false)
			helpers.assert_eq(#world.async, 1)
			User.set_paused(false)
			helpers.assert_eq(User.run_command({ command = "true", mode = "hidden", output = "none" }, 500), true)
		end)
	end)

	helpers.it("retains a cancelled child until native settlement", function()
		with_world(function(User, world)
			User.run_command({ command = "sleep 99", mode = "hidden", output = "none" }, 500)
			local handle = world.async[1]
			handle.cancel = function() return false end
			local notifications = 0
			helpers.assert_true(User.when_settled(function() notifications = notifications + 1 end))
			helpers.assert_eq(User.stop(), false)
			helpers.assert_eq(notifications, 0)
			helpers.assert_eq(User.busy(), true)
			helpers.assert_eq(User.stop(), false)
			handle.settle()
			helpers.assert_eq(notifications, 1)
			helpers.assert_eq(User.busy(), false)
			helpers.assert_eq(User.stop(), true)
		end)
	end)

	helpers.it("retains refused command cleanup until native settlement (user-actions)", function()
		with_world(function(User)
			local settled
			local debt = { cancel = function() return false end,
				on_settled = function(listener) settled = listener; return true end }
			package.loaded["core.process.adapters.shell_runner"].run_async = function()
				return nil, "pipe activation failed", debt
			end
			helpers.assert_eq(User.run_command({ command = "sleep 99", mode = "hidden", output = "none" }, 500), false)
			helpers.assert_true(User.busy(), "a refused live child remains owned")
			helpers.assert_eq(User.set_paused(true), false)
			settled()
			helpers.assert_true(not User.busy())
		end)
	end)

	helpers.it("opens the session's terminal detached, the line as an argument (user-actions)", function()
		with_world(function(User, world)
			world.installed = { ["x-terminal-emulator"] = true, konsole = true }
			helpers.assert_eq(User.resolve_terminal(function(b) return world.installed[b] == true end, "/usr/bin/konsole").binary,
				"konsole")
			helpers.assert_eq(User.resolve_terminal(function(b) return world.installed[b] == true end, "unknown-term").binary,
				"x-terminal-emulator")
			helpers.assert_eq(User.terminal_argv({ binary = "gnome-terminal", exec = { "--" } }, SECRET), {
				"gnome-terminal", "--", "/bin/sh", "-l", "-c", User.TERMINAL_SCRIPT, "ergopti", SECRET })
			helpers.assert_true(not User.TERMINAL_SCRIPT:find("s3cr3t", 1, true))
			helpers.assert_eq(User.run_command({ command = SECRET, mode = "terminal", output = "none" }, 500), true)
			local quote = require("core.text.engine.utils_core").shell_quote
			helpers.assert_eq(world.shell[1], "setsid " .. quote("x-terminal-emulator") .. " " .. quote("-e") .. " "
				.. quote("/bin/sh") .. " " .. quote("-l") .. " " .. quote("-c") .. " " .. quote(User.TERMINAL_SCRIPT)
				.. " " .. quote("ergopti") .. " " .. quote(SECRET) .. " </dev/null >/dev/null 2>&1 &")
			assert_command_never_logged(world)
		end)
	end)

	helpers.it("names a missing terminal (user-actions)", function()
		with_world(function(User, world)
			helpers.assert_eq(User.run_command({ command = "htop", mode = "terminal", output = "none" }, 500), false)
			helpers.assert_eq(world.notices, { "user_actions.terminal_unavailable" })
			helpers.assert_eq(#world.shell, 0)
		end)
	end)

	helpers.it("the terminal program runs the command then keeps the user's shell (user-actions)", function()
		with_world(function(User)
			local handle = io.popen("/bin/sh -c " .. require("core.text.engine.utils_core").shell_quote(User.TERMINAL_SCRIPT)
				.. " ergopti 'printf done' </dev/null 2>/dev/null; true", "r")
			local output = handle:read("*a")
			handle:close()
			helpers.assert_eq(output:sub(1, 4), "done")
		end)
	end)
end)

helpers.describe("open_path opens an existing file or folder (Linux)", function()
	helpers.it("refuses a path that no longer exists with a notice naming it (user-actions)", function()
		with_world(function(User, world)
			world.installed["xdg-open"] = true
			helpers.assert_eq(User.open_path({ path = "/home/me/Gone.pdf" }), false)
			helpers.assert_eq(world.notices, { "user_actions.path_missing|/home/me/Gone.pdf" })
			helpers.assert_eq(#world.shell, 0)
		end)
	end)

	helpers.it("opens through xdg-open, else gio open, else names both (user-actions)", function()
		with_world(function(User, world)
			world.present["/home/me/It's $HOME"] = true
			world.installed = { ["xdg-open"] = true, gio = true }
			helpers.assert_eq(User.open_path({ path = "/home/me/It's $HOME" }), true)
			world.installed = { gio = true }
			helpers.assert_eq(User.open_path({ path = "/home/me/It's $HOME" }), true)
			world.installed = {}
			helpers.assert_eq(User.open_path({ path = "/home/me/It's $HOME" }), false)
			local quote = require("core.text.engine.utils_core").shell_quote
			helpers.assert_eq(world.shell, {
				"setsid " .. quote("xdg-open") .. " " .. quote("/home/me/It's $HOME") .. " </dev/null >/dev/null 2>&1 &",
				"setsid " .. quote("gio") .. " " .. quote("open") .. " " .. quote("/home/me/It's $HOME")
					.. " </dev/null >/dev/null 2>&1 &",
			})
			helpers.assert_eq(world.notices, { "user_actions.opener_unavailable" })
		end)
	end)
end)

helpers.describe("the user action editors store one canonical value (Linux)", function()
	local Editor = helpers.load_module("ui.user_action_editor")

	helpers.it("a command is typed, then its mode and output are picked (user-actions)", function()
		local picks = { "hidden", "type" }
		local value = Editor.ask_command("Title", "Prompt <b>", nil, {
			ask = function(_, prompt) helpers.assert_eq(prompt, "Prompt &lt;b&gt;"); return "date +%F" end,
			pick = function() return table.remove(picks, 1) end,
		})
		helpers.assert_eq(value, '{"version":1,"command":"date +%F","mode":"hidden","output":"type"}')
	end)

	helpers.it("a terminal command asks no output; a blank one is returned for the validator (user-actions)", function()
		local asked = 0
		local value = Editor.ask_command("Title", "Prompt", nil, {
			ask = function() return " " end,
			pick = function() asked = asked + 1; return "terminal" end,
		})
		helpers.assert_eq(asked, 1)
		helpers.assert_eq(require("shortcuts.engine.user_action_parameter").parse("command", value), nil)
	end)

	helpers.it("a file or folder is picked with the owned dialog (user-actions)", function()
		local shell = { quote = require("core.text.engine.utils_core").shell_quote }
		local Chooser = helpers.load_module("ui.app_chooser")
		local dialog = require("ui.native_dialog").command()
		helpers.assert_eq(Chooser.path_picker_command(shell, "T", true, "/home/me/"),
			dialog .. " --file-selection --directory --title='T' --filename='/home/me/' 2>/dev/null")
		helpers.assert_eq(Chooser.path_picker_command(shell, "T", false, "/home/me/"),
			dialog .. " --file-selection --title='T' --filename='/home/me/' 2>/dev/null")
		local ran
		shell.exec_checked = function(command) ran = command; return "/home/me/Docs\n" end
		local value = Editor.ask_path("Title", "Prompt", nil, {
			pick = function() return "folder" end, shell = shell,
			modal = function(fn) return true, fn() end,
		})
		helpers.assert_eq(value, "/home/me/Docs")
		-- The caption is the composed window title, like every tray dialog's
		helpers.assert_true(ran:find(" --title=" .. shell.quote(require("core.ui.engine.window_titles").compose("Title")), 1, true) ~= nil,
			"the picker's caption is composed through window_titles: " .. tostring(ran))
		helpers.assert_true(ran:find(" --directory", 1, true) ~= nil, "a folder is picked as a folder")
	end)
end)

helpers.describe("ShellRunner.run_async takes a caller's output bound (Linux)", function()
	helpers.it("refuses a bound that is not a positive integer (user-actions)", function()
		local Shell = helpers.load_module("core.process.adapters.shell_runner")
		if not Shell.HAS_ASYNC then return end
		local handle, refusal = Shell.run_async("/bin/true", {}, { timeout_ms = 1000, max_output_bytes = 0 }, function() end)
		helpers.assert_eq(handle, nil)
		helpers.assert_eq(refusal, "max_output_bytes must be a positive integer")
	end)
end)

helpers.describe("private user-action notification fallback", function()
	for _, mode in ipairs({ "unavailable", "refused" }) do
		helpers.it("does not log command stderr when notifier is " .. mode, function()
			local names = { "core.logger.engine.shim", "core.i18n.engine.i18n", "core.process.adapters.shell_runner", "adapters.notifier",
				"adapters.application_notifier", "modules.gestures.user_actions" }
			local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name] end
			local logs = {}
			local logger = assert(dofile(require("core.fs.engine.paths").shared("core/logger/engine/init.lua")))
			logger.set_level("trace"); logger.set_sink(function(line) logs[#logs + 1] = line end)
			package.loaded["core.logger.engine.shim"] = logger
			package.loaded["core.i18n.engine.i18n"] = { get = function() return "Command failed: {1}: {2}" end }
			package.loaded["core.process.adapters.shell_runner"] = {
				has_command = function() return mode ~= "unavailable" end,
				quote = function(value) return "'" .. value .. "'" end,
				run = function() return false end,
				run_async = function() return nil, "controlled spawn refusal" end,
			}
			package.loaded["adapters.notifier"] = nil
			package.loaded["adapters.application_notifier"] = nil
			package.loaded["modules.gestures.user_actions"] = nil
			local ok, err = xpcall(function()
				local user = require("modules.gestures.user_actions")
				user.notify("user_actions.command_failed_detail", 6, "secretmarker")
				helpers.assert_true(not table.concat(logs, "\n"):find("secretmarker", 1, true),
					"the command's stderr must not be copied into logs")
			end, debug.traceback)
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
			if not ok then error(err, 0) end
		end)
	end
end)
