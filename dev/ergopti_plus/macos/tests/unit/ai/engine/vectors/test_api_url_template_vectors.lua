--- tests/unit/ai/engine/vectors/test_api_url_template_vectors.lua

--- ==============================================================================
--- MODULE: API URL Template Corpus (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/api_url_template_vectors.json through
--- _shared/ai/engine/api/url_template.lua, which fills the address of a
--- per-account provider (Azure resource, AWS region, Cloudflare account id,
--- Databricks workspace, Snowflake account) from the add-entry form.
---
--- ROOT CAUSE ENCODED:
--- A provider whose host depends on the account could only be reached through
--- the generic OpenAI-compatible entry, with the user typing its whole address;
--- a filled value must never add a host, a path or a query to it.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("core.text.engine.json")

local shared_lua = helpers.shared("/")
package.path = shared_lua .. "?.lua;" .. shared_lua .. "?/init.lua;" .. package.path

local Template = require("ai.engine.api.url_template")

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

--- Whether a decoded JSON value is null: the Linux decoder reads null as an
--- empty table, and no expectation of the corpus is an empty object.
local function is_null(value) return value == nil or (type(value) == "table" and next(value) == nil) end

helpers.describe("api_url_template replays the shared corpus", function()
	local corpus = read_json("tests/corpus/llm/api_url_template_vectors.json")

	helpers.it("the corpus pins the value bound and holds every section", function()
		helpers.assert_eq(Template.MAX_VALUE_LENGTH, corpus.max_value_length)
		helpers.assert_true(#corpus.fields >= 6 and #corpus.values >= 12 and #corpus.expand >= 6, "vectors")
	end)

	for _, v in ipairs(corpus.fields) do
		helpers.it("fields of '" .. v.template .. "'", function()
			local fields, reason = Template.fields(v.template)
			helpers.assert_eq(table.concat(fields, ","), table.concat(v.fields, ","), v.template)
			helpers.assert_eq(reason == nil, v.valid, v.template .. ": " .. tostring(reason))
		end)
	end

	for index, v in ipairs(corpus.values) do
		local value = v.value_repeat and string.rep(v.value_repeat, v.count) or v.value
		helpers.it("value vector " .. index, function()
			helpers.assert_eq(Template.valid_value(value), v.valid, value)
		end)
	end

	for index, v in ipairs(corpus.expand) do
		helpers.it("expand vector " .. index .. " (" .. v.template .. ")", function()
			local url, field = Template.expand(v.template, v.values)
			if is_null(v.url) then
				helpers.assert_nil(url, "refused")
				helpers.assert_eq(field, v.field)
			else
				helpers.assert_eq(url, v.url)
				helpers.assert_nil(field)
			end
		end)
	end

	for _, v in ipairs(corpus.placeholder) do
		helpers.it("placeholder in '" .. v.url .. "'", function()
			helpers.assert_eq(Template.has_placeholder(v.url), v.has, v.url)
		end)
	end

	for _, v in ipairs(corpus.optional_address.values) do
		helpers.it("optional address value '" .. v.value .. "'", function()
			local url = Template.optional_url(corpus.optional_address.block, v.value)
			if v.refused then helpers.assert_nil(url, "refused") else helpers.assert_eq(url, v.url) end
		end)
	end

	for index, v in ipairs(corpus.optional_address.blocks) do
		helpers.it("optional address block vector " .. index, function()
			helpers.assert_eq(Template.optional_problem(v.block) == nil, v.valid)
		end)
	end

	helpers.it("the catalogue's blocks are usable and every locale names their suffix", function()
		local catalogue = read_json("ai/data/api_providers.json")
		local optional = catalogue.providers.dashscope.optional_address
		helpers.assert_nil(Template.optional_problem(optional))
		for _, lang in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl", "no",
			"pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
			local locale = read_json("core/i18n/data/locales/" .. lang .. ".json")
			local text = locale["menu.llm.api_prompt_field_invalid." .. optional.field]
			helpers.assert_true(type(text) == "string" and text:find(optional.host_suffix, 1, true) ~= nil, lang)
			helpers.assert_true(type(locale["menu.llm.api_prompt_field." .. optional.field]) == "string", lang)
		end
	end)
end)
