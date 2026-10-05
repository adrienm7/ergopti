--- _shared/lua/test/layout_installed_update_contract.lua

--- Replays independently handwritten complete models for verified same-id updates.
return function(helpers, Catalogue, Json)
	local path = helpers.driver_root() .. "/../_shared/tests/corpus/layouts/installed_record_updates.json"
	local file = assert(io.open(path, "rb"))
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


	helpers.describe("installed-record verified update preservation", function()
		for _, vector in ipairs(vectors.cases) do
			helpers.it(vector.id .. " (installed-future-update)", function()
				local record = assert(Catalogue.decode_installed(vector.source, Json.decode_lossless))
				for _, operation in ipairs(vector.operations) do
					if operation.kind == "install" then
						record = Catalogue.with_installed(record, operation.entry)
					else
						record = Catalogue.without_installed(record, operation.id)
					end
				end
				assert_model(assert(Json.decode_lossless(Json.encode(record))),
					assert(Json.decode_lossless(vector.expected)), vector.id)
			end)
		end
		helpers.it("detaches carried source values and incoming verified fields (installed-future-update)", function()
			local source = '{"schema_version":1,"layouts":{"sample":{"id":"sample","sha256":"old","version":"1",'
				.. '"future":{"empty":[],"nothing":null,"flag":false}}}}'
			local record = assert(Catalogue.decode_installed(source, Json.decode_lossless))
			local entry = assert(Json.decode_lossless('{"id":"sample","sha256":"verified","version":"2","new_future":{"values":[]}}'))
			local updated = Catalogue.with_installed(record, entry)
			helpers.assert_type(updated.layouts.sample.future, "table")
			updated.layouts.sample.future.empty[1] = "candidate edit"
			updated.layouts.sample.new_future.values[1] = "candidate edit"
			helpers.assert_eq(#record.layouts.sample.future.empty, 0)
			helpers.assert_eq(#entry.new_future.values, 0)
			helpers.assert_true(Json.is_null(record.layouts.sample.future.nothing))
			helpers.assert_eq(record.layouts.sample.future.flag, false)
			helpers.assert_eq(record.layouts.sample.sha256, "old")
		end)
	end)
end
