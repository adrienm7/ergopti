--- tests/unit/modules/llm/test_opaque_network_pac_fallback.lua

--- ==============================================================================
--- MODULE: PAC Direct Fallback Receiver
--- DESCRIPTION:
--- A download whose automatic configuration (PAC, WPAD) cannot be fetched or
--- evaluated goes direct, and the shell prints a marker naming the stage. The
--- Lua callers read the stage from that marker to name both causes when the
--- direct attempt fails too:
--- 1. the fallback stages are the shared proxy_policy.json list;
--- 2. only a listed stage is read back from a marker, never other child text;
--- 3. the admission receiver ignores the marker line.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Admission = require("modules.llm.opaque_network_admission")

--- The shared policy list, read independently of the module under test.
--- @return table stages
local function policy_stages()
	local file = assert(io.open("../_shared/modules/network/proxy_policy.json", "rb"))
	local policy = Json.decode(file:read("*a"))
	file:close()
	return policy.pac_unavailable_fallback.stages
end

helpers.describe("PAC direct fallback receiver", function()
	helpers.it("takes its stages from the shared proxy policy", function()
		local stages = policy_stages()
		helpers.assert_true(#stages > 0)
		for _, stage in ipairs(stages) do
			helpers.assert_true(Admission.is_pac_fallback_stage(stage), stage)
		end
		helpers.assert_true(Admission.is_pac_fallback_stage("native_pac_download"))
		helpers.assert_true(not Admission.is_pac_fallback_stage("native_proxy_dictionary"),
			"a relay the PAC names never goes direct")
		helpers.assert_true(not Admission.is_pac_fallback_stage("native_session_terminal"))
		helpers.assert_true(not Admission.is_pac_fallback_stage(nil))
	end)

	helpers.it("reads the stage from the marker the shell prints", function()
		local output = "[OLLAMA-PULL] The automatic network settings named no route (native_pac_download).\n"
			.. Admission.pac_fallback_marker .. "native_pac_download\n"
			.. "[OLLAMA-PULL] WARNING: The automatic network configuration could not be used (native_pac_download).\n"
		helpers.assert_eq(Admission.pac_fallback_stage(output), "native_pac_download")
	end)

	helpers.it("never reads an unlisted stage or other text from a marker", function()
		local marker = Admission.pac_fallback_marker
		helpers.assert_nil(Admission.pac_fallback_stage(marker .. "native_proxy_dictionary\n"))
		helpers.assert_nil(Admission.pac_fallback_stage(marker .. "http://pac.intranet.example/a.pac\n"))
		helpers.assert_nil(Admission.pac_fallback_stage("native_pac_download\n"))
		helpers.assert_nil(Admission.pac_fallback_stage(nil))
		helpers.assert_eq(Admission.pac_fallback_stage(marker .. "bogus\n" .. marker .. "native_wpad_discovery\n"),
			"native_wpad_discovery")
	end)

	helpers.it("leaves the admission phase untouched by the marker line", function()
		local phase = Admission.new()
		helpers.assert_true(phase.push(Admission.pac_fallback_marker .. "native_pac_evaluation\n"))
		helpers.assert_true(phase.push(Admission.accepted_line .. "\n"))
		helpers.assert_nil(phase.finish(0))
	end)
end)
