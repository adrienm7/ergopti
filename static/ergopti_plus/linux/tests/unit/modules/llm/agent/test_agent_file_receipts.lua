--- tests/unit/modules/llm/agent/test_agent_file_receipts.lua

--- ==============================================================================
--- MODULE: Agent File Completion Receipts (Linux)
--- DESCRIPTION:
--- A failed write or buffered close must neither publish learned thresholds nor
--- hand an incomplete calendar file to a desktop application. Real private files
--- carry the partial bytes; only their write/close receipts are faulted.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Shell = require("adapters.shell_runner")

local FAULTS = { "write_nil", "write_false", "write_throw", "close_nil", "close_false", "close_throw" }

--- Exercises one fresh owner and closes every real stream even on the old bug.
--- @param name string Module under test.
--- @param body function Receives owner, private directory and stream observations.
local function with_files(name, body)
	local previous, original_open = package.loaded[name], io.open
	local dir = os.tmpname()
	assert(os.remove(dir)); assert(Shell.run("mkdir " .. Shell.quote(dir)))
	package.loaded[name] = nil
	local owner = require(name)
	local state = { handles = {}, closes = 0 }
	function state.read(path)
		local file = assert(original_open(path, "rb"))
		local text = assert(file:read("*a")); assert(file:close())
		return text
	end
	function state.fault(kind)
		io.open = function(path, mode)
			local stream, reason = original_open(path, mode)
			if not stream or type(path) ~= "string" or path:sub(1, #dir + 1) ~= dir .. "/"
				or (mode ~= "w" and mode ~= "wb") then return stream, reason end
			local record = { stream = stream, closed = false }
			state.handles[#state.handles + 1] = record
			return {
				write = function(_, text)
					assert(stream:write(kind:match("^write_") and text:sub(1, 7) or text))
					if kind == "write_throw" then error("controlled partial write") end
					if kind == "write_nil" then return nil, "controlled full device" end
					if kind == "write_false" then return false, "controlled refused write" end
					return stream
				end,
				close = function()
					state.closes = state.closes + 1
					assert(stream:close()); record.closed = true
					if kind == "close_throw" then error("controlled buffered close") end
					if kind == "close_nil" then return nil, "controlled close failure" end
					if kind == "close_false" then return false, "controlled refused close" end
					return true
				end,
			}
		end
	end
	function state.restore() io.open = original_open end
	local ok, detail = xpcall(function() body(owner, dir, state) end, debug.traceback)
	io.open = original_open
	for _, record in ipairs(state.handles) do
		if not record.closed then record.stream:close() end
	end
	if name == "modules.llm.agent_connectors" then pcall(owner.shutdown) end
	package.loaded[name] = previous
	assert(Shell.run("rm -rf -- " .. Shell.quote(dir)))
	if not ok then error(detail, 0) end
end

helpers.describe("agent file completion receipts", function()
	for _, fault in ipairs(FAULTS) do
		helpers.it("(agent-file-receipts) learning preserves its committed source on " .. fault, function()
			with_files("modules.llm.agent_learning", function(Learning, dir, state)
				local path = dir .. "/learning.json"
				local original = '{"version":1,"apps":{"Mail":{"used":1,"thresholds":{"calendar":0.7}}}}'
				local file = assert(io.open(path, "wb")); assert(file:write(original)); assert(file:close())
				local config = { system1 = { threshold = 0.7 },
					learning = { step = 0.05, min_threshold = 0.1, max_threshold = 0.95 } }
				Learning._reset_for_test({ path = path, scheduler = {
					after = function() return { armed = true } end, cancel = function() return true end,
				} })
				helpers.assert_eq(Learning.threshold(config, "Mail", "calendar"), 0.7)
				local learned = Learning.record(config, "Mail", "calendar", true)
				state.fault(fault)
				local called, saved = pcall(Learning.flush)
				state.restore()
				helpers.assert_true(called, "native write/close refusal is a failed save, not an exception")
				helpers.assert_eq(saved, false)
				helpers.assert_eq(state.closes, 1, "every acquired stream is closed after its write result")
				helpers.assert_eq(state.read(path), original, "partial staging bytes never replace the valid state")
				helpers.assert_eq(Learning.threshold(config, "Mail", "calendar"), learned, "the pending learning survives")
				helpers.assert_true(Learning.flush(), "a healthy later save can publish the retained learning")
				helpers.assert_eq(assert(Json.decode(state.read(path))).apps.Mail.thresholds.calendar, learned)
			end)
		end)

		helpers.it("(agent-file-receipts) calendar refuses desktop handoff on " .. fault, function()
			with_files("modules.llm.agent_connectors", function(Connector, dir, state)
				local starts, completed, directories, payload = 0, {}, 0, nil
				Connector._set_deps_for_test({
					private_dir = function()
						directories = directories + 1
						local path = dir .. "/calendar" .. directories
						assert(Shell.run("mkdir " .. Shell.quote(path))); return path
					end,
					random_hex = function() return "00ff" end,
					utc_stamp = function() return "20261023T120000Z" end,
					run = function(executable, args, _, callback)
						starts = starts + 1
						helpers.assert_eq(executable, "xdg-open")
						payload = state.read(args[1])
						callback({ ok = true, code = 0 }); return {}
					end,
				})
				local file = assert(io.open(helpers.driver_root() .. "/../_shared/modules/llm/agent.json", "r"))
				local config = assert(Json.decode(file:read("*a"))); assert(file:close())
				local action = { type = "reminder", title = "Owned reminder" }
				local function done(accepted) completed[#completed + 1] = accepted end
				state.fault(fault)
				local called, started = pcall(Connector.run, config, action, done)
				state.restore()
				helpers.assert_true(called, "stream failure becomes the connector's explicit refusal")
				helpers.assert_eq(started, false)
				helpers.assert_eq(state.closes, 1)
				helpers.assert_eq(starts, 0, "an incomplete calendar never reaches a desktop launcher")
				helpers.assert_eq(completed, { false }, "one failed action receipt")
				helpers.assert_true(Connector.run(config, action, done), "the following healthy action still runs")
				helpers.assert_eq(starts, 1)
				helpers.assert_eq(completed, { false, true })
				helpers.assert_contains(payload, "BEGIN:VTODO")
				helpers.assert_contains(payload, "SUMMARY:Owned reminder")
			end)
		end)
	end
end)
