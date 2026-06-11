--- tests/unit/modules/llm/test_api_mlx_server_config.lua

--- ==============================================================================
--- MODULE: api_mlx — MLX server address single-source-of-truth
--- DESCRIPTION:
--- Locks down the contract that the MLX server host/port live in ONE place
--- (shared/llm/mlx_server.json, loaded by api_mlx) and are exposed via getters,
--- so the port is never hardcoded across api_mlx, the models_manager_mlx
--- launcher, and the init.lua boot cleanup. Before this, "8080" was written by
--- hand in ~20 places; changing the port meant hunting them all down.
---
--- FEATURES & RATIONALE:
--- 1. Contract, not value: asserts the getters exist and agree (base_url is built
---    from host+port) rather than pinning a specific port, so the test survives a
---    deliberate port change in the shared config.
--- 2. Fallback safety: with no config file on the test box, the getters must
---    still return a usable loopback address (mlx_lm.server's 127.0.0.1:8080
---    default) rather than nil.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["modules.llm.api_mlx"] = nil
local ApiMlx = require("modules.llm.api_mlx")




-- =====================================================
-- =====================================================
-- ======= 1/ Server-address getters ===================
-- =====================================================
-- =====================================================

helpers.describe("api_mlx — MLX server address getters", function()
	helpers.it("exposes get_port / get_host / get_base_url", function()
		helpers.assert_eq(type(ApiMlx.get_port), "function")
		helpers.assert_eq(type(ApiMlx.get_host), "function")
		helpers.assert_eq(type(ApiMlx.get_base_url), "function")
	end)

	helpers.it("returns a positive integer port and a non-empty loopback host", function()
		local port = ApiMlx.get_port()
		local host = ApiMlx.get_host()
		helpers.assert_eq(type(port), "number")
		helpers.assert_true(port > 0 and math.floor(port) == port, "port must be a positive integer")
		helpers.assert_eq(type(host), "string")
		helpers.assert_true(host ~= "", "host must be non-empty (loopback)")
	end)

	helpers.it("builds base_url consistently from host and port", function()
		local expected = string.format("http://%s:%d", ApiMlx.get_host(), ApiMlx.get_port())
		helpers.assert_eq(ApiMlx.get_base_url(), expected)
	end)

	helpers.it("falls back to mlx_lm.server's 127.0.0.1:8080 default when no config is present", function()
		-- The test box has no shared/llm/mlx_server.json reachable from hs.configdir,
		-- so the loader must fall back rather than return nil/0.
		helpers.assert_eq(ApiMlx.get_host(), "127.0.0.1")
		helpers.assert_eq(ApiMlx.get_port(), 8080)
	end)
end)
