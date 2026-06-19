--- tests/unit/modules/karabiner/test_layout_poll_async.lua

--- ==============================================================================
--- MODULE: Regression — layout fallback poll reads asynchronously (F-LOW-4)
--- DESCRIPTION:
--- The Sequoia fallback poll (doEvery LAYOUT_POLL_SEC) called
--- read_current_layout_from_hitoolbox() — a SYNCHRONOUS `defaults read` subprocess
--- on the Hammerspoon main run loop — every 2 s for the whole session. It is not
--- inside an eventtap (so no kCGEventTapDisabledByTimeout), but it is exactly the
--- steady-state main-loop cost the boot/hot-path profiler work aims to eliminate,
--- and it runs forever on the very Sequoia machines the poll exists for.
---
--- Fix: the poll now reads via read_layout_async -> ShellRunner.spawn (off the main
--- loop), guarded by _layout_poll_pending so concurrent ticks cannot pile up. The
--- synchronous read stays only on the infrequent seed + notification paths.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("karabiner.watchers: layout fallback poll is async (F-LOW-4)", function()
	local function read_src()
		local path = helpers.driver_root() .. "modules/karabiner/watchers.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "cannot open watchers.lua at " .. tostring(path))
		local src = fh:read("*a"); fh:close()
		return src
	end

	helpers.it("the poll calls the async read, not the synchronous one", function()
		local src = read_src()
		helpers.assert_true(src:find("read_layout_async(function(current)", 1, true) ~= nil,
			"the doEvery poll must read via read_layout_async (off the main loop)")
		helpers.assert_true(src:find("_layout_poll_pending", 1, true) ~= nil,
			"the poll must guard against piling up concurrent async reads")
		helpers.assert_true(src:find("local current = read_current_layout_from_hitoolbox()", 1, true) == nil,
			"the poll must NOT call the synchronous read_current_layout_from_hitoolbox() any more")
	end)

	helpers.it("read_layout_async uses the ShellRunner adapter (not a synchronous hs.execute)", function()
		local src = read_src()
		local fn = src:match("local function read_layout_async.-\nend")
		helpers.assert_true(fn ~= nil, "read_layout_async must exist")
		helpers.assert_true(fn:find("ShellRunner.spawn", 1, true) ~= nil,
			"read_layout_async must spawn the read via the ShellRunner adapter")
		helpers.assert_true(fn:find("hs.execute", 1, true) == nil,
			"read_layout_async must not use a synchronous hs.execute")
	end)
end)
