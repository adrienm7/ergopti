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
	for _, suffix in ipairs({ "", ".corrupt", ".corrupt.1", ".tmp" }) do os.remove(path .. suffix) end
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

helpers.describe("agent learning quarantine ownership", function()
	for _, boundary in ipairs({ "read", "close" }) do
		for _, refusal in ipairs({ "nil", "false", "throw" }) do
			helpers.it("(agent-learning-quarantine) preserves a source after " .. boundary .. " " .. refusal, function()
				local source = PREFIX .. "7" .. SUFFIX
				with_source(source, function(Learning, path, config)
					local open, fault, handles, opened, closed = io.open, true, {}, 0, 0
					local function refused()
						if refusal == "throw" then error("controlled stream refusal", 0) end
						if refusal == "false" then return false end
						return nil
					end
					io.open = function(candidate, mode)
						local file, detail, errno = open(candidate, mode)
						if not file or not fault or candidate ~= path or mode ~= "r" then return file, detail, errno end
						handles[#handles + 1] = file; opened = opened + 1
						return {
							read = function(_, ...)
								if boundary == "read" then return refused() end
								return file:read(...)
							end,
							close = function()
								closed = closed + 1; assert(file:close())
								if boundary == "close" then return refused() end
								return true
							end,
						}
					end
					local okay, detail = xpcall(function()
						local called, threshold = pcall(Learning.threshold, config, "Mail", "calendar")
						local learned = called and Learning.record(config, "Mail", "calendar", true)
						local flushed = called and Learning.flush()
						helpers.assert_eq(read(path), source, "an I/O refusal is never a malformed source")
						helpers.assert_nil(read(path .. ".corrupt"))
						helpers.assert_true(called, "the unavailable store returns the default without leaking a read exception")
						helpers.assert_eq({ threshold, learned }, { config.system1.threshold, config.system1.threshold })
						helpers.assert_eq(flushed, false)
						helpers.assert_true(opened > 0)
						helpers.assert_eq(closed, opened, "every owned stream is closed once, including after a thrown read")
						fault = false
						local accepted = Learning.record(config, "Mail", "calendar", true)
						helpers.assert_true(Learning.flush())
						local saved = assert(Json.decode_lossless(read(path)))
						helpers.assert_eq(saved.apps.Mail.used, 8)
						helpers.assert_eq(saved.apps.Mail.thresholds.calendar, accepted)
					end, debug.traceback)
					io.open = open
					for _, handle in ipairs(handles) do pcall(handle.close, handle) end
					if not okay then error(detail, 0) end
				end)
			end)
		end
	end

	helpers.it("(agent-learning-quarantine) keeps an unreadable source authoritative until a later read succeeds", function()
		local source = PREFIX .. "7" .. SUFFIX
		with_source(source, function(Learning, path, config)
			local open, fault = io.open, true
			io.open = function(candidate, mode)
				if fault and candidate == path and mode == "r" then return nil, "controlled read refusal", 13 end
				return open(candidate, mode)
			end
			local okay, detail = xpcall(function()
				helpers.assert_eq(Learning.threshold(config, "Mail", "calendar"), config.system1.threshold)
				local refused = Learning.record(config, "Mail", "calendar", true)
				local flushed = Learning.flush()
				helpers.assert_eq(read(path), source)
				helpers.assert_eq(refused, config.system1.threshold)
				helpers.assert_eq(flushed, false)
				helpers.assert_nil(read(path .. ".corrupt"))
				fault = false
				local learned = Learning.record(config, "Mail", "calendar", true)
				helpers.assert_eq(learned, require("llm.agent").learn(config, 0.2, true))
				helpers.assert_true(Learning.flush())
				local saved = assert(Json.decode_lossless(read(path)))
				helpers.assert_eq(saved.apps.Mail.used, 8)
				helpers.assert_eq(saved.apps.Mail.thresholds.calendar, learned)
			end, debug.traceback)
			io.open = open
			if not okay then error(detail, 0) end
		end)
	end)

	for _, occupied in ipairs({ "file", "directory" }) do
		helpers.it("(agent-learning-quarantine) preserves an occupied " .. occupied .. " recovery path", function()
			local source = "invalid original learning"
			with_source(source, function(Learning, path, config)
				local Shell = require("adapters.shell_runner")
				if occupied == "file" then
					local file = assert(io.open(path .. ".corrupt", "wb"))
					assert(file:write("previous recovery")); assert(file:close())
				else assert(Shell.run("mkdir -- " .. Shell.quote(path .. ".corrupt"))) end
				helpers.assert_eq(Learning.threshold(config, "Mail", "calendar"), config.system1.threshold)
				local learned = Learning.record(config, "Mail", "calendar", true)
				helpers.assert_true(Learning.flush())
				if occupied == "file" then helpers.assert_eq(read(path .. ".corrupt"), "previous recovery")
				else helpers.assert_true(Shell.run("test -d " .. Shell.quote(path .. ".corrupt"))) end
				helpers.assert_eq(read(path .. ".corrupt.1"), source, "the newly rejected source has its own recovery name")
				helpers.assert_eq(assert(Json.decode_lossless(read(path))).apps.Mail.thresholds.calendar, learned)
				helpers.assert_eq(read(path .. ".corrupt.1"), source)
			end)
		end)
	end

	for _, refusal in ipairs({ "nil", "false", "throw" }) do
		helpers.it("(agent-learning-quarantine) blocks publication after a " .. refusal .. " preservation receipt", function()
			local source = "invalid source retained during recovery refusal"
			with_source(source, function(Learning, path, config)
				local Move = require("infra.no_replace_move")
				local rename, move, fault = os.rename, Move.move, true
				local function refused()
					if refusal == "throw" then error("controlled preservation refusal", 0) end
					if refusal == "false" then return false, "controlled preservation refusal" end
					return nil, "controlled preservation refusal"
				end
				os.rename = function(from, to)
					if fault and from == path then return refused() end
					return rename(from, to)
				end
				Move.move = function(from, to)
					if fault and from == path then return refused() end
					return move(from, to)
				end
				local okay, detail = xpcall(function()
					local called, threshold = pcall(Learning.threshold, config, "Mail", "calendar")
					helpers.assert_true(called, "a rejected quarantine is an explicit unavailable store")
					helpers.assert_eq(threshold, config.system1.threshold)
					local refused = Learning.record(config, "Mail", "calendar", true)
					local flushed = Learning.flush()
					helpers.assert_eq(read(path), source)
					helpers.assert_eq(refused, config.system1.threshold)
					helpers.assert_eq(flushed, false, "a failed preservation never authorizes replacing its source")
					helpers.assert_nil(read(path .. ".tmp"), "publication does not even begin")
					fault = false
					local learned = Learning.record(config, "Mail", "calendar", true)
					helpers.assert_eq(read(path .. ".corrupt"), source, "a later successful preservation retains the original")
					helpers.assert_true(Learning.flush())
					helpers.assert_eq(assert(Json.decode_lossless(read(path))).apps.Mail.thresholds.calendar, learned)
				end, debug.traceback)
				os.rename, Move.move = rename, move
				if not okay then error(detail, 0) end
			end)
		end)
	end
end)
