--- tests/unit/adapters/field_check_ports/test_fetch_pac_port.lua

--- ==============================================================================
--- MODULE: Field Check PAC Download Port (macOS)
--- DESCRIPTION:
--- The fetch_pac port logs why a PAC download failed, the only clue a field
--- report carries, but never the PAC address: the field report of 2026-10-27
--- 19:47 carried the company PAC URL because the transport's error text ends
--- with the request URL.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "adapters.field_check_ports", "adapters.http_client" }
local PAC = "http://pac.private-company.invalid/company-proxy.pac"

--- Runs the port over a scripted transport result.
--- @param result table What the HTTP client answers.
--- @return table warnings, any status, any body
local function run(result)
	local warnings, status, body = {}, nil, nil
	helpers.with_stub_scope(MODULES, function()
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, format, ...) warnings[#warnings + 1] = string.format(format, ...) end
		package.loaded["infra.logger"] = logger
		package.loaded["adapters.http_client"] = {
			new = function() return { get = function(_, _, callback) callback(result) end } end,
		}
		package.loaded["adapters.field_check_ports"] = nil
		require("adapters.field_check_ports").new().fetch_pac(PAC, function(s, b) status, body = s, b end)
	end)
	return warnings, status, body
end

helpers.describe("network check PAC download port", function()
	helpers.it("logs the transport reason of a failed download without the PAC address", function()
		local warnings, status = run({ status = 0, error = "Network request failed: Connection failed: "
			.. "A server with the specified hostname could not be found. - " .. PAC })
		helpers.assert_eq(status, 0)
		helpers.assert_eq(warnings, { "PAC download failed: Network request failed: Connection failed: "
			.. "A server with the specified hostname could not be found." })
		helpers.assert_eq(warnings[1]:find("private-company", 1, true), nil)
	end)

	helpers.it("hands a downloaded PAC to the check without logging", function()
		local warnings, status, body = run({ status = 200, body = "function FindProxyForURL() {}" })
		helpers.assert_eq(warnings, {})
		helpers.assert_eq(status, 200)
		helpers.assert_eq(body, "function FindProxyForURL() {}")
	end)
end)
