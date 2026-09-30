--- infra/gesture_scope.lua

--- ==============================================================================
--- MODULE: Gesture Scope Transaction (Linux)
--- DESCRIPTION:
--- Restores or clears the gesture-owned preferences through the shared file
--- transaction and the manager's acknowledged reader lifecycle. Unknown keys,
--- other binding parameters and failed runtime compensation remain owned.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local Transaction = require("config_scope_transaction")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")

--- Builds one recoverable gesture transaction with a unique backup destination.
--- @param options table Path, backup_path, files and gestures owner.
--- @return table owner Apply, pending and retry_restore operations.
function M.new(options)
	assert(type(options) == "table" and type(options.gestures) == "table", "gesture scope requires its runtime owner")
	local gestures = options.gestures
	local files = options.files or require("adapters.file_system")
	local source, decoded
	local function parameter_domain(path)
		local key = path:match("^gesture_parameters%.(.+)$")
		if not key then return nil end
		local binding, action = gestures.split_action_parameter_key(key)
		if binding and gestures.DEFAULT_GESTURES[binding] ~= nil
			and gestures.get_action_parameter_spec(action) then return "gesture" end
		return nil
	end
	local owners = { action_parameter_domain = parameter_domain }
	local function inventory()
		local bytes, status, detail = Writer.read_classified(options.path, files)
		assert(status == "ok" or status == "absent", "gesture scope source is unreadable: " .. tostring(detail))
		source = { status = status, content = bytes }
		decoded = Codec.decode(bytes or "")
		assert(type(decoded) == "table", "gesture scope source is malformed")
		assert(decoded.gesture_parameters == nil or type(decoded.gesture_parameters) == "table", "gesture parameters are malformed")
		local paths = {}
		for _, parameters in ipairs({ decoded.gesture_parameters or {}, gestures.get_all_action_parameters() }) do
			for key in pairs(parameters) do
				assert(type(key) == "string", "gesture parameters require named keys")
				local path = "gesture_parameters." .. key
				if parameter_domain(path) then paths[#paths + 1] = path end
			end
		end
		return Manifest.scope_inventory("gestures", { parameters = function() return paths end }, owners)
	end
	local transaction = Transaction.new({
		path = options.path, backup_path = options.backup_path, files = files,
		manifest = Manifest, owners = owners, owned_paths = inventory,
		prepare_batch = function(path, updates, files)
			local operations = {}
			for _, row in ipairs(updates) do operations[#operations + 1] = row end
			for _, row in ipairs(gestures.scope_legacy_operations(decoded)) do operations[#operations + 1] = row end
			return Writer.prepare_batch(path, operations, files, source)
		end,
		capture = gestures.capture_scope_state,
		apply = function(config)
			local state = gestures.capture_scope_state()
			if type(state) ~= "table" then return false end
			local settings = config.gestures or {}
			if type(settings) ~= "table" then return false end
			for slot in pairs(gestures.DEFAULT_GESTURES) do
				local action = settings[slot]
				if action == nil then action = Manifest.default_for("gestures." .. slot) end
				state.actions[slot] = action
			end
			for key in pairs(state.parameters) do
				if parameter_domain("gesture_parameters." .. key) then state.parameters[key] = nil end
			end
			state.enabled = settings.enabled
			if state.enabled == nil then state.enabled = Manifest.default_for("gestures.enabled") end
			state.reading = state.enabled
			return gestures.apply_scope_state(state)
		end,
		restore = gestures.apply_scope_state,
	})
	return {
		apply = function(mode) return transaction.apply("gestures", mode) end,
		pending = transaction.pending,
		retry_restore = transaction.retry_restore,
		revert = transaction.revert,
		release = transaction.release,
	}
end

return M
