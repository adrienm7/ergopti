--- _shared/lua/test/json_root_source_contract.lua
--- Handwritten byte-level expectations for source-bound JSON member edits.
--- This is pure parser evidence, not native storage, publication, or liveness.
return function(helpers, Json)
	local function receipt(raw)
		local model, proof = Json.decode_root_object_source(raw)
		helpers.assert_eq(type(model), "table")
		helpers.assert_eq(type(proof), "table")
		return proof, model
	end
	local function expect(raw, updates, expected)
		local proof = receipt(raw)
		local candidate, model, next_proof = Json.splice_root_object_source(proof, updates)
		helpers.assert_eq(candidate, expected)
		helpers.assert_eq(type(model), "table")
		helpers.assert_eq(type(next_proof), "table")
		local again = Json.splice_root_object_source(next_proof, {})
		helpers.assert_eq(again, expected)
	end
	local function refuses(proof, updates)
		local candidate, failure, next_proof = Json.splice_root_object_source(proof, updates)
		helpers.assert_eq(candidate, nil)
		helpers.assert_eq(type(failure), "string")
		helpers.assert_true(failure ~= "")
		helpers.assert_eq(next_proof, nil)
	end
	local function fresh_codec()
		local source = debug.getinfo(Json.decode, "S").source
		helpers.assert_eq(source:sub(1, 1), "@")
		return assert(loadfile(source:sub(2)))()
	end
	helpers.describe("source-bound root JSON members", function()
		helpers.it("keeps complete unowned precision, kinds, escaped keys and trivia", function()
			local raw = ' \n{ "future" : [0.1,{"i":9223372036854775807,"n":null,"a":[],"m":{},"e":1.2300e-20}], "\\u0061" : false }\r\n'
			local expected = ' \n{ "future" : [0.1,{"i":9223372036854775807,"n":null,"a":[],"m":{},"e":1.2300e-20}], "\\u0061" : true }\r\n'
			expect(raw, { a = { present = true, value = true } }, expected)
		end)
		helpers.it("retains no-op bytes and never rewrites rounded source numbers", function()
			local raw = '{"large":9007199254740993,"double":1.234567890123456789,"zero":-0,"tiny":1e-400,"x":false}'
			expect(raw, {}, raw)
			expect(raw, { x = { present = true, value = true } },
				'{"large":9007199254740993,"double":1.234567890123456789,"zero":-0,"tiny":1e-400,"x":true}')
		end)
		local raw = ' \n{  "a" :1 ,\t"b":2,\n"c":3 }\t'
		for _, vector in ipairs({
			{ key = "a", replacement = ' \n{  "a" :false ,\t"b":2,\n"c":3 }\t', deletion = ' \n{\t"b":2,\n"c":3 }\t' },
			{ key = "b", replacement = ' \n{  "a" :1 ,\t"b":false,\n"c":3 }\t', deletion = ' \n{  "a" :1 ,\n"c":3 }\t' },
			{ key = "c", replacement = ' \n{  "a" :1 ,\t"b":2,\n"c":false }\t', deletion = ' \n{  "a" :1 ,\t"b":2}\t' },
		}) do
			helpers.it("replaces only the " .. vector.key .. " value interval", function()
				expect(raw, { [vector.key] = { present = true, value = false } }, vector.replacement)
			end)
			helpers.it("deletes the " .. vector.key .. " member without touching surviving tokens", function()
				expect(raw, { [vector.key] = { present = false } }, vector.deletion)
			end)
		end
		helpers.it("deletes all members and admits missing-member deletion as a no-op", function()
			expect(raw, { a = { present = false }, b = { present = false }, c = { present = false } }, ' \n{}\t')
			expect(raw, { missing = { present = false } }, raw)
		end)
		helpers.it("appends in decoded-key order while preserving last-member trivia", function()
			expect('{ "keep":0.1\n}', { z = { present = true, value = false }, a = { present = true, value = true } },
				'{ "keep":0.1\n,"a":true,"z":false}')
			expect(' \t{ \n}\r', { a = { present = true, value = 1 } }, ' \t{ \n"a":1}\r')
		end)
		helpers.it("preserves distinct case, decoded escapes and NUL or empty key identity", function()
			expect('{"Key":1,"key":2,"\\u0061":3,"":4,"\\u0000":5}', {
				Key = { present = true, value = false }, a = { present = false },
				[""] = { present = true, value = true }, ["\0"] = { present = true, value = false },
			}, '{"Key":false,"key":2,"":true,"\\u0000":false}')
			expect('{}', { ['a"\\\n'] = { present = true, value = false } }, '{"a\\\"\\\\\\n":false}')
		end)
		helpers.it("rejects decoded duplicate identities at every object depth", function()
			for _, input in ipairs({ '{"a":1,"a":2}', '{"a":null,"\\u0061":2}',
				'{"x":{"a":1,"\\u0061":2}}', '{"x":[{"a":1,"a":2}]}' }) do
				local model, failure = Json.decode_root_object_source(input)
				helpers.assert_eq(model, nil)
				helpers.assert_eq(type(failure), "string")
			end
			local proof = receipt('{"A":1,"a":2}')
			helpers.assert_eq(Json.splice_root_object_source(proof, {}), '{"A":1,"a":2}')
		end)
		helpers.it("rejects non-object or malformed strict sources without changing legacy decoding", function()
			for _, input in ipairs({ '[]', 'null', 'false', '1', '"x"', '{', '{"x":01}',
				'{"x":1e400}', '{"x":true,}', '{"x":1} trailing', '{"x":"\\q"}' }) do
				helpers.assert_eq(Json.decode_root_object_source(input), nil)
			end
			helpers.assert_eq(Json.decode('{"a":1,"a":2}').a, 2)
			helpers.assert_eq(Json.decode_lossless('{"a":1,"a":2}'), nil)
			helpers.assert_eq(Json.is_array(Json.decode('[]')), false)
			helpers.assert_eq(Json.is_array(Json.decode_lossless('[]')), true)
		end)
		helpers.it("isolates receipts from mutated models, cloned tables and another codec", function()
			local proof, model = receipt('{"x":{"keep":0.1},"a":false}')
			model.x.keep = 8
			model.a = true
			helpers.assert_eq(Json.splice_root_object_source(proof, {}), '{"x":{"keep":0.1},"a":false}')
			refuses({}, {})
			refuses({ raw = '{"a":false}', members = {} }, {})
			local other = fresh_codec()
			local _, foreign = other.decode_root_object_source('{"a":false}')
			refuses(foreign, {})
			helpers.assert_eq(other.splice_root_object_source(proof, {}), nil)
			local written = pcall(function() proof.source = '{}' end)
			helpers.assert_eq(written, false)
			rawset(proof, "source", '{}')
			refuses(proof, {})
		end)
		helpers.it("requires explicit Boolean cells and refuses extra or implicit values", function()
			local proof = receipt('{}')
			for _, updates in ipairs({ false, 'x', { [1] = { present = true, value = 1 } },
				{ x = false }, { x = {} }, { x = { present = 1, value = 1 } },
				{ x = { present = true } }, { x = { present = false, value = false } },
				{ x = { present = true, value = 1, other = true } }, Json.array({}),
				setmetatable({}, {}), { x = setmetatable({ present = true, value = 1 }, {}) } }) do
				refuses(proof, updates)
			end
			refuses(proof, nil)
		end)
		helpers.it("refuses values the legacy encoder drops, normalizes or cannot round-trip", function()
			local proof = receipt('{"keep":0.1}')
			local cycle = {}; cycle.self = cycle
			for _, value in ipairs({ function() end, math.huge, -math.huge, 0 / 0,
				{ [2] = 1 }, { [1] = 1, a = 2 }, setmetatable({ a = 1 }, {}), cycle }) do
				refuses(proof, { x = { present = true, value = value } })
			end
			-- On Lua 5.4 this integer is exact before the legacy %.17g encoder rounds it.
			local integer = tonumber('9007199254740993')
			if tostring(integer) == '9007199254740993' then
				refuses(proof, { x = { present = true, value = integer } })
			end
		end)
		helpers.it("keeps explicit empty arrays, objects, nulls and false update values", function()
			local null = Json.decode_lossless('null')
			expect('{}', { x = { present = true, value = { a = Json.array({}), b = {}, c = null, d = false } } },
				'{"x":{"a":[],"b":{},"c":null,"d":false}}')
			expect('{"x":true}', { x = { present = true, value = null } }, '{"x":null}')
		end)
		helpers.it("refuses malformed and semantically wrong output from the actual encoder", function()
			local isolated = fresh_codec()
			local _, proof = isolated.decode_root_object_source('{"keep":0.1}')
			isolated.encode = function() return 'true trailing' end
			helpers.assert_eq(isolated.splice_root_object_source(proof, { x = { present = true, value = true } }), nil)
			isolated.encode = function() return 'false' end
			helpers.assert_eq(isolated.splice_root_object_source(proof, { x = { present = true, value = true } }), nil)
			isolated.encode = function() error('encoder refusal') end
			helpers.assert_eq(isolated.splice_root_object_source(proof, { x = { present = true, value = true } }), nil)
		end)
		helpers.it("reparses the complete spliced candidate and rejects key injection", function()
			local isolated = fresh_codec()
			local _, proof = isolated.decode_root_object_source('{"keep":0.1}')
			isolated.quote = function() return '"x":true,"foreign"' end
			helpers.assert_eq(isolated.splice_root_object_source(proof, { x = { present = true, value = true } }), nil)
			isolated.quote = function() return '"other"' end
			helpers.assert_eq(isolated.splice_root_object_source(proof, { x = { present = true, value = true } }), nil)
			isolated.quote = function() error('quote refusal') end
			helpers.assert_eq(isolated.splice_root_object_source(proof, { x = { present = true, value = true } }), nil)
			isolated.quote = function() return '"x",' end
			-- Overriding the public parser cannot bypass the private complete reparse.
			isolated.decode_root_object_source = function() return { x = true }, {} end
			helpers.assert_eq(isolated.splice_root_object_source(proof, { x = { present = true, value = true } }), nil)
		end)
		helpers.it("permits repeated independent edits from an authentic parse receipt only", function()
			local proof = receipt('{"x":false}')
			helpers.assert_eq(Json.splice_root_object_source(proof, { x = { present = true, value = true } }), '{"x":true}')
			helpers.assert_eq(Json.splice_root_object_source(proof, {}), '{"x":false}')
			-- No consumed flag or file-liveness claim: native owners must fence publication.
		end)
	end)
end
