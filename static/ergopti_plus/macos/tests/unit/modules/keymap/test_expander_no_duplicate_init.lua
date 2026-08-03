--- tests/unit/modules/keymap/test_expander_no_duplicate_init.lua

--- ==============================================================================
--- MODULE: keymap.expander duplicate-init Regression Test
--- DESCRIPTION:
--- Asserts that a second call to expander.M.init() is silently ignored and
--- that the module retains the dependencies injected by the first call.
---
--- FEATURES & RATIONALE:
--- 1. Guard Regression: M.init() includes an explicit duplicate-call guard that
---    logs a WARN and returns early. This file encodes that contract so the guard
---    can never be silently removed.
--- 2. Observable Binding: Because _state, _registry and _llm are module-private,
---    the test uses a sentinel field on the first state object and confirms that
---    the expander still reads from it after the second init() attempt.
--- 3. WARN Capture: Logger.set_sink() intercepts the WARNING line so the test
---    can assert both that the warning was emitted and that exactly one such line
---    appeared (no spurious duplicates from the first legitimate call).
--- ==============================================================================

local helpers = require("tests.helpers")

-- Force a fresh Logger so the sink installed below does not inherit state from
-- other suites that may have run before this file in the same process.
package.loaded["infra.logger"] = nil
local Logger = helpers.load_with_stubs("infra.logger")
Logger.set_level(Logger.LEVELS.DEBUG)





-- ===========================================
-- ===========================================
-- ======= 1/ Fixture & Loader Helpers =======
-- ===========================================
-- ===========================================

--- Builds a minimal CoreState-like table with an observable sentinel value.
--- @param sentinel any Unique value stored under the `_sentinel` key.
--- @return table Minimal state table accepted by expander.M.init().
local function make_state(sentinel)
	return {
		_sentinel              = sentinel,
		buffer                 = "",
		expected_synthetic_chars   = "",
		expected_synthetic_deletes = 0,
		start_is_word_boundary = true,
		magic_key              = "★",
		suppress_rescan        = function() end,
		suppress_rescan_keep_buffer = function() end,
		is_repeat_feature_enabled = function() return false end,
	}
end

--- Builds a minimal registry stub that satisfies the expander's require_state check.
--- @return table Minimal registry table.
local function make_registry()
	return {
		is_terminator         = function(_) return false end,
		terminator_is_consumed = function(_) return false end,
		mappings_for_tail     = function(_) return {} end,
	}
end

--- Builds a minimal LLM bridge stub that satisfies the expander's require_state check.
--- @return table Minimal LLM stub table.
local function make_llm()
	return {
		update_preview  = function(_) end,
		get_llm_enabled = function() return false end,
		start_timer     = function() end,
	}
end

--- Loads a completely fresh copy of the expander module, wiping all cached
--- dependencies so module-level private variables (_state, _registry, _llm)
--- start as nil regardless of what earlier tests may have done.
--- @return table Fresh expander module.
local function fresh_expander()
	-- Wipe every module that expander.lua requires at the top level so that
	-- load_with_stubs() forces a full re-execution of the module body.
	local to_wipe = {
		"modules.keymap.expander",
		"infra.text_utils",
		"modules.keymap.utils",
		"infra.logger",
		"modules.keylogger",
		"ui.tooltip",
	}
	for _, name in ipairs(to_wipe) do
		package.loaded[name] = nil
	end

	-- Reinstall Logger with the same fresh stub so the sink we install in the
	-- test body reaches the Logger instance used by the expander.
	local L = helpers.load_with_stubs("infra.logger")
	L.set_level(L.LEVELS.DEBUG)
	package.loaded["infra.logger"] = L

	return require("modules.keymap.expander")
end





-- =======================================================
-- =======================================================
-- ======= 2/ Duplicate-init Guard Regression Test =======
-- =======================================================
-- =======================================================

helpers.describe("expander.M.init(): duplicate call is ignored", function()

	helpers.it("second init() does not overwrite the first-call state binding", function()
		local expander = fresh_expander()

		local state1    = make_state("FIRST")
		local registry1 = make_registry()
		local llm1      = make_llm()

		local state2    = make_state("SECOND")
		local registry2 = make_registry()
		local llm2      = make_llm()

		-- First legitimate initialisation.
		expander.init(state1, registry1, llm1)

		-- Second call with entirely different objects — must be ignored.
		expander.init(state2, registry2, llm2)

		-- The expander must still be bound to state1. We probe this by verifying
		-- that try_expand() operates on state1.buffer: we write a sentinel string
		-- into state1.buffer and confirm try_expand reads it back unchanged from
		-- state1 (i.e., the buffer mutation performed by try_expand happens on
		-- state1, not on state2 which remains untouched).
		state1.buffer = ""
		state2.buffer = ""

		-- try_expand appends the typed char to _state.buffer when no match fires.
		-- If _state is state1 then state1.buffer becomes "x"; state2.buffer stays "".
		expander.try_expand("x", false)

		helpers.assert_eq(state1.buffer, "x",
			"state1.buffer must reflect the expansion attempt — expander must be bound to state1")
		helpers.assert_eq(state2.buffer, "",
			"state2.buffer must be untouched — expander must NOT have switched to state2")
	end)


	helpers.it("second init() emits exactly one WARN log line", function()
		local expander = fresh_expander()
		local L = require("infra.logger")
		L.set_level(L.LEVELS.DEBUG)

		local state1    = make_state("FIRST")
		local registry1 = make_registry()
		local llm1      = make_llm()

		local state2    = make_state("SECOND")
		local registry2 = make_registry()
		local llm2      = make_llm()

		-- Collect every WARNING line emitted during the two init() calls.
		local warn_lines = {}
		L.set_sink(function(line, variant)
			if variant == "warn" then
				warn_lines[#warn_lines + 1] = line
			end
		end)

		expander.init(state1, registry1, llm1)   -- legitimate — no WARN expected
		expander.init(state2, registry2, llm2)   -- duplicate — must emit one WARN

		L.set_sink(nil)

		helpers.assert_eq(#warn_lines, 1,
			"expected exactly one WARN from the duplicate init() call, got " .. tostring(#warn_lines))

		-- Confirm the message text matches the guard wording in the source.
		local line = warn_lines[1] or ""
		helpers.assert_true(
			line:find("more than once", 1, true) ~= nil or line:find("duplicate", 1, true) ~= nil,
			"WARN message should mention 'more than once' or 'duplicate', got: " .. line
		)
	end)


	helpers.it("first init() emits no WARN and leaves the module functional", function()
		local expander = fresh_expander()
		local L = require("infra.logger")
		L.set_level(L.LEVELS.DEBUG)

		local state1    = make_state("ONLY")
		local registry1 = make_registry()
		local llm1      = make_llm()

		local warn_lines = {}
		L.set_sink(function(line, variant)
			if variant == "warn" then
				warn_lines[#warn_lines + 1] = line
			end
		end)

		expander.init(state1, registry1, llm1)

		L.set_sink(nil)

		helpers.assert_eq(#warn_lines, 0,
			"first init() must not emit any WARN — got " .. tostring(#warn_lines))

		-- Module must be functional: try_expand must not crash and must bind buffer.
		state1.buffer = ""
		-- Called directly: this is the happy path after one clean init, so a raise
		-- is a plain bug and should fail with its own error.
		expander.try_expand("a", false)
		helpers.assert_eq(state1.buffer, "a",
			"buffer must be updated by try_expand after a successful init()")
	end)

end)
