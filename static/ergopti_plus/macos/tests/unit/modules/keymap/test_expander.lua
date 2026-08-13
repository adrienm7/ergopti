--- tests/unit/modules/keymap/test_expander.lua

--- ==============================================================================
--- MODULE: keymap.expander Unit Tests
--- DESCRIPTION:
--- Validates the expander's guard pattern (require_state) and early-return
--- logic for the public expansion entry points. We do NOT exercise the full
--- keystroke pipeline — that requires a richer keystroke simulator and live
--- registry / LLM bridge. The focus here is on the deterministic state-machine
--- branches that are exercised on every keystroke.
---
--- COVERAGE:
--- 1. Public surface and require_state guard behavior before init().
--- 2. try_repeat_feature early-returns: feature disabled, wrong char, buffer
---    too short, whitespace-only previous char.
--- 3. perform_text_replacement returns one exact-tag replacement transaction and
---    refreshes the buffer via the supplied buffer_action.
--- ==============================================================================

local helpers = require("tests.helpers")
local SyntheticStack = require("tests.support.synthetic_input_stack")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local Expander = helpers.load_with_stubs("modules.keymap.expander")


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

--- Builds a minimal registry stub: terminators are read from a simple set.
local function make_registry(terminator_set, consumed_set)
	local R = {}
	function R.is_terminator(c) return terminator_set[c] == true end
	function R.terminator_is_consumed(c) return consumed_set[c] == true end
	return R
end

--- Builds a minimal LLM bridge stub that records the calls it receives.
local function make_llm()
	local L = { previews = {}, timer_starts = 0, llm_on = false }
	function L.update_preview(buf) table.insert(L.previews, buf) end
	function L.get_llm_enabled() return L.llm_on end
	function L.start_timer() L.timer_starts = L.timer_starts + 1 end
	return L
end

--- Verifies one ordered, provenance-bearing replacement transaction.
--- @param events table
--- @param SyntheticInput table
--- @param owner string
local function assert_owned_transaction(events, SyntheticInput, owner)
	local property = hs.eventtap.event.properties.eventSourceUserData
	local generation = nil
	for index, event in ipairs(events) do
		local metadata = SyntheticInput.lookup_tag(event:getProperty(property))
		helpers.assert_true(metadata and metadata.owned,
			"every replacement event must carry an Ergopti-owned Quartz tag")
		helpers.assert_eq(metadata.owner, owner)
		helpers.assert_eq(metadata.effect, "replacement")
		generation = generation or metadata.generation
		helpers.assert_eq(metadata.generation, generation,
			"one replacement must never span multiple transaction generations")
		helpers.assert_eq(metadata.ordinal, math.floor((index + 1) / 2))
		helpers.assert_eq(metadata.phase, event.isDown and "down" or "up")
	end
end





-- =====================================
-- =====================================
-- ======= 1/ Public API Surface =======
-- =====================================
-- =====================================

helpers.describe("keymap.expander: public surface", function()
	helpers.it("exposes the documented entry points", function()
		helpers.assert_eq(type(Expander.init),                     "function")
		helpers.assert_eq(type(Expander.perform_text_replacement), "function")
		helpers.assert_eq(type(Expander.try_auto_expand),          "function")
		helpers.assert_eq(type(Expander.try_terminator_expand),    "function")
		helpers.assert_eq(type(Expander.try_repeat_feature),       "function")
	end)
end)




-- ===========================================
-- ===========================================
-- ======= 2/ require_state guard ============
-- ===========================================
-- ===========================================

