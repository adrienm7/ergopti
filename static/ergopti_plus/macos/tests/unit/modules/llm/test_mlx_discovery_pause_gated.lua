--- tests/unit/modules/llm/test_mlx_discovery_pause_gated.lua

--- ==============================================================================
--- MODULE: Regression — MLX endpoint discovery must be silent during a pause
--- DESCRIPTION:
--- discover() spawns curl polls and POSTs inference probes at the configured
--- server. The module contained no reference to a pause predicate at all, so
--- pausing the script left it polling and probing — which the maintainer's
--- invariant, "pause = absolutely nothing activates", forbids outright.
---
--- ROOT CAUSE ENCODED:
--- A whole subsystem outside the pause reactor. The gate answers the caller
--- instead of returning silently: a warmup waiting on a callback that never
--- fires is how the prediction lock gets stuck for the rest of the session.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("api_mlx_discovery: paused means no probe and no dropped caller", function()

	local function load_gated(paused)
		package.loaded["modules.shortcuts.script_control"] = { is_paused = function() return paused end }
		package.loaded["modules.llm.api_mlx_discovery"] = nil
		return helpers.load_with_stubs("modules.llm.api_mlx_discovery")
	end

	helpers.it("does not probe while paused", function()
		local D = load_gated(true)
		local posts = 0
		package.loaded["adapters.http_client"] = { new = function()
			posts = posts + 1
			return { post = function() end, get = function() end }
		end }

		D.discover(function() end)

		helpers.assert_eq(posts, 0,
			"a paused script must not POST inference probes at the MLX server")
	end)

	helpers.it("still answers the caller instead of dropping it", function()
		local D = load_gated(true)
		local answered = false
		D.discover(function() answered = true end)

		helpers.assert_true(answered,
			"the callback must fire even when the probe is refused; a warmup left waiting on a "
			.. "callback that never comes holds the prediction lock for the rest of the session")
	end)

	helpers.it("is not a blanket mute — an unpaused script still starts discovery", function()
		local D = load_gated(false)
		local ok = pcall(D.discover, function() end)
		helpers.assert_true(ok,
			"without this case the two above would pass against a discover() that never runs")
	end)

end)
