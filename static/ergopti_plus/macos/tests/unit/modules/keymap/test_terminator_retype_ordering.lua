--- tests/unit/modules/keymap/test_terminator_retype_ordering.lua

--- ==============================================================================
--- MODULE: Regression — the re-typed terminator must not overtake a deferred
---         paste (terminator-retype-ordering)
--- DESCRIPTION:
--- A multi-segment expansion fired by a terminator landed with the terminator in
--- the MIDDLE of the replacement instead of at its end.
---
--- ROOT CAUSE ENCODED: emit_tokens defers the second and later paste-worthy
--- segments behind a settle gap, and chains every following token behind that
--- deferral so order survives. But the fence was local to emit_tokens and
--- covered only its own tokens. The terminator re-type happens in the expander,
--- AFTER emit_dispatch returns, and reaches the OS synchronously — so it
--- overtook the very segment it was supposed to follow. From the outside
--- emit_tokens looks finished while a paste is still queued on a timer, which is
--- exactly why the caller cannot get this right by itself.
---
--- The fence is now returned and the re-type chained behind it.
---
--- WHY IT WAS SILENT: nothing failed. Every character was emitted, the buffer
--- and the telemetry were correct, and only the on-screen order was wrong — and
--- only for replacements with multiple paste-worthy segments fired by a
--- non-consumed terminator.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Longer than PASTE_THRESHOLD (50) so should_paste() routes each to the clipboard.
local LONG_A = string.rep("a", 80)
local LONG_B = string.rep("b", 80)




-- =============================================
-- =============================================
-- ======= 1/ Harness ==========================
-- =============================================
-- =============================================

--- Minimal CoreState stub, mirroring the sibling expander tests.
--- @param buffer string
--- @return table
local function make_state(buffer)
	local s = {
		buffer                    = buffer or "",
		expected_synthetic_chars  = "",
		expected_synthetic_deletes = 0,
		expected_synthetic_pastes = 0,
		start_is_word_boundary    = function() return true end,
	}
	function s.suppress_rescan(_) end
	return s
end

--- Registry stub whose terminator is a space that is NOT consumed, so the
--- expander re-types it — the emission this regression is about.
--- @param entries table
--- @return table
local function make_registry(entries)
	local R = { _entries = entries or {} }
	function R.is_terminator(c) return c == " " end
	function R.terminator_is_consumed(_c) return false end
	function R.mappings_for_tail(tail) return R._entries[tail] or {} end
	return R
end

local function make_llm()
	local L = {}
	function L.update_preview(_) end
	function L.get_llm_enabled() return false end
	function L.start_timer() end
	return L
end

