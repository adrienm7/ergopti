-- tests/unit/updater/engine/test_version_compare_vectors.lua
--- Replays the cross-driver version ordering contract using the shared Lua owner.
local helpers = require("tests.helpers")
local Version = require("updater.engine.version_core")

helpers.describe("updater.engine.version_core shared ordering vectors", function()
	helpers.it("compares every published vector", function()
		local file = assert(io.open(helpers.shared("updater/data/version_vectors.json"), "rb"))
		local raw = file:read("*a"); assert(file:close())
		local vectors = assert(require("core.text.engine.json").decode(raw)).vectors
		for _, row in ipairs(vectors) do
			helpers.assert_eq(Version.compare_versions(row.a, row.b), row.expect, row.id)
		end
	end)
end)
