--- tests/unit/adapters/test_process_lifecycle.lua
---
--- ==============================================================================
--- MODULE: Process Snapshot Failures Must Not Synthesize Mass Events
--- DESCRIPTION:
--- A failed `ps` snapshot used to read as an empty machine: the tick diffed it
--- against the last known set, firing a quit callback for EVERY known process,
--- then a launch callback for every one of them when ps recovered. A transient
--- fork failure therefore looked like the whole desktop quitting and relaunching
--- within four seconds.
---
--- These tests drive the real M.start()/M.tick() with a stubbed io.popen and
--- assert on the exact callback sequences.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs body with io.popen stubbed to replay canned `ps` outputs.
--- Each entry of outputs is either a string (ps stdout, exit 0) or false (fork
--- failure: io.popen returns nil). A table carries { output, status } for a
--- real checked-runner status frame. Restores io.popen even on failure.
--- @param outputs table Array of string|false.
--- @param body function Receives nothing; reads popen calls in order.
local function with_ps(outputs, body)
	local real_popen = io.popen
	local at = 0
	io.popen = function(cmd)
		at = at + 1
		local out = outputs[at]
		if out == nil then out = outputs[#outputs] end
		if out == false then return nil end
		local receipt = type(out) == "table" and out or { output = tostring(out), status = 0 }
		local content = receipt.output
		-- Fixture strings include the conventional header. A headerless request
		-- removes only that first protocol row; subsequent COMMAND rows are data.
		if cmd:find("ps -eo comm=", 1, true) then content = content:gsub("^COMMAND\n", "", 1) end
		local lines = {}
		for line in (content .. "\n"):gmatch("([^\n]*)\n") do
			lines[#lines + 1] = line
		end
		local pos = 0
		return {
			read = function() return string.format("%d %d\n%s\nERGOPTI_CAPTURE_COMPLETE\n", receipt.status, #content, content) end,
			lines = function()
				return function()
					pos = pos + 1
					return lines[pos]
				end
			end,
			close = function() return true end,
		}
	end
	local ok, err = pcall(body)
	io.popen = real_popen
	if not ok then error(err, 0) end
end

--- Fresh lifecycle module with recording launch/quit callbacks.
--- @return table module, table launched, table quit
local function fresh_lifecycle()
	local M = helpers.load_module("adapters.process_lifecycle")
	local launched, quit = {}, {}
	M.onAppLaunch(function(name) launched[#launched + 1] = name end)
	M.onAppQuit(function(name) quit[#quit + 1] = name end)
	return M, launched, quit
end

local PS_AB = "COMMAND\na\nb\n"
local PS_ABC = "COMMAND\na\nb\nc\n"
local PS_AC = "COMMAND\na\nc\n"

-- process_every = floor(2.0 / 0.25) = 8: the process poll runs on these ticks.
local PROCESS_TICK = 8

helpers.describe("linux-process-snapshot-receipts", function()
	for _, status in ipairs({ 1, 7, 127, 143 }) do
		helpers.it("linux-process-snapshot-receipts: failed status " .. status .. " cannot replace a successful baseline", function()
			with_ps({ PS_ABC }, function()
				local M, launched, quit = fresh_lifecycle()
				M.start()
				with_ps({ { output = PS_AB, status = status } }, function() M.tick(PROCESS_TICK) end)
				helpers.assert_eq(quit, {}, "nonempty partial stdout cannot prove any process quit")
				helpers.assert_eq(launched, {})
				with_ps({ PS_AC }, function() M.tick(PROCESS_TICK * 2) end)
				M.stop()
				helpers.assert_eq(quit, { "b" }, "recovery diffs only the last successful baseline")
				helpers.assert_eq(launched, {}, "partial failure cannot synthesize a recovery launch")
			end)
		end)
		helpers.it("linux-process-snapshot-receipts: failed status " .. status .. " cannot seed startup ownership", function()
			with_ps({ { output = PS_AB, status = status } }, function()
				local M, launched, quit = fresh_lifecycle()
				M.start()
				with_ps({ PS_ABC }, function() M.tick(PROCESS_TICK) end)
				M.stop()
				helpers.assert_eq(launched, {}, "the first trustworthy snapshot silently adopts existing processes")
				helpers.assert_eq(quit, {})
			end)
		end)
	end
end)

helpers.describe("linux-process-header-receipts", function()
	helpers.it("linux-process-header-receipts: COMMAND launches and quits as an ordinary process", function()
		with_ps({ PS_AB }, function()
			local M, launched, quit = fresh_lifecycle()
			M.start()
			with_ps({ PS_AB .. "COMMAND\n" }, function() M.tick(PROCESS_TICK) end)
			helpers.assert_eq(launched, { "COMMAND" }, "protocol headers cannot reserve a legitimate application name")
			with_ps({ PS_AB }, function() M.tick(PROCESS_TICK * 2) end)
			M.stop()
			helpers.assert_eq(quit, { "COMMAND" })
		end)
	end)
	helpers.it("linux-process-header-receipts: COMMAND present at startup remains in the baseline", function()
		with_ps({ PS_AB .. "COMMAND\n" }, function()
			local M, launched, quit = fresh_lifecycle()
			M.start()
			with_ps({ PS_AB }, function() M.tick(PROCESS_TICK) end)
			M.stop()
			helpers.assert_eq(launched, {})
			helpers.assert_eq(quit, { "COMMAND" }, "startup must retain every real row")
		end)
	end)
end)

helpers.describe("linux-process-name-byte-receipts", function()
	for index, name in ipairs({ " ep lead", "ep trail ", " ep both ", "   " }) do
		helpers.it("linux-process-name-byte-receipts: native whitespace case " .. index .. " launches and quits exactly", function()
			with_ps({ PS_AB }, function()
				local M, launched, quit = fresh_lifecycle()
				M.start()
				with_ps({ PS_AB .. name .. "\n" }, function() M.tick(PROCESS_TICK) end)
				helpers.assert_eq(launched, { name }, "native name bytes cannot be treated as column padding")
				with_ps({ PS_AB }, function() M.tick(PROCESS_TICK * 2) end)
				M.stop()
				helpers.assert_eq(quit, { name })
			end)
		end)
	end
	helpers.it("linux-process-name-byte-receipts: a live neighbor cannot hide a distinct whitespace identity", function()
		with_ps({ PS_AB .. "ep pair\n" }, function()
			local M, launched, quit = fresh_lifecycle()
			M.start()
			with_ps({ PS_AB .. "ep pair\n ep pair \n" }, function() M.tick(PROCESS_TICK) end)
			helpers.assert_eq(launched, { " ep pair " })
			with_ps({ PS_AB .. "ep pair\n" }, function() M.tick(PROCESS_TICK * 2) end)
			helpers.assert_eq(quit, { " ep pair " }, "trimmed alias cannot hide the neighbor's real retirement")
			with_ps({ PS_AB }, function() M.tick(PROCESS_TICK * 3) end)
			M.stop()
			helpers.assert_eq(quit, { " ep pair ", "ep pair" })
		end)
	end)
end)

helpers.describe("process_lifecycle: a failed snapshot fires nothing (ps-storm)", function()

	helpers.it("ps-storm: a failed ps reports no quits and no launches", function()
		with_ps({ PS_AB }, function()
			local M, launched, quit = fresh_lifecycle()
			M.start()
			with_ps({ false }, function()
				M.tick(PROCESS_TICK)
			end)
			M.stop()
			helpers.assert_eq(#quit, 0,
				"a failed snapshot is not an empty machine — quitting every process is fabricated")
			helpers.assert_eq(#launched, 0,
				"and nothing launched either")
		end)
	end)

	helpers.it("ps-storm: recovery after a failure reports only the real delta", function()
		with_ps({ PS_AB }, function()
			local M, launched, quit = fresh_lifecycle()
			M.start()
			with_ps({ false }, function()
				M.tick(PROCESS_TICK)
			end)
			with_ps({ PS_ABC }, function()
				M.tick(PROCESS_TICK)
			end)
			M.stop()
			helpers.assert_eq(quit, {},
				"no process quit across a ps failure and its recovery")
			helpers.assert_eq(launched, { "c" },
				"only the genuinely new process reports as launched")
		end)
	end)

	helpers.it("ps-storm: empty ps output is a failure, not an empty desktop", function()
		with_ps({ PS_AB }, function()
			local M, launched, quit = fresh_lifecycle()
			M.start()
			with_ps({ "COMMAND\n" }, function()
				M.tick(PROCESS_TICK)
			end)
			M.stop()
			helpers.assert_eq(#quit, 0,
				"a header-only read must not quit every known process")
			helpers.assert_eq(#launched, 0)
		end)
	end)

	helpers.it("ps-storm: a failed start adopts the first snapshot silently", function()
		with_ps({ false }, function()
			local M, launched, quit = fresh_lifecycle()
			M.start()
			with_ps({ PS_AB }, function()
				M.tick(PROCESS_TICK)
			end)
			M.stop()
			helpers.assert_eq(launched, {},
				"processes already running when ps recovers did not launch")
			helpers.assert_eq(quit, {})
		end)
	end)

	helpers.it("ps-storm: the ordinary diff still reports real launches and quits", function()
		-- Without this, the three cases above pass on a module that never
		-- diffs at all — which is precisely the failure being fenced here,
		-- one level down.
		with_ps({ PS_AB }, function()
			local M, launched, quit = fresh_lifecycle()
			M.start()
			with_ps({ PS_ABC }, function()
				M.tick(PROCESS_TICK)
			end)
			helpers.assert_eq(launched, { "c" }, "a real launch must still fire")
			with_ps({ PS_AC }, function()
				M.tick(PROCESS_TICK)
			end)
			M.stop()
			helpers.assert_eq(quit, { "b" }, "a real quit must still fire")
		end)
	end)

end)
