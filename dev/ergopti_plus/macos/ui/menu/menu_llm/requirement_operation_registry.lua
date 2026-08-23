--- ui/menu/menu_llm/requirement_operation_registry.lua

--- =============================================================================
--- MODULE: Requirement Operation Registry
--- DESCRIPTION:
--- Owns the logical lifetime of one backend requirement request while the
--- backend's existing exact owners retain every native task/timer/process.
--- =============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "menu_llm.requirements"

--- Creates one backend-local capability registry.
--- @param opts table|nil `{ backend = string, require_owned = boolean }`.
--- @return table registry
function M.new(opts)
	local registry = {}
	local backend = type(opts) == "table" and tostring(opts.backend or "requirements")
		or "requirements"
	local require_owned = type(opts) == "table" and opts.require_owned == true
	local capabilities = {}
	local operations = {}
	local anonymous_capability = {}

	local function has_children(operation)
		return next(operation.children) ~= nil
	end

	local function release_if_terminal(operation)
		if operation.released == true or operation.logical_terminal ~= true
			or has_children(operation) then
			return false
		end
		operation.released = true
		operations[operation] = nil
		return true
	end

	--- Retries the exact cleanup delegates retained by one terminal operation.
	--- A new request is itself a retry opportunity: merely refusing the sibling
	--- without touching the same native handles would leave false/nil/throw
	--- cleanup debt dependent on an unrelated late callback.
	--- @param operation table Terminal operation whose children remain owned.
	--- @param context string Stable diagnostic context.
	--- @return boolean settled True only when the operation is fully released.
	local function retry_terminal_cleanup(operation, context)
		local children = {}
		for child, entry in pairs(operation.children) do
			children[#children + 1] = { child = child, entry = entry }
		end
		for _, item in ipairs(children) do
			if operation.children[item.child] == item.entry then
				local ok, joined = xpcall(function()
					return item.entry.pause_join(item.child)
				end, debug.traceback)
				if ok == true and joined == true then
					operation.lifecycle.settle(item.child)
				elseif not ok then
					Logger.error(LOG, "%s %s cleanup retry raised: %s.",
						backend, tostring(context), tostring(joined))
				end
			end
		end
		release_if_terminal(operation)
		return operation.released == true
	end

	--- Creates one opaque backend-local owner capability.
	--- @param label string Stable diagnostic label.
	--- @return table|nil capability
	function registry.create_owner(label)
		if type(label) ~= "string" or label == "" then
			Logger.error(LOG, "%s requirement owner creation requires a label.", backend)
			return nil
		end
		local capability = {}
		capabilities[capability] = label
		return capability
	end

	--- Starts one logical operation. A terminal operation that still has exact
	--- children is cleanup debt and blocks a same-capability successor.
	--- @param capability table|nil Opaque token returned by create_owner().
	--- @return table|nil operation
	--- @return string|nil refusal_reason
	function registry.begin(capability)
		local resolved = capability
		if resolved == nil then
			if require_owned then return nil, "missing_requirement_owner" end
			resolved = anonymous_capability
		elseif capabilities[resolved] == nil then
			return nil, "invalid_requirement_owner"
		end

		for operation in pairs(operations) do
			if operation.capability == resolved
				and operation.logical_terminal == true
				and has_children(operation) then
				if retry_terminal_cleanup(operation, "successor preflight") ~= true then
					return nil, "prior_operation_unsettled"
				end
			end
		end

		local operation = {
			capability = resolved,
			authorized = true,
			logical_terminal = false,
			released = false,
			children = {},
		}
		operations[operation] = true

		local lifecycle = {}
		operation.lifecycle = lifecycle

		--- Registers a delegation to an existing exact descendant owner. The child
		--- itself remains authoritative; this registry stores no native handle.
		--- @param child table Exact descendant owner identity.
		--- @param pause_join function Called with child; literal true means settled.
		--- @param label string|nil Diagnostic label.
		--- @return boolean adopted
		function lifecycle.adopt(child, pause_join, label)
			if operation.released == true or type(child) ~= "table"
				or type(pause_join) ~= "function" then
				return false
			end
			local existing = operation.children[child]
			if existing ~= nil then return existing.pause_join == pause_join end
			operation.children[child] = {
				pause_join = pause_join,
				label = label or backend .. " requirement child",
			}
			return true
		end

		--- Releases exactly one descendant after its physical owner reports terminal.
		--- Duplicate and foreign terminals are inert.
		--- @param child table Exact descendant identity.
		--- @return boolean released
		function lifecycle.settle(child)
			if operation.released == true or operation.children[child] == nil then
				return false
			end
			operation.children[child] = nil
			release_if_terminal(operation)
			return true
		end

		function lifecycle.is_authorized()
			return operation.authorized == true
				and operation.logical_terminal ~= true
				and operation.released ~= true
		end

		function operation.is_authorized()
			return lifecycle.is_authorized()
		end

		--- Publishes one logical terminal at most once. Physical children may keep
		--- the operation registered after that terminal until their exact settlement.
		--- @param callback function|nil Business terminal callback.
		--- @param label string Diagnostic label.
		--- @param ... any Callback arguments.
		--- @return boolean accepted
		function operation.finish(callback, label, ...)
			if operation.logical_terminal == true or operation.released == true then
				return false
			end
			operation.logical_terminal = true
			local deliver = operation.authorized == true
			release_if_terminal(operation)
			if not deliver then return false end
			if type(callback) ~= "function" then return true end
			local values = table.pack(...)
			local ok, result = xpcall(function()
				return callback(table.unpack(values, 1, values.n))
			end, debug.traceback)
			if not ok then
				Logger.error(LOG, "%s raised: %s.", tostring(label), tostring(result))
				return false
			end
			return result ~= false
		end

		return operation
	end

	--- Revokes, delegates cancellation, and joins every exact child launched by
	--- one capability. False, nil, and throws retain the identical child entry.
	--- @param capability table Opaque token returned by create_owner().
	--- @return boolean settled
	--- @return boolean had_operations
	function registry.pause(capability)
		local label = capabilities[capability]
		if type(label) ~= "string" then
			Logger.error(LOG, "%s requirement pause received an invalid capability.", backend)
			return false, false
		end

		local owned = {}
		for operation in pairs(operations) do
			if operation.capability == capability then owned[#owned + 1] = operation end
		end
		local settled = true
		for _, operation in ipairs(owned) do
			operation.authorized = false
			operation.logical_terminal = true
			local children = {}
			for child, entry in pairs(operation.children) do
				children[#children + 1] = { child = child, entry = entry }
			end
			for _, item in ipairs(children) do
				if operation.children[item.child] == item.entry then
					local ok, joined = xpcall(function()
						return item.entry.pause_join(item.child)
					end, debug.traceback)
					if ok == true and joined == true then
						operation.lifecycle.settle(item.child)
					elseif operation.children[item.child] ~= nil then
						settled = false
						if not ok then
							Logger.error(LOG, "%s pause/join raised: %s.",
								tostring(item.entry.label), tostring(joined))
						end
					end
				end
			end
			release_if_terminal(operation)
			if operation.released ~= true then settled = false end
		end
		return settled, #owned > 0
	end

	return registry
end

return M
