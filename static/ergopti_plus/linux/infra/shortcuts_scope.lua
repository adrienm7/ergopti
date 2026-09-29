--- infra/shortcuts_scope.lua

--- Publishes one shortcut scope through existing preference and dispatch owners.
local M = {}
local Manifest = require("infra.manifest_reader")
local Transaction = require("config_scope_transaction")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local Logger = require("logger.shim")
local LOG = "infra.shortcuts_scope"
local _owner, _sequence = nil, 0

--- Builds one terminal transaction without acquiring or closing input devices.
--- @param options table Exact path, backup path, files and live pause getter.
--- @return table owner Apply, pending and explicit compensation retry.
function M.new(options)
	assert(type(options) == "table" and type(options.is_paused) == "function", "shortcut scope requires live pause ownership")
	local manager = options.manager or require("modules.shortcuts.manager")
	local keyboard = options.keyboard or require("modules.shortcuts.keyboard_shortcuts")
	local taps = options.taps or require("modules.shortcuts.tap_keys")
	local parameters = options.parameters or require("modules.gestures.manager")
	local url = options.url or require("modules.shortcuts.chatgpt")
	local files = options.files or require("adapters.file_system")
	local owner, held, source, document, legacy = {}, {}, nil, nil, nil
	local ports = {
		{ acquire = manager.acquire_configuration, release = manager.release_configuration },
		{ acquire = parameters.acquire_parameter_configuration, release = parameters.release_parameter_configuration },
		{ acquire = url.acquire_configuration, release = url.release_configuration },
		{ acquire = keyboard.acquire_configuration, release = keyboard.release_configuration },
		{ acquire = taps.acquire_configuration, release = taps.release_configuration },
	}
	local function release()
		for index = #held, 1, -1 do
			assert(held[index].release(owner) == true, "shortcut configuration release refused")
			held[index] = nil
		end
	end
	local function domain(binding)
		return keyboard.configuration_domain(binding) or taps.configuration_domain(binding)
	end
	local function parameter_domain(path)
		local key = path:match("^gesture_parameters%.(.+)$")
		if not key then return nil end
		local binding, action = parameters.split_action_parameter_key(key)
		if action and parameters.get_action_parameter_spec(action) then return domain(binding) end
		return nil
	end
	local validators = { action_parameter_domain = parameter_domain }
	local function resolve(config)
		url.configuration_candidate(config)
		return { manager = manager.configuration_candidate(config), keyboard = keyboard.configuration_candidate(config),
			taps = taps.configuration_candidate(config) }
	end
	local function inventory()
		local bytes, status, detail = Writer.read_classified(options.path, files)
		assert(status == "ok" or status == "absent", "shortcut source is unreadable: " .. tostring(detail))
		source = { status = status, content = bytes }
		document = Codec.decode(bytes or "")
		assert(type(document) == "table", "shortcut source is malformed")
		resolve(document)
		local paths
		paths, legacy = parameters.parameter_configuration_inventory(document, domain)
		return Manifest.scope_inventory("shortcuts", {
			keyboard = function() return keyboard.configuration_paths(document) end,
			parameters = function() return paths end,
		}, validators)
	end
	local function capture()
		local snapshot = { manager = manager.configuration_snapshot(owner), keyboard = keyboard.configuration_snapshot(owner),
			taps = taps.configuration_snapshot(owner), parameters = parameters.parameter_configuration_snapshot(owner) }
		for _, key in ipairs({ "manager", "keyboard", "taps", "parameters" }) do
			if type(snapshot[key]) ~= "table" then return nil end
		end
		return snapshot
	end
	local function apply_state(state)
		local stopped = { enabled = false, wrap = false, caps_word_active = false, caps_word_triggered = false }
		if manager.apply_configuration(owner, stopped) ~= true then return false end
		if keyboard.apply_configuration(owner, state.keyboard) ~= true then return false end
		if taps.apply_configuration(owner, state.taps) ~= true then return false end
		if parameters.apply_parameter_configuration(owner, state.parameters) ~= true then return false end
		return manager.apply_configuration(owner, state.manager) == true
	end
	local transaction = Transaction.new({ path = options.path, backup_path = options.backup_path, files = files,
		manifest = Manifest, owned_paths = inventory, owners = validators, capture = capture, restore = apply_state,
		prepare_batch = function(path, updates, adapter)
			local operations = {}
			for _, row in ipairs(updates) do operations[#operations + 1] = row end
			for _, row in ipairs(legacy) do operations[#operations + 1] = row end
			return Writer.prepare_batch(path, operations, adapter, source)
		end,
		apply = function(config)
			if options.is_paused() then return false end
			local candidate = resolve(config)
			candidate.parameters = parameters.parameter_configuration_snapshot(owner)
			if type(candidate.parameters) ~= "table" then return false end
			for key in pairs(candidate.parameters) do
				if parameter_domain("gesture_parameters." .. key) then candidate.parameters[key] = nil end
			end
			return apply_state(candidate)
		end,
	})
	function owner.pending() return transaction.pending() end
	function owner.apply(mode)
		if #held > 0 or (mode ~= "clear" and mode ~= "recommended") or options.is_paused() then return false end
		for _, port in ipairs(ports) do
			local called, acquired = pcall(port.acquire, owner)
			if not called or acquired ~= true then release(); return false, "shortcut configuration is already owned" end
			held[#held + 1] = port
		end
		-- Dispatch acquisition cancels queued work irreversibly. Compensation
		-- restores preferences after that point and never replays user actions.
		local committed, detail = transaction.apply("shortcuts", mode)
		if not transaction.pending() then release() end
		return committed, detail
	end
	function owner.retry_restore()
		if transaction.retry_restore() ~= true then return false end
		if #held > 0 then release() end
		return true
	end
	--- Undoes the last commit under the same dispatch ownership as apply().
	function owner.revert()
		if #held > 0 or options.is_paused() then return false, "shortcut configuration is already owned" end
		for _, port in ipairs(ports) do
			local called, acquired = pcall(port.acquire, owner)
			if not called or acquired ~= true then release(); return false, "shortcut configuration is already owned" end
			held[#held + 1] = port
		end
		local reverted, detail = transaction.revert()
		if not transaction.pending() then release() end
		return reverted, detail
	end
	function owner.release() transaction.release() end
	return owner
end

--- Applies a menu request while retaining any refused runtime compensation.
--- @param mode string Clear or recommended.
--- @param is_paused function Live pause getter.
--- @return boolean committed
function M.apply(mode, is_paused)
	if type(is_paused) ~= "function" or is_paused() or (mode ~= "clear" and mode ~= "recommended") then return false end
	if _owner and _owner.pending() and _owner.retry_restore() ~= true then return false end
	_sequence = _sequence + 1
	local path = require("infra.config_paths").config("config.toml")
	_owner = M.new({ path = path, backup_path = path .. ".shortcuts-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. _sequence .. ".bak",
		is_paused = is_paused })
	Logger.start(LOG, "Shortcut preference scope %s started.", mode)
	local committed, detail = _owner.apply(mode)
	if committed == true then Logger.success(LOG, "Shortcut preference scope %s completed.", mode)
	else Logger.error(LOG, "Shortcut preference scope %s refused: %s.", mode, tostring(detail)) end
	return committed == true
end

--- The shortcut participant of a composed scope, bound to the retained owner.
--- @param is_paused function Live pause getter.
--- @return table participant See config_scope_composition.
function M.participant(is_paused)
	return require("config_scope_participant").synchronous({
		apply = function(mode) return M.apply(mode, is_paused) end,
		owner = function() return _owner end,
	})
end

return M
