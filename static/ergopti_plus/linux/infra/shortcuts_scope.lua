--- infra/shortcuts_scope.lua

--- Publishes one shortcut scope through existing preference and dispatch owners.
local M = {}
local Manifest = require("infra.manifest_reader")
local Transaction = require("config_scope_transaction")
local FencedTransaction = require("config_scope_fenced_transaction")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local Logger = require("logger.shim")
local LOG = "infra.shortcuts_scope"
local _owner, _sequence = nil, 0

--- The script chords' rows of the Shortcuts scope: their section and the
--- parameters of the bindings they dispatch under. Their submenu's restore and
--- clear narrow the scope to these rows.
--- @param parameter_domain function Path -> parameter domain or nil.
--- @return function select Path -> boolean.
local SCRIPT_CHORD_SECTION = "shortcuts.script_control"
local function script_chord_rows(parameter_domain)
	return function(path)
		return path == SCRIPT_CHORD_SECTION
			or path:sub(1, #SCRIPT_CHORD_SECTION + 1) == SCRIPT_CHORD_SECTION .. "."
			or parameter_domain(path) == "script"
	end
end

--- Builds one terminal transaction without acquiring or closing input devices.
--- @param options table Exact path, backup path, files and live pause getter;
---   `only = "script_chords"` narrows it to the script chords' submenu.
--- @return table owner Apply, pending and explicit compensation retry.
function M.new(options)
	assert(type(options) == "table" and type(options.is_paused) == "function", "shortcut scope requires live pause ownership")
	assert(options.only == nil or options.only == "script_chords", "unknown shortcut scope narrowing")
	local manager = options.manager or require("modules.shortcuts.manager")
	local keyboard = options.keyboard or require("modules.shortcuts.keyboard_shortcuts")
	local taps = options.taps or require("modules.shortcuts.tap_keys")
	local chords = options.chords or require("modules.shortcuts.script_chords")
	local parameters = options.parameters or require("modules.gestures.manager")
	local url = options.url or require("modules.shortcuts.chatgpt")
	local files = options.files or require("adapters.file_system")
	local owner, source, document, legacy = {}, nil, nil, nil
	local ports = {
		{ acquire = manager.acquire_configuration, release = manager.release_configuration },
		{ acquire = parameters.acquire_parameter_configuration, release = parameters.release_parameter_configuration },
		{ acquire = url.acquire_configuration, release = url.release_configuration },
		{ acquire = keyboard.acquire_configuration, release = keyboard.release_configuration },
		{ acquire = taps.acquire_configuration, release = taps.release_configuration },
		{ acquire = chords.acquire_configuration, release = chords.release_configuration },
	}
	local function domain(binding)
		return keyboard.configuration_domain(binding) or taps.configuration_domain(binding)
			or chords.configuration_domain(binding)
	end
	local function parameter_domain(path)
		local key = path:match("^gesture_parameters%.(.+)$")
		if not key then return nil end
		local binding, action = parameters.split_action_parameter_key(key)
		if action and parameters.get_action_parameter_spec(action) then return domain(binding) end
		return nil
	end
	local validators = { action_parameter_domain = parameter_domain }
	--- Resolves every owner's view of a document. The pre-write source is the
	--- user's, where outdated values are tolerated; the post-write candidate
	--- (`written`) holds only this scope's output, so owners check it strictly.
	--- Narrowed to the script chords, only their rows are this scope's output.
	--- @param config table Decoded document.
	--- @param written boolean|nil True for the post-write candidate.
	--- @return table state
	local function resolve(config, written)
		local others = options.only == nil and written or nil
		url.configuration_candidate(config, others)
		return { manager = manager.configuration_candidate(config),
			keyboard = keyboard.configuration_candidate(config, others),
			taps = taps.configuration_candidate(config, others),
			chords = chords.configuration_candidate(config, written) }
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
			taps = taps.configuration_snapshot(owner), chords = chords.configuration_snapshot(owner),
			parameters = parameters.parameter_configuration_snapshot(owner) }
		for _, key in ipairs({ "manager", "keyboard", "taps", "chords", "parameters" }) do
			if type(snapshot[key]) ~= "table" then return nil end
		end
		return snapshot
	end
	local function apply_state(state)
		local stopped = { enabled = false, wrap = false, caps_word_active = false, caps_word_triggered = false }
		if manager.apply_configuration(owner, stopped) ~= true then return false end
		if keyboard.apply_configuration(owner, state.keyboard) ~= true then return false end
		if taps.apply_configuration(owner, state.taps) ~= true then return false end
		if chords.apply_configuration(owner, state.chords) ~= true then return false end
		if parameters.apply_parameter_configuration(owner, state.parameters) ~= true then return false end
		return manager.apply_configuration(owner, state.manager) == true
	end
	local select_row = options.only == "script_chords" and script_chord_rows(parameter_domain) or nil
	local transaction = Transaction.new({ path = options.path, backup_path = options.backup_path, files = files,
		manifest = Manifest, owned_paths = inventory, owners = validators, capture = capture, restore = apply_state,
		select = select_row,
		prepare_batch = function(path, updates, adapter)
			local operations = {}
			-- A plain value an older build left where this scope keeps a table of
			-- assignments (`keyboard = "…"`) would make every row below it
			-- unwritable. The scope owns that container, so the outdated value
			-- goes with its reset instead of refusing it.
			local section = type(document) == "table" and options.only == nil and document.shortcuts or nil
			for _, key in ipairs(type(section) == "table" and { "keyboard", "tap_keys" } or {}) do
				local value = section[key]
				if value ~= nil and (type(value) ~= "table" or #value > 0) then
					operations[#operations + 1] = { section = "shortcuts", key = key, delete = true }
				end
			end
			for _, row in ipairs(updates) do operations[#operations + 1] = row end
			for _, row in ipairs(legacy) do
				if options.only == nil or select_row(row.section .. "." .. row.key) then
					operations[#operations + 1] = row
				end
			end
			return Writer.prepare_batch(path, operations, adapter, source)
		end,
		apply = function(config)
			if options.is_paused() then return false end
			local candidate = resolve(config, true)
			candidate.parameters = parameters.parameter_configuration_snapshot(owner)
			if type(candidate.parameters) ~= "table" then return false end
			for key in pairs(candidate.parameters) do
				local path = "gesture_parameters." .. key
				if parameter_domain(path) and (options.only == nil or select_row(path)) then
					candidate.parameters[key] = nil
				end
			end
			return apply_state(candidate)
		end,
	})
	-- Acquisition cancels queued dispatch irreversibly. The shared journal
	-- restores only preferences and retains refused native release claims.
	return FencedTransaction.new({ owner = owner, transaction = transaction, scope = "shortcuts", fences = ports,
		available = function() return not options.is_paused() end })
end

--- Applies a menu request while retaining any refused runtime compensation.
--- @param mode string Clear or recommended.
--- @param is_paused function Live pause getter.
--- @param only string|nil "script_chords" for the script chords' submenu.
--- @return boolean committed
function M.apply(mode, is_paused, only)
	if type(is_paused) ~= "function" or is_paused() or (mode ~= "clear" and mode ~= "recommended") then return false end
	if _owner and _owner.pending() and _owner.retry_restore() ~= true then return false end
	_sequence = _sequence + 1
	local path = require("infra.config_paths").config("config.toml")
	_owner = M.new({ path = path, backup_path = path .. ".shortcuts-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. _sequence .. ".bak",
		is_paused = is_paused, only = only })
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
