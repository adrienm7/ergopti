--- tests/meta/lua_safety/test_api_mlx_pgid_pending_timeout.lua

--- ==============================================================================
--- MODULE: MLX PGID-pending timeout (meta)
--- DESCRIPTION:
--- api_mlx.lua arms a 15 second timeout so a crashed server cannot leave the PGID pending forever.
--- Source-scan guard split out of the audit-named regression file it came from.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

helpers.describe("modules/llm/api_mlx.lua: PGID-pending safety timeout (audit-v5)", function()

	helpers.it("declares _pgid_pending_timeout variable", function()
		local src = read_source("local function read_user_port_override") -- modules/llm/api_mlx.lua
		helpers.assert_true(
			src:find("_pgid_pending_timeout", 1, true) ~= nil,
			"api_mlx.lua must declare _pgid_pending_timeout for the safety-timeout handle")
	end)

	helpers.it("reset_endpoints arms the canonical 15-second PGID timeout", function()
		local src = read_source("local function read_user_port_override") -- modules/llm/api_mlx.lua
		helpers.assert_true(
			src:find("local PGID_PENDING_TIMEOUT_SEC%s*=%s*15%.0", 1, false) ~= nil,
			"api_mlx.lua must keep the canonical PGID-pending timeout at 15 seconds")
		-- Find the reset_endpoints function body
		local idx = src:find("function M%.reset_endpoints%(", 1, false)
		helpers.assert_true(idx ~= nil, "reset_endpoints must exist in api_mlx.lua")
		-- Extract up to the closing `end` of that function
		local rest = src:sub(idx)
		local _, stop = rest:find("\nend\n")
		local body = stop and rest:sub(1, stop) or rest
		helpers.assert_true(
			body:find("TimerScheduler%.after%(PGID_PENDING_TIMEOUT_SEC", 1, false) ~= nil,
			"reset_endpoints must arm its PGID-pending safety timeout from the canonical constant")
	end)

	helpers.it("timeout callback clears _server_pgid_pending", function()
		local src = read_source("local function read_user_port_override") -- modules/llm/api_mlx.lua
		local idx = src:find("function M%.reset_endpoints%(", 1, false)
		local rest = src:sub(idx)
		local _, stop = rest:find("\nend\n")
		local body = stop and rest:sub(1, stop) or rest
		helpers.assert_true(
			body:find("_server_pgid_pending%s*=%s*false", 1, false) ~= nil,
			"reset_endpoints timeout must set _server_pgid_pending = false on expiry")
	end)

end)
