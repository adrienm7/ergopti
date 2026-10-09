--- _shared/lua/test/layout_installed_extension_contract.lua

--- Published extension invariants classify a whole unusable row without deleting it.
return function(helpers, Catalogue, Json)
	local Extension = require("layouts.extension")
	local file = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/layouts/installed_record_extensions.json", "rb"))
	local vectors = assert(Json.decode_lossless(assert(file:read("*a"))))
	assert(file:close())
	local function assert_model(actual, expected, label)
		helpers.assert_eq(type(actual), type(expected), label .. ": scalar type")
		helpers.assert_eq(Json.is_null(actual), Json.is_null(expected), label .. ": null identity")
		helpers.assert_eq(Json.is_array(actual), Json.is_array(expected), label .. ": array identity")
		if type(expected) ~= "table" or Json.is_null(expected) then
			if not Json.is_null(expected) then helpers.assert_eq(actual, expected, label) end
			return
		end
		for key, value in pairs(expected) do assert_model(actual[key], value, label .. "." .. tostring(key)) end
		for key in pairs(actual) do helpers.assert_true(expected[key] ~= nil, label .. ": extra " .. tostring(key)) end
	end


	helpers.describe("installed-record optional extension classification", function()
		for _, vector in ipairs(vectors.cases) do
			helpers.it("ignores and retains extension " .. vector.id .. " (installed-extension-outdated)", function()
				local record = assert(Catalogue.decode_installed(vector.source, Json.decode_lossless))
				helpers.assert_nil(record.layouts.retired, "invalid extension row cannot become usable")
				helpers.assert_type(record.outdated.retired.detail, "string")
				helpers.assert_type(record.layouts.base, "table", "usable base neighbor")
				local roots = Extension.roots("/private/", record)
				helpers.assert_eq(#roots, 1)
				helpers.assert_eq(roots[1], "/private/extensions/stable/" .. string.rep("a", 64))
				local written = Catalogue.with_installed(record, { id = "sample", sha256 = "verified", version = "2" })
				assert_model(assert(Json.decode_lossless(Json.encode(written))),
					assert(Json.decode_lossless(vector.expected_after_install)), vector.id)
				local removed = Catalogue.without_installed(written, "sample")
				assert_model(assert(Json.decode_lossless(Json.encode(removed))),
					assert(Json.decode_lossless(vector.source)), "remove " .. vector.id)
			end)
		end
		for _, vector in ipairs(vectors.controls) do
			helpers.it("accepts " .. vector.id .. " (installed-extension-outdated)", function()
				local record = assert(Catalogue.decode_installed(vector.source, Json.decode_lossless))
				helpers.assert_nil(next(record.outdated))
				helpers.assert_eq(#Extension.roots("/private/", record), vector.roots)
			end)
		end
	end)
end
