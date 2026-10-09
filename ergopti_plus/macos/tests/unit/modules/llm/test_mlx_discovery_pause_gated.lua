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
--- A whole subsystem outside the pause reactor. A paused refusal must answer
--- through its boolean return without re-entering the warmup callback: that
--- callback calls warmup() again and used to recurse while PAUSED.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("api_mlx_discovery: paused means a non-reentrant refusal", function()

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

		helpers.assert_eq(D.discover(function() end), false)

		helpers.assert_eq(posts, 0,
			"a paused script must not POST inference probes at the MLX server")
	end)

	helpers.it("does not re-enter the rejected caller synchronously", function()
		local D = load_gated(true)
		local answered = false
		local accepted = D.discover(function() answered = true end)

		helpers.assert_eq(accepted, false,
			"the return value must expose that paused discovery acquired no continuation")
		helpers.assert_eq(answered, false,
			"the rejected callback must remain inert instead of recursively re-entering warmup")
	end)

	helpers.it("is not a blanket mute — an unpaused script still starts discovery", function()
		local D = load_gated(false)
		-- This case exists so the two above cannot pass against a discover() that
		-- never runs. Called directly, and asserting the exact acquisition answer.
		local started = D.discover(function() end)
		helpers.assert_eq(started, true,
			"an unpaused discover() must commit one discovery continuation")
	end)

end)
