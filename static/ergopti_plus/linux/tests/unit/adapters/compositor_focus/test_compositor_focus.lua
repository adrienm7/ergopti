--- tests/unit/adapters/compositor_focus/test_compositor_focus.lua

--- ==============================================================================
--- MODULE: Compositor focus source (GNOME Shell extension, KWin script)
--- DESCRIPTION:
--- The daemon side of the pushed focus: worker lines in, snapshot out, with a
--- fake resident process. Every unknown is asserted as a stated outcome: before
--- readiness, after a clear, a malformed line or the worker's exit, the answer
--- is nil and never the previous window. Then the join through window_info:
--- the four-times-a-second poll reads the source without running a command.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A fake OwnedProcess.start keeping the output and exit callbacks.
--- @return function start, table process
local function fake_process()
	local process = { cancelled = 0, settled = false }
	local function start(executable, arguments, options, callback)
		process.executable, process.arguments, process.options = executable, arguments, options
		process.exit = callback
		local operation = { started = true }
		function operation:is_running() return not process.settled end
		function operation:is_settled() return process.settled end
		function operation:cancel()
			process.cancelled = process.cancelled + 1
			process.settled = true
			return true
		end
		process.operation = operation
		return operation
	end
	function process.say(text) process.options.on_output(text, "stdout") end
	return start, process
end

local function new_source(family)
	local Focus = helpers.load_module("adapters.compositor_focus")
	local start, process = fake_process()
	local source = Focus.new({
		family = family or "gnome", start_process = start,
		command = function() return "/usr/bin/luajit", { "worker" }, "/driver" end,
	})
	return source, process
end

local FOCUS = '{"kind":"focus","class":"org.gnome.Nautilus","title":"Documents","pid":4242,"id":"17"}\n'




-- =================================
-- =================================
-- ======= 1/ Admission ============
-- =================================
-- =================================

helpers.describe("compositor_focus: admission", function()
	helpers.it("(wayland-desktop-focus) names GNOME and KDE from XDG_CURRENT_DESKTOP only", function()
		local Focus = helpers.load_module("adapters.compositor_focus")
		helpers.assert_eq(Focus.desktop_family("ubuntu:GNOME"), "gnome")
		helpers.assert_eq(Focus.desktop_family("KDE"), "kde")
		helpers.assert_eq(Focus.desktop_family("COSMIC"), nil)
		helpers.assert_eq(Focus.desktop_family("gnome-flashback:gnome-classic"), nil,
			"a token that only contains gnome is another session")
		helpers.assert_eq(Focus.desktop_family(""), nil)
	end)

	helpers.it("(wayland-desktop-focus) the worker admits a bounded report and refuses the rest", function()
		local Worker = helpers.load_module("adapters.compositor_focus_worker")
		helpers.assert_eq(Worker.activation_record("kitty", "nvim", "2468", "{a1-b2}"),
			{ kind = "focus", class = "kitty", title = "nvim", pid = 2468, id = "{a1-b2}" })
		helpers.assert_eq(Worker.activation_record("kitty", "nvim", "", "9").pid, nil)
		for _, case in ipairs({
			{ "kitty", "nvim", "0", "9" }, { "kitty", "nvim", "-1", "9" }, { "kitty", "nvim", "12x", "9" },
			{ "kitty", "nvim", "99999999999", "9" }, { "kitty", "nvim", "1", "" },
			{ "kitty", "nvim", "1", "a b" }, { "kitty", string.rep("t", 2049), "1", "9" },
			{ "kitty\0", "nvim", "1", "9" },
		}) do
			helpers.assert_eq(Worker.activation_record(case[1], case[2], case[3], case[4]), nil,
				"refused: " .. table.concat(case, "|"))
		end
	end)
end)




-- =================================
-- =================================
-- ======= 2/ Source ===============
-- =================================
-- =================================

helpers.describe("compositor_focus: source", function()
	helpers.it("(wayland-desktop-focus) answers only after readiness and from the last report", function()
		local source, process = new_source("gnome")
		helpers.assert_true(source.start())
		helpers.assert_eq(process.arguments, { "worker" })
		helpers.assert_eq(source.snapshot(), nil, "unknown before the worker owns its name")
		process.say('{"kind":"ready"}\n')
		helpers.assert_eq(source.snapshot(), nil, "unknown until the desktop reports")
		-- A line split across chunks is one record.
		process.say(FOCUS:sub(1, 20))
		helpers.assert_eq(source.snapshot(), nil)
		process.say(FOCUS:sub(21))
		helpers.assert_eq(source.snapshot(), { class = "org.gnome.Nautilus", title = "Documents", pid = 4242, id = "17" })
		process.say('{"kind":"clear"}\n')
		helpers.assert_eq(source.snapshot(), nil, "a cleared focus is unknown, not the last window")
	end)

	for _, case in ipairs({
		{ "a report before readiness", FOCUS },
		{ "a malformed line", '{"kind":"ready"}\nnot json\n' },
		{ "an unknown kind", '{"kind":"ready"}\n{"kind":"guess"}\n' },
		{ "a zero process id", '{"kind":"ready"}\n{"kind":"focus","class":"a","title":"b","pid":0,"id":"1"}\n' },
		{ "a second readiness", '{"kind":"ready"}\n{"kind":"ready"}\n' },
		{ "an unbounded line", '{"kind":"ready"}\n' .. string.rep("x", 9000) },
	}) do
		helpers.it("(wayland-desktop-focus) fails closed on " .. case[1], function()
			local source, process = new_source("kde")
			source.start()
			process.say(case[2])
			process.say('{"kind":"ready"}\n' .. FOCUS)
			helpers.assert_eq(source.snapshot(), nil)
			helpers.assert_eq(process.cancelled, 1, "the worker that misspoke is stopped")
			helpers.assert_true(source.is_active(), "the failed source still owns the answer: unknown")
		end)
	end

	helpers.it("(wayland-desktop-focus) the worker's exit forgets the focus", function()
		local source, process = new_source("gnome")
		source.start()
		process.say('{"kind":"ready"}\n' .. FOCUS)
		helpers.assert_true(source.snapshot() ~= nil)
		process.exit({ stderr = "bus name org.ergopti.Focus already owned\n" })
		helpers.assert_eq(source.snapshot(), nil)
	end)

	helpers.it("(wayland-desktop-focus) a refused dispatch is unknown, and start is single-use", function()
		local Focus = helpers.load_module("adapters.compositor_focus")
		local source = Focus.new({ family = "gnome", command = function() return "x", {}, "/" end,
			start_process = function() return { started = false } end })
		helpers.assert_eq(source.start(), false)
		helpers.assert_eq(source.snapshot(), nil)
		helpers.assert_eq(pcall(source.start), false, "a second start is refused")
	end)

	helpers.it("(wayland-desktop-focus) stop cancels the worker and ignores its late lines", function()
		local source, process = new_source("gnome")
		source.start()
		process.say('{"kind":"ready"}\n')
		helpers.assert_true(source.stop())
		helpers.assert_eq(process.cancelled, 1)
		process.say(FOCUS)
		helpers.assert_eq(source.snapshot(), nil)
		helpers.assert_eq(source.is_active(), false)
	end)
end)