--- Loads the expander with every emission recorded in one ordered log and with
--- doAfter captured so deferrals can be fired deliberately.
--- @return table expander, table emissions, function fire_pending
local function load_expander()
	local emissions = {}
	local pending   = {}

	package.loaded["modules.keymap.utils"] = nil
	package.loaded["modules.keymap.expander"] = nil
	-- The terminator is emitted by the replay gate, not by the expander, and the
	-- gate binds its TextSender at load time. Leaving it cached would keep the
	-- reference taken before the recording stub below was installed, so every
	-- terminator would go somewhere this test cannot see and the ordering
	-- assertions would pass on an empty log.
	package.loaded["modules.keymap.terminator_replay"] = nil
	-- Same reasoning one level down: the scheduler captures `hs` at load time, and
	-- load_with_stubs builds a FRESH hs per call. A cached scheduler would keep
	-- posting into the previous test case's timer list, so this case's
	-- fire_pending() would find nothing to fire and conclude the terminator was
	-- never queued.
	package.loaded["adapters.timer_scheduler"] = nil

	local E = helpers.load_with_stubs("modules.keymap.expander", {
		eventtap = {
			keyStroke  = function(_mods, key) emissions[#emissions + 1] = "key:" .. tostring(key) end,
			keyStrokes = function(s) emissions[#emissions + 1] = "type:" .. tostring(s):sub(1, 6) end,
			event      = { types = { keyDown = 10 } },
			new        = function() return { start = function() end, stop = function() end } end,
		},
		pasteboard = {
			getContents  = function() return "" end,
			readAllData  = function() return {} end,
			writeAllData = function(_) return true end,
			setContents  = function(s)
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

	-- The terminator re-type goes through TextSender, not through hs.eventtap, so
	-- it must be recorded on the SAME log to be comparable with the pastes.
	package.loaded["adapters.text_sender"] = {
		send     = function(s, _o) emissions[#emissions + 1] = "term:" .. tostring(s) end,
		pressKey = function(k, _m, _d) emissions[#emissions + 1] = "term:" .. tostring(k) end,
		sendKeys = function() end,
		-- perform_text_replacement erases the trigger before emitting; recorded
		-- rather than ignored so the log shows the full sequence.
		eraseChars = function(n, _d) emissions[#emissions + 1] = "erase:" .. tostring(n) end,
	}
	package.loaded["modules.keymap.expander"] = nil
	package.loaded["modules.keymap.terminator_replay"] = nil
	E = require("modules.keymap.expander")

	local function fire_pending()
		table.sort(pending, function(x, y) return x.delay < y.delay end)
		for _, p in ipairs(pending) do pcall(p.fn) end
		pending = {}
	end

	return E, emissions, fire_pending
end

--- 1-based position of the first emission containing needle.
--- @param log table
--- @param needle string
--- @return integer|nil
local function index_of(log, needle)
	for i, e in ipairs(log) do
		if e:find(needle, 1, true) then return i end
	end
	return nil
end





-- ==============================================
-- ==============================================
-- ======= 2/ Order Survives The Deferral =======
-- ==============================================
-- ==============================================

helpers.describe("try_terminator_expand: the re-typed terminator lands last", function()
	helpers.it("is emitted after a deferred second paste segment", function()
		local E, log, fire_pending = load_expander()

		local s = make_state("btw ")
		-- repl carries a {Left} directive so plain_repl ~= repl and emit_dispatch
		-- routes through emit_tokens — two paste-worthy segments, so the second
		-- one is deferred.
		local m = {
			trigger       = "btw",
			trigger_bytes = 3,
			tlen          = 3,
			repl          = LONG_A .. "{Left}" .. LONG_B,
			plain_repl    = LONG_A .. LONG_B,
			is_word       = false,
			match_mode    = "exact",
			final_result  = false,
		}
		local reg = make_registry({ ["w"] = { m } })
		E.init(s, reg, make_llm())

		local fired = E.try_terminator_expand(m, " ", 1, false)
		helpers.assert_true(fired, "the expansion must fire, or nothing below is exercised")
		fire_pending()

		local b_at    = index_of(log, "bbbbbb")
		local term_at = index_of(log, "term:")

		helpers.assert_true(b_at ~= nil,
			"the second paste segment must be emitted — without it there is no deferral and "
				.. "this test would pass vacuously. Order was: " .. table.concat(log, " | "))
		helpers.assert_true(term_at ~= nil,
			"the terminator must be re-typed: it is not consumed, so it has to stay on screen. "
				.. "Order was: " .. table.concat(log, " | "))
		helpers.assert_true(term_at > b_at,
			"the terminator must land AFTER the segment it follows. emit_tokens defers that "
				.. "paste onto a timer while the re-type reaches the OS synchronously, so an "
				.. "unfenced re-type arrives in the MIDDLE of the replacement. Order was: "
				.. table.concat(log, " | "))
	end)

	helpers.it("waits for the settle window when the replacement was pasted", function()
		local E, log, fire_pending = load_expander()

		local s = make_state("btw ")
		-- One paste-worthy segment: nothing is deferred on OUR side, and this case
		-- used to assert the re-type therefore fired immediately. It must not. The
		-- pasted text is produced by the target after it reads the pasteboard, so a
		-- terminator posted straight after Cmd+V overtakes it.
		local m = {
			trigger       = "btw",
			trigger_bytes = 3,
			tlen          = 3,
			repl          = LONG_A .. "{Left}",
			plain_repl    = LONG_A,
			is_word       = false,
			match_mode    = "exact",
			final_result  = false,
		}
		local reg = make_registry({ ["w"] = { m } })
		E.init(s, reg, make_llm())

		E.try_terminator_expand(m, " ", 1, false)

		helpers.assert_true(index_of(log, "term:") == nil,
			"the terminator must NOT be emitted before the paste has settled. "
				.. "Order was: " .. table.concat(log, " | "))

		fire_pending()

		local a_at    = index_of(log, "aaaaaa")
		local term_at = index_of(log, "term:")
		helpers.assert_true(a_at ~= nil and term_at ~= nil,
			"both the paste and the terminator must be emitted once the fence elapses. "
				.. "Order was: " .. table.concat(log, " | "))
		helpers.assert_true(term_at > a_at,
			"the terminator must land after the replacement it terminates. "
				.. "Order was: " .. table.concat(log, " | "))
	end)

	helpers.it("a typed replacement releases its terminator on the echo, not on a timer", function()
		-- The non-regression the paste cases must not cost us: an ordinary
		-- keystroke-emitted autocorrection must not sit behind a settle gap. Its
		-- terminator is released by the echo of what we injected, which arrives
		-- through the keyboard tap within a keystroke or two — so here we drain the
		-- counters the tap would drain and assert the terminator follows at once,
		-- with no timer fired.
		local E, log, fire_pending = load_expander()
		local Replay = require("modules.keymap.terminator_replay")

		local s = make_state("btw ")
		local m = {
			trigger       = "btw",
			trigger_bytes = 3,
			tlen          = 3,
			repl          = "by the way",
			plain_repl    = "by the way",
			is_word       = false,
			match_mode    = "exact",
			final_result  = false,
		}
		local reg = make_registry({ ["w"] = { m } })
		E.init(s, reg, make_llm())

		E.try_terminator_expand(m, " ", 1, false)

		helpers.assert_true(index_of(log, "type:") ~= nil,
			"the replacement must be typed, or this case proves nothing. "
				.. "Order was: " .. table.concat(log, " | "))
		helpers.assert_true(index_of(log, "term:") == nil,
			"the terminator must NOT go out while the replacement's own echoes are still "
				.. "outstanding — that ordering is the whole point. "
				.. "Order was: " .. table.concat(log, " | "))

		-- What the keyboard tap does as our injected events come back.
		s.expected_synthetic_deletes = 0
		s.expected_synthetic_chars   = " "   -- only the terminator's own echo remains
		Replay.flush_if_delivered()

		local text_at = index_of(log, "type:")
		local term_at = index_of(log, "term:")
		helpers.assert_true(term_at ~= nil,
			"once the echoes have drained the terminator must be released immediately, with "
				.. "no timer in the way. Order was: " .. table.concat(log, " | "))
		helpers.assert_true(term_at > text_at,
			"and it must land last. Order was: " .. table.concat(log, " | "))

		fire_pending()
	end)
end)

-- Restore the real adapter for later test files.
package.loaded["adapters.text_sender"] = nil
package.loaded["modules.keymap.expander"] = nil
package.loaded["modules.keymap.utils"] = nil