helpers.describe("keymap.expander: require_state guard", function()
	helpers.it("HS-L-01 every state-dependent public entry fails closed before init", function()
		local previous_logger = package.loaded["infra.logger"]
		local errors = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...)
			local ok_fmt, message = pcall(string.format, tostring(fmt), ...)
			errors[#errors + 1] = ok_fmt and message or tostring(fmt)
		end
		package.loaded["infra.logger"] = logger

		local ok_body, body_err = pcall(function()
			local E = helpers.load_with_stubs("modules.keymap.expander")
			local cases = {
				{
					name = "perform_text_replacement",
					call = function()
						return E.perform_text_replacement(0, function() return 0, "" end,
							function() end, false, false, "test")
					end,
				},
				{ name = "try_auto_expand", call = function() return E.try_auto_expand({}, 0, false) end },
				{
					name = "try_terminator_expand",
					call = function() return E.try_terminator_expand({}, " ", 1, false) end,
				},
				{ name = "try_repeat_feature", call = function() return E.try_repeat_feature("★", false) end },
				{ name = "try_expand", call = function() return E.try_expand("", false) end },
			}

			for index, case in ipairs(cases) do
				local ok_call, result = pcall(case.call)
				helpers.assert_true(ok_call,
					case.name .. " must not raise when a cold-start caller reaches it")
				helpers.assert_eq(result, false,
					case.name .. " must fail closed before M.init()")
				helpers.assert_eq(#errors, index,
					case.name .. " must emit exactly one ERROR for the rejected call")
				helpers.assert_true(errors[index]:find(case.name, 1, true) ~= nil,
					case.name .. " must name itself in the ERROR log")
			end
		end)

		package.loaded["modules.keymap.expander"] = nil
		package.loaded["infra.logger"] = previous_logger
		if not ok_body then error(body_err, 0) end
	end)

	-- Each test reloads the module so _state is freshly nil.
	helpers.it("try_auto_expand returns false when init() not called", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		helpers.assert_eq(E.try_auto_expand({}, 1, false), false)
	end)

	helpers.it("try_terminator_expand returns false when init() not called", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		helpers.assert_eq(E.try_terminator_expand({}, " ", 1, false), false)
	end)

	helpers.it("try_repeat_feature returns false when init() not called", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		helpers.assert_eq(E.try_repeat_feature("★", false), false)
	end)
end)




-- ============================================
-- ============================================
-- ======= 3/ init argument validation ========
-- ============================================
-- ============================================

helpers.describe("keymap.expander: init argument validation", function()
	helpers.it("init() is a no-op when core_state is not a table", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		E.init("oops", {}, {})
		-- Subsequent calls must still hit the guard (state never assigned).
		helpers.assert_eq(E.try_repeat_feature("★", false), false)
	end)

	helpers.it("init() is a no-op when registry_mod is not a table", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		E.init(make_state(), "oops", make_llm())
		helpers.assert_eq(E.try_repeat_feature("★", false), false)
	end)

	helpers.it("init() is a no-op when llm_mod is not a table", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		E.init(make_state(), make_registry({}, {}), "oops")
		helpers.assert_eq(E.try_repeat_feature("★", false), false)
	end)
end)





--- ===================================================
--- ===================================================
--- ======= 4/ try_repeat_feature early-returns =======
--- ===================================================
--- ===================================================

helpers.describe("keymap.expander: try_repeat_feature early-returns", function()
	helpers.it("returns false when the repeat feature is disabled", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state("ab★"); s.repeat_enabled = false
		E.init(s, make_registry({}, {}), make_llm())
		helpers.assert_eq(E.try_repeat_feature("★", false), false)
	end)

	helpers.it("returns false when chars is not the magic key", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state("ab★")
		E.init(s, make_registry({}, {}), make_llm())
		helpers.assert_eq(E.try_repeat_feature("x", false), false)
	end)

	helpers.it("returns false when buffer is shorter than the magic key", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state("★")  -- only the magic key, no preceding char
		E.init(s, make_registry({}, {}), make_llm())
		helpers.assert_eq(E.try_repeat_feature("★", false), false)
	end)

	helpers.it("returns false when the previous char is whitespace", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state(" ★")  -- space before magic key — repeating space is useless
		E.init(s, make_registry({}, {}), make_llm())
		helpers.assert_eq(E.try_repeat_feature("★", false), false)
	end)

	helpers.it("fires for a normal letter before the magic key", function()
		local E, SyntheticInput = SyntheticStack.load("modules.keymap.expander")
		local s = make_state("ab★")
		E.init(s, make_registry({}, {}), make_llm())
		SyntheticInput.enter_callback()
		local result = E.try_repeat_feature("★", false)
		local consume, events = SyntheticInput.leave_callback(result)
		helpers.assert_eq(result, true)
		helpers.assert_true(consume)
		helpers.assert_eq(#events, 2,
			"repeat must return one tagged key pair from the callback")
		assert_owned_transaction(events, SyntheticInput, "repeat_key")
		-- The magic key is stripped and the previous char ("b") is repeated, so
		-- the buffer goes from "ab★" → "ab" + "b" = "abb".
		helpers.assert_eq(s.buffer, "abb")
		if hs and hs.timer and hs.timer.__fire_all then hs.timer.__fire_all() end
	end)
end)




-- ===============================================
-- ===============================================
-- ======= 5/ perform_text_replacement ===========
-- ===============================================
-- ===============================================

