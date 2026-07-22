--- tests/unit/modules/keylogger/test_notify_synthetic_disabled_guard.lua

--- ==============================================================================
--- MODULE: Regression — notify_synthetic gated + synth_queue cleared on enable (F-MED-3)
--- DESCRIPTION:
--- expander.perform_text_replacement calls keylogger.notify_synthetic on EVERY
--- expansion, unconditionally. notify_synthetic had no is_enabled guard, so with
--- the keylogger OFF (a supported opt-in default) every hotstring expansion still
--- pushed into CoreState.synth_queue / recent_typing_eff — and because handle_key
--- returns at its own is_enabled guard, the SYNTH_IDLE_DRAIN self-heal never ran,
--- so the queue grew unbounded. When the user later enabled the keylogger, M.start
--- did NOT clear synth_queue, so the first real keystrokes were matched against the
--- stale head and mis-tagged synthetic (dropped from WPM/n-grams) until a >500 ms gap.
---
--- Fix: gate notify_synthetic on CoreState.is_enabled (like sibling log_hotstring /
--- log_llm), and clear the synthetic state in M.start. CoreState is a module local
--- (not exposed), so the root cause is pinned at source level: the guard must
--- precede the first synth_queue insert, and M.start must reset synth_queue.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("keylogger: notify_synthetic gated on is_enabled + start clears the queue (F-MED-3)", function()
	local function read_src()
		local path = helpers.driver_root() .. "modules/keylogger/init.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "cannot open keylogger/init.lua at " .. tostring(path))
		local src = fh:read("*a"); fh:close()
		return src
	end

	helpers.it("notify_synthetic bails on is_enabled BEFORE touching synth_queue", function()
		local src = read_src()
		local body = src:match("function M.notify_synthetic.-\nend")
		helpers.assert_true(body ~= nil, "notify_synthetic body must be locatable")
		local guard_pos  = body:find("if not CoreState.is_enabled then return end", 1, true)
		local insert_pos = body:find("table.insert(CoreState.synth_queue", 1, true)
		helpers.assert_true(guard_pos ~= nil, "notify_synthetic must guard on `not CoreState.is_enabled`")
		helpers.assert_true(insert_pos ~= nil, "notify_synthetic still inserts into synth_queue")
		helpers.assert_true(guard_pos < insert_pos, "the is_enabled guard must precede the first synth_queue insert")
	end)

	helpers.it("M.start clears synth_queue right after enabling", function()
		local src = read_src()
		local enable_pos = src:find("CoreState.is_enabled%s*=%s*true")
		helpers.assert_true(enable_pos ~= nil, "M.start must set CoreState.is_enabled = true")
		local region = src:sub(enable_pos, enable_pos + 600)
		helpers.assert_true(region:find("CoreState.synth_queue%s*=%s*{}") ~= nil,
			"M.start must reset CoreState.synth_queue right after enabling (so a stale queue cannot poison the first keystrokes)")
	end)
end)
