-- tests/unit/modules/updater/test_version_compare_vectors.lua
--- Replays the cross-driver version ordering contract using the shared Lua owner.
local helpers = require("tests.helpers")
local Version = require("updater.version")

helpers.describe("updater.version shared ordering vectors", function()
	helpers.it("compares every published vector", function()
		local file = assert(io.open(helpers.shared("modules/updater/version_vectors.json"), "rb"))
		local raw = file:read("*a"); assert(file:close())
		local vectors = assert(require("json").decode(raw)).vectors
		for _, row in ipairs(vectors) do
			helpers.assert_eq(Version.compare_versions(row.a, row.b), row.expect, row.id)
		end
	end)
end)
