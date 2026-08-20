--- tests/unit/modules/keymap/test_expander_notify_synthetic_pcall.lua

--- ==============================================================================
--- MODULE: Regression — expander guards notify_synthetic against raising (F-HIGH-16)
--- DESCRIPTION:
--- perform_text_replacement — the synthetic-injection choke point used by every
--- hotstring/LLM-paste path — called keylogger.notify_synthetic(...) WITHOUT a
--- pcall, unlike the neighboring buffer_action call a few lines below (which is
--- explicitly pcall-wrapped, with a comment acknowledging exactly this desync
--- risk). notify_synthetic's own utf8.codes loop can raise on malformed UTF-8
--- (e.g. a truncated LLM completion cut mid-codepoint), which used to abort the
--- expansion mid-flight and drop the replacement before callback handoff.
---
--- This test drives the REAL perform_text_replacement with an injected
--- modules.keylogger stub whose notify_synthetic always raises, and asserts the
--- expansion still commits one complete, provenance-tagged transaction.
--- ==============================================================================

local helpers = require("tests.helpers")
local SyntheticStack = require("tests.support.synthetic_input_stack")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

--- Builds a minimal CoreState object that satisfies the expander's contract.
--- @return table
local function make_state(buffer)
	local s = {
		buffer         = buffer or "",
		magic_key      = "★",
		repeat_enabled = true,
	}
	function s.is_repeat_feature_enabled() return s.repeat_enabled end
	function s.suppress_rescan(_) end
	return s
end

local function make_registry(terminator_set, consumed_set)
	local R = {}
	function R.is_terminator(c) return (terminator_set or {})[c] == true end
	function R.terminator_is_consumed(c) return (consumed_set or {})[c] == true end
	return R
end

local function make_llm()
	local L = { previews = {}, timer_starts = 0, llm_on = false }
	function L.update_preview(buf) table.insert(L.previews, buf) end
	function L.get_llm_enabled() return L.llm_on end
	function L.start_timer() L.timer_starts = L.timer_starts + 1 end
	return L
end

--- Verifies one complete callback-return transaction.
--- @param events table
--- @param SyntheticInput table
--- @param owner string
local function assert_owned_transaction(events, SyntheticInput, owner)
	local property = hs.eventtap.event.properties.eventSourceUserData
	local generation = nil
	for index, event in ipairs(events) do
		local metadata = SyntheticInput.lookup_tag(event:getProperty(property))
		helpers.assert_true(metadata and metadata.owned,
			"telemetry failure must not strip exact ownership from output")
		helpers.assert_eq(metadata.owner, owner)
		helpers.assert_eq(metadata.effect, "replacement")
		generation = generation or metadata.generation
		helpers.assert_eq(metadata.generation, generation)
		helpers.assert_eq(metadata.ordinal, math.floor((index + 1) / 2))
		helpers.assert_eq(metadata.phase, event.isDown and "down" or "up")
	end
end




-- ==================================================================================
-- ==================================================================================
-- ======= 1/ perform_text_replacement survives a raising notify_synthetic ========
-- ==================================================================================
-- ==================================================================================

helpers.describe("keymap.expander: perform_text_replacement survives notify_synthetic raising (F-HIGH-16)", function()

	helpers.it("completes the expansion (buffer_action still runs) when notify_synthetic throws", function()
		-- Inject a keylogger stub whose notify_synthetic always raises, mimicking
		-- notify_synthetic's own utf8.codes crash on malformed UTF-8 input BEFORE
		-- the keylogger-side fix guards it — pins that the CALL SITE in expander.lua
		-- must not let this propagate regardless of what notify_synthetic does.
		package.loaded["modules.keylogger"] = {
			notify_synthetic = function() error("simulated malformed-UTF-8 crash") end,
			set_buffer       = function() end,
		}
		local E, SyntheticInput = SyntheticStack.load("modules.keymap.expander")

		local s = make_state("hello")
		E.init(s, make_registry({}, {}), make_llm())

		local buf_called = false
		SyntheticInput.enter_callback()
		local ok, replaced = pcall(E.perform_text_replacement,
			3,
			function()
				SyntheticInput.emit_key_strokes("wrld")
				return 4, "wrld", "wrld"
			end,
			function() buf_called = true; s.buffer = "hewrld" end,
			false, false, "test"
		)
		local consume, events
		if ok then
			consume, events = SyntheticInput.leave_callback(replaced == true)
		else
			SyntheticInput.abort_callback()
		end

		-- Must run before any assertion could fail-and-return-early below:
		-- this test is the only one that ever assigns a raising stub into
		-- package.loaded["modules.keylogger"]. Without clearing it here, the
		-- poisoned stub leaks into every later test file that requires
		-- modules.keylogger in this same Lua process — it doesn't crash them
		-- (the real notify_synthetic pcall guard swallows it), but for a
		-- module like test_expander.lua that reads notify_synthetic's return
		-- value or side effects, the always-raising stub silently changes
		-- behaviour and fails unrelated tests with this file's own error
		-- message, which is exactly what happened in CI on 2026-07-01.
		package.loaded["modules.keylogger"] = nil

		helpers.assert_true(ok, "perform_text_replacement must not propagate a notify_synthetic error")
		helpers.assert_true(replaced, "telemetry failure must not veto a valid replacement")
		helpers.assert_true(buf_called, "buffer_action must still run after notify_synthetic throws")
		helpers.assert_true(consume)
		helpers.assert_eq(#events, 14,
			"three delete pairs and four Unicode pairs must be handed off atomically")
		assert_owned_transaction(events, SyntheticInput, "test")
		helpers.assert_eq(s.buffer, "hewrld")
		if hs and hs.timer and hs.timer.__fire_all then hs.timer.__fire_all() end
		helpers.assert_eq(SyntheticInput.stats().active_transactions, 0)
	end)

	helpers.it("seals repeat-key output and releases its transaction when notification raises", function()
		package.loaded["modules.keylogger"] = {
			notify_synthetic = function() error("simulated repeat telemetry failure") end,
			set_buffer       = function() end,
		}
		local E, SyntheticInput = SyntheticStack.load("modules.keymap.expander")
		local s = make_state("ab★")
		E.init(s, make_registry({}, {}), make_llm())

		SyntheticInput.enter_callback()
		local call_ok, fired = pcall(E.try_repeat_feature, "★", false)
		local consume, events = SyntheticInput.leave_callback(fired)
		if hs and hs.timer and hs.timer.__fire_all then hs.timer.__fire_all() end
		package.loaded["modules.keylogger"] = nil

		helpers.assert_true(call_ok,
			"telemetry failure must not escape the repeat-key producer")
		helpers.assert_true(fired and consume)
		helpers.assert_eq(#events, 2,
			"the repeated character must still be returned as one complete pair")
		assert_owned_transaction(events, SyntheticInput, "repeat_key")
		helpers.assert_eq(s.buffer, "abb")
		helpers.assert_eq(SyntheticInput.stats().active_transactions, 0,
			"the repeat transaction must be terminal after callback handoff")
	end)
end)
