--- tests/unit/modules/shortcuts/text_actions/test_clipboard_state_hygiene.lua

--- ==============================================================================
--- MODULE: Regression — clipboard/selection state must not be reused once stale
--- DESCRIPTION:
--- Two defects that both destroy user data by acting on a snapshot that has since
--- been invalidated.
---
--- ROOT CAUSE 1 — do_transform had no re-entrancy guard.
--- The transform pipeline owns the clipboard for roughly half a second: copy,
--- transform, paste, re-select, restore. A second press inside that window
--- snapshotted a clipboard the first run had ALREADY overwritten with its own
--- intermediate value, then "restored" that at the end — silently destroying
--- whatever the user actually had copied. Two quick presses of a case-toggle
--- shortcut is entirely ordinary input.
---
--- ROOT CAUSE 2 — the wrap-text AX cache outlived the selection it described.
--- wrap_selection REPLACES the selection it is given, so the cached value is stale
--- the moment a wrap fires. Inside the 200 ms TTL the next wrap key re-wrapped text
--- that was no longer selected: the keystroke was swallowed and the previous
--- selection duplicated.
---
--- The consumed-marker deliberately writes a fresh NEGATIVE rather than clearing
--- the validity flag: clearing would re-pay both cross-process AX calls on every
--- subsequent wrap key and undo the negative-caching fix this file received in the
--- same audit. That interaction is the whole reason this is easy to get wrong.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==============================================
-- ==============================================
-- ======= 1/ Transform Is Not Re-entrant =======
-- ==============================================
-- ==============================================

helpers.describe("a second text transform cannot start while one owns the clipboard", function()
	helpers.it("guards the pipeline with an in-flight flag", function()
		-- The unique declaration selects the owner even if its source file moves.
		local src = helpers.read_driver_source("local function do_transform(")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"modules/shortcuts/actions/text.lua source must be locatable")
		if type(src) ~= "string" or src == "" then return end

		local declaration = "local function do_transform("
		local following = "\nfunction M.paste_as_plain_text("
		local first = src:find(declaration, 1, true)
		local last = src:find(following, 1, true)
		helpers.assert_true(first ~= nil and src:find(declaration, first + #declaration, true) == nil,
			"the transform declaration must be unique and locatable")
		helpers.assert_true(last ~= nil and src:find(following, last + #following, true) == nil,
			"the following public declaration must be unique and locatable")
		if not first or not last then return end
		local header_end = src:find("\n", first, true)
		helpers.assert_true(header_end ~= nil and first < header_end and header_end < last,
			"the transform body must have valid nonempty bounds")
		if not header_end or header_end >= last then return end
		local body = ("\n" .. src:sub(header_end + 1, last - 1)):gsub("\n[ \t]*%-%-[^\n]*", "")
		helpers.assert_true(body:find("%S") ~= nil, "the transform body must be nonempty")

		helpers.assert_true(body:find("_transform_in_flight", 1, true) ~= nil,
			"do_transform must refuse re-entry: a second press inside the ~0.5 s window "
			.. "snapshots a clipboard the first run already overwrote and restores that "
			.. "intermediate value as if it were the user's own")

		local guard_at = body:find("if _transform_in_flight then", 1, true)
		local copy_at = body:find("capture_text_clipboard(owner, false)", 1, true)
		helpers.assert_true(guard_at ~= nil and copy_at ~= nil,
			"both the guard and the clipboard snapshot must be locatable")
		helpers.assert_true(guard_at ~= nil and copy_at ~= nil and guard_at < copy_at,
			"the guard must run BEFORE the clipboard is snapshotted — after it, the "
			.. "damage is already done")
	end)

	helpers.it("arms a failsafe release so the flag cannot stick", function()
		-- Selected by a declaration unique to modules/shortcuts/actions/text.lua rather than by path.
		local src = helpers.read_driver_source("local function load_shared_groups")
		helpers.assert_true(src ~= nil, "modules/shortcuts/actions/text.lua source must be locatable")
		if not src then return end

		helpers.assert_true(src:find("TRANSFORM_LOCK_TIMEOUT_SEC") ~= nil,
			"the in-flight flag needs a hard timeout — api_mlx's warmup flag carries one "
			.. "for exactly this reason: a stuck flag blocks every later transform for "
			.. "the whole session, which is worse than the race it prevents")
	end)
end)





-- ================================================
-- ================================================
-- ======= 2/ A Consumed Selection Is Stale =======
-- ================================================
-- ================================================

helpers.describe("the wrap-text cache is invalidated once the selection is consumed", function()
	helpers.it("marks the cached selection consumed after wrapping", function()
		-- Selected by a declaration unique to modules/shortcuts/actions/system.lua rather than by path.
		local src = helpers.read_driver_source("local function close_awake_alert")
		helpers.assert_true(src ~= nil, "modules/shortcuts/actions/system.lua source must be locatable")
		if not src then return end

		helpers.assert_true(src:find("mark_wrap_selection_consumed") ~= nil,
			"wrap_selection replaces the selection it was given, so the cached copy is "
			.. "stale immediately. Reusing it inside the TTL re-wraps text that is no "
			.. "longer selected: the keystroke is swallowed and the previous selection "
			.. "duplicated")

		local wrap_at = src:find("pcall%(%s*text_acts%.wrap_selection")
		local success_at = src:find("wrapped_or_err%s*~=%s*true", wrap_at or 1)
		local mark_at = src:find("mark_wrap_selection_consumed%(%)", success_at or 1)
		helpers.assert_true(wrap_at ~= nil and success_at ~= nil and mark_at ~= nil
			and wrap_at < success_at and success_at < mark_at,
			"the cache must be marked consumed only AFTER wrap_selection confirms output")
	end)

	helpers.it("keeps the entry valid as a negative rather than clearing it", function()
		-- Selected by a declaration unique to modules/shortcuts/actions/system.lua rather than by path.
		local src = helpers.read_driver_source("local function close_awake_alert")
		helpers.assert_true(src ~= nil, "modules/shortcuts/actions/system.lua source must be locatable")
		if not src then return end

		local at = src:find("local function mark_wrap_selection_consumed")
		helpers.assert_true(at ~= nil, "the marker must be locatable")
		local body = src:sub(at, at + 400)

		helpers.assert_true(body:find("_wrap_ax_selection_valid%s*=%s*true") ~= nil,
			"the entry must stay VALID as a fresh negative. Clearing the validity flag "
			.. "would re-pay both cross-process AX calls on every subsequent wrap key, "
			.. "undoing the negative-caching fix and putting that cost back on the "
			.. "CGEventTap thread")
	end)
end)
