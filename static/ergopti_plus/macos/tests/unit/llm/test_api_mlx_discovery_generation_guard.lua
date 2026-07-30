--- tests/unit/llm/test_api_mlx_discovery_generation_guard.lua

--- ==============================================================================
--- MODULE: MLX discovery generation guard (F-MED-8)
--- DESCRIPTION:
--- Unlike api_mlx.lua's _warmup_gen and api_mlx_inference.lua's
--- _stream.generation, api_mlx_discovery.lua's M.discover() had no
--- generation/epoch guard. Its opportunistic background chat-route probe
--- (fired after the completions route resolves, explicitly documented as
--- outliving finish_discovery()) could silently overwrite a freshly-discovered
--- chat route cached by a NEWER discovery cycle started by an intervening
--- reset() (a model switch).
---
--- Fix: added a module-level _discovery_gen counter, bumped in M.reset();
--- M.discover() captures my_discovery_gen at the start of its probe chain and
--- every async callback that writes _completions_endpoint/_chat_endpoint or
--- calls finish_discovery re-checks it against the live _discovery_gen before
--- acting, discarding a stale write instead of corrupting the newer cycle's
--- cached routes.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Selected by a declaration unique to modules/llm/api_mlx_discovery.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function read_active_model_arg")
helpers.assert_true(src ~= nil, "modules/llm/api_mlx_discovery.lua source must be locatable")





-- ======================================================
-- ======================================================
-- ======= 1/ F-MED-8: discovery generation guard =======
-- ======================================================
-- ======================================================

helpers.describe("api_mlx_discovery.lua: discovery cycles carry a generation guard (F-MED-8)", function()

	helpers.it("declares a module-level _discovery_gen counter", function()
		helpers.assert_true(
			src:find("local _discovery_gen", 1, true) ~= nil,
			"api_mlx_discovery.lua must declare _discovery_gen counter (F-MED-8)"
		)
	end)

	helpers.it("M.reset() bumps _discovery_gen", function()
		local reset_pos = src:find("function M.reset()", 1, true)
		helpers.assert_true(reset_pos ~= nil, "api_mlx_discovery.lua must define M.reset() (F-MED-8)")
		local reset_body = src:sub(reset_pos, reset_pos + 600)
		helpers.assert_true(
			reset_body:find("_discovery_gen = _discovery_gen + 1", 1, true) ~= nil,
			"M.reset() must increment _discovery_gen so in-flight probes become stale (F-MED-8)"
		)
	end)

	helpers.it("M.discover() captures my_discovery_gen before dispatching probes", function()
		local discover_pos = src:find("function M.discover(", 1, true)
		helpers.assert_true(discover_pos ~= nil, "api_mlx_discovery.lua must define M.discover() (F-MED-8)")
		local discover_body = src:sub(discover_pos, discover_pos + 1500)
		helpers.assert_true(
			discover_body:find("local my_discovery_gen = _discovery_gen", 1, true) ~= nil,
			"M.discover() must capture local my_discovery_gen = _discovery_gen before the async probe chain (F-MED-8)"
		)
	end)

	helpers.it("the opportunistic background chat probe re-checks the generation before writing _chat_endpoint", function()
		-- This is the exact bug the finding describes: the comment right above it
		-- explicitly says the probe can outlive finish_discovery() and fire after
		-- a reset() for a new model — the write must be gen-guarded.
		local bg_probe_pos = src:find(
			"Only update the cached URL", 1, true)
		helpers.assert_true(bg_probe_pos ~= nil,
			"api_mlx_discovery.lua must retain the opportunistic background chat-probe comment (F-MED-8 context)")
		local bg_probe_body = src:sub(bg_probe_pos, bg_probe_pos + 600)
		helpers.assert_true(
			bg_probe_body:find("my_discovery_gen == _discovery_gen", 1, true) ~= nil,
			"the background chat-route probe must check my_discovery_gen == _discovery_gen before writing _chat_endpoint (F-MED-8)"
		)
	end)

	helpers.it("the completions-probe callback discards a stale (superseded) result", function()
		local discover_pos = src:find("function M.discover(", 1, true)
		local completions_cb_pos = src:find('probe_one(COMPLETIONS_CANDIDATES, 1, nil, "completions"', discover_pos, true)
		helpers.assert_true(completions_cb_pos ~= nil,
			"M.discover() must probe COMPLETIONS_CANDIDATES (F-MED-8 context)")
		local cb_body = src:sub(completions_cb_pos, completions_cb_pos + 400)
		helpers.assert_true(
			cb_body:find("my_discovery_gen ~= _discovery_gen", 1, true) ~= nil,
			"the completions-probe callback must discard a stale result via my_discovery_gen ~= _discovery_gen (F-MED-8)"
		)
	end)
end)
