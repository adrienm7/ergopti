--- tests/unit/modules/keylogger/test_synth_queue_context_clear.lua

--- ==============================================================================
--- MODULE: Regression — synth_queue cleared on context change (F-LOW-1 / C6)
--- DESCRIPTION:
--- When a synthetic expansion's echoes are suppressed by the secure-field /
--- private-window / disabled-app guards (which return before consuming the
--- synth_queue), the queued entries persist. If the user returns to a normal field
--- and types within SYNTH_IDLE_DRAIN_MS (500 ms), the stale head mis-tags the first
--- real keystroke as synthetic. The only recovery was the time-based idle drain.
---
--- Fix: clear CoreState.synth_queue on the context changes that suppress input —
--- secure-field entry (update_secure_field_state) and app activation
--- (app_watcher_cb) — so the C6 case is deterministically safe, not drain-timed.
--- context_tracker's _state is module-local, so the two clears are pinned at source.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("context_tracker: synth_queue cleared on context change (F-LOW-1)", function()
	local function read_src()
		local path = helpers.driver_root() .. "modules/keylogger/context_tracker.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "cannot open context_tracker.lua at " .. tostring(path))
		local src = fh:read("*a"); fh:close()
		return src
	end

	helpers.it("clears synth_queue on secure-field entry (right after the buffer clears)", function()
		local src = read_src()
		local rc_pos = src:find("_state.rich_chunks   = {}", 1, true)
		helpers.assert_true(rc_pos ~= nil, "secure-field buffer clear must exist")
		local sq_pos = src:find("_state.synth_queue", rc_pos, true)
		helpers.assert_true(sq_pos ~= nil and (sq_pos - rc_pos) < 500,
			"the secure-field branch must clear _state.synth_queue right after the buffers")
	end)

	helpers.it("clears synth_queue on app activation (context boundary)", function()
		local src = read_src()
		-- Anchor on the active_app_name ASSIGNMENT (not the earlier `if` check); the
		-- clear sits just before it.
		local assign_pos = src:find("_state%.active_app_name%s*=%s*app_name")
		helpers.assert_true(assign_pos ~= nil, "app_watcher_cb must assign active_app_name = app_name")
		local window = src:sub(math.max(1, assign_pos - 400), assign_pos)
		helpers.assert_true(window:find("_state.synth_queue", 1, true) ~= nil,
			"app activation must clear _state.synth_queue just before updating the active app")
	end)

	helpers.it("has at least two synth_queue clears (both context paths)", function()
		local src = read_src()
		local n = 0
		for _ in src:gmatch("_state%.synth_queue%s*=%s*{}") do n = n + 1 end
		helpers.assert_true(n >= 2, "expected synth_queue cleared on both secure-field entry and app activation, found " .. n)
	end)
end)
