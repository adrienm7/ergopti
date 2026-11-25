--- tests/unit/modules/keymap/test_kde_layout_watch.lua

--- ==============================================================================
--- MODULE: KDE Active Layout Watch
--- DESCRIPTION:
--- KWin switches the active layout without sending a new keymap, so the daemon
--- kept typing on the layout it resolved at start (field report of 2026-11-25:
--- a↔q and m↔, swapped after a switch to AZERTY). The watch calls its owner on
--- each layout signal of the KDE keyboard daemon, ignores every other line,
--- and stops for good on a failure (kde-layout-watch).
--- ==============================================================================

local helpers = require("tests.helpers")
local Watch = require("modules.keymap.kde_layout_watch")

--- A scripted gdbus monitor child.
local function fake_child()
	local child = { killed = false, closed = 0 }
	local function handle()
		local h = { closing = false }
		function h:is_closing() return self.closing end
		function h:close() self.closing = true; child.closed = child.closed + 1 end
		return h
	end
	child.stdout, child.process = handle(), handle()
	function child.stdout:read_start(callback) child.feed = callback end
	function child.stdout:read_stop() end
	function child.process:kill(signal) child.killed = signal end
	return child
end

helpers.describe("kde layout watch (kde-layout-watch)", function()
	helpers.it("calls back on each layout signal, split across reads (kde-layout-watch)", function()
		local child, exit = fake_child(), nil
		local owner = Watch.new({ spawn = function(on_exit) exit = on_exit; return child end })
		local calls = 0
		helpers.assert_true(owner.start(function() calls = calls + 1 end))
		helpers.assert_eq(owner.status(), "watching")
		child.feed(nil, "/Layouts: org.kde.KeyboardLayouts.layoutCha")
		helpers.assert_eq(calls, 0, "half a line is not a signal")
		child.feed(nil, "nged (uint32 1,)\n/Layouts: org.kde.KeyboardLayouts.layoutListChanged ()\n")
		helpers.assert_eq(calls, 2, "a switch and a list change both resolve again")
		child.feed(nil, "/Layouts: org.kde.KeyboardLayouts.longNameChanged ('x',)\n")
		helpers.assert_eq(calls, 2, "another signal is ignored")
		owner.shutdown()
		helpers.assert_eq(child.killed, "sigterm", "the monitor child is ended with the watch")
		helpers.assert_eq(child.closed, 2, "both handles are closed")
		exit(0, 15)
		helpers.assert_eq(owner.status(), "stopped")
	end)

	helpers.it("stops for the session when the child ends (kde-layout-watch)", function()
		local child, exit = fake_child(), nil
		local owner = Watch.new({ spawn = function(on_exit) exit = on_exit; return child end })
		local calls = 0
		owner.start(function() calls = calls + 1 end)
		exit(1, 0)
		helpers.assert_eq(owner.status(), "stopped")
		helpers.assert_eq(child.closed, 2)
		helpers.assert_true(not pcall(owner.start, function() end), "a second start is a programming error")
	end)

	helpers.it("reports a monitor that cannot start (kde-layout-watch)", function()
		local owner = Watch.new({ spawn = function() return nil, "ENOENT" end })
		helpers.assert_eq(owner.start(function() end), false)
		helpers.assert_eq(owner.status(), "stopped")
	end)

	helpers.it("probes gdbus before the production spawn (kde-layout-watch-probe)", function()
		-- A minimal Arch, Fedora or openSUSE image has no GLib tools: the
		-- watch names the missing gdbus instead of spawning it blind.
		local ShellRunner = require("core.process.adapters.shell_runner")
		local uv = require("luv")
		local real_has, real_spawn = ShellRunner.has_command, uv.spawn
		local probed, spawned = nil, false
		ShellRunner.has_command = function(binary) probed = binary; return false end
		uv.spawn = function() spawned = true; return nil, "unexpected" end
		Watch._reset_for_test()
		local ok, started = pcall(Watch.start, function() end)
		local status = Watch.status()
		Watch._reset_for_test()
		ShellRunner.has_command, uv.spawn = real_has, real_spawn
		helpers.assert_true(ok, tostring(started))
		helpers.assert_eq(started, false)
		helpers.assert_eq(status, "stopped")
		helpers.assert_eq(probed, "gdbus")
		helpers.assert_true(not spawned, "gdbus was spawned without a probe")
	end)
end)
