--- tests/unit/modules/shortcuts/system_actions/test_wrap_decisions.lua

--- ==============================================================================
--- MODULE: System Action Regression Tests
--- DESCRIPTION:
--- Exercises system actions while preserving exact native and dependency ownership.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.system_actions_fixture")
local load_system = fixture.load_system
local with_fixture = fixture.with_fixture

helpers.describe("shortcuts.actions.system: wrap_event_decision", function()
	local PAIRS = { ["("] = { left = "(", right = ")" }, [")"] = { left = "(", right = ")" } }

	helpers.it("wraps an AltGr-typed symbol when a selection exists (alt must not block)", function()
		with_fixture(function()
			package.loaded["infra.keycodes"] = nil
			package.loaded["modules.shortcuts.actions.system"] = nil
			package.loaded["adapters.timer_scheduler"] = nil
			local sys = load_system()
			helpers.assert_eq(sys.wrap_event_decision({ alt = true }, "(", PAIRS, true), "wrap")
		end)
	end)

	helpers.it("passes the symbol through when no selection is readable", function()
		with_fixture(function()
			package.loaded["infra.keycodes"] = nil
			package.loaded["modules.shortcuts.actions.system"] = nil
			package.loaded["adapters.timer_scheduler"] = nil
			local sys = load_system()
			-- The regression that lost the character in VS Code: pair matches but the
			-- app exposes no selection, so we must NOT suppress the keystroke.
			helpers.assert_eq(sys.wrap_event_decision({ alt = true }, "(", PAIRS, false), "passthrough")
		end)
	end)

	helpers.it("never treats Cmd/Ctrl combos as wrap input", function()
		with_fixture(function()
			package.loaded["infra.keycodes"] = nil
			package.loaded["modules.shortcuts.actions.system"] = nil
			package.loaded["adapters.timer_scheduler"] = nil
			local sys = load_system()
			helpers.assert_eq(sys.wrap_event_decision({ cmd = true }, "(", PAIRS, true), "passthrough")
			helpers.assert_eq(sys.wrap_event_decision({ ctrl = true }, "(", PAIRS, true), "passthrough")
		end)
	end)

	helpers.it("passes through characters that are not configured wrap symbols", function()
		with_fixture(function()
			package.loaded["infra.keycodes"] = nil
			package.loaded["modules.shortcuts.actions.system"] = nil
			package.loaded["adapters.timer_scheduler"] = nil
			local sys = load_system()
			helpers.assert_eq(sys.wrap_event_decision({}, "x", PAIRS, true), "passthrough")
		end)
	end)

	helpers.it("passes through empty / nil characters without crashing", function()
		with_fixture(function()
			package.loaded["infra.keycodes"] = nil
			package.loaded["modules.shortcuts.actions.system"] = nil
			package.loaded["adapters.timer_scheduler"] = nil
			local sys = load_system()
			helpers.assert_eq(sys.wrap_event_decision({}, "", PAIRS, true), "passthrough")
			helpers.assert_eq(sys.wrap_event_decision(nil, "(", PAIRS, true), "wrap")
		end)
	end)

	helpers.it("wraps a plain (no-modifier) wrap symbol with a selection", function()
		with_fixture(function()
			package.loaded["infra.keycodes"] = nil
			package.loaded["modules.shortcuts.actions.system"] = nil
			package.loaded["adapters.timer_scheduler"] = nil
			local sys = load_system()
			helpers.assert_eq(sys.wrap_event_decision({}, "(", PAIRS, true), "wrap")
		end)
	end)
end)
