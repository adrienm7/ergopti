--- tests/unit/modules/llm/agent/test_agent_learning_source.lua

--- ==============================================================================
--- MODULE: Agent Learning JSON Source Admission (Linux)
--- DESCRIPTION:
--- Only complete, unambiguous JSON may seed learned thresholds and the LRU
--- sequence. Legacy decoding admits overflow numbers which can leave eviction
--- without an oldest entry; malformed input must take the existing quarantine.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- Reads exact fixture bytes, including an absent quarantined source.
--- @param path string
--- @return string|nil
local function read(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local text = file:read("*a"); assert(file:close()); return text
end

--- Owns every file and uses a scheduler which cannot publish behind assertions.
--- @param source string Source image under test.
--- @param body function Receives learning owner, source path and actual config.
local function with_source(source, body)
	local path = os.tmpname()
	local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
	assert(read(path .. ".corrupt") == nil)
	local previous = package.loaded["modules.llm.agent_learning"]
	package.loaded["modules.llm.agent_learning"] = nil
	local Learning = require("modules.llm.agent_learning")
	Learning._reset_for_test({ path = path, scheduler = {
		after = function() return { armed = true } end, cancel = function() return true end,
	} })
	local config = assert(Json.decode_lossless(assert(read(helpers.driver_root() .. "/../_shared/modules/llm/agent.json"))))
	local ok, detail = xpcall(function() body(Learning, path, config) end, debug.traceback)
	Learning._reset_for_test()
	package.loaded["modules.llm.agent_learning"] = previous
	for _, suffix in ipairs({ "", ".corrupt", ".tmp" }) do os.remove(path .. suffix) end
	if not ok then error(detail, 0) end
end

local PREFIX = '{"version":1,"apps":{"Mail":{"used":'
local SUFFIX = ',"thresholds":{"calendar":0.2}}}}'

helpers.describe("agent learning source admission", function()
	for _, candidate in ipairs({
		{ name = "overflow number", source = PREFIX .. "1e999" .. SUFFIX },
		{ name = "leading-zero number", source = PREFIX .. "01" .. SUFFIX },
		{ name = "trailing bytes", source = PREFIX .. "1" .. SUFFIX .. " trailing" },
		{ name = "duplicate root key", source = (PREFIX .. "1" .. SUFFIX):sub(1, -2) .. ',"version":1}' },
	}) do
		helpers.it("(agent-learning-source) quarantines the exact " .. candidate.name .. " source", function()
			with_source(candidate.source, function(Learning, path, config)
				helpers.assert_eq(Learning.threshold(config, "Mail", "calendar"), config.system1.threshold)
				helpers.assert_eq(read(path .. ".corrupt"), candidate.source)
				helpers.assert_nil(read(path), "the invalid file is retained separately, never adopted")
			end)
		end)
	end

	helpers.it("(agent-learning-source) overflow LRU clocks cannot crash a later record", function()
		local apps = {}
		local limit = require("modules.llm.agent_learning").MAX_APPS
		for index = 1, limit + 1 do
			apps[#apps + 1] = string.format('"app%d":{"used":1e999,"thresholds":{}}', index)
		end
		local source = '{"version":1,"apps":{' .. table.concat(apps, ",") .. '}}'
		with_source(source, function(Learning, path, config)
			local okay, learned = pcall(Learning.record, config, "fresh", "calendar", true)
			helpers.assert_true(okay, "all-infinite LRU entries cannot make the oldest key nil")
			helpers.assert_eq(learned, require("llm.agent").learn(config, config.system1.threshold, true))
			helpers.assert_eq(read(path .. ".corrupt"), source)
			helpers.assert_true(Learning.flush())
			local saved = assert(Json.decode_lossless(read(path)))
			helpers.assert_eq(saved.apps.fresh.used, 1)
			helpers.assert_nil(saved.apps.app1)
		end)
	end)

	helpers.it("(agent-learning-source) preserves valid thresholds and resumes their finite sequence", function()
		local source = PREFIX .. "7" .. SUFFIX
		with_source(source, function(Learning, path, config)
			helpers.assert_eq(Learning.threshold(config, "Mail", "calendar"), 0.2)
			helpers.assert_eq(read(path), source)
			helpers.assert_nil(read(path .. ".corrupt"))
			local learned = Learning.record(config, "Mail", "calendar", true)
			helpers.assert_true(Learning.flush())
			local saved = assert(Json.decode_lossless(read(path)))
			helpers.assert_eq(saved.apps.Mail.used, 8)
			helpers.assert_eq(saved.apps.Mail.thresholds.calendar, learned)
		end)
	end)
end)
