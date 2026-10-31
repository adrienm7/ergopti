--- _shared/lua/test/network_proxy_override_contract.lua

--- ==============================================================================
--- MODULE: Network Proxy Override Contract
--- DESCRIPTION:
--- The proxy override setting (Issue #101 point 2) read from its canonical
--- declaration, and the shared proxy policy honouring it before an exported
--- relay and the system lookup (PAC, WPAD). Both drivers register it through
--- their own path owner.
--- ==============================================================================

local M = {}
local Json = require("json")
local Override = require("network.proxy_override")
local Policy = require("network.proxy_policy")

--- Registers the controls.
--- @param read function Reads a file relative to the shared tree.
--- @param helpers table The driver's test helpers.
function M.register(read, helpers)
	local declaration = Json.decode(assert(read("modules/network/proxy_override.json")))
	local function override() return assert(Override.new(declaration)) end
	local function policy() return assert(Policy.new(Json.decode(assert(read("modules/network/proxy_policy.json"))))) end

	helpers.describe("shared proxy override: setting", function()
		helpers.it("reads an unset or empty value as automatic, the default", function()
			local active = override()
			helpers.assert_eq(active.default, "")
			helpers.assert_eq(active.parse(nil).mode, "automatic")
			helpers.assert_eq(active.parse("  ").mode, "automatic")
		end)

		helpers.it("accepts the direct token and the relays an environment client can export", function()
			local active = override()
			helpers.assert_eq(active.parse("direct").mode, "direct")
			helpers.assert_eq(active.normalize(" Direct "), "direct")
			for _, relay in ipairs({ "http://proxy.corp.invalid:3128", "https://proxy.corp.invalid:443",
				"socks5h://127.0.0.1:1080", "http://user:p%40ss@proxy.corp.invalid:8080", "http://[::1]:3128" }) do
				local choice = active.parse(relay)
				helpers.assert_eq(choice and choice.mode, "relay", relay)
				helpers.assert_eq(choice.relay, relay)
				helpers.assert_eq(active.normalize("  " .. relay .. "\t"), relay)
			end
		end)

		helpers.it("refuses any other value instead of reading it as automatic", function()
			local active = override()
			for _, value in ipairs({ "proxy.corp.invalid:3128", "http://proxy.corp.invalid", "ftp://proxy.invalid:21",
				"http://proxy.invalid:70000", "http://proxy.invalid:3128/path", "DIRECT; PROXY a:1", 3128, true }) do
				local choice, reason = active.parse(value)
				helpers.assert_eq(choice, nil, tostring(value))
				helpers.assert_eq(reason, Override.INVALID, tostring(value))
			end
		end)

		helpers.it("refuses a declaration whose default is not automatic", function()
			local broken = Json.decode(assert(read("modules/network/proxy_override.json")))
			broken.default = "direct"
			helpers.assert_eq(select(2, Override.new(broken)), Override.DECLARATION_INVALID)
			helpers.assert_eq(select(2, Override.new({})), Override.DECLARATION_INVALID)
		end)
	end)

	helpers.describe("shared proxy override: menu row", function()
		local function ports(stored, typed, set_result)
			local p = { store = { ["network.proxy_override"] = stored }, shown = {}, logs = {}, writes = 0 }
			p.get = function(key) return p.store[key] end
			p.set = function(key, value) p.writes = p.writes + 1; p.store[key] = value; return set_result ~= false end
			p.prompt = function(_, _, initial) p.initial = initial; return typed end
			p.error = function(_, text) p.shown[#p.shown + 1] = "error:" .. text end
			p.info = function(_, text) p.shown[#p.shown + 1] = "info:" .. text end
			p.t = function(key) return key end
			p.log = function(level, message, ...) p.logs[#p.logs + 1] = level .. ":" .. string.format(message, ...) end
			return p
		end

		helpers.it("stores the canonical relay and says downloads use it, never logging the relay", function()
			local p = ports(nil, "  http://user:secret@proxy.corp.invalid:3128 ")
			helpers.assert_eq(Override.edit(override(), p), true)
			helpers.assert_eq(p.initial, "")
			helpers.assert_eq(p.store["network.proxy_override"], "http://user:secret@proxy.corp.invalid:3128")
			helpers.assert_eq(p.shown[1], "info:proxy_override.saved_relay")
			for _, line in ipairs(p.logs) do helpers.assert_eq(line:find("secret", 1, true), nil, line) end
		end)

		helpers.it("shows the stored value and clears it back to automatic", function()
			local p = ports("direct", "")
			helpers.assert_eq(Override.edit(override(), p), true)
			helpers.assert_eq(p.initial, "direct")
			helpers.assert_eq(p.store["network.proxy_override"], "")
			helpers.assert_eq(p.shown[1], "info:proxy_override.saved_automatic")
		end)

		helpers.it("refuses an invalid value and a cancel without writing", function()
			local p = ports("direct", "proxy.corp.invalid:3128")
			helpers.assert_eq(Override.edit(override(), p), false)
			helpers.assert_eq(p.writes, 0)
			helpers.assert_eq(p.store["network.proxy_override"], "direct")
			helpers.assert_eq(p.shown[1], "error:proxy_override.invalid")
			local cancelled = ports("direct", nil)
			helpers.assert_eq(Override.edit(override(), cancelled), false)
			helpers.assert_eq(cancelled.writes, 0)
			helpers.assert_eq(#cancelled.shown, 0)
		end)

		helpers.it("says so when the settings store refuses the write", function()
			local p = ports(nil, "direct", false)
			helpers.assert_eq(Override.edit(override(), p), false)
			helpers.assert_eq(p.shown[1], "error:proxy_override.not_saved")
		end)
	end)

	helpers.describe("shared proxy override: route precedence", function()
		local exported = { HTTPS_PROXY = "http://exported.invalid:8080", http_proxy = "http://exported.invalid:8080" }

		helpers.it("automatic keeps the exported relay, then the system lookup", function()
			local active, setting = policy(), override()
			helpers.assert_eq(active.route("https://registry.invalid/", exported, setting.parse("")).mode, "environment")
			helpers.assert_eq(active.route("https://registry.invalid/", {}, setting.parse("")).mode, "system")
			helpers.assert_eq(active.route("https://registry.invalid/", {}).mode, "system")
		end)

		helpers.it("a relay override wins over the exported relay and skips the system lookup", function()
			local active, setting = policy(), override()
			for _, environment in ipairs({ exported, {} }) do
				local route = active.route("https://registry.invalid/v2/", environment,
					setting.parse("http://proxy.corp.invalid:3128"))
				helpers.assert_eq(route.mode, "selected")
				helpers.assert_eq(route.proxy, "http://proxy.corp.invalid:3128")
				helpers.assert_eq(route.bypass, "environment")
				helpers.assert_eq(route.source, "override")
			end
		end)

		helpers.it("a direct override sends every non-loopback origin direct, never to the system lookup", function()
			local active, setting = policy(), override()
			local route = active.route("http://corporate.invalid/", exported, setting.parse("direct"))
			helpers.assert_eq(route.mode, "direct")
			helpers.assert_eq(route.source, "override")
		end)

		helpers.it("loopback stays direct whatever the override", function()
			local active, setting = policy(), override()
			local route = active.route("http://127.0.0.1:11435/api/pull", {}, setting.parse("http://proxy.corp.invalid:3128"))
			helpers.assert_eq(route.mode, "direct")
			helpers.assert_eq(route.source, nil)
		end)

		helpers.it("refuses a malformed override choice", function()
			local active = policy()
			for _, choice in ipairs({ "http://proxy.invalid:1", { mode = "relay" }, { mode = "relay", relay = "ftp://a:1" },
				{ mode = "pac" } }) do
				local route, reason = active.route("https://registry.invalid/", {}, choice)
				helpers.assert_eq(route, nil)
				helpers.assert_eq(reason, "proxy-override-invalid")
			end
		end)
	end)
end

return M
