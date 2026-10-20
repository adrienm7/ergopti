--- tests/unit/adapters/synthetic_input/test_clipboard_write_deadline.lua

--- ==============================================================================
--- MODULE: Clipboard Write Deadlines
--- DESCRIPTION:
--- Runs genuine shell commands against private clipboard executables. A stalled
--- display must refuse writes without losing exact stdin or acknowledging an
--- outstanding restoration. These are process tests, not desktop GUI tests.
--- ==============================================================================

local helpers = require("tests.helpers")
local uv, Shell = require("luv"), require("adapters.shell_runner")
-- Complete native constructors before replacing the session-specific ports.
require("adapters.clipboard")

local function read(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local text = assert(file:read("*a")); assert(file:close())
	return text
end

local function write(path, text)
	local file = assert(io.open(path, "wb")); assert(file:write(text)); assert(file:close())
end

--- Keeps controlled backend processes local without replacing the shell owner.
--- @param route string Desktop clipboard executable.
--- @param body function Receives clipboard and the private process state.
local function with_backend(route, body)
	local names = { "adapters.clipboard", "adapters.shell_runner", "infra.display_server" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local root = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-clipboard-bound-XXXXXX"))
	local state = { commands = {}, root = root }
	local command = route == "wl-copy" and "wl-copy"
		or route == "xclip" and "xclip -selection clipboard -in" or "xsel --clipboard --input"
	local okay, detail = xpcall(function()
		write(root .. "/current", "saved")
		write(root .. "/" .. route, "#!/bin/sh\nset -eu\ncat > " .. Shell.quote(root .. "/stdin")
			.. "\nif [ -f " .. Shell.quote(root .. "/delayed") .. " ]; then sleep 2; fi\n"
			.. "cat " .. Shell.quote(root .. "/stdin") .. " > " .. Shell.quote(root .. "/current")
			.. "\nprintf done > " .. Shell.quote(root .. "/completed") .. "\n")
		assert(Shell.run("chmod 700 " .. Shell.quote(root .. "/" .. route)))
		package.loaded["adapters.shell_runner"] = {
			has_command = function(name)
				return name == route or (route == "wl-copy" and name == "wl-paste")
			end,
			exec_checked = function() return true, assert(read(root .. "/current")) end,
			with_exact_stdin = function(selected, text)
				state.commands[#state.commands + 1] = selected
				return Shell.with_exact_stdin(selected, text)
			end,
			run = function(selected)
				-- Only this child gets the private backend, never the process environment.
				return Shell.run("env PATH=" .. Shell.quote(root .. ":" .. assert(os.getenv("PATH")))
					.. " sh -c " .. Shell.quote(selected))
			end,
		}
		package.loaded["infra.display_server"] = {
			is_wayland = function() return route == "wl-copy" end,
			is_x11 = function() return route ~= "wl-copy" end,
		}
		package.loaded["adapters.clipboard"] = nil
		state.expected = "timeout 1 " .. command
		state.delay = function(enabled)
			if enabled then write(root .. "/delayed", "yes") else os.remove(root .. "/delayed") end
		end
		state.current = function() return read(root .. "/current") end
		state.input = function() return read(root .. "/stdin") end
		body(require("adapters.clipboard"), state)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	local cleaned = Shell.run("rm -rf " .. Shell.quote(root))
	if not okay then error(detail, 0) end
	assert(cleaned, "private clipboard process files must be removed")
end

helpers.describe("bounded clipboard backend writes", function()
	for _, route in ipairs({ "wl-copy", "xclip", "xsel" }) do
		helpers.it("preserves exact stdin and successful " .. route .. " acknowledgement", function()
			with_backend(route, function(clipboard, state)
				local text = "emoji 🌿\n' $HOME $(false) `false`\n\n"
				helpers.assert_eq(clipboard.write(text), true)
				helpers.assert_eq(state.input(), text)
				helpers.assert_eq(state.current(), text)
				helpers.assert_eq(state.commands, { state.expected }, "the deadline wraps the backend before stdin framing")
			end)
		end)
		helpers.it("refuses a stalled " .. route .. " setter without publishing success", function()
			with_backend(route, function(clipboard, state)
				state.delay(true)
				helpers.assert_eq(clipboard.write("replacement\n\n"), false, "an expired backend cannot acknowledge a write")
				helpers.assert_eq(state.input(), "replacement\n\n")
				helpers.assert_eq(state.current(), "saved")
				helpers.assert_nil(read(state.root .. "/completed"))
			end)
		end)
		helpers.it("keeps " .. route .. " restoration debt until a later write succeeds", function()
			with_backend(route, function(clipboard, state)
				local stage = clipboard.new_paste_stage("replacement", function() return true end, 47)
				helpers.assert_eq(stage.prepare(), true)
				state.delay(true)
				helpers.assert_eq(stage.close(), false, "a timed-out restoration is not a retirement receipt")
				helpers.assert_eq(state.current(), "replacement")
				state.delay(false)
				helpers.assert_eq(stage.close(), true)
				helpers.assert_eq(state.current(), "saved", "retry must retain the original saved bytes")
				helpers.assert_eq(#state.commands, 3)
			end)
		end)
		helpers.it("retires a refused " .. route .. " preparation only after its restore succeeds", function()
			with_backend(route, function(clipboard, state)
				state.delay(true)
				local stage = clipboard.new_paste_stage("replacement", function() return true end, 47)
				helpers.assert_eq(stage.prepare(), false)
				helpers.assert_eq(state.commands, { state.expected, state.expected }, "the failed setter still needs compensation")
				state.delay(false)
				helpers.assert_eq(stage.close(), true)
				helpers.assert_eq(state.current(), "saved")
				helpers.assert_eq(#state.commands, 3)
			end)
		end)
	end
end)
