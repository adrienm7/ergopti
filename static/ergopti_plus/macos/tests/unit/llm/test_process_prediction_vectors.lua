--- tests/unit/llm/test_process_prediction_vectors.lua

--- ==============================================================================
--- MODULE: process_prediction Cross-Driver Corpus (Hammerspoon / shared oracle)
--- DESCRIPTION:
--- Runs the cross-driver golden corpus
--- (_shared/tests/corpus/llm/process_prediction_vectors.json) through the SHARED
--- Lua parser — the canonical oracle the corpus was generated from. The AHK suite
--- asserts its port matches the same corpus row-by-row (test_llm_parser.ahk §3), so
--- together they pin macOS ≡ AHK on the physical injection contract (deletes /
--- to_type / nw / has_corrections / disable_bold).
---
--- This side passes by construction; its purpose is to make the corpus a tripwire:
--- any change to _shared/lua/llm/parser.lua that shifts the output fails here until
--- the corpus is regenerated (lua tools/build/gen-process-prediction-corpus.lua),
--- forcing the AHK port to be re-verified against the new truth.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The shared parser logs through logger.shim; load the lib.logger stub first.
package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")

-- Put _shared/lua on the path so require("llm.parser") resolves to the oracle.
local shared_lua  = helpers.shared("lua/")
package.path = shared_lua .. "?.lua;" .. shared_lua .. "?/init.lua;" .. package.path

local parser = require("llm.parser")

local corpus_path = helpers.shared("tests/corpus/llm/process_prediction_vectors.json")




-- ============================================
-- ======= 1/ Corpus loading ==================
-- ============================================

--- Reads and JSON-decodes the shared corpus.
--- @return table|nil corpus, string|nil err
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

--- Coerces any truthy/falsey value to a strict boolean for comparison.
local function as_bool(v) return v and true or false end




-- ============================================
-- ======= 2/ Row-by-row oracle assertions ====
-- ============================================

helpers.describe("process_prediction corpus — shared oracle", function()
	helpers.it("corpus loads and has vectors", function()
		helpers.assert_eq(corpus_err, nil, "corpus_err: " .. tostring(corpus_err))
		helpers.assert_true(corpus ~= nil and type(corpus.vectors) == "table",
			"corpus.vectors must be a table")
	end)

	if not corpus or type(corpus.vectors) ~= "table" then return end

	for _, v in ipairs(corpus.vectors) do
		local vec = v
		helpers.it("[" .. tostring(vec.id) .. "] matches the oracle", function()
			local pred = parser.process_prediction(vec.full_text, vec.tail_text, vec.block,
				{ min_words = vec.min_words, max_words = vec.max_words })
			local exp = vec.expected
			if exp.is_nil then
				helpers.assert_true(pred == nil,
					"vector " .. vec.id .. ": expected nil prediction")
				return
			end
			helpers.assert_true(pred ~= nil, "vector " .. vec.id .. ": expected a prediction")
			helpers.assert_eq(pred.deletes, exp.deletes, "vector " .. vec.id .. ": deletes")
			helpers.assert_eq(pred.to_type, exp.to_type, "vector " .. vec.id .. ": to_type")
			helpers.assert_eq(pred.nw, exp.nw, "vector " .. vec.id .. ": nw")
			helpers.assert_eq(as_bool(pred.has_corrections), as_bool(exp.has_corrections),
				"vector " .. vec.id .. ": has_corrections")
			helpers.assert_eq(as_bool(pred.disable_bold), as_bool(exp.disable_bold),
				"vector " .. vec.id .. ": disable_bold")
		end)
	end
end)
