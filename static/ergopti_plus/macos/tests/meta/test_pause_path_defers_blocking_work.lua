--- tests/meta/test_pause_path_defers_blocking_work.lua

--- ==============================================================================
--- MODULE: Pause/Resume Blocking-Work Guard Meta Test
--- DESCRIPTION:
--- pause_all() and resume_all() run SYNCHRONOUSLY inside the script-control
--- eventtap callback: handle_key -> dispatch_action -> pause_all/resume_all. Any
--- blocking work there stalls the tap, and macOS answers a slow tap by disabling
--- it (kCGEventTapDisabledByTimeout) — which kills AltGr+Enter itself, so the user
--- can no longer un-pause and must reload Hammerspoon by hand.
---
--- ROOT CAUSE ENCODED:
--- karabiner.pause() encodes and writes a 100 kB+ karabiner.json through
--- Generator.deploy_string (plus a /bin/mkdir subprocess on its fallback path), and
--- karabiner.resume() calls regenerate(), which rebuilds the FULL Ergopti config —
--- heavier still. Both were invoked inline from these two functions.
---
--- The project already knew the hazard AT THIS EXACT CALL SITE: ui/menu/init.lua's
--- on_pause_change listener defers its layout switch with the comment "this
--- callback runs synchronously inside the script-control eventtap callback, and the
--- switch spawns blocking osascript subprocesses that would otherwise stall the tap
--- long enough for macOS to disable it (killing AltGr+Enter)". The karabiner
--- redeploy — larger than the layout switch — was the forgotten sibling.
---
--- WHY A SOURCE GUARD:
--- The stall itself cannot be reproduced in the harness — there is no real event
--- tap and no real subprocess, so nothing can actually time out. The harness CAN
--- observe the deferral (tests/stubs/hs.lua records timers and fires them on
--- __fire_all, which is why the quiescence test in test_script_control.lua now
--- flushes), but observing that a call happened eventually does not distinguish
--- deferred from inline. What distinguishes them, and what the bug actually was, is
--- whether the call is lexically wrapped in a deferral. This test asserts that for
--- every known blocking-capable subsystem call in both functions, so a future
--- inline call fails CI rather than shipping a tap that dies on the next pause.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Subsystem calls made from pause_all/resume_all that reach file I/O, a subprocess
-- or a full config regeneration, and must therefore never run inline in the tap.
local MUST_BE_DEFERRED = {
	"_karabiner.pause()",
	"_karabiner.resume()",
}

-- The deferral wrapper the driver uses everywhere for this purpose.
local DEFER_TOKEN = "hs.timer.doAfter(0,"





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
	helpers.it("every blocking subsystem call in pause_all/resume_all is deferred", function()
		local path = helpers.driver_root() .. "modules/shortcuts/script_control.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "script_control.lua must be readable at " .. path)
		if not fh then return end
		local src = fh:read("*a")
		fh:close()

		-- The premise: these really are reached from the tap callback.
		helpers.assert_true(src:find("local function handle_key", 1, true) ~= nil,
			"handle_key must exist — it is the eventtap callback this guard is about")
		helpers.assert_true(src:find("pause_all()", 1, true) ~= nil,
			"dispatch_action must call pause_all — if it stops doing so this guard needs rewriting")

		for _, decl in ipairs({ "local function pause_all()", "local function resume_all()" }) do
			local slice = function_slice(src, decl)
			helpers.assert_true(slice ~= nil, decl .. " must be locatable")

			for _, call in ipairs(MUST_BE_DEFERRED) do
				local at = slice:find(call, 1, true)
				if at then
					-- Look backwards a short way for the deferral wrapper: the call must
					-- sit inside an hs.timer.doAfter(0, ...) rather than run inline.
					local window_start = math.max(1, at - 200)
					local window = slice:sub(window_start, at)
					helpers.assert_true(window:find(DEFER_TOKEN, 1, true) ~= nil, string.format(
						"%s calls %s inline. pause_all/resume_all run synchronously inside the "
						.. "script-control eventtap callback, and this call writes a 100 kB+ "
						.. "karabiner.json (resume additionally regenerates the full config). "
						.. "Blocking the tap lets macOS disable it, killing AltGr+Enter so the "
						.. "user cannot un-pause. Wrap it in %s ... ) like the layout switch is.",
						decl, call, DEFER_TOKEN))
				end
			end
		end
	end)
end)
