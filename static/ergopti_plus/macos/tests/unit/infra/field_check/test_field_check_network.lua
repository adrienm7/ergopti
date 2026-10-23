--- tests/unit/infra/field_check/test_field_check_network.lua

--- ==============================================================================
--- MODULE: Field Check Network Definition
--- DESCRIPTION:
--- The one-click network check over scripted ports:
--- 1. the proxy settings, the PAC download and the PAC verdict each have their
---    own step, and a missing PAC skips both PAC steps;
--- 2. the native helper's lines become the route, TLS, transfer and digest
---    steps, and a helper that cannot run fails the transfer, not the report;
--- 3. no step value can carry the PAC address, a host or PAC content.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "platform.remap.ke_paths" }

local PAC_URL = "http://pac.intranet.example/proxy.pac"
local SCUTIL_PAC = "<dictionary> {\n  ProxyAutoConfigEnable : 1\n  ProxyAutoConfigURLString : " .. PAC_URL .. "\n}\n"
local GOOD_PAC = "function FindProxyForURL(url, host) { return 'DIRECT'; }"
local HELPER_OK = "step route_lookup pass selected\nstep tls pass trusted\nstep transfer pass http_200\nstep digest skip head_only\n"

--- Runs the network check over scripted answers.
--- @param world table { scutil, pac_status, pac_body, helper_code, helper_output }
--- @return table steps, table result, table seen Addresses the ports received.
local function run(world)
	local seen = {}
	local ports = {
		exec = function(_, _, _, callback) callback(world.scutil_code or 0, world.scutil or "") end,
		fetch_pac = function(url, callback)
			seen[#seen + 1] = url
			callback(world.pac_status, world.pac_body)
		end,
		network_chain = function(callback) callback(world.helper_code, world.helper_output or "") end,
	}
	local result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		local Engine = require("infra.field_check")
		assert(Engine.run("network", ports, function(done) result = done end), "check did not start")
	end)
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result, seen
end

helpers.describe("network check", function()
	helpers.it("passes when the PAC is usable and the helper reports a clean route", function()
		local steps, result, seen = run({ scutil = SCUTIL_PAC, pac_status = 200, pac_body = GOOD_PAC,
			helper_code = 0, helper_output = HELPER_OK })
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.proxy_settings.value, "pac")
		helpers.assert_eq(steps.pac_download.value, "http_200")
		helpers.assert_eq(steps.pac_script.value, "valid")
		helpers.assert_eq(steps.route_lookup.value, "selected")
		helpers.assert_eq(steps.transfer.value, "http_200")
		helpers.assert_eq(steps.digest.state, "skip")
		helpers.assert_eq(seen[1], PAC_URL)
	end)

	helpers.it("names a PAC that cannot be downloaded or is not a script", function()
		local steps, result = run({ scutil = SCUTIL_PAC, pac_status = 404, pac_body = "",
			helper_code = 0, helper_output = HELPER_OK })
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.pac_download.state, "fail")
		helpers.assert_eq(steps.pac_download.value, "http_404")
		helpers.assert_eq(steps.pac_script.value, "invalid")
		local bad = run({ scutil = SCUTIL_PAC, pac_status = 200, pac_body = "<html>login</html>",
			helper_code = 0, helper_output = HELPER_OK })
		helpers.assert_eq(bad.pac_download.state, "pass")
		helpers.assert_eq(bad.pac_script.state, "fail")
	end)

	helpers.it("fails the route step with the native stage that made the download go direct", function()
		local steps, result = run({ scutil = SCUTIL_PAC, pac_status = 200, pac_body = GOOD_PAC, helper_code = 0,
			helper_output = "step route_lookup fail direct_pac_evaluation\nstep tls pass trusted\nstep transfer pass http_200\nstep digest skip head_only\n" })
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.route_lookup.value, "direct_pac_evaluation")
		helpers.assert_eq(steps.transfer.state, "pass")
	end)

	helpers.it("skips both PAC steps when no PAC is configured", function()
		local steps, result = run({ scutil = "<dictionary> {\n  HTTPEnable : 0\n}\n", helper_code = 0, helper_output = HELPER_OK })
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.proxy_settings.value, "none")
		helpers.assert_eq(steps.pac_download.state, "skip")
		helpers.assert_eq(steps.pac_script.state, "skip")
	end)

	helpers.it("fails the transfer, and skips the rest, when the helper cannot run", function()
		local steps, result = run({ scutil = "", helper_code = nil })
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.transfer.state, "fail")
		helpers.assert_eq(steps.transfer.value, "helper_unavailable")
		helpers.assert_eq(steps.route_lookup.state, "skip")
	end)

	helpers.it("ignores helper lines that add a step, repeat one or carry a bad state", function()
		local steps = run({ scutil = "", helper_code = 0,
			helper_output = "step transfer pass http_200\nstep transfer fail http_500\nstep extra pass x\nstep tls maybe trusted\n" })
		helpers.assert_eq(steps.transfer.value, "http_200")
		helpers.assert_nil(steps.extra)
		helpers.assert_eq(steps.tls.state, "skip")
	end)

	helpers.it("never lets the PAC address or a host reach a step value", function()
		local steps = run({ scutil = SCUTIL_PAC, pac_status = 200, pac_body = GOOD_PAC, helper_code = 0,
			helper_output = "step transfer fail https://intranet.example/x\nstep route_lookup pass selected\n" })
		for _, step in pairs(steps) do
			helpers.assert_true(step.value == nil or not step.value:find("intranet", 1, true), "leaked in " .. step.id)
			helpers.assert_true(step.value == nil or not step.value:find("://", 1, true), "URL in " .. step.id)
		end
		helpers.assert_eq(steps.transfer.value, "redacted")
	end)
end)
