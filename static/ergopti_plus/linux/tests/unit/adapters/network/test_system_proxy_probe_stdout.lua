--- tests/unit/adapters/network/test_system_proxy_probe_stdout.lua

--- ==============================================================================
--- MODULE: System Proxy Probe Stdout Is Its Receipt Alone
--- DESCRIPTION:
--- The native lookup child answers on stdout with exactly one JSON receipt,
--- which the parent decodes whole (adapters/system_proxy.lua). The curl
--- capability probe resolved its curl through owned_programs.path(), which in a
--- source run (no ERGOPTI_RUNTIME_PREFIX) logs the PATH mode once. The helper's
--- own package.path cannot load the shared logger, so the shim's print fallback
--- wrote that line to the child's stdout, ahead of the receipt. The parent then
--- refused every system-route lookup as proxy-receipt-invalid, so on a host
--- with no proxy variable the owned Ollama archive download never started.
---
--- ROOT CAUSE ENCODED:
--- The real helper, run as its own process in a source run with the curl
--- capability probe requested, prints one line that decodes as a receipt.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
local Paths = require("core.fs.engine.paths")
local Shell = require("adapters.shell_runner")
local uv = require("luv")

local helper = assert(package.searchpath("platform.network.system_proxy_probe", package.path))

--- Runs the real helper as a child of this interpreter and returns its stdout.
--- @param request table The packet written to the helper's stdin.
--- @return string output
local function run_helper(request)
	local input = os.tmpname()
	local file = assert(io.open(input, "wb"))
	file:write(Json.encode(request))
	file:close()
	local interpreter = assert(uv.exepath())
	-- Hermetic like a daemon-spawned child: no inherited Lua path can lend the
	-- helper a logger, and a source run has no private runtime prefix.
	local command = "cd / && env -u ERGOPTI_RUNTIME_PREFIX -u LUA_PATH -u LUA_PATH_5_1 " .. Shell.quote(interpreter) .. " " .. Shell.quote(helper)
		.. " " .. Shell.quote(assert(Paths.shared_root())) .. " < " .. Shell.quote(input) .. " 2>/dev/null"
	local pipe = assert(io.popen(command, "r"))
	local output = pipe:read("*a")
	pipe:close()
	os.remove(input)
	return output
end

helpers.describe("system proxy probe: stdout carries the receipt alone (proxy-probe-stdout)", function()
	helpers.it("a source run with the curl probe prints exactly one decodable receipt", function()
		local output = run_helper({ url = "https://github.com/ollama/ollama/releases/download/v0/x", probe_curl = true })
		local lines = {}
		for line in output:gmatch("[^\n]+") do lines[#lines + 1] = line end
		helpers.assert_eq(#lines, 1, "stdout must hold only the receipt, got: " .. output)
		local decoded, receipt = pcall(Json.decode, lines[1])
		helpers.assert_true(decoded and type(receipt) == "table" and type(receipt.ok) == "boolean",
			"the one line must be the receipt: " .. lines[1])
		helpers.assert_type(receipt.curl_capabilities, "table", "the curl probe ran")
	end)
end)

return true
