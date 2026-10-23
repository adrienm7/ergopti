--- tests/unit/adapters/atspi/test_x11_focus.lua

--- ==============================================================================
--- MODULE: X11 Focus Query Tests
--- DESCRIPTION:
--- The focused-window identity is read from the X server in this process
--- instead of forking xdotool twice per poll (eight forks a second at idle).
--- The protocol logic is driven here through a scripted transport; the libxcb
--- transport itself is checked against a real X server by
--- tests/hardware/run_x11_focus_receipt.lua. The window_info cases pin that the
--- native route spawns nothing and that transport trouble degrades to xdotool.
--- ==============================================================================

local helpers = require("tests.helpers")

local ATOM_STRING, ATOM_WM_NAME = 31, 39

--- A scripted transport over a table of windows.
--- @param state table { active = id|nil, windows = { [id] = { title, wm_name, pid, wm_name_type } }, ... }
--- @return table transport
local function scripted(state)
	local atoms = { _NET_ACTIVE_WINDOW = 301, _NET_WM_NAME = 302, UTF8_STRING = 303, _NET_WM_PID = 304 }
	state.connects, state.interns, state.disconnects = 0, 0, 0
	local function le32(value)
		return string.char(value % 256, math.floor(value / 256) % 256,
			math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
	end
	return {
		connect = function()
			state.connects = state.connects + 1
			if state.refuse then return false, "no server" end
			return true
		end,
		disconnect = function() state.disconnects = state.disconnects + 1 end,
		healthy = function() return not state.broken end,
		root = function() return 1 end,
		intern = function(name) state.interns = state.interns + 1; return atoms[name] end,
		property = function(window, property)
			if window == 1 and property == atoms._NET_ACTIVE_WINDOW then
				if not state.active then return nil end
				return { type = 33, format = 32, bytes = le32(state.active) }
			end
			local entry = state.windows[window]
			if not entry then return nil end
			if property == atoms._NET_WM_NAME and entry.title then
				return { type = atoms.UTF8_STRING, format = 8, bytes = entry.title }
			elseif property == atoms._NET_WM_NAME then
				return { type = 0, format = 0, bytes = "" }
			elseif property == ATOM_WM_NAME and entry.wm_name then
				return { type = entry.wm_name_type or ATOM_STRING, format = 8, bytes = entry.wm_name }
			elseif property == atoms._NET_WM_PID and entry.pid then
				return { type = 6, format = 32, bytes = le32(entry.pid) }
			end
			return nil
		end,
	}
end

--- Loads a fresh module bound to a scripted transport.
--- @param state table
--- @return table focus
local function bound(state)
	local focus = helpers.load_module("adapters.x11_focus")
	focus._set_transport(scripted(state))
	return focus
end

helpers.describe("x11_focus: what the server is asked and how it is read", function()
	helpers.it("reads the active window, its UTF-8 title and its owner", function()
		local state = { active = 77, windows = { [77] = { title = "Brouillon \195\169t\195\169", pid = 4242 } } }
		local id, title, pid, reason = bound(state).query()
		helpers.assert_eq(id, "77", "decimal, as xdotool prints it")
		helpers.assert_eq(title, "Brouillon \195\169t\195\169")
		helpers.assert_eq(pid, "4242")
		helpers.assert_nil(reason)
	end)

	helpers.it("falls back to WM_NAME and converts its Latin-1 bytes to UTF-8", function()
		local state = { active = 5, windows = { [5] = { wm_name = "caf\233" } } }
		local _, title, pid = bound(state).query()
		helpers.assert_eq(title, "caf\195\169")
		helpers.assert_nil(pid, "a window that states no owner has none")
	end)

	helpers.it("keeps only the first line of a title", function()
		local state = { active = 5, windows = { [5] = { title = "first\nsecond" } } }
		helpers.assert_eq(select(2, bound(state).query()), "first")
	end)

	helpers.it("answers nothing, without a reason, for no window or an untitled one", function()
		local focus = bound({ active = nil, windows = {} })
		helpers.assert_nil(focus.query())
		local untitled = bound({ active = 9, windows = { [9] = { pid = 1 } } })
		local id, _, _, reason = untitled.query()
		helpers.assert_nil(id)
		helpers.assert_nil(reason, "an untitled window is an answer, not a transport failure")
	end)

	helpers.it("interns each atom once per connection", function()
		local state = { active = 5, windows = { [5] = { title = "t", pid = 1 } } }
		local focus = bound(state)
		focus.query()
		local after_first = state.interns
		focus.query(); focus.query()
		helpers.assert_eq(state.interns, after_first, "polls after the first intern nothing")
	end)
end)

helpers.describe("x11_focus: connection lifecycle", function()
	helpers.it("reports a refused connection as a reason and retries only after the delay", function()
		local state = { active = 5, windows = { [5] = { title = "t" } }, refuse = true }
		local focus = bound(state)
		focus.RECONNECT_MS = 60000
		local id, _, _, reason = focus.query()
		helpers.assert_nil(id)
		helpers.assert_contains(reason, "no server")
		helpers.assert_eq(state.connects, 1)
		local _, _, _, again = focus.query()
		helpers.assert_contains(again, "retry pending")
		helpers.assert_eq(state.connects, 1, "no second attempt inside the delay")
		focus.RECONNECT_MS = 0
		state.refuse = false
		helpers.assert_eq(focus.query(), "5", "a later attempt connects")
		helpers.assert_eq(state.connects, 2)
	end)

	helpers.it("drops a broken connection and reconnects on the next query", function()
		local state = { active = 5, windows = { [5] = { title = "t" } } }
		local focus = bound(state)
		focus.RECONNECT_MS = 0
		helpers.assert_eq(focus.query(), "5")
		state.broken = true
		-- The broken connection is closed and reopened inside the same query.
		helpers.assert_eq(focus.query(), "5")
		helpers.assert_true(state.disconnects >= 1, "the broken connection was closed")
		helpers.assert_true(state.connects >= 2, "and opened again")
	end)

	helpers.it("answers with a reason when no transport is bound", function()
		local focus = helpers.load_module("adapters.x11_focus")
		local _, _, _, reason = focus.query()
		helpers.assert_contains(reason, "no X transport")
	end)
end)

helpers.describe("window_info: the native X11 route", function()
	--- window_info on X11 with a scripted transport and a recording shell.
	local function under(state, shell_answers)
		local display = helpers.load_module("infra.display_server")
		display._set_for_test(display.X11, "x11 focus fixture")
		package.loaded["infra.display_server"] = display
		local shell = helpers.load_module("adapters.shell_runner")
		local commands = {}
		shell._set_runner(function(command)
			commands[#commands + 1] = command
			for pattern, answer in pairs(shell_answers or {}) do
				if command:find(pattern, 1, true) then return answer end
			end
			return ""
		end)
		local focus = helpers.load_module("adapters.x11_focus")
		focus._set_transport(scripted(state))
		package.loaded["adapters.x11_focus"] = focus
		local window = helpers.load_module("adapters.window_info")
		window._reset_state()
		return window, commands, shell
	end

	helpers.it("spawns nothing to poll an unchanged window", function()
		local state = { active = 12, windows = { [12] = { title = "Notes", pid = 1337 } } }
		local window, commands, shell = under(state, { ["/proc/1337/comm"] = "editor\n" })
		local info, identity = window.focused_snapshot()
		helpers.assert_eq(info.appId, "editor")
		helpers.assert_eq(info.windowTitle, "Notes")
		helpers.assert_eq(identity, "x11:1337:12")
		local after_first = #commands
		for _ = 1, 20 do window.focused_snapshot() end
		helpers.assert_eq(#commands, after_first, "twenty polls of the same window spawned " .. (#commands - after_first))
		shell._reset_runner()
	end)

	helpers.it("never starts xdotool while the server answers", function()
		local state = { active = 12, windows = { [12] = { title = "Notes", pid = 1337 } } }
		local window, commands, shell = under(state, { ["/proc/1337/comm"] = "editor\n" })
		window.focused_snapshot()
		for _, command in ipairs(commands) do
			helpers.assert_true(not command:find("xdotool", 1, true), "unexpected: " .. command)
		end
		shell._reset_runner()
	end)

	helpers.it("treats no window as no answer without asking xdotool", function()
		local state = { active = nil, windows = {} }
		local window, commands, shell = under(state)
		local info = window.focused_snapshot()
		helpers.assert_eq(info.appId, "")
		helpers.assert_eq(#commands, 0)
		shell._reset_runner()
	end)

	helpers.it("degrades to xdotool when the server cannot be reached", function()
		local state = { active = 12, windows = {}, refuse = true }
		local window, commands, shell = under(state, {
			["xdotool getactivewindow"] = "0x5\n", ["xdotool getwindowname"] = "Fallback\n",
			["xdotool getwindowpid"] = "77\n", ["/proc/77/comm"] = "term\n" })
		local info = window.focused_snapshot()
		helpers.assert_eq(info.windowTitle, "Fallback")
		helpers.assert_eq(info.appId, "term")
		local asked = false
		for _, command in ipairs(commands) do if command:find("xdotool getactivewindow", 1, true) then asked = true end end
		helpers.assert_true(asked, "the tools were asked when the server was unreachable")
		shell._reset_runner()
	end)
end)
