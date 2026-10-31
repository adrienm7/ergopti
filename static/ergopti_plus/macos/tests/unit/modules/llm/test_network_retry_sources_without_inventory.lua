--- tests/unit/modules/llm/test_network_retry_sources_without_inventory.lua

--- ==============================================================================
--- MODULE: Network Policy Loads Without Its Inventory (network-retry-set-e)
--- DESCRIPTION:
--- network-retry.sh resolved the shared route inventory folder with a command
--- substitution in a plain assignment. Under `set -e`, which every installer and
--- the macOS build use, a missing folder ended the sourcing script at once with
--- exit 1 and no line saying why (found through the Sparkle feed fixture, a
--- partial checkout). Loading must survive, and the lookup that needs the
--- inventory is the step that refuses.
--- ==============================================================================

local helpers = require("tests.helpers")

local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end

local function command(text)
	local pipe = assert(io.popen("( " .. text .. " ) 2>&1; printf '\\n__STATUS__:%s' \"$?\"", "r"))
	local bytes = assert(pipe:read("*a"))
	assert(pipe:close())
	local status = assert(tonumber(bytes:match("__STATUS__:(%d+)%s*$")))
	return bytes:gsub("\n?__STATUS__:%d+%s*$", ""), status
end

helpers.describe("network policy without its inventory folder (network-retry-set-e)", function()
	helpers.it("a set -e caller survives loading it, and the lookup refuses", function()
		local root = os.tmpname()
		os.remove(root)
		root = root .. "-lone-policy"
		local policy = helpers.driver_root() .. "modules/llm/network-retry.sh"
		local script = "set -eu; source " .. quote(root .. "/network-retry.sh")
			.. "; echo loaded; if route_origins_for_client ollama; then echo found; else echo refused; fi"
		local output, status = command("mkdir -p " .. quote(root) .. " && cp " .. quote(policy) .. " "
			.. quote(root .. "/") .. " && env -u ROUTE_ORIGINS_FILE /bin/bash -c " .. quote(script))
		command("rm -rf " .. quote(root))
		helpers.assert_eq(status, 0, output)
		helpers.assert_true(output:find("loaded", 1, true) ~= nil, "loading must not end the caller: " .. output)
		helpers.assert_true(output:find("refused", 1, true) ~= nil, "the inventory lookup is what refuses")
	end)

	helpers.it("in the checkout it still finds the shared inventory", function()
		local policy = helpers.driver_root() .. "modules/llm/network-retry.sh"
		local output, status = command("env -u ROUTE_ORIGINS_FILE /bin/bash -c "
			.. quote("set -eu; source " .. quote(policy) .. "; route_origins_for_client ollama"))
		helpers.assert_eq(status, 0, output)
		helpers.assert_true(output:find("https://registry.ollama.ai", 1, true) ~= nil, output)
	end)
end)