-- ==================================
-- ==================================
-- ======= 3/ WindowInfo join =======
-- ==================================
-- ==================================

--- Loads window_info under a Wayland desktop with a shell that records commands.
local function wayland_window_info(desktop)
	local display = helpers.load_module("infra.display_server")
	display._set_for_test(display.WAYLAND, desktop)
	package.loaded["infra.display_server"] = display
	local shell = helpers.load_module("adapters.shell_runner")
	local commands = {}
	shell._set_runner(function(command)
		commands[#commands + 1] = command
		if command:find("command -v", 1, true) then return false end
		return ""
	end)
	local window_info = helpers.load_module("adapters.window_info")
	window_info._reset_state()
	return window_info, commands, function()
		window_info._reset_state()
		shell._reset_runner()
	end
end

helpers.describe("compositor_focus: window_info join", function()
	helpers.it("(wayland-desktop-focus) GNOME answers the poll from memory, without a command", function()
		local window_info, commands, restore = wayland_window_info("ubuntu:GNOME")
		local start, process = fake_process()
		local ok, failure = pcall(function()
			helpers.assert_true(window_info.start_compositor_focus({ start_process = start,
				command = function() return "luajit", {}, "/" end }))
			helpers.assert_eq(window_info.getFocused().appId, "", "unknown before the first report")
			process.say('{"kind":"ready"}\n' .. FOCUS)
			for _ = 1, 4 do
				helpers.assert_eq(window_info.getFocused(),
					{ appId = "org.gnome.Nautilus", windowTitle = "Documents", bundleId = "", executablePath = "" })
			end
			local info, identity, pid = window_info.focused_process_snapshot()
			helpers.assert_eq(info.windowTitle, "Documents")
			helpers.assert_eq(identity, "gnome:4242:17")
			helpers.assert_eq(pid, 4242)
			helpers.assert_eq(commands, {}, "the focus poll may not fork: no sway, hyprctl, niri or lswt probe either")
		end)
		restore()
		helpers.assert_true(ok, tostring(failure))
	end)

	helpers.it("(wayland-desktop-focus) KWin without a class is named by its process, read in-process", function()
		local window_info, commands, restore = wayland_window_info("KDE")
		local start, process = fake_process()
		local ok, failure = pcall(function()
			window_info._set_proc_comm_reader_for_test(function(pid) return pid == 77 and "konsole" or "" end)
			window_info.start_compositor_focus({ start_process = start, command = function() return "luajit", {}, "/" end })
			process.say('{"kind":"ready"}\n{"kind":"focus","class":"","title":"~","pid":77,"id":"{u-1}"}\n')
			helpers.assert_eq(window_info.getFocused().appId, "konsole")
			helpers.assert_eq(window_info.focused_identity(), "kwin:77:{u-1}")
			helpers.assert_eq(commands, {})
		end)
		restore()
		helpers.assert_true(ok, tostring(failure))
	end)

	helpers.it("(wayland-desktop-focus) a failed source stays unknown and does not fall through", function()
		local window_info, commands, restore = wayland_window_info("GNOME")
		local start, process = fake_process()
		local ok, failure = pcall(function()
			window_info.start_compositor_focus({ start_process = start, command = function() return "luajit", {}, "/" end })
			process.say('{"kind":"ready"}\n' .. FOCUS)
			process.exit({})
			helpers.assert_eq(window_info.getFocused().appId, "")
			helpers.assert_eq(window_info.focused_process_snapshot().appId, "")
			helpers.assert_eq(commands, {})
		end)
		restore()
		helpers.assert_true(ok, tostring(failure))
	end)

	for _, case in ipairs({ { "x11", "GNOME" }, { "wayland", "COSMIC" }, { "wayland", "sway" } }) do
		helpers.it("(wayland-desktop-focus) starts nothing on " .. case[1] .. " " .. case[2], function()
			local display = helpers.load_module("infra.display_server")
			display._set_for_test(case[1], case[2])
			package.loaded["infra.display_server"] = display
			local window_info = helpers.load_module("adapters.window_info")
			window_info._reset_state()
			local started = false
			local result = window_info.start_compositor_focus({ start_process = function() started = true end })
			window_info._reset_state()
			helpers.assert_eq(result, false)
			helpers.assert_eq(started, false)
		end)
	end
end)
