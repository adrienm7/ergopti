--- tests/support/sqlite_flush_fake.lua

--- Logical SQLite transaction double: records the same raw/derived intent through
--- a test's explicit writer overrides. Native process/rollback tests use SQLite.
local M = {}
local unpack_values = table.unpack or unpack

function M.attach(writer)
	writer.flush_transport_available = function() return true end
	writer.start_flush = function(device, payload)
		local ok = true
		local raw_methods = { typing = "insert_typing_events", hotstrings = "insert_hotstring_events",
			shortcuts = "insert_shortcut_events", switches = "insert_app_switch_events",
			llm = "insert_llm_events", windows = "insert_window_switch_events",
			sessions = "insert_session_events" }
		for family, method in pairs(raw_methods) do
			if #(payload.raw[family] or {}) > 0 and writer[method](device, payload.raw[family]) == false then ok = false end
		end
		for _, entry in ipairs(payload.upserts) do
			local args = { device }
			for _, value in ipairs(entry.args) do args[#args + 1] = value end
			if writer["upsert_" .. entry.kind](unpack_values(args)) == false then ok = false end
		end
		if ok and writer.bump_rev then writer.bump_rev() end
		local operation = { result = { committed = ok } }
		function operation:is_settled() return true end
		function operation:pump() return true end
		function operation:phase() return "done" end
		function operation:is_read_safe() return true end
		function operation:is_retryable() return false end
		function operation:cancel() return true end
		return operation
	end
	return writer
end
return M
