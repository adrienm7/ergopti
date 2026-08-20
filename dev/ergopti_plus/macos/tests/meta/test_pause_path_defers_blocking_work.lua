--- tests/meta/test_pause_path_defers_blocking_work.lua

--- ==============================================================================
--- MODULE: Pause/Resume Blocking-Work Guard Meta Test
--- DESCRIPTION:
--- The script-control shortcut originates in an eventtap. Native pause/resume
--- work must be scheduled after that callback returns; a stalled tap is disabled
--- by macOS and strands the only keyboard path that can leave pause.
---
--- ROOT CAUSE ENCODED:
--- The ACK-transaction refactor moved Karabiner calls out of pause_all/resume_all.
--- This guard forbids them from moving back and pins the deferred handoff in
--- request_pause_transition. Behavioral ordering is covered separately by
--- test_pause_transaction.lua, so this source guard cannot pass merely because a
--- scheduler token exists somewhere unrelated.
--- ==============================================================================

local helpers = require("tests.helpers")

local NATIVE_MODULE_TOKEN = "_karabiner"
local DEFER_TOKEN = "pcall(hs.timer.doAfter, 0,"





-- ================================================
-- ================================================
-- ======= 1/ Both Functions Defer The Work =======
-- ================================================
-- ================================================

--- Returns the source slice of one local function, bounded by the next top-level
--- declaration so the search cannot leak into a neighbouring function's body.
--- @param src string Full file contents.
--- @param decl string Exact declaration text.
--- @return string|nil The slice.
local function function_slice(src, decl)
	local start_pos = src:find(decl, 1, true)
	if not start_pos then return nil end
	local from = start_pos + #decl
	local next_fn    = src:find("\nlocal function ", from, true)
	local next_pub   = src:find("\nfunction ", from, true)
	local stop = math.min(next_fn or #src, next_pub or #src)
	return src:sub(start_pos, stop)
end

helpers.describe("pause/resume never do blocking work inline in the eventtap callback", function()
	helpers.it("native transition is absent from submodule commit and explicitly deferred", function()
		-- Selected by a declaration unique to script_control.lua rather than by
		-- path: the invariant is about that function pair, not about where the
		-- file currently lives.
		local src = helpers.read_driver_source("local function pause_all()")
		helpers.assert_true(src ~= nil, "the pause_all/resume_all source must be locatable")
		if not src then return end

		-- The premise: the shortcut callback reaches the transaction request.
		helpers.assert_true(src:find("local function handle_key", 1, true) ~= nil,
			"handle_key must exist — it is the eventtap callback this guard is about")
		helpers.assert_true(src:find("request_pause_transition(target_paused)", 1, true) ~= nil,
			"the shortcut dispatcher must route through the ACK transaction")

		for _, decl in ipairs({ "local function pause_all()", "local function resume_all()" }) do
			local slice = function_slice(src, decl)
			helpers.assert_true(slice ~= nil, decl .. " must be locatable")
			helpers.assert_true(slice:find(NATIVE_MODULE_TOKEN, 1, true) == nil,
				decl .. " must commit Hammerspoon state only, never call Karabiner inline")
		end

		local schedule_at = src:find(DEFER_TOKEN, 1, true)
		local dispatch_at = schedule_at and src:find(
			"dispatch_native_pause_transition(transaction)", schedule_at + #DEFER_TOKEN, true) or nil
		helpers.assert_true(schedule_at ~= nil and dispatch_at ~= nil and schedule_at < dispatch_at,
			"the native controller handoff must remain inside the zero-delay timer")
	end)
end)
