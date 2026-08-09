--- tests/unit/platform/remap/test_layout_rebuild_timer.lua

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
--- rebuild before arming a new one, invalidates its callback at shutdown intent,
--- and nils it only after the exact Karabiner fence settles.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
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
		local src = read_source("local KARABINER_KE_TILDE_PATH") -- platform/remap/init.lua
		helpers.assert_true(
			src:find("_layout_rebuild_timer", 1, true) ~= nil,
			"init.lua must declare _layout_rebuild_timer to cancel pending rebuilds")
	end)

	helpers.it("doAfter result is retained as the current timer", function()
		local src = strip_comments(read_source("local KARABINER_KE_TILDE_PATH"))
		helpers.assert_true(
			src:find("_layout_rebuild_timer%s*=%s*timer_or_err") ~= nil,
			"the validated doAfter return value must be stored in _layout_rebuild_timer")
	end)

	helpers.it("pending rebuild is cancelled before arming a new one", function()
		local src = strip_comments(read_source("local KARABINER_KE_TILDE_PATH"))
		-- Scope the ordering check to the layout helper: another guarded timer
		-- intentionally exists earlier for the deferred F17 bindings.
		local helper_pos = src:find("local function schedule_layout_refresh", 1, true)
		local cancel_pos = helper_pos and src:find("_layout_rebuild_timer:stop()", helper_pos, true)
		local arm_pos    = helper_pos and src:find("pcall%(hs%.timer%.doAfter", helper_pos)
		local retain_pos = helper_pos and src:find("_layout_rebuild_timer%s*=%s*timer_or_err", helper_pos)
		helpers.assert_true(cancel_pos ~= nil and arm_pos ~= nil and retain_pos ~= nil,
			"init.lua must cancel the pending timer before arming a new rebuild")
		helpers.assert_true(cancel_pos < arm_pos and arm_pos < retain_pos,
			"timer cancellation must appear before the doAfter arm call")
	end)

	helpers.it("a cancelled queued callback cannot erase its replacement", function()
		local src = strip_comments(read_source("local KARABINER_KE_TILDE_PATH"))
		helpers.assert_true(
			src:find("if _layout_rebuild_timer ~= timer then return end", 1, true) ~= nil,
			"the callback must prove exact retained-handle ownership before clearing state")
	end)

	helpers.it("the fenced local teardown cancels the pending rebuild timer", function()
		local src = strip_comments(read_source("local KARABINER_KE_TILDE_PATH"))
		local local_stop_pos = src:find("local function stop_local_resources()", 1, true)
		local stop_tmr_pos = src:find("_layout_rebuild_timer:stop()", local_stop_pos or 1, true)
		local public_stop_pos = src:find("function M.stop()", stop_tmr_pos or 1, true)
		local shutdown_call_pos = public_stop_pos
			and src:find('return M.shutdown("hammerspoon_stop")', public_stop_pos, true)
		helpers.assert_true(local_stop_pos ~= nil and stop_tmr_pos ~= nil
			and public_stop_pos ~= nil and shutdown_call_pos ~= nil,
			"public stop must reach the timer cancellation only through the exact fenced teardown")
		helpers.assert_true(local_stop_pos < stop_tmr_pos and stop_tmr_pos < public_stop_pos,
			"the pending timer must be released by stop_local_resources after the fence")
	end)

end)
