--- tests/meta/test_audit_v6_fixes.lua

--- ==============================================================================
--- MODULE: Audit V6 Regression Guards
--- DESCRIPTION:
--- Static-source regression guards for the three bugs identified in
--- RAPPORT_AUDIT_EXPERT_V6.md (macOS/Hammerspoon side):
---
---   Bug 1 — modules/keymap/init.lua: the synthetic-backspace guard decremented
---     `expected_synthetic_deletes` for ANY Backspace event, including human
---     ones. If the user pressed Backspace while an expansion was in flight, the
---     counter was consumed by the wrong event and the buffer entry was skipped,
---     leaving the buffer desynced from the screen. Fix: check
---     eventSourceUnixProcessID == hs.processInfo.processID before decrementing.
---
---   Bug 2 — modules/keymap/utils.lua + expander.lua + init.lua: paste
---     expansions (Cmd+V path) returned the full pasted text as `emitted_str`,
---     causing expected_synthetic_chars to be populated with text that Cmd+V
---     never echoes back as individual keystrokes. Subsequent real keystrokes
---     matching the expansion prefix were silently absorbed. Fix: return empty
---     emitted_str on paste; signal the pending Cmd+V echo via a dedicated
---     `expected_synthetic_pastes` counter instead.
---
---   Bug 3 — modules/keymap/utils.lua: clipboard save/restore used
---     `getContents()`/`setContents()` which silently drops non-text clipboard
---     data (images, RTF, files). Fix: use `readAllData()`/`writeAllData()` to
---     preserve all UTI types.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

local function func_body(src, func_def)
	local idx = src:find(func_def, 1, true)
	if not idx then return "" end
	local rest = src:sub(idx)
	local _, stop = rest:find("\nend\n")
	if stop then return rest:sub(1, stop) end
	return rest
end





-- ==============================================================================
-- ==============================================================================
-- ======= 1/ keymap/init.lua - backspace guard checks source PID (Bug 1) =======
-- ==============================================================================
-- ==============================================================================

helpers.describe("modules/keymap/init.lua: synthetic-backspace guard checks source PID (audit-v6-bug1)", function()

	helpers.it("guard uses eventSourceUnixProcessID before decrementing deletes counter", function()
		local src = read_source("local function invalidate_observed_context") -- modules/keymap/init.lua
		helpers.assert_true(
			src:find("eventSourceUnixProcessID", 1, true) ~= nil,
			"init.lua must check eventSourceUnixProcessID to distinguish human vs synthetic Backspace")
	end)

	helpers.it("guard uses hs.processInfo.processID for PID comparison", function()
		local src = read_source("local function invalidate_observed_context") -- modules/keymap/init.lua
		helpers.assert_true(
			src:find("hs.processInfo.processID", 1, true) ~= nil,
			"init.lua must compare source PID against hs.processInfo.processID")
	end)

	helpers.it("old unconditional decrement pattern is gone", function()
		local src = read_source("local function invalidate_observed_context") -- modules/keymap/init.lua
		-- The old code decremented immediately on any Backspace; it must now be
		-- nested inside a source-PID check (the decrement is not at column 2).
		-- We verify by checking the line structure: no tabs+decrement without a
		-- surrounding if/then block that involves processID.
		local plain_decrement = src:find(
			"expected_synthetic_deletes = CoreState.expected_synthetic_deletes - 1\n\t\treturn false\n\tend",
			1, true)
		helpers.assert_true(plain_decrement == nil,
			"init.lua must not decrement expected_synthetic_deletes without a PID check")
	end)

end)





-- ===============================================================================
-- ===============================================================================
-- ======= 2/ keymap: paste uses expected_synthetic_pastes counter (Bug 2) =======
-- ===============================================================================
-- ===============================================================================