helpers.describe("keymap.expander: perform_text_replacement", function()
	helpers.it("calls the tooltip renderer with forced hiding on expansion", function()
		local tt_hidden_forced = false
		local old_renderer = package.loaded["adapters.tooltip_renderer"]
		package.loaded["adapters.tooltip_renderer"] = {
			hide = function(opts) tt_hidden_forced = type(opts) == "table" and opts.forced == true end,
		}
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state("hello")
		E.init(s, make_registry({}, {}), make_llm())
		E.perform_text_replacement(1, function() end, function() end, false, false, "star", nil)
		helpers.assert_eq(tt_hidden_forced, true)
		package.loaded["adapters.tooltip_renderer"] = old_renderer
	end)

	helpers.it("issues the requested deletes and runs the buffer_action", function()
		local E, SyntheticInput = SyntheticStack.load("modules.keymap.expander")
		local s = make_state("hello")
		local llm = make_llm()
		E.init(s, make_registry({}, {}), llm)

		local emit_called, buf_called = false, false
		SyntheticInput.enter_callback()
		local replaced = E.perform_text_replacement(
			3,
			function()
				emit_called = true
				SyntheticInput.emit_key_strokes("wrld")
				return 4, "wrld"
			end,
			function() buf_called = true ; s.buffer = "hewrld" end,
			false, false, "test"
		)
		local consume, events = SyntheticInput.leave_callback(replaced)
		-- Dispatch confirmation and its lifecycle callback occupy two run-loop
		-- turns; neither may publish the preview from the eventtap itself.
		if hs and hs.timer and hs.timer.__fire_all then
			hs.timer.__fire_all()
			hs.timer.__fire_all()
		end

		helpers.assert_eq(emit_called, true)
		helpers.assert_eq(buf_called,  true)
		helpers.assert_true(consume)
		helpers.assert_eq(#events, 14,
			"three Backspace pairs plus four text pairs must be returned atomically")
		assert_owned_transaction(events, SyntheticInput, "test")
		helpers.assert_eq(s.buffer, "hewrld")
		-- update_preview must be called on the rebuilt buffer.
		helpers.assert_eq(llm.previews[#llm.previews], "hewrld")
	end)

	helpers.it("refreshes chained preview only from committed replacement completion", function()
		local E, SyntheticInput = SyntheticStack.load("modules.keymap.expander")
		local s = make_state("old")
		local llm = make_llm()
		E.init(s, make_registry({}, {}), llm)

		SyntheticInput.enter_callback()
		local replaced = E.perform_text_replacement(
			0,
			function()
				SyntheticInput.emit_key_strokes("new")
				return 3, "new"
			end,
			function() s.buffer = "new" end,
			false, false, "completion-preview"
		)
		helpers.assert_true(replaced)

		-- A standalone doAfter refresh could run here while the replacement batch
		-- was still owned by the eventtap return path. Completion ownership must
		-- keep the new preview unpublished until that exact batch commits.
		if hs and hs.timer and hs.timer.__fire_all then
			hs.timer.__fire_all()
			hs.timer.__fire_all()
		end
		helpers.assert_eq(#llm.previews, 0)

		local consume = SyntheticInput.leave_callback(replaced)
		helpers.assert_true(consume)
		if hs and hs.timer and hs.timer.__fire_all then
			hs.timer.__fire_all()
			hs.timer.__fire_all()
		end
		helpers.assert_eq(#llm.previews, 1)
		helpers.assert_eq(llm.previews[1], "new")
	end)

	helpers.it("does not arm the LLM timer when LLM is disabled", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state("x")
		local llm = make_llm() ; llm.llm_on = false
		E.init(s, make_registry({}, {}), llm)
		E.perform_text_replacement(
			0,
			function() return 0, "" end,
			function() end,
			false, false, "test"
		)
		helpers.assert_eq(llm.timer_starts, 0)
	end)

	helpers.it("arms the LLM timer when LLM is enabled and not ignored", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state("x")
		local llm = make_llm() ; llm.llm_on = true
		E.init(s, make_registry({}, {}), llm)
		E.perform_text_replacement(
			0,
			function() return 0, "" end,
			function() end,
			false, false, "test"
		)
		helpers.assert_eq(llm.timer_starts, 1)
	end)

	helpers.it("skips LLM side-effects when is_ignored=true", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state("x")
		local llm = make_llm() ; llm.llm_on = true
		E.init(s, make_registry({}, {}), llm)
		E.perform_text_replacement(
			0,
			function() return 0, "" end,
			function() end,
			false, true, "test"
		)
		-- update_preview is gated on is_ignored, and so is start_timer.
		helpers.assert_eq(#llm.previews, 0)
		helpers.assert_eq(llm.timer_starts, 0)
	end)

	helpers.it("cancels an emitted prefix when the producer raises before commit", function()
		local E, SyntheticInput = SyntheticStack.load("modules.keymap.expander")
		local s = make_state("trigger")
		E.init(s, make_registry({}, {}), make_llm())
		local buffer_committed = false

		SyntheticInput.enter_callback()
		local replaced = E.perform_text_replacement(
			2,
			function()
				SyntheticInput.emit_key_strokes("x")
				error("producer failed after a partial prefix")
			end,
			function()
				buffer_committed = true
				s.buffer = "claimed-output"
			end,
			false, false, "test"
		)
		local consume, events = SyntheticInput.leave_callback(replaced)

		helpers.assert_true(not replaced)
		helpers.assert_true(not consume,
			"the original physical key must pass through after rollback")
		helpers.assert_true(events == nil,
			"no prefix event may escape a cancelled callback transaction")
		helpers.assert_true(not buffer_committed)
		helpers.assert_eq(s.buffer, "trigger")
		helpers.assert_eq(SyntheticInput.stats().active_transactions, 0)
	end)

	helpers.it("cancels the transaction when emit_action throws before output", function()
		local E, SyntheticInput = SyntheticStack.load("modules.keymap.expander")
		local s = make_state("x")
		E.init(s, make_registry({}, {}), make_llm())
		local before = SyntheticInput.stats()
		local replaced = E.perform_text_replacement(
			0,
			function() error("boom") end,
			function() end,
			false, false, "test"
		)
		local after = SyntheticInput.stats()
		helpers.assert_true(not replaced)
		helpers.assert_eq(s.buffer, "x")
		helpers.assert_eq(after.active_transactions, before.active_transactions,
			"a rejected producer must not strand an active transaction")
		helpers.assert_eq(after.records, before.records,
			"a rejected producer must leave no owned-event records behind")
		helpers.assert_eq(after.pending, before.pending,
			"a rejected producer must not queue an empty broker batch")
	end)
end)


-- ===============================================
-- ===============================================
-- ======= 6/ Pause & Stress (Encore) ============
-- ===============================================
-- ===============================================

helpers.describe("keymap.expander: the pause gate is not here", function()
	-- The expander runs on the hotstring path of every keystroke, and the pause
	-- check is the early return at the top of that path. Both cases below used to
	-- say so with assert_true(true) and a sentence — a design claim written as a
	-- test, which costs a suite line and deters anyone from writing the real one.
	helpers.it("the module names no pause or suspend state", function()
		-- A second check here would mean two modules decide whether an expansion
		-- fires. They will disagree, and the failure is silent in the worst
		-- direction: a paused driver that still mutates the buffer expands the
		-- first thing typed after resume against text the user never saw tracked.
		local src = helpers.read_driver_source("function M.perform_text_replacement")
		helpers.assert_true(src ~= nil, "modules/keymap/expander.lua source must be locatable")
		helpers.assert_true(src:find("paus") == nil,
			"the expander must stay pure — the Feed path early-returns before reaching it")
		helpers.assert_true(src:find("suspend") == nil, "same for suspend")
	end)

	helpers.it("150 non-matching calls leave the buffer exactly where they found it", function()
		-- The stress claim is worth keeping; what it needed was to read the state
		-- back and inspect the transaction adapter. A refusal that opened or retained
		-- a transaction would make the next real action inherit stale output state.
		local E, SyntheticInput = SyntheticStack.load("modules.keymap.expander")
		local s = make_state("ab★")
		E.init(s, make_registry({}, {}), make_llm())
		local before = SyntheticInput.stats()

		for i = 1, 150 do
			helpers.assert_eq(E.try_repeat_feature("x" .. i, false), false,
				"a char that is not the magic key must never fire the repeat feature")
		end

		helpers.assert_eq(s.buffer, "ab★", "150 refusals must not have touched the buffer")
		local after = SyntheticInput.stats()
		helpers.assert_eq(after.generation, before.generation,
			"a non-match must not allocate a synthetic transaction")
		helpers.assert_eq(after.records, before.records,
			"a non-match must not allocate any event provenance")
		helpers.assert_eq(after.active_transactions, before.active_transactions)
	end)
end)
