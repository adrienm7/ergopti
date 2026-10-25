--- tests/unit/modules/keystats/log_manager/test_rotation_restart_record_boundary.lua

--- ==============================================================================
--- MODULE: Journal Restart Record Boundary Tests
--- DESCRIPTION:
--- A process can stop after a partial unbuffered journal write. The next writer
--- must preserve the physical tail while separating its acknowledged JSON record
--- from that retired write, including a complete object lacking its final LF.
--- ==============================================================================

local helpers = require("tests.helpers")
local TIMESTAMP = "2026-10-26 00:00:00.000"

--- Replay the production writer and tail reader against one actual journal.
--- @param prefix string Physical bytes left by the previous process.
--- @param expected string[] Text values of the complete recoverable records.
local function replay(prefix, expected)
	helpers.with_stub_scope({ "modules.keystats.rotation", "adapters.ledger_append", "infra.logger" }, function()
		local path = os.tmpname()
		local seed = assert(io.open(path, "w"))
		assert(seed:write(prefix)); assert(seed:close())
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		-- This owner is used only to close the real append stream during cleanup.
		package.loaded["adapters.ledger_append"] = { rollover = function(_, _, _, _, next_date, reset)
			return reset(next_date, {})
		end }
		local rotation = helpers.load_with_stubs("modules.keystats.rotation")
		local ok, reason = xpcall(function()
			rotation.init({ paths = { today_log_path = path }, state = {} })
			helpers.assert_eq(rotation.append_log({ type = "typing", timestamp = TIMESTAMP, text = "after_restart" }), true)
			local file = assert(io.open(path, "r"))
			local bytes = assert(file:read("*a")); assert(file:close())
			helpers.assert_eq(bytes:sub(1, #prefix), prefix, "restart must preserve all prior physical bytes")
			local entries, offset, status = rotation.read_new_entries()
			local observed = {}
			for _, item in ipairs(entries) do observed[#observed + 1] = item.entry.text end
			helpers.assert_eq(observed, expected, "the first acknowledged record after restart must remain independently readable")
			helpers.assert_eq(offset, #bytes)
			helpers.assert_eq(status, rotation.READ_STATUS_EOF)
			if prefix == "" then helpers.assert_eq(bytes:sub(1, 1), "{", "an empty journal needs no separator") end
		end, debug.traceback)
		local closed = rotation.rollover(path .. ".sql", rotation.READ_STATUS_EOF, function() return true end,
			function() return true end)
		assert(closed, "fixture must release the exact append stream")
		assert(os.remove(path))
		if not ok then error(reason, 0) end
	end)
end

helpers.describe("rotation restart framing", function()
	helpers.it("(journal-restart-boundary) separates a torn JSON tail from the first acknowledged new event", function()
		replay('{"type":"typing","text":"unfinished', { "after_restart" })
	end)
	helpers.it("(journal-restart-boundary) preserves a complete object whose final LF was not written", function()
		replay('{"type":"typing","timestamp":"' .. TIMESTAMP .. '","text":"before_restart"}',
			{ "before_restart", "after_restart" })
	end)
	helpers.it("(journal-restart-boundary) preserves an existing complete line", function()
		replay('{"type":"typing","timestamp":"' .. TIMESTAMP .. '","text":"before_restart"}\n',
			{ "before_restart", "after_restart" })
	end)
	helpers.it("(journal-restart-boundary) starts an empty journal directly with its first record", function()
		replay("", { "after_restart" })
	end)
	for _, failed_stage in ipairs({ "size_query", "tail_seek", "tail_read", "append_seek" }) do
		helpers.it("(journal-restart-boundary) refuses " .. failed_stage .. " before acknowledging any new bytes", function()
			helpers.with_stub_scope({ "modules.keystats.rotation", "adapters.ledger_append", "infra.logger" }, function()
				local path, prefix = os.tmpname(), '{"torn":'
				local seed = assert(io.open(path, "w")); assert(seed:write(prefix)); assert(seed:close())
				local errors, handles, writes = {}, {}, 0
				local logger = helpers.make_logger_stub()
				logger.error = function(_, format, ...) errors[#errors + 1] = string.format(format, ...) end
				package.loaded["infra.logger"] = logger
				package.loaded["adapters.ledger_append"] = { rollover = function(_, _, _, _, next_date, reset)
					return reset(next_date, {})
				end }
				local rotation = helpers.load_with_stubs("modules.keystats.rotation")
				local original_open, fault = io.open, failed_stage
				io.open = function(filename, mode)
					local file, reason, code = original_open(filename, mode)
					if not file or filename ~= path or mode ~= "a+" then return file, reason, code end
					handles[#handles + 1] = file
					local ends = 0
					return {
						setvbuf = function(_, ...) return file:setvbuf(...) end,
						seek = function(_, origin, offset)
							if origin == "end" then ends = ends + 1 end
							if (fault == "size_query" and origin == "end" and ends == 1)
								or (fault == "tail_seek" and origin == "set")
								or (fault == "append_seek" and origin == "end" and ends == 2) then
								return nil, "private journal content"
							end
							return file:seek(origin, offset)
						end,
						read = function(_, count)
							helpers.assert_eq(count, 1, "startup may inspect only the last physical byte")
							if fault == "tail_read" then return nil, "private journal content" end
							return file:read(count)
						end,
						write = function(self, bytes)
							writes = writes + 1
							local result, detail, errno = file:write(bytes)
							return result and self or result, detail, errno
						end,
						close = function() return file:close() end,
					}
				end
				local ok, reason = xpcall(function()
					rotation.init({ paths = { today_log_path = path }, state = {} })
					helpers.assert_eq(rotation.append_log({ type = "typing", timestamp = TIMESTAMP, text = "refused" }), false)
					helpers.assert_eq(writes, 0, "an uninspected journal cannot accept another event")
					for _, file in ipairs(handles) do helpers.assert_eq(io.type(file), "closed file") end
					helpers.assert_true(table.concat(errors, "\n"):find("record boundary", 1, true) ~= nil,
						"the failed inspection must remain visible")
					helpers.assert_nil(table.concat(errors, "\n"):find("private journal content", 1, true))
					fault = nil
					helpers.assert_eq(rotation.append_log({ type = "typing", timestamp = TIMESTAMP, text = "after_restart" }), true)
					local entries = rotation.read_new_entries()
					helpers.assert_eq(#entries, 1)
					helpers.assert_eq(entries[1].entry.text, "after_restart")
				end, debug.traceback)
				io.open = original_open
				assert(rotation.rollover(path .. ".sql", rotation.READ_STATUS_EOF, function() return true end,
					function() return true end))
				for _, file in ipairs(handles) do assert(io.type(file) == "closed file") end
				assert(os.remove(path))
				if not ok then error(reason, 0) end
			end)
		end)
	end
end)
