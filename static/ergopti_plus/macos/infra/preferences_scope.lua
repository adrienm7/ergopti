--- infra/preferences_scope.lua

--- ==============================================================================
--- MODULE: Scoped Preferences Owner (macOS)
--- DESCRIPTION:
--- Bridges the shared single-file transaction to the inline action-parameter
--- table owned by Preferences and the live gesture registry. Other native state
--- stays behind explicit capture/apply/restore ports until its terminal result.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local Transaction = require("config_scope_transaction")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local Scanner = require("toml_codec.record_scanner")
local PARAMETER_PREFIX = "gestures.action_parameters."

local function clone(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for key, child in pairs(value) do out[key] = clone(child) end
	return out
end

local function identifier(value)
	return type(value) == "string" and value:match("^[a-z0-9_]+$") ~= nil
		and value:sub(1, 1) ~= "_" and value:sub(-1) ~= "_" and not value:find("__", 1, true)
end

--- Creates one scope transaction with explicit native terminal acknowledgements.
--- @param options table Path, backup path, files, gestures and native state ports.
--- @return table owner Apply, pending and retained-compensation operations.
function M.new(options)
	assert(type(options) == "table" and type(options.gestures) == "table", "scope gesture owner is unavailable")
	local gestures = options.gestures
	for _, name in ipairs({ "get_all_action_parameters", "replace_action_parameters",
		"split_action_parameter_key", "get_action_parameter_spec" }) do
		assert(type(gestures[name]) == "function", "scope gesture owner is incomplete: " .. name)
	end
	assert(type(gestures.SINGLE_SLOTS) == "table" and type(gestures.AXIS_SLOTS) == "table",
		"scope gesture slots are unavailable")
	assert(type(options.capture) == "function" and type(options.apply) == "function"
		and type(options.restore) == "function", "scope native terminal ports are incomplete")
	local slots, domains = {}, {}
	for _, list in ipairs({ gestures.SINGLE_SLOTS, gestures.AXIS_SLOTS }) do
		for _, slot in ipairs(list) do slots[slot] = true end
	end
	for _, scope in pairs(Manifest.scopes()) do
		for _, domain in ipairs(scope.action_parameters and scope.action_parameters.domains or {}) do domains[domain] = true end
	end
	local function parameter_domain(path)
		if path:sub(1, #PARAMETER_PREFIX) ~= PARAMETER_PREFIX then return nil end
		local key = path:sub(#PARAMETER_PREFIX + 1)
		local binding, action = gestures.split_action_parameter_key(key)
		if not identifier(action) or type(binding) ~= "string" then return nil end
		local spec = gestures.get_action_parameter_spec(action)
		if type(spec) ~= "string" or spec == "" then return nil end
		if slots[binding] then return "gesture" end
		local domain, name = binding:match("^([a-z_]+)__(.+)$")
		if domain and domain ~= "gesture" and domains[domain] and identifier(name) then return domain end
		return nil
	end
	local owners = { action_parameter_domain = parameter_domain }
	local source_snapshot, disk_parameters, scope_id
	local transaction
	local function inventory()
		local content, status, detail = Writer.read_classified(options.path, options.files)
		assert(status == "ok" or status == "absent", "scope source is unreadable: " .. tostring(detail))
		local decoded = Codec.decode(content or "")
		assert(type(decoded) == "table", "scope source is not valid TOML")
		source_snapshot = { status = status, content = content }
		disk_parameters = decoded.gestures and decoded.gestures.action_parameters or nil
		assert(disk_parameters == nil or type(disk_parameters) == "table", "scope parameter table is malformed")
		local runtime_parameters = gestures.get_all_action_parameters()
		assert(type(runtime_parameters) == "table", "scope parameter inventory is unavailable")
		local paths = {}
		for _, parameters in ipairs({ disk_parameters or {}, runtime_parameters }) do
			assert(type(parameters) == "table", "scope parameter inventory is unavailable")
			for key in pairs(parameters) do
				assert(type(key) == "string", "scope parameter table must be a dictionary")
				local path = PARAMETER_PREFIX .. key
				if parameter_domain(path) then paths[#paths + 1] = path end
			end
		end
		return Manifest.scope_inventory(scope_id, {
			parameters = function() return paths end,
			native = function() return options.owned_paths and options.owned_paths() or {} end,
		}, owners)
	end
	local function prepare(path, updates, files)
		local scanned, detail = Scanner.scan_records(source_snapshot.content or "", { quoted_headers = true })
		if not scanned then return false, detail end
		local inline = false
		for _, record in ipairs(scanned.records) do
			if record.addressable and record.section == "gestures" and record.key == "action_parameters" then inline = true end
		end
		local candidate, rows, changed = clone(disk_parameters or {}), {}, false
		for _, row in ipairs(updates) do
			local full_path = row.section .. "." .. row.key
			if inline and full_path:sub(1, #PARAMETER_PREFIX) == PARAMETER_PREFIX then
				assert(row.delete == true and parameter_domain(full_path), "scope parameter operation is not owned")
				candidate[row.key] = nil
				changed = true
			else rows[#rows + 1] = row end
		end
		if changed then
			rows[#rows + 1] = next(candidate) == nil and { section = "gestures", key = "action_parameters", delete = true }
				or { section = "gestures", key = "action_parameters", value = candidate }
		end
		return Writer.prepare_batch(path, rows, files, source_snapshot)
	end
	transaction = Transaction.new({
		path = options.path, backup_path = options.backup_path, files = options.files,
		manifest = Manifest, owners = owners, owned_paths = inventory, prepare_batch = prepare,
		capture = function()
			local native = options.capture()
			assert(type(native) == "table", "scope native capture was not acknowledged")
			local parameters = gestures.get_all_action_parameters()
			assert(type(parameters) == "table", "scope parameter capture was not acknowledged")
			return { native = native, parameters = parameters }
		end,
		apply = function(decoded, updates)
			if options.apply(decoded, updates) ~= true then return false end
			local parameters = gestures.get_all_action_parameters()
			for _, row in ipairs(updates) do
				if parameter_domain(row.section .. "." .. row.key) then
					assert(row.delete == true, "scope parameter restoration requires absence")
					parameters[row.key] = nil
				end
			end
			return gestures.replace_action_parameters(parameters) == true
		end,
		restore = function(snapshot)
			if gestures.replace_action_parameters(snapshot.parameters) ~= true then return false end
			return options.restore(snapshot.native) == true
		end,
	})
	return {
		pending = transaction.pending,
		retry_restore = transaction.retry_restore,
		apply = function(scope, mode)
			if transaction.pending() then return false, "a configuration transaction is still pending" end
			local planned, plan = pcall(Manifest.scope_plan, scope, mode)
			if not planned then return false, tostring(plan) end
			if #plan.presets > 0 then return false, "scope requires separate preset ownership" end
			scope_id = scope
			return transaction.apply(scope, mode)
		end,
	}
end

return M
