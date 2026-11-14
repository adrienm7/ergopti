--- tests/unit/modules/gestures/actions/test_user_actions.lua

--- ==============================================================================
--- MODULE: run_command, open_path and run_apple_shortcut (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/action_parameters/user_action_vectors.json
--- through the real gesture validator, then runs the three actions against
--- recording process, clipboard, typing and notification owners: the hidden
--- command and its Terminal window, its bounds and failure notices, a missing
--- path, and a shortcut invoked through the real Apple Shortcut owner and its
--- command-line transport, refused by name once deleted or renamed.
---
--- ROOT CAUSE ENCODED:
--- No action could run a shell command line, open a chosen file or folder, or
--- run one of the user's Apple shortcuts: each needed a script instead. The
--- command text is user configuration and must never reach the log.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("core.text.engine.json")

local CORPUS = helpers.shared("tests/corpus/action_parameters/user_action_vectors.json")
local ACTION_OF_KIND = { command = "run_command", path = "open_path", apple_shortcut = "run_apple_shortcut" }
local SECRET = "curl -H 'Authorization: Bearer s3cr3t-T0KEN' https://example.invalid"
local SHORTCUT_ID = "1B2C3D4E-5F60-4718-9A0B-C1D2E3F40516"
local OTHER_ID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the user action corpus is not valid JSON")
end

package.loaded["core.logger.engine.logger"] = nil
local _ = helpers.load_with_stubs("core.logger.engine.logger")
package.loaded["modules.gestures.engine"] = nil
package.loaded["modules.gestures.actions"] = nil
package.loaded["modules.gestures.conflicts"] = nil
local _gestures = helpers.load_with_stubs("modules.gestures")
local Actions = require("modules.gestures.actions")

helpers.describe("user actions replay the shared parameter corpus (macOS)", function()
	local corpus = read_corpus()

	helpers.it("the three parameters are declared", function()
		for kind, action in pairs(ACTION_OF_KIND) do
			helpers.assert_eq(Actions.get_action_parameter_spec(action), kind, action)
		end
		helpers.assert_true(#corpus.vectors >= 50, "the corpus must hold its vectors")
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("user action vector '" .. vector.kind .. ":" .. vector.id .. "'", function()
			helpers.assert_eq(Actions.validate_action_parameter(ACTION_OF_KIND[vector.kind], vector.value),
				vector.valid ~= false, vector.id)
		end)
	end
end)

-- The modules each fixture loads fresh, and the owners it replaces.
local OWNED = {
	"modules.gestures.user_actions", "modules.gestures.apple_shortcut_action",
	"adapters.apple_shortcuts_cli", "adapters.apple_shortcuts", "core.logger.engine.logger", "core.i18n.engine.i18n",
	"infra.notifications", "modules.gestures.actions_aux_owner", "core.fs.adapters.file_system", "adapters.clipboard",
	"adapters.synthetic_input", "core.process.adapters.shell_runner", "core.events.timer_scheduler",
	"adapters.apple_shortcuts_native", "modules.shortcuts.actions.text",
}

--- Runs body with every owner of the user actions recorded.
--- @param body function fn(world)
local function with_world(body)
	helpers.with_fresh_modules(OWNED, function()
		local world = { logs = {}, notices = {}, runs = {}, clipboard = {}, typed = {}, files = {}, removed = {},
			spawned = {}, timers = {}, library = {}, run_code = 0, run_stderr = "", hold_run = false,
			listeners = {}, status = {} }
		local logger = helpers.make_logger_stub()
		for _, level in ipairs({ "debug", "trace", "done", "info", "start", "success", "evidence", "warn", "error" }) do
			logger[level] = function(_, fmt, ...)
				world.logs[#world.logs + 1] = string.format(tostring(fmt), ...)
			end
		end
		package.loaded["core.logger.engine.logger"] = logger
		package.loaded["core.i18n.engine.i18n"] = {
			get = function(key) return key end,
			format = function(key, ...)
				local parts = { key }
				for _, value in ipairs({ ... }) do parts[#parts + 1] = tostring(value) end
				return table.concat(parts, "|")
			end,
		}
		package.loaded["infra.notifications"] = { notify = function(text)
			world.notices[#world.notices + 1] = text
			return true
		end }
		package.loaded["modules.gestures.actions_aux_owner"] = {
			run_private = function(executable, args, label, callback, parent, deadline, max_bytes)
				world.runs[#world.runs + 1] = { executable = executable, args = args, label = label,
					callback = callback, parent = parent, deadline = deadline, max_bytes = max_bytes }
				return true
			end,
			register_pause_listener = function(id, listener) world.listeners[id] = listener end,
			is_paused = function() return world.paused == true end,
		}
		local temp_count = 0
		package.loaded["core.fs.adapters.file_system"] = {
			path_status = function(path)
				local status = world.status[path] or "present"
				return status, status == "present" and { size = world.reported_size or #(world.files[path] or "") } or nil
			end,
			create_secure_temp_file = function()
				temp_count = temp_count + 1
				local path = "/tmp/lua_test_" .. temp_count
				world.files[path] = ""
				if world.before_temp_return then world.before_temp_return() end
				return path
			end,
			write = function(path, content)
				world.files[path] = content
				if world.before_temp_write_return then world.before_temp_write_return() end
				return true
			end,
			read = function(path) return world.files[path] end,
			read_bounded = function(path, limit)
				local content = world.files[path]
				if world.before_output_read then world.before_output_read() end
				if content == nil then return nil, "absent" end
				if #content > limit then return nil, "too_large" end
				return content, "ok"
			end,
			remove_exact = function(path)
				if world.refuse_remove then return false, "refused" end
				world.removed[#world.removed + 1] = path; world.files[path] = nil; return true
			end,
			classify_no_follow = function(path)
				if world.files[path] == nil then return nil, "absent" end
				return { mode = "file" }, "ok"
			end,
		}
		package.loaded["adapters.clipboard"] = { write = function(text)
			world.clipboard[#world.clipboard + 1] = text
			return true
		end }
		package.loaded["adapters.synthetic_input"] = { emit_key_strokes = function(text)
			world.typed[#world.typed + 1] = text
			return true
		end }
		package.loaded["core.events.timer_scheduler"] = {
			after = function(_, fn)
				if world.raise_timer then error("timer unavailable") end
				local handle = { fn = fn }
				world.timers[#world.timers + 1] = handle
				return handle, not world.refuse_timer
			end,
			cancel = function(handle) handle.cancelled = true; return true end,
		}
		package.loaded["adapters.apple_shortcuts_native"] = {
			cli_identity = function() return { executable = "/usr/bin/shortcuts", token = "fingerprint" } end,
		}
		package.loaded["modules.shortcuts.actions.text"] = {
			read_copied_selection = function(_, on_selection, on_empty)
				if world.defer_selection then world.empty_selection = on_empty; return true end
				if world.selection then on_selection(world.selection) else on_empty() end
				return true
			end,
		}
		--- The process layer of /usr/bin/shortcuts: a listing of world.library,
		--- a run answered with world.run_code unless world.hold_run keeps it.
		package.loaded["core.process.adapters.shell_runner"] = { spawn = function(executable, args, on_done, _, _, private)
			local handle = { executable = executable, args = args, private = private, observers = {} }
			world.spawned[#world.spawned + 1] = handle
			local function settle(code, out, err)
				if handle.settled then return end
				handle.settled = true
				on_done(code, out, err)
				for _, observer in ipairs(handle.observers) do observer() end
			end
			handle.settle = settle
			function handle.start()
				if args[1] == "list" then
					if world.hold_list then return true end
					if world.before_list then world.before_list(#world.spawned) end
					local lines = {}
					for _, row in ipairs(world.library) do lines[#lines + 1] = row.name .. " (" .. row.id .. ")" end
					settle(0, table.concat(lines, "\n") .. "\n", "")
				elseif not world.hold_run then
					local output_at
					for index, value in ipairs(args) do if value == "--output-path" then output_at = index + 1 end end
					if output_at and world.run_output then world.files[args[output_at]] = world.run_output end
					settle(world.run_code, "", world.run_stderr)
				end
				return true
			end
			function handle.terminate() handle.terminated = true; settle(15, "", ""); return true, "settled" end
			function handle.isSettled() return handle.settled == true end
			function handle.onSettled(observer)
				if handle.settled then observer() else handle.observers[#handle.observers + 1] = observer end
				return true
			end
			return handle
		end }
		world.User = require("modules.gestures.user_actions")
		world.Shortcut = require("modules.gestures.apple_shortcut_action")
		world.Cli = require("adapters.apple_shortcuts_cli")
		body(world)
	end)
end

--- Fails when a log line quotes the command.
--- @param world table
local function assert_command_never_logged(world)
	for _, line in ipairs(world.logs) do
		helpers.assert_true(not line:find("s3cr3t", 1, true), "a log line quotes the command: " .. line)
	end
end

helpers.describe("run_command runs the user's line hidden or in Terminal (macOS)", function()
	helpers.it("runs it through a login /bin/sh, bounded, and copies its output", function()
		with_world(function(world)
			helpers.assert_eq(world.User.run_command({ command = SECRET, mode = "hidden", output = "copy" }, "gestures", 500), true)
			local run = world.runs[1]
			helpers.assert_eq(run.executable, "/bin/sh")
			helpers.assert_eq(run.args, { "-l", "-c", SECRET })
			helpers.assert_eq(run.deadline, require("core.timing.engine.timings").sec("gestures", "run_command_timeout_ms"))
			helpers.assert_eq(run.max_bytes, require("core.timing.engine.timings").count("limits", "user_action_output_bytes"))
			helpers.assert_eq(run.parent, "gestures")
			run.callback({ code = 0, stdout = "token\n", stderr = "", overflow = false })
			helpers.assert_eq(world.clipboard, { "token" })
			helpers.assert_eq(#world.notices, 0)
			assert_command_never_logged(world)
		end)
	end)

	helpers.it("types its output, refusing one longer than the send_text limit", function()
		with_world(function(world)
			world.User.run_command({ command = "date", mode = "hidden", output = "type" }, "gestures", 5)
			world.runs[1].callback({ code = 0, stdout = "12345\n", stderr = "" })
			helpers.assert_eq(world.typed, { "12345" })
			world.User.run_command({ command = "date", mode = "hidden", output = "type" }, "gestures", 5)
			world.runs[2].callback({ code = 0, stdout = "123456", stderr = "" })
			helpers.assert_eq(#world.typed, 1)
			helpers.assert_eq(world.notices, { "user_actions.output_too_long_to_type|5" })
		end)
	end)

	helpers.it("counts Unicode code points and removes trailing line endings before typing", function()
		with_world(function(world)
			world.User.run_command({ command = "print", mode = "hidden", output = "type" }, "gestures", 3)
			world.runs[1].callback({ code = 0, stdout = "é日🙂\r\n", stderr = "" })
			helpers.assert_eq(world.typed, { "é日🙂" })
			helpers.assert_eq(world.notices, {})
		end)
	end)

	helpers.it("refuses invalid UTF-8 for both typing and clipboard output", function()
		with_world(function(world)
			for _, output in ipairs({ "type", "copy" }) do
				world.User.run_command({ command = "print", mode = "hidden", output = output }, "gestures", 5)
				world.runs[#world.runs].callback({ code = 0, stdout = "ok\255", stderr = "" })
			end
			helpers.assert_eq(world.typed, {})
			helpers.assert_eq(world.clipboard, {})
			helpers.assert_eq(world.notices, { "user_actions.output_not_text", "user_actions.output_not_text" })
		end)
	end)

	helpers.it("notifies a failure with its first stderr line, and logs only the exit code", function()
		with_world(function(world)
			world.User.run_command({ command = SECRET, mode = "hidden", output = "none" }, "gestures", 500)
			world.runs[1].callback({ code = 7, stdout = "", stderr = "\n  curl: (6) s3cr3t host  \nmore\n" })
			helpers.assert_eq(world.notices, { "user_actions.command_failed_detail|7|curl: (6) s3cr3t host" })
			assert_command_never_logged(world)
		end)
	end)

	helpers.it("notifies the deadline and the output bound", function()
		with_world(function(world)
			world.User.run_command({ command = "yes", mode = "hidden", output = "none" }, "gestures", 500)
			world.runs[1].callback(false)
			world.User.run_command({ command = "yes", mode = "hidden", output = "none" }, "gestures", 500)
			world.runs[2].callback({ code = 15, stdout = "", stderr = "", overflow = true })
			helpers.assert_eq(world.notices[1], "user_actions.command_timeout|30")
			helpers.assert_eq(world.notices[2], "user_actions.command_output_too_large|65536")
		end)
	end)

	helpers.it("opens Terminal with the line as an argument, never as AppleScript source", function()
		with_world(function(world)
			world.User.run_command({ command = SECRET, mode = "terminal", output = "none" }, "gestures", 500)
			local run = world.runs[1]
			helpers.assert_eq(run.executable, "/usr/bin/osascript")
			helpers.assert_eq(run.args[#run.args], "/bin/sh -l -c '" .. SECRET:gsub("'", "'\\''") .. "'")
			for index = 1, #run.args - 1 do
				helpers.assert_true(not run.args[index]:find("s3cr3t", 1, true), "the script source quotes the command")
			end
			run.callback({ code = 1, stdout = "", stderr = "" })
			helpers.assert_eq(world.notices, { "user_actions.terminal_unavailable" })
			assert_command_never_logged(world)
		end)
	end)
end)

helpers.describe("open_path opens an existing file or folder (macOS)", function()
	helpers.it("refuses a path that no longer exists with a notice naming it", function()
		with_world(function(world)
			world.status["/Users/me/Gone.pdf"] = "absent"
			helpers.assert_eq(world.User.open_path({ path = "/Users/me/Gone.pdf" }, "gestures"), false)
			helpers.assert_eq(#world.runs, 0)
			helpers.assert_eq(world.notices, { "user_actions.path_missing|/Users/me/Gone.pdf" })
		end)
	end)

	helpers.it("opens an existing one with open, privately", function()
		with_world(function(world)
			helpers.assert_eq(world.User.open_path({ path = "/Users/me/Docs" }, "gestures"), true)
			helpers.assert_eq(world.runs[1].executable, "/usr/bin/open")
			helpers.assert_eq(world.runs[1].args, { "/Users/me/Docs" })
		end)
	end)
end)

--- The decoded parameter of a run_apple_shortcut binding.
local function shortcut(fields)
	local value = { id = SHORTCUT_ID, name = "Resize Image", input = "none", output = "none" }
	for key, field in pairs(fields or {}) do value[key] = field end
	return value
end

--- The runs of `shortcuts run` the fake process layer saw.
local function shortcut_runs(world)
	local runs = {}
	for _, handle in ipairs(world.spawned) do
		if handle.args[1] == "run" then runs[#runs + 1] = handle end
	end
	return runs
end

helpers.describe("run_apple_shortcut runs a library shortcut through its owner (macOS)", function()
	helpers.it("parses the listing and refuses a line it cannot read", function()
		with_world(function(world)
			helpers.assert_eq(world.Cli.parse_list("Resize Image (" .. SHORTCUT_ID .. ")\nA (b) (" .. OTHER_ID .. ")\n"),
				{ { id = SHORTCUT_ID, name = "Resize Image" }, { id = OTHER_ID, name = "A (b)" } })
			helpers.assert_eq(world.Cli.parse_list("Resize Image\n"), nil)
			helpers.assert_eq(world.Cli.parse_list("A (" .. SHORTCUT_ID .. ")\nB (" .. SHORTCUT_ID .. ")\n"), nil)
		end)
	end)

	helpers.it("lists the library for the editor with each identifier", function()
		with_world(function(world)
			world.library = { { id = SHORTCUT_ID, name = "Resize Image" }, { id = OTHER_ID, name = "Ergopti Field Test" } }
			local listed
			helpers.assert_eq(world.Shortcut.list(function(rows) listed = rows end), true)
			helpers.assert_eq(listed, world.library)
			for _, handle in ipairs(world.spawned) do helpers.assert_eq(handle.private, true) end
		end)
	end)

	helpers.it("runs the stored shortcut by identifier after revalidating it", function()
		with_world(function(world)
			world.library = { { id = OTHER_ID, name = "Other" }, { id = SHORTCUT_ID, name = "Resize Image" } }
			local outcome
			helpers.assert_eq(world.Shortcut.run(shortcut(), "gestures", 500, function(ok, category)
				outcome = { ok, category }
			end), true)
			local runs = shortcut_runs(world)
			helpers.assert_eq(#runs, 1)
			helpers.assert_eq(runs[1].args, { "run", SHORTCUT_ID })
			-- Discovery, then the owner's own revalidation of the identifier
			helpers.assert_eq(world.spawned[2].args, { "list", "--show-identifiers" })
			helpers.assert_eq(outcome, { true, "completed" })
			helpers.assert_eq(#world.notices, 0)
			helpers.assert_eq(world.Shortcut.busy(), false)
		end)
	end)

	helpers.it("refuses a deleted shortcut by name, without running anything", function()
		with_world(function(world)
			world.library = { { id = OTHER_ID, name = "Other" } }
			local outcome
			world.Shortcut.run(shortcut(), "gestures", 500, function(ok, category) outcome = { ok, category } end)
			helpers.assert_eq(#shortcut_runs(world), 0)
			helpers.assert_eq(world.notices, { "user_actions.shortcut_missing|Resize Image" })
			helpers.assert_eq(outcome, { false, "missing" })
		end)
	end)

	helpers.it("refuses a renamed shortcut by name, without running anything", function()
		with_world(function(world)
			world.library = { { id = SHORTCUT_ID, name = "Resize Images" } }
			world.Shortcut.run(shortcut(), "gestures", 500)
			helpers.assert_eq(#shortcut_runs(world), 0)
			helpers.assert_eq(world.notices, { "user_actions.shortcut_renamed|Resize Image" })
		end)
	end)

	helpers.it("refuses a shortcut renamed or deleted between discovery and its revalidation", function()
		with_world(function(world)
			world.library = { { id = SHORTCUT_ID, name = "Resize Image" } }
			world.before_list = function(count)
				if count == 2 then world.library = { { id = SHORTCUT_ID, name = "Renamed" } } end
			end
			world.Shortcut.run(shortcut(), "gestures", 500)
			world.library = { { id = SHORTCUT_ID, name = "Resize Image" } }
			world.spawned = {}
			world.before_list = function(count) if count == 2 then world.library = {} end end
			world.Shortcut.run(shortcut(), "gestures", 500)
			helpers.assert_eq(#shortcut_runs(world), 0)
			helpers.assert_eq(world.notices, {
				"user_actions.shortcut_renamed|Resize Image", "user_actions.shortcut_missing|Resize Image",
			})
		end)
	end)

	helpers.it("passes the selection as a private file and copies the text output", function()
		with_world(function(world)
			world.library = { { id = SHORTCUT_ID, name = "Resize Image" } }
			world.selection, world.run_output = "selected words", "translated\n"
			world.Shortcut.run(shortcut({ input = "selection", output = "copy" }), "gestures", 500)
			local args = shortcut_runs(world)[1].args
			helpers.assert_eq(args[3], "--input-path")
			helpers.assert_eq(args[5], "--output-path")
			helpers.assert_eq({ args[7], args[8] }, { "--output-type", "public.plain-text" })
			helpers.assert_eq(#args, 8)
			helpers.assert_eq(world.clipboard, { "translated" })
			-- Both temporary files are removed once the run is over
			helpers.assert_eq(#world.removed, 2)
			helpers.assert_eq(world.files[args[4]], nil)
		end)
	end)

	helpers.it("refuses oversized and invalid shortcut output before changing the clipboard", function()
		with_world(function(world)
			world.library = { { id = SHORTCUT_ID, name = "Resize Image" } }
			world.run_output = string.rep("x", world.Shortcut.MAX_OUTPUT_BYTES + 1)
			world.Shortcut.run(shortcut({ output = "copy" }), "gestures", 500)
			helpers.assert_eq(world.clipboard, {})
			helpers.assert_eq(world.notices, { "user_actions.command_output_too_large|65536" })
			world.run_output = "invalid\255"
			world.Shortcut.run(shortcut({ output = "copy" }), "gestures", 500)
			helpers.assert_eq(world.clipboard, {})
			helpers.assert_eq(world.notices[2], "user_actions.output_not_text")
		end)
	end)

	helpers.it("refuses output that grows after its size was inspected", function()
		with_world(function(world)
			world.library = { { id = SHORTCUT_ID, name = "Resize Image" } }
			world.run_output = string.rep("x", world.Shortcut.MAX_OUTPUT_BYTES + 1)
			world.reported_size = 1
			world.Shortcut.run(shortcut({ output = "copy" }), "gestures", 500)
			helpers.assert_eq(world.clipboard, {}, "the bytes read, not just the earlier stat, must fit")
			helpers.assert_eq(world.notices, { "user_actions.command_output_too_large|65536" })
		end)
	end)

	helpers.it("notifies a failed run with its first stderr line", function()
		with_world(function(world)
			world.library = { { id = SHORTCUT_ID, name = "Resize Image" } }
			world.run_code, world.run_stderr = 1, "Error: The operation couldn’t be completed.\n"
			world.Shortcut.run(shortcut(), "gestures", 500)
			helpers.assert_eq(world.notices,
				{ "user_actions.shortcut_failed_detail|Resize Image|Error: The operation couldn’t be completed." })
		end)
	end)

	helpers.it("stops a run at its deadline and notifies it", function()
		with_world(function(world)
			world.library = { { id = SHORTCUT_ID, name = "Resize Image" } }
			world.hold_run = true
			world.Shortcut.run(shortcut(), "gestures", 500)
			local run = shortcut_runs(world)[1]
			helpers.assert_eq(world.Shortcut.busy(), true)
			world.timers[#world.timers].fn()
			helpers.assert_eq(run.terminated, true)
			helpers.assert_eq(world.notices, { "user_actions.shortcut_timeout|Resize Image|60" })
			helpers.assert_eq(world.Shortcut.busy(), false)
		end)
	end)

	helpers.it("stops a running shortcut if its deadline cannot be armed", function()
		with_world(function(world)
			world.library = { { id = SHORTCUT_ID, name = "Resize Image" } }
			world.hold_run = true
			world.refuse_timer = true
			world.Shortcut.run(shortcut(), "gestures", 500)
			local run = shortcut_runs(world)[1]
			helpers.assert_true(run ~= nil, "the refused deadline must follow process start")
			helpers.assert_eq(run.terminated, true, "an unbounded shortcut must be stopped")
			helpers.assert_eq(world.Shortcut.busy(), false)
		end)
	end)

	helpers.it("stops an unbounded library query when its deadline raises", function()
		with_world(function(world)
			world.hold_list = true
			world.raise_timer = true
			local result, reason
			local accepted = world.Shortcut.list(function(rows, refused) result, reason = rows, refused end)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(world.spawned[1].terminated, true)
			helpers.assert_nil(result, "a refused query cannot publish a library")
			helpers.assert_eq(reason, "query_refused")
		end)
	end)

	helpers.it("reports a synchronous discovery refusal only once for an action", function()
		with_world(function(world)
			world.hold_list = true
			world.raise_timer = true
			local outcomes = {}
			world.Shortcut.run(shortcut(), "gestures", 500, function(ok, reason)
				outcomes[#outcomes + 1] = { ok, reason }
			end)
			helpers.assert_eq(#world.notices, 1, "the callback and false return describe one refusal")
			helpers.assert_eq(outcomes, { { false, "query_refused" } })
		end)
	end)

	helpers.it("reports a synchronous revalidation refusal only once for an action", function()
		with_world(function(world)
			world.library = { { id = SHORTCUT_ID, name = "Resize Image" } }
			world.before_list = function()
				world.hold_list = true
				world.raise_timer = true
			end
			local outcomes = {}
			world.Shortcut.run(shortcut(), "gestures", 500, function(ok, reason)
				outcomes[#outcomes + 1] = { ok, reason }
			end)
			helpers.assert_eq(#world.notices, 1)
			helpers.assert_eq(outcomes, { { false, "query_refused" } })
		end)
	end)

	helpers.it("pausing its parent cancels a run without a later notice", function()
		with_world(function(world)
			world.library = { { id = SHORTCUT_ID, name = "Resize Image" } }
			world.hold_run = true
			local outcome
			world.Shortcut.run(shortcut({ output = "type" }), "gestures", 500, function(ok, category)
				outcome = { ok, category }
			end)
			local run = shortcut_runs(world)[1]
			world.listeners.run_apple_shortcut("gestures")
			helpers.assert_eq(run.terminated, true)
			helpers.assert_eq(outcome, { false, "cancelled" })
			helpers.assert_eq(#world.notices, 0)
			helpers.assert_eq(#world.typed, 0)
			helpers.assert_eq(world.Shortcut.busy(), false)
		end)
	end)

	helpers.it("does not publish shortcut output after pause during the bounded read", function()
		with_world(function(world)
			world.library = { { id = SHORTCUT_ID, name = "Resize Image" } }
			world.run_output = "private result"
			world.before_output_read = function() world.listeners.run_apple_shortcut("gestures") end
			local outcome
			world.Shortcut.run(shortcut({ output = "copy" }), "gestures", 500, function(ok, category)
				outcome = { ok, category }
			end)
			helpers.assert_eq(outcome, { false, "cancelled" })
			helpers.assert_eq(world.clipboard, {}, "an old result cannot cross the pause boundary")
		end)
	end)

	helpers.it("ignores an empty selection delivered after the run was cancelled", function()
		with_world(function(world)
			world.defer_selection = true
			local outcome
			world.Shortcut.run(shortcut({ input = "selection" }), "gestures", 500, function(ok, category)
				outcome = { ok, category }
			end)
			world.listeners.run_apple_shortcut("gestures")
			world.empty_selection()
			helpers.assert_eq(outcome, { false, "cancelled" })
			helpers.assert_eq(world.notices, {}, "a cancelled run cannot announce a missing selection")
		end)
	end)

	helpers.it("cancels an implicit gesture parent when that parent is paused", function()
		with_world(function(world)
			world.defer_selection = true
			local outcome
			world.Shortcut.run(shortcut({ input = "selection" }), nil, 500, function(ok, category)
				outcome = { ok, category }
			end)
			world.listeners.run_apple_shortcut("gestures")
			helpers.assert_eq(outcome, { false, "cancelled" })
			helpers.assert_eq(world.Shortcut.busy(), false)
		end)
	end)

	helpers.it("removes a temporary output acquired during a reentrant pause", function()
		with_world(function(world)
			world.before_temp_return = function()
				world.listeners.run_apple_shortcut("gestures")
				world.successor = world.Shortcut.run(shortcut(), "shortcut_bindings", 500)
			end
			local accepted = world.Shortcut.run(shortcut({ output = "copy" }), "gestures", 500)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(world.successor, false, "the in-flight allocation must still own admission")
			helpers.assert_eq(world.Shortcut.busy(), false)
			helpers.assert_nil(next(world.files), "the late temporary file must be removed")
			helpers.assert_eq(#world.spawned, 0, "a cancelled run must not start a library query")
		end)
	end)

	helpers.it("removes a temporary input written during a reentrant pause", function()
		with_world(function(world)
			world.selection = "private text"
			world.before_temp_write_return = function() world.listeners.run_apple_shortcut("gestures") end
			world.Shortcut.run(shortcut({ input = "selection" }), "gestures", 500)
			helpers.assert_nil(next(world.files), "the file must remain owned until the write returns")
			helpers.assert_eq(world.Shortcut.busy(), false)
			helpers.assert_eq(#world.spawned, 0)
		end)
	end)

	helpers.it("retains a failed cleanup and retries it before admitting another run", function()
		with_world(function(world)
			world.before_temp_return = function()
				world.refuse_remove = true
				world.listeners.run_apple_shortcut("gestures")
			end
			helpers.assert_eq(world.Shortcut.run(shortcut({ output = "copy" }), "gestures", 500), false)
			helpers.assert_eq(world.Shortcut.busy(), true)
			helpers.assert_eq(world.Shortcut.run(shortcut(), "shortcut_bindings", 500), false)
			helpers.assert_eq(#world.spawned, 0)
			world.refuse_remove = false
			world.before_temp_return = nil
			helpers.assert_eq(world.Shortcut.run(shortcut(), "shortcut_bindings", 500), true)
			helpers.assert_nil(next(world.files))
		end)
	end)
end)
