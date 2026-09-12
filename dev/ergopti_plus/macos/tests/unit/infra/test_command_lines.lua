--- tests/unit/infra/test_command_lines.lua

--- ==============================================================================
--- MODULE: Command Output Ownership Tests
--- DESCRIPTION:
--- Real child exit statuses and controlled stream failures must reject partial
--- output without leaking the pipe or losing the original iteration error.
--- ==============================================================================

local helpers = require("tests.helpers")
local Reader = require("tests.support.command_lines")

local function with_popen(factory, callback)
	local original = io.popen
	io.popen = factory
	local result = table.pack(pcall(callback))
	io.popen = original
	if not result[1] then error(result[2], 0) end
	return table.unpack(result, 2, result.n)
end

helpers.describe("complete command output", function()
	helpers.it("(command-lines) accepts real successful output and rejects a real failed child", function()
		local windows = package.config:sub(1, 1) == "\\"
		local success = windows and 'cmd /d /c "echo first&echo second&exit /b 0"'
			or "printf 'first\\nsecond\\n'; exit 0"
		local failure = windows and 'cmd /d /c "echo partial&exit /b 7"'
			or "printf 'partial\\n'; exit 7"
		helpers.assert_eq(Reader.read(success), { "first", "second" })
		local ok, reason = pcall(Reader.read, failure)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(reason):find("exit 7", 1, true) ~= nil)
	end)

	for _, mode in ipairs({ "iteration", "close_throw", "close_refusal", "empty" }) do
		helpers.it("(command-lines) owns stream settlement for " .. mode, function()
			local closes, emitted = 0, false
			local sentinel = {}
			with_popen(function()
				return {
					lines = function() return function()
						if mode == "empty" then return nil end
						if emitted then
							if mode == "iteration" then error(sentinel) end
							return nil
						end
						emitted = true
						return "partial"
					end end,
					close = function()
						closes = closes + 1
						if mode == "close_throw" then error(sentinel) end
						if mode == "close_refusal" then return nil, "exit", 9 end
						return true, "exit", 0
					end,
				}
			end, function()
				local ok, result = pcall(Reader.read, "fixture")
				helpers.assert_eq(closes, 1, "attempt closure exactly once before reporting any outcome")
				if mode == "empty" then
					helpers.assert_eq(ok, true)
					helpers.assert_eq(result, {})
				else
					helpers.assert_eq(ok, false)
					if mode == "close_refusal" then
						helpers.assert_true(tostring(result):find("exit 9", 1, true) ~= nil)
					else
						helpers.assert_true(rawequal(result, sentinel), "preserve the exact stream error")
					end
				end
			end)
		end)
	end

	helpers.it("(command-lines) reports startup refusal without publishing empty success", function()
		with_popen(function() return nil, "controlled startup refusal" end, function()
			local ok, reason = pcall(Reader.read, "fixture")
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(reason):find("controlled startup refusal", 1, true) ~= nil)
		end)
	end)
end)
