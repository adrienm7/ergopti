--- tests/unit/modules/keymap/test_llm_bridge_chain_delay.lua

--- ==============================================================================
--- MODULE: Regression — LLM-after-hotstring chain delay (F-MED-4)
--- DESCRIPTION:
--- update_preview() armed the chained-LLM timer with `tooltip_timeout +
--- HOTSTRING_CHAIN_OFFSET_SEC`. tooltip_timeout is derived from min_timeout, which
--- is only set by ENABLED preview rows; when previews are disabled (or the
--- matched group's show_tooltip=false) min_timeout is nil and tooltip_timeout
--- falls back to INFINITE_TOOLTIP_SEC (86400 s — the "never auto-dismiss a VISIBLE
--- tooltip" sentinel). The chain branch ran unconditionally of any_enabled, so it
--- armed the LLM timer for ~24 h and the chained prediction never appeared; each
--- further matching keystroke re-armed the same 24 h timer.
---
--- Fix: gate the chain delay on any_enabled — when nothing is shown there is no
--- tooltip to wait for, so fire after the short offset, never the INFINITE sentinel.
--- update_preview needs the full keymap/registry/engine/tooltip stack, so the root
--- cause is pinned at source level.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("llm_bridge: chain delay must not be the INFINITE tooltip sentinel when no preview is shown (F-MED-4)", function()
	local function read_src()
		local path = helpers.driver_root() .. "modules/keymap/llm_bridge.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "cannot open llm_bridge.lua at " .. tostring(path))
		local src = fh:read("*a"); fh:close()
		return src
	end

	helpers.it("computes the chain delay gated on any_enabled", function()
		local src = read_src()
		-- Accept the parenthesised clamped form `chain_delay = (any_enabled and ...`
		-- introduced by the F-M1 fix, as well as the original bare form.
		helpers.assert_true(
			src:find("chain_delay = (any_enabled", 1, true) ~= nil
				or src:find("chain_delay = any_enabled", 1, true) ~= nil,
			"the chain delay must be gated on any_enabled (short offset when no tooltip is shown)")
		helpers.assert_true(src:find("engine.start_timer(chain_delay)", 1, true) ~= nil,
			"start_timer must use the gated chain_delay")
	end)

	helpers.it("no longer arms the chain unconditionally with the (possibly INFINITE) tooltip_timeout", function()
		local src = read_src()
		helpers.assert_true(src:find("engine.start_timer(tooltip_timeout + HOTSTRING_CHAIN_OFFSET_SEC)", 1, true) == nil,
			"the chain timer must not be armed with tooltip_timeout directly (it is INFINITE_TOOLTIP_SEC when no row is enabled)")
	end)

	-- F-M1: an ENABLED preview row can still carry a 0 ms ("infinite") delay, so
	-- tooltip_timeout degenerates to INFINITE_TOOLTIP_SEC while any_enabled is true.
	-- The any_enabled gate alone (F-MED-4) did NOT cover this; the delay must also
	-- be clamped against the sentinel.
	helpers.it("clamps the chain delay against the INFINITE sentinel even when a row IS enabled (F-M1)", function()
		local src = read_src()
		helpers.assert_true(src:find("tooltip_timeout < INFINITE_TOOLTIP_SEC", 1, true) ~= nil,
			"chain_delay must guard against tooltip_timeout == INFINITE_TOOLTIP_SEC (a 0 ms enabled row)")
	end)
end)
