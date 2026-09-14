--- tests/unit/platform/remap/test_package_manifest.lua

--- Verifies the direct-Hammerspoon reader consumes the shared package manifest.
local helpers = require("tests.helpers")

local function with_manifest_decoder(decode, callback)
	return helpers.with_stub_scope({ "adapters.json_codec", "infra.logger" }, function()
		helpers.load_with_stubs("adapters.json_codec", { json = { decode = decode } })
		return callback()
	end)
end

helpers.describe("shared Karabiner package manifest", function()
	helpers.it("reads JSON identity instead of retaining a separate Lua pin", function()
		local decoded = { version = "fixture-version", sha256 = "fixture-checksum" }
		local received
		with_manifest_decoder(function(content) received = content; return decoded end, function()
			local manifest = dofile("vendor/karabiner-elements/manifest.lua")
			helpers.assert_true(rawequal(manifest, decoded))
			helpers.assert_true(type(received) == "string" and received:find('"source_url"', 1, true) ~= nil)
		end)
	end)

	helpers.it("rejects a failed decoder instead of returning an installation pin", function()
		with_manifest_decoder(function() error("manifest decoder refused") end, function()
			local ok, detail = pcall(dofile, "vendor/karabiner-elements/manifest.lua")
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(detail):find("manifest decoder refused", 1, true) ~= nil)
		end)
	end)
end)
