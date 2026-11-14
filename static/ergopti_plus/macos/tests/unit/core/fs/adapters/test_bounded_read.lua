--- tests/unit/core/fs/adapters/test_bounded_read.lua

--- ==============================================================================
--- MODULE: Bounded File Read
--- DESCRIPTION:
--- Tests the real read adapter against a stream that records its requested size.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("bounded file read", function()
	helpers.it("refuses missing and invalid limits before opening a file", function()
		helpers.with_fresh_modules({ "core.fs.adapters.file_system", "infra.logger" }, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local adapter = require("core.fs.adapters.file_system")
			for _, limit in ipairs({ -1, 0.5, math.huge, 0 / 0 }) do
				local content, status = adapter.read_bounded("/PRIVATE_FILE", limit)
				helpers.assert_nil(content)
				helpers.assert_eq(status, "error")
			end
			local content, status = adapter.read_bounded("/PRIVATE_FILE", nil)
			helpers.assert_nil(content)
			helpers.assert_eq(status, "error")
		end)
	end)
	for _, data in ipairs({ "", "abc", "abcd", string.rep("x", 10000) }) do
		helpers.it("limits the native read for a " .. #data .. " byte file", function()
			local previous_open, previous_hs = io.open, _G.hs
			local ok, failure = xpcall(function()
				helpers.with_fresh_modules({ "core.fs.adapters.file_system", "infra.logger" }, function()
					package.loaded["infra.logger"] = helpers.make_logger_stub()
					local adapter = helpers.load_with_stubs("core.fs.adapters.file_system", {
						fs = { symlinkAttributes = function()
							return { mode = "file", dev = 1, ino = 2, size = #data }
						end },
					})
					local read_size, closed
					io.open = function()
						return {
							read = function(_, size)
								read_size = size
								if data == "" then return nil end
								return data:sub(1, size)
							end,
							close = function() closed = true; return true end,
						}
					end
					local content, status = adapter.read_bounded("/PRIVATE_FILE", 3)
					io.open = previous_open
					helpers.assert_eq(read_size, 4, "at most the limit plus one byte may be requested")
					helpers.assert_eq(closed, true)
					if #data > 3 then
						helpers.assert_nil(content)
						helpers.assert_eq(status, "too_large")
					else
						helpers.assert_eq(content, data)
						helpers.assert_eq(status, "ok")
					end
				end)
			end, debug.traceback)
			io.open, _G.hs = previous_open, previous_hs
			if not ok then error(failure, 0) end
		end)
	end
end)
