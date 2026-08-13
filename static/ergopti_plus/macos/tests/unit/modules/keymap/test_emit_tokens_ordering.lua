--- tests/unit/modules/keymap/test_emit_tokens_ordering.lua

--- ==============================================================================
--- MODULE: Regression — emit_tokens must preserve token ORDER, not just serialise pastes
--- DESCRIPTION:
--- Visible output corruption: a multi-segment replacement landed scrambled.
---
--- ROOT CAUSE ENCODED:
--- F-HIGH-1 fixed the clipboard race by deferring the SECOND and later
--- paste-worthy segments behind a settle gap (test_emit_tokens_multi_paste.lua
--- pins that, and it stays true). But `key` tokens and short `text` tokens reach
--- the OS SYNCHRONOUSLY — keyStroke/keyStrokes, no timer. So once a paste had been
--- deferred, every later non-paste token overtook it:
---
---   tokens: [ long-text-A ] [ long-text-B ] [ key Return ]
---   emitted: A (inline)     B (+gap)        Return (inline, BEFORE B)
---
--- The user saw the Return land in the middle of the replacement instead of at its
--- end. The deferral fixed WHICH clipboard content each paste sees; it did not fix
--- the ORDER the segments arrive in.
---
--- The fix keeps every emission on one cursor: only paste-worthy tokens advance
--- it, but all three kinds are chained behind it.
---
--- The test drives the real emit_tokens with a captured hs.timer.doAfter and
--- asserts the RELATIVE ORDER of the emissions, which is the property that broke —
--- not merely that a deferral happened.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Longer than PASTE_THRESHOLD (50) so should_paste() routes it to the clipboard.
local LONG_A = string.rep("a", 80)
local LONG_B = string.rep("b", 80)





-- =============================================
-- =============================================
-- ======= 1/ Emission Recorder Harness ========
-- =============================================
-- =============================================

