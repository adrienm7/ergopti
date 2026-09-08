--- tests/unit/modules/shortcuts/system_actions/test_selection_cache.lua

--- ==============================================================================
--- MODULE: System Action Regression Tests
--- DESCRIPTION:
--- Exercises system actions while preserving exact native and dependency ownership.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.system_actions_fixture")
local load_system = fixture.load_system
local with_fixture = fixture.with_fixture
local as_physical = fixture.as_physical
local extend_contract = fixture.extend_contract
local fresh_hs_contract = fixture.fresh_hs_contract

helpers.describe("shortcuts.actions.system: bind_wrap_text_if_selected AX cache (shortcuts-wrap-ax-uncached regression)", function()

	-- Builds a fresh system module with hs.eventtap.new stubbed to capture the wrap
	-- callback, hs.timer.secondsSinceEpoch stubbed to a controllable fake clock, and
	-- modules.shortcuts.actions.text's read_ax_selection replaced with a call counter.
	-- @param selection string|nil What read_ax_selection returns. nil is the COMMON
	--   real-world result (nothing selected, or an app hiding AXSelectedText such as
	--   VS Code/Electron) and was the case the original spy could not express.
	local function make_sys_with_ax_spy(selection)
		if selection == nil then selection = "selected text" end
		if selection == "" then selection = nil end
		package.loaded["infra.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil
		package.loaded["adapters.timer_scheduler"] = nil
		package.loaded["modules.shortcuts.actions.text"]   = nil
		package.loaded["adapters.synthetic_input"] = nil
		package.loaded["adapters.event_provenance"] = nil

		local ax_call_count = 0
		local clock = { now = 1000 }

		-- Stub text.lua fully (system.lua only needs read_ax_selection + WRAP_PAIRS +
		-- wrap_selection for this path) so the real AX-dependent implementation is
		-- never exercised — we only care about call-count caching behaviour here.
		package.loaded["modules.shortcuts.actions.text"] = {
			WRAP_PAIRS = { ["("] = { left = "(", right = ")" } },
			read_ax_selection = function()
				ax_call_count = ax_call_count + 1
				return selection
			end,
			wrap_selection = function() return true end,
		}

		local captured = { cb = nil }
		local contract = fresh_hs_contract()
		local eventtap = extend_contract(contract.eventtap, {
			new = function(_types, cb)
				captured.cb = cb
				local tap = { enabled = false }
				function tap:start() self.enabled = true; return self end
				function tap:stop() self.enabled = false; return self end
				function tap:isEnabled() return self.enabled end
				return tap
			end,
		})
		local timer = extend_contract(contract.timer, {
			secondsSinceEpoch = function() return clock.now end,
		})
		local sys = load_system({
			eventtap = eventtap,
			timer    = timer,
		})

		sys.bind_wrap_text_if_selected(nil)
		local function invoke(event)
			return captured.cb(event)
		end
		return sys, captured, clock, function() return ax_call_count end, invoke, _G.hs
	end

	-- A fake keyDown event typing the wrap symbol "(" with no modifiers.
	local function fake_wrap_key_event()
		return as_physical({
			getFlags      = function() return {} end,
			getCharacters = function() return "(" end,
		})
	end

	helpers.it("N rapid wrap-key presses within the TTL trigger at most 1 real AX call", function()
		with_fixture(function()
			local _sys, captured, _clock, get_count, invoke = make_sys_with_ax_spy()
			helpers.assert_true(type(captured.cb) == "function", "bind_wrap_text_if_selected must register an eventtap callback")

			local REPEAT_COUNT = 10
			for _ = 1, REPEAT_COUNT do
				invoke(fake_wrap_key_event())
			end

			helpers.assert_eq(get_count(), 1,
				string.format("%d rapid wrap-key presses must trigger at most 1 real read_ax_selection() call", REPEAT_COUNT))
		end)
	end)

	helpers.it("a press after the TTL window elapses triggers a second real AX call", function()
		with_fixture(function()
			local _sys, _captured, clock, get_count, invoke = make_sys_with_ax_spy()

			invoke(fake_wrap_key_event())
			helpers.assert_eq(get_count(), 1, "first press must call read_ax_selection")

			clock.now = clock.now + 0.05  -- still within the TTL window
			invoke(fake_wrap_key_event())
			helpers.assert_eq(get_count(), 1, "a press within the TTL window must reuse the cached selection")

			clock.now = clock.now + 1.0  -- past the TTL window
			invoke(fake_wrap_key_event())
			helpers.assert_eq(get_count(), 2, "a press after the TTL window must trigger a fresh AX call")
		end)
	end)

	-- Regression: freshness was keyed on the cached VALUE
	-- (`_wrap_ax_selection_cache ~= nil`), so a nil selection was never cached and
	-- every wrap-key press re-paid both synchronous cross-process AX calls inline on
	-- the CGEventTap thread. nil is the COMMON result — nothing selected, or an app
	-- that hides AXSelectedText — so the cache was effectively inert exactly when it
	-- mattered. Same defect and same fix as infra/vscode_bridge.lua (3e403b254), whose
	-- sibling site this is. The spy above could not express it: it hardcoded a
	-- positive selection.
	helpers.it("N rapid presses with NO selection also trigger at most 1 real AX call", function()
		with_fixture(function()
			local _sys, _captured, _clock, get_count, invoke = make_sys_with_ax_spy("")

			local REPEAT_COUNT = 10
			for _ = 1, REPEAT_COUNT do
				invoke(fake_wrap_key_event())
			end

			helpers.assert_eq(get_count(), 1,
				string.format("%d rapid wrap-key presses with nothing selected must still trigger at "
					.. "most 1 real read_ax_selection() call — a negative result must be cached like "
					.. "any other, or the cache is inert in the most common case", REPEAT_COUNT))
		end)
	end)
end)
