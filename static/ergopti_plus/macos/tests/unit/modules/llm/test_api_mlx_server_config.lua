--- tests/unit/modules/llm/test_api_mlx_server_config.lua

--- ==============================================================================
--- MODULE: api_mlx — MLX server address single-source-of-truth
--- DESCRIPTION:
--- Locks down the contract that the MLX server host/port live in ONE place
--- (_shared/modules/llm/mlx_server.json, loaded by api_mlx, overridable per-user) and are
--- exposed via getters, so the port is never hardcoded across api_mlx, the
--- models_manager_mlx launcher, and the init.lua boot cleanup. Before this, "8080"
--- was written by hand in ~20 places; changing the port meant hunting them all down.
---
--- FEATURES & RATIONALE:
--- 1. Contract, not value: asserts the getters exist and agree (base_url is built
---    from host+port) rather than pinning a specific port, so the test survives a
---    deliberate port change in the shared config.
--- 2. Dedicated default: with no config file and no override on the test box, the
---    getters must return Ergopti's dedicated default (127.0.0.1:3460) — NOT
---    mlx_lm.server's collision-prone 8080, which is the whole point of moving off it.
--- 3. Runtime override: set_port() must rebuild the base URL, reject out-of-range
---    values, and expose stable bounds + default-port getters for the menu layer.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["modules.llm.api_mlx"] = nil
local ApiMlx = require("modules.llm.api_mlx")

-- The dedicated default shipped in _shared/modules/llm/mlx_server.json and hardcoded as the
-- final fallback in api_mlx. Kept in sync with both; a regression that reverts the
-- default to 8080 fails here.
local DEDICATED_DEFAULT_PORT = 3460




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

	helpers.it("falls back to Ergopti's dedicated 127.0.0.1:3460 default (NOT 8080) when no config/override is present", function()
		-- The test box has no _shared/modules/llm/mlx_server.json reachable from hs.configdir
		-- and no hs.settings override, so the loader must fall back to the dedicated
		-- default rather than mlx_lm.server's collision-prone 8080.
		helpers.assert_eq(ApiMlx.get_host(), "127.0.0.1")
		helpers.assert_eq(ApiMlx.get_port(), DEDICATED_DEFAULT_PORT)
		helpers.assert_eq(ApiMlx.get_default_port(), DEDICATED_DEFAULT_PORT)
	end)
end)




-- =====================================================
-- =====================================================
-- ======= 2/ Runtime port override (set_port) =========
-- =====================================================
-- =====================================================

helpers.describe("api_mlx — runtime port override", function()
	helpers.it("exposes get_port_bounds and get_default_port", function()
		helpers.assert_eq(type(ApiMlx.get_port_bounds), "function")
		helpers.assert_eq(type(ApiMlx.get_default_port), "function")
		local lo, hi = ApiMlx.get_port_bounds()
		helpers.assert_eq(lo, 1024)
		helpers.assert_eq(hi, 65535)
	end)

	helpers.it("set_port applies a valid port and rebuilds the base URL", function()
		local ok = ApiMlx.set_port(54321)
		helpers.assert_true(ok, "set_port should accept an in-range port")
		helpers.assert_eq(ApiMlx.get_port(), 54321)
		helpers.assert_eq(ApiMlx.get_base_url(), "http://127.0.0.1:54321")
	end)

	helpers.it("set_port rejects out-of-range values and leaves the port unchanged", function()
		ApiMlx.set_port(54321)
		helpers.assert_true(not ApiMlx.set_port(80), "ports below 1024 must be rejected")
		helpers.assert_true(not ApiMlx.set_port(70000), "ports above 65535 must be rejected")
		helpers.assert_true(not ApiMlx.set_port("nope"), "non-numeric ports must be rejected")
		helpers.assert_eq(ApiMlx.get_port(), 54321)
	end)
end)




-- =====================================================
-- =====================================================
-- ======= 3/ Shared registry bounds ===================
-- =====================================================
-- =====================================================

local function require_with_registry_port(port)
	local Paths = require("infra.paths")
	local Storage = require("adapters.storage")
	local original_shared = Paths.shared
	local original_get = Storage.get
	local original_open = io.open
	local fixture_path = "/fixture/mlx_server.json"
	local previous_api = package.loaded["modules.llm.api_mlx"]

	local ok, result = xpcall(function()
		Paths.shared = function(relative)
			if relative == "modules/llm/mlx_server.json" then return fixture_path end
			return original_shared(relative)
		end
		Storage.get = function(key)
			if key == "llm.mlx_port" then return nil end
			return original_get(key)
		end
		io.open = function(path, mode)
			if path ~= fixture_path then return original_open(path, mode) end
			return {
				read = function()
					return string.format('{"host":"127.0.0.1","port":%s}', tostring(port))
				end,
				close = function() return true end,
			}
		end
		package.loaded["modules.llm.api_mlx"] = nil
		return require("modules.llm.api_mlx")
	end, debug.traceback)

	Paths.shared = original_shared
	Storage.get = original_get
	io.open = original_open
	package.loaded["modules.llm.api_mlx"] = previous_api
	return ok, result
end

helpers.describe("api_mlx — shared registry port bounds", function()
	helpers.it("accepts an in-range registry port", function()
		local ok, loaded = require_with_registry_port(54321)
		helpers.assert_eq(ok, true)
		helpers.assert_eq(loaded.get_port(), 54321)
	end)

	for _, port in ipairs({ 80, 70000 }) do
		helpers.it("fails fast for registry port " .. tostring(port), function()
			local ok, detail = require_with_registry_port(port)
			helpers.assert_eq(ok, false,
				"the shared registry must obey the same bounds as the user override")
			helpers.assert_contains(tostring(detail), "outside [1024, 65535]")
		end)
	end
end)
