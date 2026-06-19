--- tests/unit/modules/karabiner/test_layout_rebuild_timer.lua

--- ==============================================================================
--- MODULE: Layout Rebuild Timer Regression Test
--- DESCRIPTION:
--- Guards against the regression where karabiner/init.lua created an
--- hs.timer.doAfter(0.5, ...) inside the input-source watcher callback but
--- discarded the returned timer object. Rapid layout changes (e.g. the
--- pause-layout feature switching layouts twice in quick succession) would
--- pile up multiple concurrent rebuild timers, generating duplicate
--- M.regenerate() calls and redundant KE config deploys.
---
--- The fix stores the timer in _layout_rebuild_timer, cancels any pending
--- rebuild before arming a new one, and nils it in M.stop().
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
-- ======= 1/ Layout rebuild timer is stored and cancellable ===========
-- =====================================================================
-- =====================================================================

helpers.describe("karabiner/init.lua: layout rebuild timer stored and cancellable", function()

	helpers.it("_layout_rebuild_timer module-level variable is declared", function()
		local src = read_source("modules/karabiner/init.lua")
		helpers.assert_true(
			src:find("_layout_rebuild_timer", 1, true) ~= nil,
			"init.lua must declare _layout_rebuild_timer to cancel pending rebuilds")
	end)

	helpers.it("doAfter result is assigned to _layout_rebuild_timer", function()
		local src = strip_comments(read_source("modules/karabiner/init.lua"))
		helpers.assert_true(
			src:find("_layout_rebuild_timer%s*=%s*hs%.timer%.doAfter") ~= nil,
			"the rebuild doAfter return value must be stored in _layout_rebuild_timer")
	end)

	helpers.it("pending rebuild is cancelled before arming a new one", function()
		local src = strip_comments(read_source("modules/karabiner/init.lua"))
		-- The cancellation block must precede the doAfter call
		local cancel_pos = src:find("_layout_rebuild_timer:stop()", 1, true)
		local arm_pos    = src:find("_layout_rebuild_timer%s*=%s*hs%.timer%.doAfter")
		helpers.assert_true(cancel_pos ~= nil and arm_pos ~= nil,
			"init.lua must cancel the pending timer before arming a new rebuild")
		helpers.assert_true(cancel_pos < arm_pos,
			"timer cancellation must appear before the doAfter arm call")
	end)

	helpers.it("M.stop() cancels the pending rebuild timer", function()
		local src = strip_comments(read_source("modules/karabiner/init.lua"))
		-- M.stop() must have a _layout_rebuild_timer:stop() call inside it
		-- We check that the :stop() call appears after the function M.stop() declaration
		local stop_fn_pos  = src:find("function M.stop()", 1, true)
		local stop_tmr_pos = src:find("_layout_rebuild_timer:stop()", stop_fn_pos or 1, true)
		helpers.assert_true(stop_fn_pos ~= nil and stop_tmr_pos ~= nil,
			"M.stop() must cancel _layout_rebuild_timer to prevent stale rebuild after module teardown")
	end)

end)