--- Loads keymap.utils with every emission path recorded in a single ordered log,
--- and with doAfter capturing its callbacks so they can be fired deliberately.
--- @return table utils, table log, function fire_pending, table clipboard
local function load_utils()
	local emissions = {}
	local pending   = {}
	local clipboard = { clears = 0 }

	package.loaded["modules.keymap.utils"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["adapters.synthetic_input"] = {
		current_transaction = function() return nil end,
		emit_key_stroke = function(_mods, key)
			emissions[#emissions + 1] = "key:" .. tostring(key)
			return true
		end,
		emit_key_strokes = function(text)
			emissions[#emissions + 1] = "type:" .. tostring(text):sub(1, 6)
			return true
		end,
	}
	local KU = helpers.load_with_stubs("modules.keymap.utils", {
		-- The override replaces hs.pasteboard wholesale, so it must carry every
		-- member perform_paste touches (readAllData / writeAllData included).
		pasteboard = {
			getContents  = function() return "" end,
			readAllData  = function() return {} end,
			writeAllData = function(_) return true end,
			clearContents = function()
				clipboard.clears = clipboard.clears + 1
			end,
			setContents  = function(s)
				-- perform_paste writes the clipboard then sends Cmd+V; the write is what
				-- marks the segment as having been emitted, so record it here.
				emissions[#emissions + 1] = "paste:" .. tostring(s):sub(1, 6)
				return true
			end,
		},
		timer = {
			doAfter = function(delay, fn)
				pending[#pending + 1] = { delay = delay, fn = fn }
				return { stop = function() end }
			end,
			new = function(delay, fn)
				local record = { delay = delay, fn = fn, running = false, stopped = false }
				local native = {}
				function native:start()
					record.running = true
					pending[#pending + 1] = record
					return self
				end
				function native:stop()
					record.running = false
					record.stopped = true
					return self
				end
				return native
			end,
			doEvery           = function() return { stop = function() end } end,
			secondsSinceEpoch = function() return 1000 end,
			absoluteTime      = function() return 0 end,
			usleep            = function() end,
		},
	})

	--- Fires only the callbacks owned at entry, lowest delay first.
	--- A callback may schedule a later retry; iterating the live growing table
	--- would execute that retry in the same turn and can make the harness loop
	--- forever instead of modelling Hammerspoon's next run-loop delivery.
	local function fire_pending()
		local scheduled = pending
		pending = {}
		table.sort(scheduled, function(x, y) return x.delay < y.delay end)
		for _, p in ipairs(scheduled) do
			if p.running ~= false and p.stopped ~= true then pcall(p.fn) end
		end
		return #scheduled
	end

	return KU, emissions, fire_pending, clipboard
end

--- Returns the 1-based position of the first emission whose text contains needle.
--- @param log table Ordered emission log.
--- @param needle string Substring to find.
--- @return integer|nil
local function index_of(log, needle)
	for i, e in ipairs(log) do
		if e:find(needle, 1, true) then return i end
	end
	return nil
end





-- ============================================
-- ============================================
-- ======= 2/ Order Survives A Deferral =======
-- ============================================
-- ============================================

helpers.describe("emit_tokens preserves token order across a deferred paste", function()
	helpers.it("a key token after two paste segments is emitted AFTER the second paste", function()
		local KU, log, fire_pending = load_utils()

		KU.emit_tokens({
			{ kind = "text", value = LONG_A },
			{ kind = "text", value = LONG_B },
			{ kind = "key",  value = "return" },
		})
		fire_pending()

		local b_at   = index_of(log, "bbbbbb")
		local key_at = index_of(log, "key:return")

		helpers.assert_true(b_at ~= nil, "the second paste segment must be emitted at some point")
		helpers.assert_true(key_at ~= nil, "the key token must be emitted at some point")
		helpers.assert_true(key_at > b_at,
			"the key token follows the second paste segment in the token list, so it must be "
			.. "emitted AFTER it. Emitting inline while that paste is still deferred lands the "
			.. "key in the middle of the replacement — the user sees scrambled output. "
			.. "Order was: " .. table.concat(log, " | "))
	end)

	helpers.it("short text after two paste segments is also emitted AFTER the second paste", function()
		local KU, log, fire_pending = load_utils()

		KU.emit_tokens({
			{ kind = "text", value = LONG_A },
			{ kind = "text", value = LONG_B },
			{ kind = "text", value = "zzz" },   -- below PASTE_THRESHOLD -> keystrokes
		})
		fire_pending()

		local b_at = index_of(log, "bbbbbb")
		local z_at = index_of(log, "type:zzz")

		helpers.assert_true(b_at ~= nil and z_at ~= nil, "both segments must be emitted")
		helpers.assert_true(z_at > b_at,
			"a short text token must not overtake the deferred paste that precedes it. "
			.. "Order was: " .. table.concat(log, " | "))
	end)

	helpers.it("a key after a single inline paste is fenced behind it, and lands after it", function()
		-- This case used to assert the key was emitted INLINE, on the reasoning that
		-- an inline paste has already posted its Cmd+V and post order is preserved.
		-- Post order is preserved — but the pasted TEXT is not one of our events:
		-- the target produces it later, when it gets around to reading the
		-- pasteboard. A key posted immediately behind the Cmd+V therefore reaches
		-- the host ahead of the text it is supposed to follow, which is how an
		-- Enter terminator landed on a line whose replacement had not arrived and
		-- submitted it as it was. The fence now covers every paste.
		local KU, log, fire_pending = load_utils()

		KU.emit_tokens({
			{ kind = "text", value = LONG_A },
			{ kind = "key",  value = "return" },
		})

		helpers.assert_true(index_of(log, "key:return") == nil,
			"the key must NOT be emitted before the paste has had its settle window — "
				.. "Cmd+V is our last event, the text itself is the target's work. "
				.. "Order was: " .. table.concat(log, " | "))

		fire_pending()

		local a_at   = index_of(log, "aaaaaa")
		local key_at = index_of(log, "key:return")
		helpers.assert_true(a_at ~= nil and key_at ~= nil,
			"both the paste and the key must be emitted once the fence elapses. "
				.. "Order was: " .. table.concat(log, " | "))
		helpers.assert_true(key_at > a_at, "order must hold on the fenced path too")
	end)

	helpers.it("a keystroke-only expansion is never fenced", function()
		-- The real non-regression behind the case above: nothing that avoids the
		-- clipboard may pay a settle gap. Ordinary autocorrections are short ASCII
		-- text and must still reach the screen with no timer in the way.
		local KU, log, fire_pending = load_utils()

		KU.emit_tokens({
			{ kind = "text", value = "oui" },
			{ kind = "key",  value = "return" },
		})

		local t_at   = index_of(log, "type:oui")
		local key_at = index_of(log, "key:return")
		helpers.assert_true(t_at ~= nil and key_at ~= nil,
			"a keystroke-only expansion must be fully emitted inline, with no timer. "
				.. "Order was: " .. table.concat(log, " | "))
		helpers.assert_true(key_at > t_at, "order must hold inline")

		fire_pending()
	end)
end)






-- ================================================
-- ================================================
-- ======= 3/ The Fence Is Reported Outward =======
-- ================================================
-- ================================================

helpers.describe("emit_tokens reports its ordering fence to the caller", function()
	helpers.it("faithfully restores an originally empty clipboard and settles the timer wave", function()
		local KU, _log, fire_pending, clipboard = load_utils()
		KU.emit_text(LONG_A)

		helpers.assert_eq(fire_pending(), 1,
			"one inline paste must own one delayed restoration attempt")
		helpers.assert_eq(clipboard.clears, 1,
			"an empty all-type snapshot is restored through hs.pasteboard.clearContents; "
				.. "omitting that real API from the fixture turns the restore into an endless retry")
		helpers.assert_eq(fire_pending(), 0,
			"a successful restore must not leave a retry scheduled for the next run-loop turn")
	end)

	helpers.it("returns a positive delay once a paste has been deferred", function()
		local KU, _log, fire_pending = load_utils()

		local _c, _s, _logical, fence = KU.emit_tokens({
			{ kind = "text", value = LONG_A },
			{ kind = "text", value = LONG_B },
		})
		fire_pending()

		helpers.assert_eq(type(fence), "number",
			"emit_tokens must report the fence — a caller that emits anything MORE afterwards "
				.. "has the same ordering hazard as the tokens and no other way to learn about it")
		helpers.assert_true(fence > 0,
			"with a paste still queued on a timer, a later synchronous send would overtake it, "
				.. "so the fence must tell the caller how long to wait")
	end)

	helpers.it("returns zero when no clipboard was involved at all", function()
		local KU, _log, fire_pending = load_utils()

		local _c, _s, _logical, fence = KU.emit_tokens({
			{ kind = "text", value = "oui" },
			{ kind = "key",  value = "return" },
		})
		fire_pending()

		helpers.assert_eq(fence, 0,
			"keystrokes are OUR events end to end and CGEvent delivery preserves post order, so "
				.. "nothing follows them on a timer. Reporting a delay here would add a settle "
				.. "gap to every ordinary expansion, which is the cost this case exists to refuse")
	end)

	helpers.it("a single inline paste still reports a fence", function()
		-- The fence is not about whether WE deferred anything. It is about who
		-- produces the text: after Cmd+V the target does, on its own schedule, so a
		-- caller emitting anything more must wait even though our own queue is empty.
		local KU, _log, fire_pending = load_utils()

		local _c, _s, _logical, fence = KU.emit_tokens({
			{ kind = "text", value = LONG_A },
			{ kind = "key",  value = "return" },
		})
		fire_pending()

		helpers.assert_true(type(fence) == "number" and fence > 0,
			"an inline paste must report a settle fence — reporting 0 told the terminator "
				.. "re-type it was safe to fire immediately, and it landed on unpasted text")
	end)

	helpers.it("emit_text reports the same fence for the same reason", function()
		local KU = load_utils()
		local _c, _s, _logical, fence = KU.emit_text(LONG_A)
		helpers.assert_true(type(fence) == "number" and fence > 0,
			"emit_text pastes inline too — the contract must be uniform so callers need not "
				.. "know which emitter they reached")
	end)

	helpers.it("emit_text reports no fence for text it types", function()
		local KU = load_utils()
		local _c, _s, _logical, fence = KU.emit_text("oui")
		helpers.assert_eq(fence, 0,
			"short text goes out as keystrokes, which need no settle window")
	end)
end)

package.loaded["adapters.synthetic_input"] = nil
