--- tests/unit/adapters/network/test_system_proxy_probe_policy_limits.lua

--- ==============================================================================
--- MODULE: System Proxy Probe Policy Limits
--- DESCRIPTION:
--- The native lookup child bounds the answer it returns (selections and bytes
--- per selection) by the shared proxy policy, the same limits the parent applies
--- to the receipt. It used to type 128 and 65536 itself, so a policy change
--- left the child on the old numbers. These cases run the actual helper:
--- a policy without the limits is a refusal, and the source holds no copy.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Paths = require("infra.paths")
local helper = helpers.driver_root() .. "/platform/network/system_proxy_probe.lua"

--- Runs the helper against a shared root and returns its one receipt.
--- @param root string Shared root handed as the helper's argument.
--- @return table receipt
local function run(root)
	local output = ""
	local saved = { stdin = io.stdin, stdout = io.stdout, arguments = arg, ffi = package.loaded.ffi }
	package.loaded.ffi = { cdef = function() error("independent unavailable native ABI") end }
	io.stdin = { read = function() return Json.encode({ url = "https://corporate.invalid/private" }) end }
	io.stdout = {
		write = function(_, ...) for _, value in ipairs({ ... }) do output = output .. value end end,
		flush = function() return true end,
	}
	arg = { [1] = root }
	local ok, err = pcall(dofile, helper)
	io.stdin, io.stdout, arg, package.loaded.ffi = saved.stdin, saved.stdout, saved.arguments, saved.ffi
	if not ok then error(err) end
	return Json.decode(output)
end

--- A scratch shared root holding the given policy text.
--- @param policy string
--- @return string root
local function root_with(policy)
	local root = os.tmpname()
	os.remove(root)
	assert(os.execute("mkdir -p '" .. root .. "/modules/network'"))
	local file = assert(io.open(root .. "/modules/network/proxy_policy.json", "wb"))
	file:write(policy)
	file:close()
	return root
end

helpers.describe("system proxy probe: selection limits come from the shared policy (proxy-policy-single-source)", function()
	helpers.it("refuses to look up when the policy carries no valid limits", function()
		for _, policy in ipairs({ "{}", '{"max_selections":0,"max_proxy_bytes":65536}', '{"max_selections":128}', "not json" }) do
			local root = root_with(policy)
			local receipt = run(root)
			os.execute("rm -rf '" .. root .. "'")
			helpers.assert_eq(receipt.ok, false)
			helpers.assert_eq(receipt.error, "proxy-policy-unavailable", policy)
		end
	end)

	helpers.it("proceeds to the native lookup with the shipped policy", function()
		local receipt = run(assert(Paths.shared_root()))
		helpers.assert_eq(receipt.error, "proxy-native-unavailable", "the policy was admitted; only the modelled native ABI is absent")
	end)

	helpers.it("holds no typed copy of the policy's limits", function()
		local file = assert(io.open(helper, "rb"))
		local source = file:read("*a")
		file:close()
		helpers.assert_nil(source:find("#values >= 128", 1, true))
		helpers.assert_nil(source:find("#value > 65536 or value:find", 1, true))
		helpers.assert_not_nil(source:find("limits.max_selections", 1, true))
		helpers.assert_not_nil(source:find("limits.max_proxy_bytes", 1, true))
	end)
end)

return true
