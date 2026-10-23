--- tests/support/sqlite_flush_native.lua

--- Native fixture driver for asynchronous SQLite ACKs. Production never runs a
--- nested luv loop; standalone tests explicitly own and advance their event loop.
local M = {}
local uv = require("luv")

function M.wait(keystats)
	local deadline = uv.hrtime() + 4000000000
	repeat
		uv.run("nowait")
		keystats.pump_flush()
		if keystats.get_flush_status().read_safe then return not keystats.has_flush_debt() end
		uv.sleep(1)
	until uv.hrtime() >= deadline
	error("Native SQLite fixture did not observe a conclusive physical ACK")
end

function M.flush(keystats)
	keystats.flush()
	if not M.wait(keystats) then return false end
	-- Input admitted during an older immutable snapshot belongs to the next
	-- transaction. Exercise that real next dispatch, without replaying failures.
	while keystats._pending_buffer_count_for_test() > 0 do
		keystats.flush()
		if not M.wait(keystats) then return false end
	end
	return true
end

--- Changes a fixture's deliberate fault only after its refused operation has
--- physically retired. It does not bypass the production writer's debt fence.
function M.control(writer, sql)
	local request = assert(require("infra.sqlite_batch_process").start(writer.get_db_path(), sql,
		{ owner = "native-sqlite-fault-controller", timeout_ms = require("infra.timings").ms("keystats", "sqlite_operation_timeout_ms") }))
	local deadline = uv.hrtime() + 4000000000
	local result
	repeat uv.run("nowait"); result = request:poll(); if not result then uv.sleep(1) end until result or uv.hrtime() >= deadline
	assert(result and result.ok, "Native SQLite fixture control was refused")
	return true
end
return M
