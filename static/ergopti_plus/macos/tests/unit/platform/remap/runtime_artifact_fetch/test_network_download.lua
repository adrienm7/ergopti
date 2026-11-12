--- tests/unit/platform/remap/runtime_artifact_fetch/test_network_download.lua

--- ==============================================================================
--- MODULE: Remap Engine Download Route
--- DESCRIPTION:
--- The owned runtime artifact, the VirtualHIDDevice package and the Karabiner
--- DMG ran /usr/bin/curl with the inherited Hammerspoon environment, which holds
--- no proxy (NET-001). The route command must source the shared system network
--- policy for the `karabiner` origins of route_origins.json, exec curl with its
--- arguments, and name a refused route by its shared managed network class.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "adapters.file_system", "modules.llm.network_env", "modules.llm.opaque_network_admission",
	"platform.remap.network_download" }

--- Loads the route over the real shared files.
--- @param body function Receives the module.
local function with_route(body)
	local saved = {}
	for _, name in ipairs(MODULES) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local function read(path)
		local file = io.open(path, "rb")
		if not file then return nil end
		local bytes = file:read("*a")
		file:close()
		return bytes
	end
	package.loaded["adapters.file_system"] = setmetatable({
		exists = function(path) local file = io.open(path, "rb"); if file then file:close() end; return file ~= nil end,
		read = read,
		read_with_status = function(path)
			local bytes = read(path)
			return bytes, bytes and "ok" or "missing"
		end,
	}, { __index = saved["adapters.file_system"] })
	local ok, err = pcall(function() body(require("platform.remap.network_download")) end)
	for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("remap download network route (net-001-remap-route)", function()
	helpers.it("runs curl behind the system network policy for GitHub's release origins", function()
		with_route(function(Route)
			local executable, args, describe = Route.command("REMAP-RUNTIME", { "-L", "--proto", "=https", "https://github.com/x" })
			helpers.assert_eq(executable, "/bin/sh", tostring(args))
			helpers.assert_eq(args[1], "-c")
			helpers.assert_contains(args[2], "apply_system_network opaque", "the opaque system network admission")
			helpers.assert_contains(args[2], "OPAQUE_NETWORK_PAC_PROBE_URLS='https://github.com https://release-assets.githubusercontent.com'",
				"the PAC route is resolved for the origins the download contacts")
			helpers.assert_true(args[2]:sub(-#'exec /usr/bin/curl "$@"') == 'exec /usr/bin/curl "$@"',
				"curl is exec'd, so the task's PID and status stay its own")
			helpers.assert_eq(args[3], "REMAP-RUNTIME")
			helpers.assert_eq({ args[4], args[5], args[6], args[7] }, { "-L", "--proto", "=https", "https://github.com/x" })
			helpers.assert_eq(type(describe), "function")
		end)
	end)

	helpers.it("names a refused route by its shared class and leaves curl's own failures alone", function()
		with_route(function(Route)
			local Admission = require("modules.llm.opaque_network_admission")
			local named = Route.describe_failure(Admission.refusal_exit_code, Admission.refusal_prefix .. "verified:unavailable\n")
			helpers.assert_true(type(named) == "string" and named:find("proxy route could not be resolved", 1, true) ~= nil,
				tostring(named))
			helpers.assert_eq(Route.describe_failure(6, "curl: (6) Could not resolve host"), nil)
		end)
	end)

	helpers.it("wires the artifact fetch and the VirtualHIDDevice update to the route", function()
		local source = assert(helpers.read_module_source("adapters.runtime_owner_ports"))
		for _, tag in ipairs({ "REMAP-RUNTIME", "VIRTUAL-HID" }) do
			helpers.assert_contains(source, 'require("platform.remap.network_download").command("' .. tag .. '", curl_args)',
				"the production port runs the " .. tag .. " download behind the network route")
		end
	end)
end)
