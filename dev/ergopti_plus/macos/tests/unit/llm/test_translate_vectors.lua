--- tests/unit/llm/test_translate_vectors.lua

--- ==============================================================================
--- MODULE: Selection Translation Corpus (shared Lua oracle)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/translate_vectors.json through the shared
--- translation helpers (_shared/lua/llm/translate.lua), which macOS and Linux
--- use and the AutoHotkey port replays too: the binding parameter, the target
--- language it resolves to, the prompt, the user turn and the answer reading.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local shared_lua = helpers.shared("lua/")
package.path = shared_lua .. "?.lua;" .. shared_lua .. "?/init.lua;" .. package.path

local Translate = require("llm.translate")

--- @param path string Shared-relative JSON path.
--- @return table decoded
local function read_json(path)
	local fh = assert(io.open(helpers.shared(path), "r"), "cannot open " .. path)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), path .. " is not valid JSON")
end




-- ============================================
-- ======= 1/ Corpus replay ===================
-- ============================================

helpers.describe("translation helpers replay the shared translate corpus", function()
	local corpus = read_json("tests/corpus/llm/translate_vectors.json")
	local config = read_json("modules/llm/translate.json")
	local names = read_json("data/locale_names.json")

	for _, v in ipairs(corpus.parse_vectors) do
		helpers.it("parse vector '" .. v.id .. "'", function()
			helpers.assert_eq(Translate.is_valid(v.value, config, names), v.valid, v.id)
		end)
	end

	for _, v in ipairs(corpus.target_vectors) do
		helpers.it("target vector '" .. v.id .. "'", function()
			local code = Translate.target_locale(Translate.parse(v.value, config, names), config, v.ui_locale)
			helpers.assert_eq(code, v.locale, v.id .. ": locale")
			helpers.assert_eq(Translate.language_name(code, names), v.language, v.id .. ": language")
		end)
	end

	for _, v in ipairs(corpus.prompt_vectors) do
		helpers.it("prompt vector '" .. v.id .. "'", function()
			helpers.assert_eq(Translate.system_prompt(config, v.language), v.prompt, v.id)
		end)
	end

	for _, v in ipairs(corpus.user_text_vectors) do
		helpers.it("user text vector '" .. v.id .. "'", function()
			helpers.assert_eq(Translate.user_text(config, v.text), v.user_text, v.id)
		end)
	end

	for _, v in ipairs(corpus.extract_vectors) do
		helpers.it("extract vector '" .. v.id .. "'", function()
			helpers.assert_eq(Translate.extract(config, v.block), v.text, v.id)
		end)
	end
end)




-- ============================================
-- ======= 2/ Choices =========================
-- ============================================

helpers.describe("the translation target choices follow the language menu", function()
	helpers.it("offers the interface language first, then every shipped locale in menu order", function()
		local config = read_json("modules/llm/translate.json")
		local names = read_json("data/locale_names.json")
		local order = read_json("data/locale_order.json")
		local choices = Translate.choices(names, order, config, "Interface")
		helpers.assert_eq(choices[1].value, config.ui_value)
		helpers.assert_eq(choices[1].label, "Interface")
		helpers.assert_eq(#choices, #order.order + 1)
		for i, code in ipairs(order.order) do
			helpers.assert_eq(choices[i + 1].value, code)
			helpers.assert_true(Translate.is_valid(code, config, names), code .. " must be accepted")
		end
	end)
end)
