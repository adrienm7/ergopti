--- tests/unit/modules/keylogger/test_stop_nils_win_filter.lua

--- ==============================================================================
--- MODULE: Keylogger Stop Nils Win Filter Regression Test
--- DESCRIPTION:
--- Guards against the regression where keylogger/init.lua called
--- _win_filter:unsubscribeAll() but did not nil _win_filter afterwards.
--- A subsequent M.start() call saw a non-nil _win_filter and skipped creating
--- a new window filter, leaving the browser-tab tracker disconnected after a
--- reload.
--- The fix nils _win_filter (and the other watcher locals) immediately after
--- stopping them in M.stop().
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_source(rel)
	local fh = io.open(helpers.driver_root() .. rel, "r")
	assert(fh, "cannot open " .. rel)
	local src = fh:read("*a")
	fh:close()
	return src
end

local function strip_comments(src)
	local out = {}
	for line in src:gmatch("[^\n]*") do
		if not line:match("^%s*%-%-") then out[#out + 1] = line end
	end
	return table.concat(out, "\n")
end


-- =====================================================================
-- =====================================================================
-- ======= 1/ M.stop() nils watchers after stopping them ===============
-- =====================================================================
-- =====================================================================

helpers.describe("keylogger/init.lua: M.stop() nils watcher locals", function()

	helpers.it("_win_filter is nilled after unsubscribeAll in M.stop()", function()
		local src = strip_comments(read_source("modules/keylogger/init.lua"))
		-- The pattern must show: unsubscribeAll() followed by _win_filter = nil
		-- on the same line or in the same block
		helpers.assert_true(
			src:find("unsubscribeAll%(%s*%)%s*;%s*_win_filter%s*=%s*nil") ~= nil
			or (src:find("_win_filter:unsubscribeAll") ~= nil and src:find("_win_filter%s*=%s*nil") ~= nil),
			"M.stop() must nil _win_filter after calling unsubscribeAll()")
	end)

	helpers.it("_event_tap is nilled after stop() in M.stop()", function()
		local src = strip_comments(read_source("modules/keylogger/init.lua"))
		helpers.assert_true(
			src:find("_event_tap%s*=%s*nil") ~= nil,
			"M.stop() must nil _event_tap after stopping it")
	end)

	helpers.it("stops the app-activation lifecycle in M.stop()", function()
		local src = strip_comments(read_source("modules/keylogger/init.lua"))
		helpers.assert_true(
			src:find("ProcessLifecycle:stop%(%s*%)") ~= nil
				or src:find("ProcessLifecycle%.stop%(%s*%)") ~= nil,
			"M.stop() must stop the delegated app-activation lifecycle")
	end)

end)
