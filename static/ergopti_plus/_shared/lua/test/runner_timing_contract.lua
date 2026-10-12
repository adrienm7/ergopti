--- _shared/lua/test/runner_timing_contract.lua

--- ==============================================================================
--- MODULE: Shared Lua Runner Timing Regression Contract
--- DESCRIPTION:
--- Exercises the real recorder on both interpreter families with recording
--- clocks and sinks. No native timing or operating-system qualification is made.
--- ==============================================================================

local Timing = require("test.runner_timing")
local M = {}

local function fixture(clock)
	local rows = {}
	return Timing.new("fixture", clock, function(row) rows[#rows + 1] = row end), rows
end

--- Registers the same recorder controls in each driver's existing runner owner.
--- @param helpers table Actual driver's describe/it/assertion functions.
function M.run(helpers)
	helpers.describe("Lua runner wall timing", function()
		helpers.it("Lua timing: records setup and body inside the same real protected interval", function()
			local calls, now = {}, 1000000
			local recorder, rows = fixture(function() calls[#calls + 1] = "clock"; return now end)
			local ok, result = recorder.measure("case", "subject", function()
				calls[#calls + 1] = "setup"; now = now + 2000000
				calls[#calls + 1] = "body"; now = now + 3000000
				return "original result"
			end, "tests.unit.owner")
			helpers.assert_true(ok)
			helpers.assert_eq(result, "original result")
			helpers.assert_eq(calls, { "clock", "setup", "body", "clock" })
			helpers.assert_eq(rows[1].elapsed_ms, 5)
			helpers.assert_eq(rows[1].module, "tests.unit.owner")
		end)

		helpers.it("Lua timing: retains actual callback failure identity and a completed fail row", function()
			local sentinel, now = {}, 0
			local recorder, rows = fixture(function() now = now + 1000000; return now end)
			local ok, err = recorder.measure("case", "fails", function() error(sentinel) end)
			helpers.assert_true(not ok and rawequal(err, sentinel))
			helpers.assert_eq(rows[1].status, "fail")
			helpers.assert_eq(rows[1].elapsed_ms, 1)
			helpers.assert_true(not recorder.has_errors())
		end)

		helpers.it("Lua timing: does not execute the body after its actual setup fails", function()
			local body_called, now, sentinel = false, 0, {}
			local recorder, rows = fixture(function() now = now + 1; return now end)
			local ok, err = recorder.case("setup", function() body_called = true end,
				function() error(sentinel) end, nil, "owner")
			helpers.assert_true(not ok and not body_called and rawequal(err, sentinel))
			helpers.assert_eq(#rows, 1)
			helpers.assert_eq(rows[1].status, "fail")
		end)

		helpers.it("Lua timing: records nested module and case intervals with distinct identities", function()
			local now = 0
			local recorder, rows = fixture(function() now = now + 1000000; return now end)
			recorder.measure("module", "owner", function()
				recorder.measure("case", "child", function() end, "owner")
			end, "owner")
			helpers.assert_eq(#rows, 2)
			helpers.assert_eq(rows[1].id, 2)
			helpers.assert_eq(rows[2].id, 1)
			helpers.assert_eq(rows[1].kind, "case")
			helpers.assert_eq(rows[2].elapsed_ms, 3)
		end)

		helpers.it("Lua timing: refuses missing native provider before minting a recorder", function()
			local previous = package.loaded.luv
			package.loaded.luv = {}
			local ok, err = pcall(Timing.capture, "fixture")
			package.loaded.luv = previous
			helpers.assert_true(not ok)
			helpers.assert_contains(tostring(err), "requires native luv.hrtime")
		end)

		helpers.it("Lua timing: retains an unavailable provider as startup refusal without fallback", function()
			local loaded, preload = package.loaded.luv, package.preload.luv
			package.loaded.luv = nil
			package.preload.luv = function() error("owned missing provider") end
			local ok, err = pcall(Timing.capture, "fixture")
			package.loaded.luv, package.preload.luv = loaded, preload
			helpers.assert_true(not ok)
			helpers.assert_contains(tostring(err), "requires native luv.hrtime")
		end)

		helpers.it("Lua timing: retains its captured clock after the provider table is replaced", function()
			local previous = package.loaded.luv
			local reads, now = 0, 0
			package.loaded.luv = { hrtime = function() reads = reads + 1; now = now + 1000000; return now end }
			local captured_rows = {}
			local ok, err = pcall(function()
				local recorder = Timing.capture("fixture", function(row) captured_rows[#captured_rows + 1] = row end)
				package.loaded.luv.hrtime = function() error("replacement must not be called") end
				package.loaded.luv = {}
				recorder.measure("case", "captured-clock-control", function() end)
				helpers.assert_true(not recorder.has_errors())
			end)
			package.loaded.luv = previous
			helpers.assert_true(ok, tostring(err))
			helpers.assert_eq(reads, 2)
			helpers.assert_eq(#captured_rows, 1)
		end)

		helpers.it("Lua timing: emits no row and calls neither clock nor setup for a filtered case", function()
			local reads, called = 0, false
			local recorder, rows = fixture(function() reads = reads + 1; return 0 end)
			local result = recorder.case("unrelated", function() called = true end,
				function() called = true end, "subject", "owner")
			helpers.assert_eq(result, nil)
			helpers.assert_eq(reads, 0)
			helpers.assert_eq(#rows, 0)
			helpers.assert_true(not called)
		end)

		helpers.it("Lua timing: retains the existing plain substring selection without Lua patterns", function()
			local now = 0
			local recorder, rows = fixture(function() now = now + 1; return now end)
			local ok = recorder.case("subject [x]", function() end, nil, "[x]", "owner")
			helpers.assert_true(ok)
			helpers.assert_eq(#rows, 1)
		end)

		for _, vector in ipairs({
			{ name = "negative", value = -1 }, { name = "NaN", value = 0 / 0 },
			{ name = "infinite", value = math.huge }, { name = "string", value = "10" },
		}) do
			helpers.it("Lua timing: marks " .. vector.name .. " clock data incomplete without replacing verdict", function()
				local called = false
				local recorder, rows = fixture(function() return vector.value end)
				local ok = recorder.measure("case", "invalid", function() called = true end)
				helpers.assert_true(ok and called and recorder.has_errors())
				helpers.assert_eq(rows[1].elapsed_ms, nil)
				helpers.assert_eq(rows[1].timing_error, "clock_invalid")
			end)
		end

		helpers.it("Lua timing: retains primary failure when clock and sink both throw", function()
			local sentinel = {}
			local recorder = Timing.new("fixture", function() error("clock") end, function() error("sink") end)
			local ok, err, row = recorder.measure("case", "primary", function() error(sentinel) end)
			helpers.assert_true(not ok and rawequal(err, sentinel) and recorder.has_errors())
			helpers.assert_eq(row.elapsed_ms, nil)
			helpers.assert_eq(row.timing_error, "clock_failed")
		end)

		helpers.it("Lua timing: refuses reversed clock intervals instead of reporting negative duration", function()
			local now = 3
			local recorder, rows = fixture(function() now = now - 1; return now end)
			recorder.measure("case", "reversed", function() end)
			helpers.assert_true(recorder.has_errors())
			helpers.assert_eq(rows[1].timing_error, "clock_reversed")
		end)

		helpers.it("Lua timing: escapes authored names and keeps explicit zero duration", function()
			local recorder, rows = fixture(function() return 0 end)
			recorder.measure("case", "Unicode é \"quote\"\nnext", function() end)
			local line = Timing.line(rows[1])
			helpers.assert_contains(line, '"elapsed_ms":0.000000')
			helpers.assert_contains(line, "\\u000a")
			helpers.assert_true(not line:find("\n", 1, true))
		end)
	end)
end

return M
