-- _shared/lua/config_cleanup_session.lua

-- ==============================================================================
-- MODULE: Configuration Cleanup Session
-- DESCRIPTION:
-- Owns the preview and deletion targets for the shared cleanup page. A stale
-- page cannot replace the path, delete additional keys, or reuse a closed scan.
-- ==============================================================================

local Engine = require("config_unused_keys")
local has_logger, Logger = pcall(require, "infra.logger")
if not has_logger then Logger = require("logger.shim") end
local M = {}
local sequence = 0

--- Creates one host-owned session. Opening alone never writes configuration.
--- @param opts table Engine options, with optional on_removed callback.
--- @return table session
function M.new(opts)
	assert(type(opts) == "table" and type(opts.path) == "string", "cleanup session needs a path")
	sequence = sequence + 1
	local token = tostring(sequence)
	local closed, busy, scan = false, false, nil
	local state = { session = token, path = opts.path, keys = {}, status = "empty" }
	local session = {}

	--- Invalidates all callbacks belonging to the closing window.
	function session:close()
		closed = true
		scan = nil
	end

	local function refresh()
		local ok, result = pcall(Engine.find, opts)
		if not ok then
			Logger.error("ConfigCleanup", "The configuration preview failed: %s.", tostring(result))
			result = { status = "unreadable", keys = {} }
		end
		scan = result
		state.keys = scan.keys
		state.reason_key = "dialog.unused_keys.reason.unreadable"
		state.status = scan.status == "ok" and (#scan.keys > 0 and "ready" or "empty") or "failed"
		return state
	end

	--- Handles an action against this session's exact preview.
	--- @param payload string|table Page request; no filesystem input is accepted.
	--- @return table|nil state
	function session:handle(payload)
		if closed or busy then return nil end
		if payload == "ready" then return scan and state or refresh() end
		if type(payload) ~= "table" then return nil end
		if payload.action == "close" and (payload.session == token or payload.session == "") then
			self:close()
			return nil
		end
		if payload.session ~= token then return nil end
		if payload.action == "refresh" then return refresh() end
		if payload.action ~= "clean" or state.status ~= "ready" then return nil end
		busy = true
		local removal = {}
		for key, value in pairs(opts) do removal[key] = value end
		removal.keys = scan.keys
		removal.expected_source = scan.source
		local ok, result = pcall(Engine.remove, removal)
		busy = false
		if not ok then
			state.status = "failed"
			state.reason_key = "dialog.unused_keys.reason.write"
			Logger.error("ConfigCleanup", "The cleanup transaction failed: %s.", tostring(result))
			return state
		end
		state.status = result.status
		if result.status == "removed" then
			state.keys, state.backup, state.removed = {}, result.backup, result.removed
			if opts.on_removed then
				local adopted, detail = pcall(opts.on_removed, result)
				if not adopted then
					Logger.error("ConfigCleanup", "Configuration was cleaned but adoption failed: %s.", tostring(detail))
				end
			end
		elseif result.status ~= "changed" then
			state.status = "failed"
			local reasons = { backup_failed = "backup", unreadable = "unreadable", write_failed = "write" }
			state.reason_key = "dialog.unused_keys.reason." .. assert(reasons[result.status], "unknown cleanup outcome")
		end
		return closed and nil or state
	end

	return session
end

return M
