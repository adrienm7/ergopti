--- tests/unit/modules/llm/vectors/test_api_url_template_vectors.lua

--- ==============================================================================
--- MODULE: API URL Template Corpus (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/api_url_template_vectors.json through
--- _shared/lua/llm/api_url_template.lua, which fills the address of a
--- per-account provider (Azure resource, AWS region, Cloudflare account id,
--- Databricks workspace, Snowflake account) from the add-entry form.
---
--- ROOT CAUSE ENCODED:
--- A provider whose host depends on the account could only be reached through
--- the generic OpenAI-compatible entry, with the user typing its whole address;
--- a filled value must never add a host, a path or a query to it.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local SHARED = helpers.driver_root() .. "/../_shared/"

local Template = require("llm.api_url_template")

--- @param path string Shared-relative JSON path.
--- @return table decoded
local function read_json(path)
	local fh = assert(io.open(SHARED .. path, "r"), "cannot open " .. path)
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
end)
