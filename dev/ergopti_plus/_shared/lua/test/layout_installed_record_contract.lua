--- _shared/lua/test/layout_installed_record_contract.lua

--- Replays independently written complete installed-record preservation models.
return function(helpers, Catalogue, Json)
	local path = helpers.driver_root() .. "/../_shared/tests/corpus/layouts/installed_record_preservation.json"
	local file = assert(io.open(path, "rb"))
	local source = assert(file:read("*a"))
	assert(file:close())
	local vectors = assert(Json.decode_lossless(source))

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

	helpers.describe("installed record source preservation", function()
		for _, vector in ipairs(vectors.cases) do
			helpers.it(vector.id .. " (config-outdated-installed-preservation)", function()
				local record = assert(Catalogue.decode_installed(vector.source, Json.decode_lossless))
				local original = assert(Json.decode_lossless(vector.source))
				if vector.mutate_runtime then
					record.outdated.retired.entry = "runtime mutation"
					record.outdated.extra = { entry = "runtime-only", detail = "runtime classification" }
					record.future.nested.value = 99
				end
				for position, operation in ipairs(vector.operations) do
					local previous = record
					if operation.kind == "install" then record = Catalogue.with_installed(record, operation.entry)
					else record = Catalogue.without_installed(record, operation.id) end
					helpers.assert_true(record ~= previous, vector.id .. ": detached builder record")
					if vector.mutate_builder and position == 1 then
						record.future_root.nested.value = 99
						record.layouts.gone.fields[1] = false
						record.layouts.sample.version = "2"
						helpers.assert_eq(previous.future_root.nested.value, 12)
						helpers.assert_true(Json.is_null(previous.outdated.gone.entry.fields[1]))
						helpers.assert_eq(previous.layouts.sample.version, "1")
					end
				end
				local payload = assert(Json.encode(record))
				assert_model(assert(Json.decode_lossless(payload)), assert(Json.decode_lossless(vector.expected)), vector.id)
				assert_model(assert(Json.decode_lossless(vector.source)), original, vector.id .. ": original source")
			end)
		end
		helpers.it("keeps fresh constructor members and public obsolete registry (config-outdated-installed-preservation)", function()
			local fresh = Catalogue.empty_installed()
			fresh.future = assert(Json.decode_lossless('{"empty":[],"nothing":null,"flag":false}'))
			fresh.outdated = { legacy = { entry = false, detail = "old shape" } }
			local entry = { id = "new", sha256 = "verified", version = "2" }
			local built = Catalogue.with_installed(fresh, entry)
			local expected = assert(Json.decode_lossless(
				'{"schema_version":1,"layouts":{"legacy":false,"new":{"id":"new","sha256":"verified","version":"2"}},'
				.. '"future":{"empty":[],"nothing":null,"flag":false}}'))
			assert_model(assert(Json.decode_lossless(Json.encode(built))), expected, "fresh constructor")
			built.future.empty[1] = "candidate edit"
			built.layouts.new.version = "3"
			helpers.assert_eq(#fresh.future.empty, 0)
			helpers.assert_eq(entry.version, "2")
			local removed = Catalogue.without_installed(built, "new")
			expected.layouts.new = nil
			assert_model(assert(Json.decode_lossless(Json.encode(removed))), expected, "fresh source identity")
		end)
		helpers.it("keeps genuine syntax, header and schema refusals (config-outdated-installed-preservation)", function()
			for _, text in ipairs(vectors.refusals) do
				local record, err = Catalogue.decode_installed(text, Json.decode_lossless)
				helpers.assert_nil(record, "accepted: " .. text)
				helpers.assert_type(err, "string")
			end
		end)
		helpers.it("keeps the generic decoder contract unchanged (config-outdated-installed-preservation)", function()
			local legacy = assert(Json.decode('{"empty":[],"nothing":null}'))
			helpers.assert_eq(Json.is_array(legacy.empty), false)
			helpers.assert_eq(Json.is_null(legacy.nothing), false)
			local lossless = assert(Json.decode_lossless('{"empty":[],"nothing":null}'))
			helpers.assert_true(Json.is_array(lossless.empty))
			helpers.assert_true(Json.is_null(lossless.nothing))
		end)
	end)
end