helpers.describe("modules/keymap/utils.lua: paste path uses paste counter, not expected_synthetic_chars (audit-v6-bug2)", function()

	helpers.it("utils.lua exposes take_paste_ops()", function()
		local src = read_source("local function invalidate_ignored_win_cache") -- modules/keymap/utils.lua
		helpers.assert_true(
			src:find("function M.take_paste_ops()", 1, true) ~= nil,
			"utils.lua must expose M.take_paste_ops() for expander to read pending paste count")
	end)

	helpers.it("emit_text paste path increments _paste_ops_pending", function()
		local src = read_source("local function invalidate_ignored_win_cache") -- modules/keymap/utils.lua
		local body = func_body(src, "function M.emit_text(")
		helpers.assert_true(
			body:find("_paste_ops_pending", 1, true) ~= nil,
			"M.emit_text() paste path must increment _paste_ops_pending")
	end)

	helpers.it("emit_text paste path returns empty emitted_str", function()
		local src = read_source("local function invalidate_ignored_win_cache") -- modules/keymap/utils.lua
		local body = func_body(src, "function M.emit_text(")
		-- Must return "", not the text, for the paste path
		helpers.assert_true(
			body:find('return (ok_l and l or 1), ""', 1, true) ~= nil,
			"M.emit_text() paste path must return (count, \"\") to keep expected_synthetic_chars clean")
	end)

	helpers.it("expander.lua calls take_paste_ops after emit_action", function()
		local src = read_source("function M.try_terminator_expand") -- modules/keymap/expander.lua
		helpers.assert_true(
			src:find("take_paste_ops", 1, true) ~= nil,
			"expander.lua must call km_utils.take_paste_ops() to consume the paste counter")
	end)

	helpers.it("expander.lua updates expected_synthetic_pastes from paste ops", function()
		local src = read_source("function M.try_terminator_expand") -- modules/keymap/expander.lua
		helpers.assert_true(
			src:find("expected_synthetic_pastes", 1, true) ~= nil,
			"expander.lua must update _state.expected_synthetic_pastes when paste ops > 0")
	end)

	helpers.it("init.lua checks expected_synthetic_pastes for Cmd+V echo", function()
		local src = read_source("local function invalidate_observed_context") -- modules/keymap/init.lua
		helpers.assert_true(
			src:find("expected_synthetic_pastes", 1, true) ~= nil,
			"init.lua must check expected_synthetic_pastes to swallow Cmd+V echo without wiping buffer")
	end)

	helpers.it("state.lua initialises expected_synthetic_pastes to 0", function()
		local src = read_source("local DEFAULT_SUPPRESS_KEEP_SEC") -- modules/keymap/state.lua
		helpers.assert_true(
			src:find("expected_synthetic_pastes", 1, true) ~= nil,
			"state.lua must declare expected_synthetic_pastes = 0 in the initial state table")
	end)

end)





-- =============================================================================
-- =============================================================================
-- ======= 3/ keymap/utils.lua - clipboard uses readAllData/writeAllData =======
-- =============================================================================
-- =============================================================================

helpers.describe("modules/keymap/utils.lua: clipboard preserves non-text data (audit-v6-bug3)", function()

	helpers.it("clipboard save uses readAllData() instead of getContents()", function()
		local src = read_source("local function invalidate_ignored_win_cache") -- modules/keymap/utils.lua
		helpers.assert_true(
			src:find("hs.pasteboard.readAllData()", 1, true) ~= nil,
			"utils.lua must use readAllData() to save clipboard (preserves images / RTF / files)")
	end)

	helpers.it("clipboard restore uses writeAllData() instead of setContents()", function()
		local src = read_source("local function invalidate_ignored_win_cache") -- modules/keymap/utils.lua
		helpers.assert_true(
			src:find("hs.pasteboard.writeAllData", 1, true) ~= nil,
			"utils.lua must use writeAllData() to restore clipboard (preserves images / RTF / files)")
	end)

	helpers.it("old getContents() pattern is gone from the paste save paths", function()
		local src = read_source("local function invalidate_ignored_win_cache") -- modules/keymap/utils.lua
		-- getContents may still exist in comments; guard is that the actual
		-- clipboard-save assignment uses readAllData, not getContents.
		-- Verify neither paste path assigns from getContents().
		local assignment = src:find("_paste_saved_original = hs.pasteboard.getContents()", 1, true)
		helpers.assert_true(assignment == nil,
			"utils.lua must not assign _paste_saved_original from getContents() — use readAllData()")
	end)

	helpers.it("old setContents() is no longer used in paste restore timers", function()
		local src = read_source("local function invalidate_ignored_win_cache") -- modules/keymap/utils.lua
		-- setContents is still allowed as a fallback for empty clipboard, but the
		-- primary restore path must use writeAllData.
		-- The guard: writeAllData must appear inside a doAfter callback.
		local timer_body_idx = src:find("hs.timer.doAfter", 1, true)
		helpers.assert_true(timer_body_idx ~= nil,
			"utils.lua must still have a doAfter clipboard restore timer")
		local after_timer = src:sub(timer_body_idx)
		helpers.assert_true(
			after_timer:find("writeAllData", 1, true) ~= nil,
			"the doAfter restore timer must use writeAllData() as the primary restore path")
	end)

end)
