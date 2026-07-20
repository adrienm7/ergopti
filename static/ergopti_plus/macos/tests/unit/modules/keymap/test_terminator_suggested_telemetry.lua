--- tests/unit/modules/keymap/test_terminator_suggested_telemetry.lua

--- ==============================================================================
--- MODULE: Regression — no zero-argument log_hotstring_suggested from the expander
--- DESCRIPTION:
--- Audit finding G2/G4. try_terminator_expand fired
---   pcall(keylogger.log_hotstring_suggested)
--- with ZERO arguments against the real four-parameter signature
---   M.log_hotstring_suggested(app_name, trigger, replacement, h_type)
--- so every terminator-fired hotstring double-counted hs_suggested, wrote
--- nil-trigger rows that poison any per-trigger breakdown, and did so
--- unconditionally — even in ignored windows and with tooltips disabled,
--- recording "suggestions shown" for suggestions that were never rendered. It
--- also cost two synchronous write+flush pairs inside the HID callback.
---
--- The LEGITIMATE call already exists with all four arguments in
--- llm_bridge.update_preview, at the moment the tooltip is actually rendered.
--- The acceptance side is covered by log_hotstring. So the fix is to delete the
--- call outright, not to "fix up" its arguments.
---
--- This test asserts on the ARGUMENT COUNT of every recorded invocation rather
--- than on the absence of a source line, so re-adding the call anywhere in the
--- expansion path — with any argument list that omits the trigger — fails here.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local TRIGGER     = "trgx"
local REPLACEMENT = "REPLACEMENTVALUE"
local TERMINATOR  = " "


--- Installs a keylogger stub recording the arity and arguments of every
--- log_hotstring_suggested call. Must run BEFORE the expander loads.
--- @return table Recorder with `suggested` and `accepted` lists.
local function install_keylogger_recorder()
	local rec = { suggested = {}, accepted = {} }
	package.loaded["modules.keylogger"] = {
		log_hotstring_suggested = function(...)
			table.insert(rec.suggested, { argc = select("#", ...), args = { ... } })
		end,
		log_hotstring = function(trigger, replacement)
			table.insert(rec.accepted, { trigger = trigger, replacement = replacement })
		end,
		notify_synthetic = function() end,
		set_buffer       = function() end,
	}
	return rec
end


helpers.describe("terminator expansion records no zero-argument suggestion event", function()
	helpers.it("fires the expansion without any argument-less log_hotstring_suggested call", function()
		local rec = install_keylogger_recorder()

		local State    = helpers.load_with_stubs("modules.keymap.state")
		local Registry = helpers.load_with_stubs("modules.keymap.registry")
		local Expander = helpers.load_with_stubs("modules.keymap.expander")

		local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, { autocorrection = 0.3 })
		Registry.init(state)

		-- Make the terminator deterministic without disturbing the real mapping
		-- construction: everything else still resolves through the real Registry.
		local registry_proxy = setmetatable({
			is_terminator          = function(c) return c == TERMINATOR end,
			terminator_is_consumed = function() return false end,
		}, { __index = Registry })

		Expander.init(state, registry_proxy, {
			update_preview  = function() end,
			get_llm_enabled = function() return false end,
			start_timer     = function() end,
		})

		-- A real, terminator-triggered mapping (auto_expand = false).
		Registry.add(TRIGGER, REPLACEMENT, { is_case_sensitive = true })
		local m
		for _, entry in ipairs(state.mappings) do
			if entry.trigger == TRIGGER then m = entry end
		end
		helpers.assert_not_nil(m, "the terminator mapping must be registered")

		-- Seed the buffer with trigger + terminator, exactly as the keydown loop
		-- would have it at the moment try_terminator_expand is consulted.
		state.buffer = TRIGGER .. TERMINATOR
		local fired = Expander.try_terminator_expand(m, TERMINATOR, 1, false)
		helpers.assert_eq(fired, true, "the terminator expansion must fire")

		-- THE load-bearing assertion. Pre-fix exactly one such call is recorded.
		for i, call in ipairs(rec.suggested) do
			helpers.assert_true(call.argc ~= 0, string.format(
				"log_hotstring_suggested invocation #%d was made with ZERO arguments against a "
				.. "four-parameter signature (app_name, trigger, replacement, h_type) — it "
				.. "double-counts hs_suggested and writes nil-trigger rows", i))
		end

		-- The acceptance-side telemetry must be untouched by the removal.
		helpers.assert_eq(#rec.accepted, 1,
			"log_hotstring must still record the accepted expansion")
		helpers.assert_eq(rec.accepted[1].trigger, TRIGGER)
		helpers.assert_eq(rec.accepted[1].replacement, REPLACEMENT)
	end)
end)
