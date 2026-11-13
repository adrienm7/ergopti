--- tests/unit/core/network/adapters/test_system_proxy_probe_policy_limits.lua

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
local Json = require("core.text.engine.json")
local Paths = require("core.fs.engine.paths")
local helper = helpers.driver_root() .. "/core/network/adapters/system_proxy_probe.lua"

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

-- The policy the helper reads, relative to the shared root.
local POLICY = "core/network/data/proxy_policy.json"

--- Mirrors the real shared tree into `fake`: every entry is linked, except the
--- folders on the way to `relative`, which are made, and `relative` itself, so
--- the helper finds its own modules wherever the layout puts them.
local function shadow(real, fake, relative)
	local uv = require("luv")
	assert(uv.fs_mkdir(fake, 448))
	local head, rest = relative:match("^([^/]+)/(.+)$")
	local scanner = assert(uv.fs_scandir(real))
	while true do
		local name = uv.fs_scandir_next(scanner)
		if not name then break end
		if name == head then shadow(real .. "/" .. name, fake .. "/" .. name, rest)
		elseif head or name ~= relative then assert(uv.fs_symlink(real .. "/" .. name, fake .. "/" .. name)) end
	end
end

--- A scratch shared root holding the given policy text.
--- @param policy string
--- @return string root
local function root_with(policy)
	local root = os.tmpname()
	os.remove(root)
	shadow(assert(Paths.shared_root()), root, POLICY)
	local file = assert(io.open(root .. "/" .. POLICY, "wb"))
	file:write(policy)
	file:close()
	return root
end

helpers.describe("system proxy probe: selection limits come from the shared policy (proxy-policy-single-source)", function()
	helpers.it("proxy-policy-reader: closes and refuses an exceptional native read", function()
		local previous = package.loaded["core.network.engine.proxy_policy"]
		local ok, failure = pcall(function()
			for _, method in ipairs({ "load", "override_setting" }) do
				local closed = 0
				local reader = { open_source = function() return {
					read = function() error("controlled read failure") end,
					close = function() closed = closed + 1; return true end,
				} end }
				local binding = helpers.load_module_with_dependency("core.network.engine.proxy_policy", "core.fs.engine.regular_file_reader", reader)
				local called, result, reason = pcall(binding[method])
				helpers.assert_true(called, "read failure must return a refusal")
				helpers.assert_nil(result)
				helpers.assert_eq(reason, method == "load" and "proxy-policy-unavailable" or "proxy-override-unavailable")
				helpers.assert_eq(closed, 1, "the acquired stream must be closed")
			end
		end)
		package.loaded["core.network.engine.proxy_policy"] = previous
		if not ok then error(failure, 0) end
	end)
	helpers.it("proxy-policy-single-source: refuses a valid prefix of an oversized policy", function()
		local prefix = '{"max_selections":128,"max_proxy_bytes":65536}'
		local root = root_with(prefix .. string.rep(" ", 32769 - #prefix) .. "not-json")
		local receipt = run(root)
		os.execute("rm -rf '" .. root .. "'")
		helpers.assert_eq(receipt.error, "proxy-policy-unavailable", "a truncated prefix cannot admit a corrupt policy")
	end)
	helpers.it("proxy-policy-single-source: a FIFO policy produces an immediate refusal", function()
		local root = root_with("{}")
		local path = root .. "/" .. POLICY
		os.remove(path)
		local Shell = require("adapters.shell_runner")
		local quote = Shell.quote
		assert(os.execute("mkfifo " .. quote(path)))
		local executable = assert(require("luv").exepath())
		local command = "printf '%s' " .. quote(Json.encode({ url = "https://corporate.invalid/private" }))
			.. " | timeout 2 " .. quote(executable) .. " " .. quote(helper) .. " " .. quote(root)
		local pipe = assert(io.popen(command, "r"))
		local output = pipe:read("*a")
		pipe:close()
		os.execute("rm -rf " .. quote(root))
		local ok, receipt = pcall(Json.decode, output)
		helpers.assert_true(ok and type(receipt) == "table", "the helper must return a receipt without waiting on the FIFO")
		helpers.assert_eq(receipt.error, "proxy-policy-unavailable")
	end)

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
