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
--- @return table utils, table log, function fire_pending
local function load_utils()
	local emissions = {}
	local pending   = {}

	package.loaded["modules.keymap.utils"] = nil
	local KU = helpers.load_with_stubs("modules.keymap.utils", {
		eventtap = {
			keyStroke  = function(_mods, key) emissions[#emissions + 1] = "key:" .. tostring(key) end,
			keyStrokes = function(s) emissions[#emissions + 1] = "type:" .. tostring(s):sub(1, 6) end,
			event      = { types = { keyDown = 10 } },
			new        = function() return { start = function() end, stop = function() end } end,
		},
		-- The override replaces hs.pasteboard wholesale, so it must carry every
		-- member perform_paste touches (readAllData / writeAllData included).
		pasteboard = {
			getContents  = function() return "" end,
			readAllData  = function() return {} end,
			writeAllData = function(_) return true end,
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
			doEvery           = function() return { stop = function() end } end,
			secondsSinceEpoch = function() return 1000 end,
			absoluteTime      = function() return 0 end,
			usleep            = function() end,
		},
	})

	--- Fires captured callbacks in scheduled order, lowest delay first.
	local function fire_pending()
		table.sort(pending, function(x, y) return x.delay < y.delay end)
		for _, p in ipairs(pending) do pcall(p.fn) end
		pending = {}
	end

	return KU, emissions, fire_pending
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

	helpers.it("a single paste with a following key still emits inline, in order", function()
		-- Non-regression: with only ONE paste-worthy token nothing is deferred, so
		-- the key must still be emitted immediately and after it. A fix that
		-- deferred everything unconditionally would add latency to every expansion.
		local KU, log, fire_pending = load_utils()

		KU.emit_tokens({
			{ kind = "text", value = LONG_A },
			{ kind = "key",  value = "return" },
		})

		local a_at   = index_of(log, "aaaaaa")
		local key_at = index_of(log, "key:return")

		helpers.assert_true(a_at ~= nil and key_at ~= nil,
			"both the paste and the key must be emitted without needing the timer to fire")
		helpers.assert_true(key_at > a_at, "order must hold on the inline path too")

		fire_pending()
	end)
end)
