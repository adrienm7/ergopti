--- _shared/lua/test/network_proxy_policy_contract.lua

--- ==============================================================================
--- MODULE: Network Proxy Policy Contract
--- DESCRIPTION:
--- Preserves independent managed-network controls and actual production imports.
--- Source registration alone does not qualify native or installed behavior.
--- ==============================================================================

--- Pure shared proxy-policy controls; no native acquisition or regenerated expectations.
local M = {}
local Json = require("json")
local module = require("network.proxy_policy")

function M.register_base(read, helpers)
local bytes = assert(read("modules/network/proxy_policy.json"))
local function data() return Json.decode(bytes) end
local function policy() return assert(module.new(data())) end

helpers.describe("shared_proxy_policy: independent admission vectors", function()
	helpers.it("matches curl HTTP uppercase exclusion and HTTPS/ALL_PROXY environment precedence", function()
		local active = policy()
		helpers.assert_eq(active.route("http://corporate.invalid/", { HTTP_PROXY = "http://ignored.invalid" }).mode, "system")
		for _, environment in ipairs({ { http_proxy = "http://selected.invalid" }, { all_proxy = "socks5://selected.invalid" },
			{ ALL_PROXY = "socks5://selected.invalid" } }) do
			helpers.assert_eq(active.route("http://corporate.invalid/", environment).mode, "environment")
		end
		for _, name in ipairs({ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" }) do
			helpers.assert_eq(active.route("https://corporate.invalid/", { [name] = "http://selected.invalid" }).mode, "environment")
		end
		helpers.assert_eq(active.route("https://corporate.invalid/", { https_proxy = "", HTTPS_PROXY = "" }).mode, "system")
	end)

	helpers.it("bypasses environment proxies only for independently fixed valid loopback authorities", function()
		local active = policy()
		for _, authority in ipairs({ "localhost", "LOCALHOST.", "service.localhost", "127.0.0.1", "127.23.45.67", "127.255.255.255",
			"[::1]", "[0:0:0:0:0:0:0:1]", "[0000:0000:0000:0000:0000:0000:0000:0001]" }) do
			helpers.assert_eq(active.route("http://" .. authority .. ":9000/private", { HTTP_PROXY = "http://private.invalid",
				http_proxy = "http://private.invalid" }).mode, "direct", authority)
		end
		for _, authority in ipairs({ "notlocalhost", "localhost.corporate.invalid", "126.255.255.255", "128.0.0.1", "[::2]",
			"[:::1]", "[0:0:0:0:0:0:0:1:]", "[:0:0:0:0:0:0:0:1]" }) do
			helpers.assert_eq(active.route("http://" .. authority .. "/", {}).mode, "system", authority)
		end
	end)

	helpers.it("does not let userinfo or a private query alter native host routing", function()
		local active = policy()
		helpers.assert_eq(active.route("https://localhost@corporate.invalid/private?next=http://127.0.0.1", {}).mode, "system")
		helpers.assert_eq(active.route("https://corporate.invalid@localhost/private", {}).mode, "direct")
	end)

	helpers.it("preserves all native PAC choices and explicit DIRECT with no truncation", function()
		local actual = assert(policy().selection({ ok = true, proxies = {
			"http://first.invalid:81", "https://second.invalid:82", "socks5h://third.invalid:83", "direct://" } }))
		helpers.assert_eq(#actual, 4)
		helpers.assert_eq(actual[1].proxy, "http://first.invalid:81")
		helpers.assert_eq(actual[2].proxy, "https://second.invalid:82")
		helpers.assert_eq(actual[3].proxy, "socks5h://third.invalid:83")
		helpers.assert_eq(actual[4].mode, "direct")
	end)

	helpers.it("exposes native capability absence without disabling the normal curl environment path", function()
		local actual = assert(policy().selection({ ok = false, error = "proxy-backend-unavailable", backend = "GDummyProxyResolver" }))
		helpers.assert_eq(#actual, 1)
		helpers.assert_eq(actual[1].mode, "environment")
		helpers.assert_eq(actual[1].capability, "unavailable")
	end)

	helpers.it("refuses malformed, unsupported and oversized native selections", function()
		for _, proxies in ipairs({ {}, { "file:///private" }, { "http://valid.invalid\nprivate" },
			{ "http://valid.invalid", metadata = "untrusted" }, { [1] = "http://valid.invalid", [3] = "direct://" },
			{ "http://" .. string.rep("x", 65537) } }) do
			helpers.assert_eq(policy().selection({ ok = true, proxies = proxies }), nil)
		end
		local oversized = {}
		for index = 1, 129 do oversized[index] = "direct://" end
		helpers.assert_eq(policy().selection({ ok = true, proxies = oversized }), nil)
	end)

	helpers.it("does not retain mutable caller data or expose mutable exclusion arrays", function()
		local inventory = data()
		local active = assert(module.new(inventory))
		inventory.loopback.dns_hosts[1] = "corporate.invalid"
		inventory.max_selections = 1
		inventory.system_lookup_environment_exclusions[1] = "MUTATED"
		helpers.assert_eq(active.route("http://corporate.invalid/", {}).mode, "system")
		helpers.assert_eq(active.route("http://localhost/", {}).mode, "direct")
		local route = active.route("http://corporate.invalid/", {})
		route.environment_exclusions[1] = "MUTATED"
		helpers.assert_eq(active.route("http://corporate.invalid/", {}).environment_exclusions[1], "http_proxy")
		helpers.assert_eq(#assert(active.selection({ ok = true, proxies = { "http://first.invalid", "direct://" } })), 2)
	end)

	helpers.it("refuses canonical data that removes required relay proof or uses invalid native names", function()
		for _, mutate in ipairs({
			function(value) value.failover.requires_verified_native_receipt = false end,
			function(value) value.failover.connect_requires_actual_proxy_used = false end,
			function(value) value.system_lookup_environment_exclusions[1] = "http_proxy;private" end,
			function(value) value.loopback.ipv4_cidrs[1] = "127.1.0.0/8" end,
			function(value) value.loopback.ipv6_addresses[1] = ":::1" end,
			function(value) value.max_selections = 0 end,
			function(value) value.environment_precedence.http[2] = value.environment_precedence.http[1] end,
		}) do
			local inventory = data(); mutate(inventory)
			helpers.assert_eq(module.new(inventory), nil)
		end
	end)
end)

end

function M.register_bypass(read, helpers)
local bytes = assert(read("modules/network/proxy_policy.json"))
local function data() return Json.decode(bytes) end

helpers.describe("shared_proxy_policy: explicit environment bypass", function()
	helpers.it("preserves the inherited environment bypass for every selected native relay", function()
		local active = assert(module.new(data()))
		local choices = assert(active.selection({ ok = true, proxies = {
			"http://first.invalid:81", "https://second.invalid:82", "socks5h://third.invalid:83", "direct://",
		}, bypass = "clear" }))
		helpers.assert_eq(#choices, 4)
		for index = 1, 3 do
			helpers.assert_eq(choices[index].mode, "selected")
			helpers.assert_eq(choices[index].bypass, "environment")
		end
		helpers.assert_eq(choices[1].proxy, "http://first.invalid:81")
		helpers.assert_eq(choices[2].proxy, "https://second.invalid:82")
		helpers.assert_eq(choices[3].proxy, "socks5h://third.invalid:83")
		helpers.assert_eq(choices[4].mode, "direct")
		helpers.assert_eq(choices[4].bypass, nil)
	end)

	helpers.it("refuses missing or overriding canonical selected-bypass laws", function()
		local missing = data()
		missing.selected_proxy_bypass = nil
		helpers.assert_eq(module.new(missing), nil)
		for _, override in ipairs({ "clear", "*", "direct", false, 1 }) do
			local inventory = data()
			inventory.selected_proxy_bypass = override
			helpers.assert_eq(module.new(inventory), nil)
		end
	end)

	helpers.it("freezes canonical bypass and never shares mutable selection records", function()
		local inventory = data()
		local active = assert(module.new(inventory))
		inventory.selected_proxy_bypass = "clear"
		local first = assert(active.selection({ ok = true, proxies = { "http://first.invalid:81" } }))
		first[1].bypass = "clear"
		local second = assert(active.selection({ ok = true, proxies = { "http://first.invalid:81" } }))
		helpers.assert_eq(second[1].bypass, "environment")
	end)

	helpers.it("retains environment precedence and excludes no explicit bypass variable from lookup", function()
		local active = assert(module.new(data()))
		helpers.assert_eq(active.route("https://corporate.invalid/private", {
			HTTPS_PROXY = "http://environment.invalid:81", NO_PROXY = "corporate.invalid",
		}).mode, "environment")
		helpers.assert_eq(active.route("http://localhost:9000/private", {
			http_proxy = "http://environment.invalid:81", NO_PROXY = "unrelated.invalid",
		}).mode, "direct")
		local route = assert(active.route("https://corporate.invalid/private", { NO_PROXY = "corporate.invalid" }))
		helpers.assert_eq(route.mode, "system")
		for _, name in ipairs(route.environment_exclusions) do
			helpers.assert_true(name ~= "NO_PROXY" and name ~= "no_proxy")
		end
	end)
end)

end

return M
