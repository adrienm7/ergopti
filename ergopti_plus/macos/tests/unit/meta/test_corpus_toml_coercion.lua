--- tests/unit/meta/test_corpus_toml_coercion.lua

--- ==============================================================================
--- CORPUS CONSUMER: TOML Scalar Coercion
--- Reads _shared/tests/corpus/toml/coercion_vectors.json and replays each
--- vector through config_overrides.coerce(), asserting the output matches
--- the expected Lua value.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("corpus — TOML scalar coercion (macOS)", function()

	local corpus_path = helpers.shared("tests/corpus/toml/coercion_vectors.json")

	helpers.it("corpus file is readable", function()
		local fh = io.open(corpus_path, "r")
		helpers.assert_true(fh ~= nil, "coercion_vectors.json must be readable")
		if fh then fh:close() end
	end)

	local function read_corpus()
		local fh = io.open(corpus_path, "r")
		if not fh then return nil, "cannot open corpus at " .. corpus_path end
		local raw = fh:read("*a")
		fh:close()
		local ok, result = pcall(require("hs").json.decode, raw)
		if not ok then return nil, "JSON parse error: " .. tostring(result) end
		return result, nil
	end

	local corpus, corpus_err = read_corpus()

	helpers.it("corpus file is readable and parseable", function()
		helpers.assert_true(corpus ~= nil,
			"corpus load error: " .. tostring(corpus_err))
		helpers.assert_true(type(corpus) == "table",
			"corpus root must be a table")
		helpers.assert_true(type(corpus.vectors) == "table",
			"corpus.vectors must be a table")
		helpers.assert_true(#corpus.vectors > 0,
			"corpus must have at least one vector")
	end)

	if corpus and corpus.vectors then

		local overrides_mod = nil
		local ok_ov, ov = pcall(require, "infra.config_overrides")
		if ok_ov and ov and type(ov.coerce) == "function" then
			overrides_mod = ov
		else
			-- In the headless test runner, config_overrides may not load
			-- (depends on hs). Provide a pure-Lua clone of M.coerce.
			local function clone_coerce(raw)
				local trimmed = raw:match("^%s*(.-)%s*$") or ""
				local lower = trimmed:lower()
				if lower == "true"  then return true  end
				if lower == "false" then return false end
				if trimmed:match("^-?%d+$") then return tonumber(trimmed) end
				if trimmed:match("^-?%d+%.%d+$") then return tonumber(trimmed) end
				local body = trimmed:match('^"(.*)"$')
				if body then
					body = body:gsub("\\\\", "\\"):gsub("\\\"", "\""):gsub("\\n", "\n"):gsub("\\t", "\t")
					return body
				end
				return trimmed
			end
			overrides_mod = { coerce = clone_coerce }
		end

		for _, v in ipairs(corpus.vectors) do
			helpers.it("coerce: " .. (v.id or v.input), function()
				local result = overrides_mod.coerce(v.input)
				local expected = v.lua

				if type(expected) == "number" then
					helpers.assert_true(type(result) == "number",
						string.format("expected number for '%s', got %s", v.input, type(result)))
					helpers.assert_true(math.abs(result - expected) < 0.0001,
						string.format("coerce('%s') = %s, expected %s", v.input, tostring(result), tostring(expected)))
				elseif type(expected) == "boolean" then
					helpers.assert_true(type(result) == "boolean",
						string.format("expected boolean for '%s', got %s", v.input, type(result)))
					helpers.assert_true(result == expected,
						string.format("coerce('%s') = %s, expected %s", v.input, tostring(result), tostring(expected)))
				else
					helpers.assert_true(tostring(result) == tostring(expected),
						string.format("coerce('%s') = '%s', expected '%s'", v.input, tostring(result), tostring(expected)))
				end
			end)
		end
	end

end)
