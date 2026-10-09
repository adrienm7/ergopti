--- tests/unit/llm/test_vision_vectors.lua

--- ==============================================================================
--- MODULE: Screen Reading Corpus (shared Lua oracle)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/vision_vectors.json through the shared
--- screen-reading helpers (_shared/lua/llm/vision.lua), which macOS and Linux
--- use and the AutoHotkey port replays too: the binding parameter, the vision
--- model it resolves to, each API dialect's request body and the answer reading.
---
--- ROOT CAUSE ENCODED:
--- No request could carry an image: every backend sent text only, so no
--- action could read what is on the screen.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local shared_lua = helpers.shared("lua/")
package.path = shared_lua .. "?.lua;" .. shared_lua .. "?/init.lua;" .. package.path

local Vision = require("llm.vision")

--- @param path string Shared-relative JSON path.
--- @return table decoded
local function read_json(path)
	local fh = assert(io.open(helpers.shared(path), "r"), "cannot open " .. path)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), path .. " is not valid JSON")
end

--- Compares two decoded JSON values structurally.
--- @return boolean equal, string|nil where
local function deep_equal(a, b, where)
	where = where or "$"
	if type(a) ~= type(b) then return false, where .. ": " .. type(a) .. " vs " .. type(b) end
	if type(a) ~= "table" then return a == b, a == b and nil or (where .. ": " .. tostring(a) .. " vs " .. tostring(b)) end
	for k, v in pairs(a) do
		local ok, why = deep_equal(v, b[k], where .. "." .. tostring(k))
		if not ok then return false, why end
	end
	for k in pairs(b) do
		if a[k] == nil then return false, where .. "." .. tostring(k) .. " is missing" end
	end
	return true
end




-- ============================================
-- ======= 1/ Corpus replay ===================
-- ============================================

helpers.describe("screen reading helpers replay the shared vision corpus", function()
	local corpus = read_json("tests/corpus/llm/vision_vectors.json")
	local config = read_json("modules/llm/vision.json")

	for _, v in ipairs(corpus.parse_vectors) do
		helpers.it("parse vector '" .. v.id .. "'", function()
			local parsed = Vision.parse(v.value)
			if v.valid == false then
				helpers.assert_eq(parsed, nil, v.id)
			else
				helpers.assert_true(parsed ~= nil, v.id .. " must parse")
				helpers.assert_eq(parsed.backend, v.backend, v.id .. ": backend")
				helpers.assert_eq(parsed.model, v.model, v.id .. ": model")
			end
		end)
	end

	for _, v in ipairs(corpus.model_vectors) do
		helpers.it("model vector '" .. v.id .. "'", function()
			helpers.assert_eq(Vision.resolve_model(Vision.parse(v.value), config), v.model, v.id)
		end)
	end

	for _, v in ipairs(corpus.request_vectors) do
		helpers.it("request vector '" .. v.id .. "'", function()
			local ok, why = deep_equal(Vision.build_request(v.format, v.spec), v.body)
			helpers.assert_true(ok, v.id .. ": " .. tostring(why))
		end)
	end

	for _, v in ipairs(corpus.extract_vectors) do
		helpers.it("extract vector '" .. v.id .. "'", function()
			helpers.assert_eq(Vision.extract(v.block, v.tag), v.text, v.id)
		end)
	end
end)




-- ============================================
-- ======= 2/ Shipped configuration ===========
-- ============================================

helpers.describe("vision.json holds what the screen actions need", function()
	helpers.it("prompts, tags and answers are complete", function()
		local config = read_json("modules/llm/vision.json")
		helpers.assert_true(config.read_prompt:find(config.screen_tag, 1, true) ~= nil,
			"the reading prompt must ask for the screen tag")
		helpers.assert_eq(#config.answers, 3, "reply, translate, explain")
		for _, answer in ipairs(config.answers) do
			helpers.assert_true(answer.prompt:find(config.answer_tag, 1, true) ~= nil,
				answer.id .. " must ask for the answer tag")
		end
		helpers.assert_true(config.default_models[Vision.LOCAL_BACKEND] ~= nil, "a local default model")
	end)

	helpers.it("the error explanation offers the cause, then the fix", function()
		local config = read_json("modules/llm/vision.json")
		helpers.assert_eq(#config.error_answers, 2)
		helpers.assert_eq(config.error_answers[1].id, "cause")
		helpers.assert_eq(config.error_answers[2].id, "fix")
		helpers.assert_true(config.error_answers[1].prompt:find("{language}", 1, true) ~= nil,
			"the explanation is written in the interface language")
		for _, answer in ipairs(config.error_answers) do
			helpers.assert_true(answer.prompt:find(config.answer_tag, 1, true) ~= nil,
				answer.id .. " must ask for the answer tag")
		end
	end)
end)
