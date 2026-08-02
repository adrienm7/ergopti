--- tests/unit/modules/keylogger/test_midnight_rotation_invariants.lua

--- ==============================================================================
--- MODULE: Regression — midnight rotation does not reset in-flight state (C3)
--- DESCRIPTION:
--- perform_maintenance() in keylogger/init.lua fires once per second via the
--- maintenance timer. When it detects a date change it runs the midnight rotation:
---
---   LogManager.flush_buffer()
---   LogManager.day_rollover()
---   CoreState.today_idx     = {}
---   CoreState.ngram_context = nil
---   _current_day = today
---
--- Two invariants must hold:
---
--- INVARIANT 1 — ORDER: flush_buffer() MUST precede day_rollover(). Reversing the
--- order drains today.log before the in-memory buffer is written, losing the last
--- batch of keystrokes from the just-ended day (data loss, unrecoverable).
---
--- INVARIANT 2 — SCOPE: the rotation must NOT reset synth_queue, is_enabled,
--- is_paused, or the tap / watchdog references. Wiping synth_queue mid-rotation
--- desynchronises the two synthetic-event trackers (keymap + keylogger) and can
--- produce phantom or missing text. Touching enabled/paused state during a
--- background maintenance tick violates G1 (no unhandled state transitions).
---
--- These pins are structural (source-text); loading the full 1500-line module is
--- not feasible in the unit harness, and the patterns encode the root cause.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("keylogger: midnight rotation invariants (C3)", function()
	local function read_src()
		-- perform_maintenance() was extracted from keylogger/init.lua into the
		-- self-contained keylogger/watchers.lua. Concatenate both so the body
		-- introspection survives that move (move-resilient). The shared state is
		-- the injected CoreState, named _state inside watchers.lua.
		-- Takes a selector unique to one production file rather than that file's
		-- path, so moving or splitting a module cannot turn these invariants into
		-- path errors.
		local function read_one(selector)
			local s = helpers.read_driver_source(selector)
			return s
		end
		return read_one("local function ensure_browser_window_filter") -- modules/keylogger/init.lua
			.. "\n" .. read_one("local function poll_mouse_distance") -- modules/keylogger/watchers.lua
	end

	local function extract_maintenance(src)
		-- Extract the body of perform_maintenance() by finding its definition
		-- and taking the next ~3000 chars (the function grew past ~15 lines
		-- once the drain-success gate was added — see F-HIGH-2). After the
		-- watchers extraction it is exposed as M.perform_maintenance; accept
		-- both the old local form and the public form (move-resilient).
		local fn_start = src:find("local function perform_maintenance()", 1, true)
			or src:find("function M.perform_maintenance()", 1, true)
		helpers.assert_true(fn_start ~= nil, "perform_maintenance() must exist in keylogger init/watchers")
		return src:sub(fn_start, fn_start + 3000)
	end


	-- ===== Invariant 1: flush_buffer precedes day_rollover =====

	helpers.it("flush_buffer() is called BEFORE day_rollover() during rotation", function()
		local src = read_src()
		local body = extract_maintenance(src)
		local flush_pos    = body:find("flush_buffer()", 1, true)
		local rollover_pos = body:find("day_rollover()", 1, true)
		helpers.assert_true(flush_pos ~= nil,
			"perform_maintenance() must call LogManager.flush_buffer()")
		helpers.assert_true(rollover_pos ~= nil,
			"perform_maintenance() must call LogManager.day_rollover()")
		helpers.assert_true(flush_pos < rollover_pos,
			"flush_buffer() must precede day_rollover(): reversing the order "
			.. "drains today.log before the in-memory buffer is written — permanent data loss")
	end)


	-- ===== Invariant 2: only today_idx + ngram_context are reset =====

	helpers.it("rotation resets the shared today_idx to {}", function()
		local src = read_src()
		local body = extract_maintenance(src)
		-- The shared state is CoreState in init.lua; it is the injected _state
		-- inside watchers.lua. Accept either name (same table, move-resilient).
		helpers.assert_true(
			body:find("CoreState%.today_idx%s*=%s*{}", 1, false) ~= nil
			or body:find("_state%.today_idx%s*=%s*{}", 1, false) ~= nil,
			"perform_maintenance() must reset <state>.today_idx = {} on date change")
	end)

	helpers.it("rotation resets the shared ngram_context to nil", function()
		local src = read_src()
		local body = extract_maintenance(src)
		helpers.assert_true(
			body:find("CoreState%.ngram_context%s*=%s*nil", 1, false) ~= nil
			or body:find("_state%.ngram_context%s*=%s*nil", 1, false) ~= nil,
			"perform_maintenance() must reset <state>.ngram_context = nil on date change")
	end)

	helpers.it("rotation does NOT wipe CoreState.synth_queue", function()
		local src = read_src()
		local body = extract_maintenance(src)
		-- Any assignment to synth_queue inside perform_maintenance would desync the
		-- dual synthetic-event trackers (keymap expected_synthetic_* + keylogger synth_queue)
		helpers.assert_true(
			body:find("synth_queue", 1, true) == nil,
			"perform_maintenance() must not touch CoreState.synth_queue — wiping it mid-rotation "
			.. "desynchronises the two synthetic-event trackers and can corrupt injected text")
	end)

	helpers.it("rotation does NOT modify CoreState.is_enabled or is_paused", function()
		local src = read_src()
		local body = extract_maintenance(src)
		helpers.assert_true(
			body:find("is_enabled", 1, true) == nil,
			"perform_maintenance() must not assign CoreState.is_enabled — "
			.. "changing enabled state from a background maintenance tick violates G1")
		-- Note: is_paused is READ at the top via _is_paused() to early-return;
		-- that read is correct. The test here bans ASSIGNMENT inside the function body.
		local assign_paused = body:find("is_paused%s*=", 1, false)
		helpers.assert_true(assign_paused == nil,
			"perform_maintenance() must not assign is_paused — "
			.. "changing pause state from a maintenance tick violates G1")
	end)

	helpers.it("rotation does NOT stop or restart _event_tap", function()
		local src = read_src()
		local body = extract_maintenance(src)
		helpers.assert_true(
			body:find("_event_tap", 1, true) == nil,
			"perform_maintenance() must not touch _event_tap — "
			.. "stopping or restarting the tap from a maintenance timer loses keystrokes (G2)")
	end)
end)
