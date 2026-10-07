--- infra/shortcuts_scope.lua

--- Publishes one shortcut scope through existing preference and dispatch owners.
local M = {}
local PhysicalAvailability = require("shortcuts.physical_availability")
local Manifest = require("infra.manifest_reader")
local Transaction = require("config_scope_transaction")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local Parents = require("config_obsolete_parents")
local Logger = require("logger.shim")
local LOG = "infra.shortcuts_scope"
local _owner, _sequence = nil, 0
local _editor_owner, _editor_path, _editor_pause, _editor_busy = nil, nil, nil, false

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
	local manifest = options.manifest or Manifest
	local pair_feature = manifest.find_entry_by_path("category_enabled.key_combinations")
	local admitted_pairs = options.combinations ~= nil or (type(pair_feature) == "table"
		and pair_feature.type == "boolean" and pair_feature.default == true)
	local combinations = admitted_pairs and (options.combinations or require("modules.shortcuts.key_combinations")) or nil
	if combinations then
		for _, name in ipairs({ "acquire_configuration", "release_configuration", "owns_configuration", "configuration_snapshot", "configuration_source", "configuration_source_matches", "capture_edit_source", "configuration_candidate", "apply_configuration", "configuration_domain", "acquire_delivery_fence", "owns_delivery_fence", "release_delivery_fence" }) do
			assert(type(combinations[name]) == "function", "shortcut scope requires its actual combination owner")
		end
	end
	local owner, held, source, document, legacy = {}, {}, nil, nil, nil
	local editing, busy, retiring, uncertain_pair = false, false, false, false
	local pair_source, published_source, publication_acked, delivery_held
	local release_claims
	local acquire
	local ports = {
		{ acquire = manager.acquire_configuration, release = manager.release_configuration },
		{ acquire = parameters.acquire_parameter_configuration, release = parameters.release_parameter_configuration },
		{ acquire = url.acquire_configuration, release = url.release_configuration },
		{ acquire = keyboard.acquire_configuration, release = keyboard.release_configuration },
		{ acquire = taps.acquire_configuration, release = taps.release_configuration },
		{ acquire = chords.acquire_configuration, release = chords.release_configuration },
	}
	local pair_port = combinations and { acquire = combinations.acquire_configuration, release = combinations.release_configuration, pair = true } or nil
	if pair_port then table.insert(ports, 1, pair_port) end
	local function reclaim_releases()
		if release_claims then
			for _, port in ipairs(release_claims) do
				local retained = false
				for _, existing in ipairs(held) do if existing == port then retained = true end end
				if not retained then
					local called, accepted = pcall(port.acquire, owner)
					if not called or accepted ~= true then return false end
					held[#held + 1] = port
				end
			end
			release_claims = nil
		end
		return true
	end
	local function release(expected, restoring)
		-- Any refused terminal acknowledgement must re-fence the exact Pair
		-- owner after its native installation, before exposing inverse debt.
		local function refuse()
			reclaim_releases()
			if combinations then
				local known, exact = pcall(combinations.owns_configuration, owner)
				if not known or type(exact) ~= "boolean" then uncertain_pair = true; return false end
				if not exact then
					pcall(pair_port.acquire, owner)
					known, exact = pcall(combinations.owns_configuration, owner)
					if not known or type(exact) ~= "boolean" then uncertain_pair = true; return false end
				end
				if exact then
					local retained = false
					for _, port in ipairs(held) do if port == pair_port then retained = true end end
					if not retained then held[#held + 1] = pair_port end
				end
			end
			return false
		end
		if uncertain_pair or retiring then return false end
		if reclaim_releases() ~= true then return false end
		local decoded = expected and Codec.decode(expected.content or "")
		if expected and type(decoded) ~= "table" then return refuse() end
		if expected then
			local exact = parameters.parameter_configuration_snapshot(owner)
			if parameters.parameter_configuration_matches(type(exact) == "table" and owner or nil, decoded,
				function() return true end) ~= true then return refuse() end
		end
		-- The only native construction callback is the pair installation. Keep
		-- keyboard and parameter ownership while it acknowledges its replacement.
		local pair_index
		for index, port in ipairs(held) do if port == pair_port then pair_index = index end end
		if expected and pair_index then
			if combinations.configuration_source_matches(owner, expected, restoring) ~= true then return refuse() end
			local called, accepted = pcall(pair_port.release, owner)
			if not called or accepted ~= true then return refuse() end
			table.remove(held, pair_index)
		end
		local claimed = {}
		for index, port in ipairs(held) do claimed[index] = port end
		for index = #held, 1, -1 do
			if expected then
				local exact = combinations.owns_configuration(owner)
				if exact then
					if combinations.configuration_source_matches(owner, expected, restoring) ~= true then return refuse() end
				else
					local receipt = combinations.capture_edit_source(owner, restoring)
					if type(receipt) ~= "table" or receipt.path ~= expected.path or receipt.status ~= expected.status
						or receipt.content ~= expected.content or receipt.guard() ~= true then return refuse() end
				end
			end
			local called, accepted = pcall(held[index].release, owner)
			if not called or accepted ~= true then
				if #held < #claimed then release_claims = claimed end
				return refuse()
			end
			held[index] = nil
		end
		if expected then
			local parameter_guard = parameters.capture_parameter_source_guard(decoded, function() return true end)
			if type(parameter_guard) ~= "function" then return refuse() end
			local receipt = combinations.capture_edit_source(owner, restoring)
			if type(receipt) ~= "table" or receipt.path ~= expected.path or receipt.status ~= expected.status
				or receipt.content ~= expected.content or receipt.guard() ~= true
				or parameter_guard() ~= true then return refuse() end
		end
		-- Every source/native callback has returned. Opening delivery is the
		-- producer's private-only final acknowledgement, with no callback tail.
		if delivery_held then
			if combinations.owns_delivery_fence(owner) ~= true then uncertain_pair = true; return false end
			if combinations.release_delivery_fence(owner) ~= true then return refuse() end
			delivery_held = false
		end
		return true
	end
	local function domain(binding)
		return keyboard.configuration_domain(binding) or taps.configuration_domain(binding)
			or chords.configuration_domain(binding) or (combinations and combinations.configuration_domain(binding))
	end
	local function parameter_domain(path)
		local key = path:match("^gesture_parameters%.(.+)$")
		if not key then return nil end
		local binding, action = parameters.split_action_parameter_key(key)
		if action and parameters.get_action_parameter_spec(action) then return domain(binding) end
		return nil
	end
	local editor_inventory = require("shortcuts.physical_editor_inventory").new({
		path = options.path, current_path = options.current_path or function() return require("infra.config_paths").config("config.toml") end,
		read = function(path) return Writer.read_classified(path, files) end,
		keyboard = keyboard, parameters = parameters, recognizes = domain,
	})
	local edit_source = options.expected_source
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
			chords = chords.configuration_candidate(config, written),
			combinations = combinations and combinations.configuration_candidate(config, others) or nil }
	end
	local function inventory()
		local bytes, status, detail = Writer.read_classified(options.path, files)
		assert(status == "ok" or status == "absent", "shortcut source is unreadable: " .. tostring(detail))
		source = { status = status, content = bytes }
		if combinations then
			pair_source = combinations.configuration_source(owner)
			assert(type(pair_source) == "table" and pair_source.path == options.path
				and pair_source.status == status and pair_source.content == bytes,
				"shortcut pair runtime disagrees with its acknowledged source")
		end
		document = Codec.decode(bytes or "")
		assert(type(document) == "table", "shortcut source is malformed")
		assert(parameters.parameter_configuration_matches(owner, document, domain) == true,
			"shortcut runtime parameters disagree with their acknowledged source")
		resolve(document)
		local paths
		paths, legacy = parameters.parameter_configuration_inventory(document, domain)
		return manifest.scope_inventory("shortcuts", {
			keyboard = function() return keyboard.configuration_paths(document) end,
			parameters = function() return paths end,
			combinations = function()
				local pair_paths = {}
				if not combinations then return pair_paths end
				local desired = combinations.configuration_snapshot(owner)
				assert(type(desired) == "table", "shortcut pair inventory requires its exact lease")
				for _, record in ipairs({ { "key_combination_taps", "taps" }, { "key_combination_holds", "holds" } }) do
					local stored = type(document.shortcuts) == "table" and document.shortcuts[record[1]] or nil
					local seen = {}
					for pair, value in pairs(desired[record[2]]) do if value ~= "none" then seen[pair] = true end end
					for pair in pairs(type(stored) == "table" and stored or {}) do
						if combinations.configuration_domain("combination__" .. pair) == "combination" then seen[pair] = true end
					end
					for pair in pairs(seen) do pair_paths[#pair_paths + 1] = "shortcuts." .. record[1] .. "." .. pair end
				end
				return pair_paths
			end,
		}, validators)
	end
	local function capture()
		local snapshot = { manager = manager.configuration_snapshot(owner), keyboard = keyboard.configuration_snapshot(owner),
			taps = taps.configuration_snapshot(owner), chords = chords.configuration_snapshot(owner),
			parameters = parameters.parameter_configuration_snapshot(owner),
			combinations = combinations and combinations.configuration_snapshot(owner) or nil }
		for _, key in ipairs({ "manager", "keyboard", "taps", "chords", "parameters" }) do
			if type(snapshot[key]) ~= "table" then return nil end
		end
		if combinations and type(snapshot.combinations) ~= "table" then return nil end
		return snapshot
	end
	local function apply_state(state)
		local stopped = { enabled = false, wrap = false, caps_word_active = false, caps_word_triggered = false }
		if manager.apply_configuration(owner, stopped) ~= true then return false end
		if keyboard.apply_configuration(owner, state.keyboard) ~= true then return false end
		if taps.apply_configuration(owner, state.taps) ~= true then return false end
		if chords.apply_configuration(owner, state.chords) ~= true then return false end
		if combinations and combinations.apply_configuration(owner, state.combinations) ~= true then return false end
		if parameters.apply_parameter_configuration(owner, state.parameters) ~= true then return false end
		return manager.apply_configuration(owner, state.manager) == true
	end
	local select_row = options.only == "script_chords" and script_chord_rows(parameter_domain) or nil
	local transaction_options = { path = options.path, backup_path = options.backup_path, files = files,
		manifest = manifest, owned_paths = inventory, owners = validators, capture = capture, restore = apply_state,
		select = select_row,
		after_publish = function() publication_acked = true; return release(published_source) end,
		before_restore = function() return acquire() end,
		after_restore = function()
			local restored = combinations and (publication_acked and pair_source or combinations.configuration_source(owner, true)) or nil
			if combinations and type(restored) ~= "table" then return false end
			return release(restored, true)
		end,
		validate_update = function(scope, row)
			if scope ~= "shortcuts" or options.only ~= nil then return false end
			if row.section == "shortcuts.keyboard" then
				return keyboard.physical_slot_descriptor(row.key) ~= nil
					and (row.delete == true or parameters.is_assignable(row.value) == true)
			end
			if row.section == "gesture_parameters" then
				local binding, action = parameters.split_action_parameter_key(row.key)
				local slot = type(binding) == "string" and binding:match("^keyboard__(.+)$") or nil
				return slot ~= nil and keyboard.physical_slot_descriptor(slot) ~= nil
					and type(action) == "string" and type(parameters.get_action_parameter_spec(action)) == "string"
					and (row.delete == true or parameters.validate_action_parameter(action, row.value) == true)
			end
			return false
		end,
		prepare_batch = function(path, updates, adapter)
			local operations = {}
			for _, row in ipairs(updates) do operations[#operations + 1] = row end
			for _, row in ipairs(legacy) do
				if not editing and (options.only == nil or select_row(row.section .. "." .. row.key)) then
					operations[#operations + 1] = row
				end
			end
			-- Ordinary reset preserves obsolete assignment parents until explicit cleanup.
			-- Editing keeps its exact source receipt and strict non-neutral collisions.
			if options.only == nil then
				operations = Parents.preserve(source.content or "", operations, Parents.shortcut_namespaces())
			end
			if editing and edit_source and (edit_source.path ~= path or edit_source.status ~= source.status
			or edit_source.content ~= source.content) then return false, "source_changed" end
			return Writer.prepare_batch(path, operations, adapter, source)
		end,
		apply = function(config, updates, _, candidate_bytes)
			if options.is_paused() then return false end
			if combinations and combinations.configuration_source_matches(owner, pair_source) ~= true then return false end
			local candidate = resolve(config, true)
			candidate.parameters = parameters.parameter_configuration_snapshot(owner)
			if type(candidate.parameters) ~= "table" then return false end
			if editing then
				for _, row in ipairs(updates) do
					if row.section == "gesture_parameters" then
						if row.delete then candidate.parameters[row.key] = nil
						else candidate.parameters[row.key] = row.value end
					end
				end
			else
				for key in pairs(candidate.parameters) do
					local path = "gesture_parameters." .. key
					if parameter_domain(path) and (options.only == nil or select_row(path)) then
						candidate.parameters[key] = nil
					end
				end
			end
			if apply_state(candidate) ~= true then return false end
			if combinations then
				if combinations.configuration_source_matches(owner, pair_source) ~= true then return false end
				published_source = { path = options.path, status = "ok", content = candidate_bytes }
			end
			return true
		end,
	}
	local transaction, publication_sequence = Transaction.new(transaction_options), 0
	local function next_transaction()
		publication_acked = false
		if publication_sequence > 0 then
			transaction.release()
			local fresh = {}
			for key, value in pairs(transaction_options) do fresh[key] = value end
			fresh.backup_path = options.backup_path .. ".edit-" .. publication_sequence
			transaction = Transaction.new(fresh)
		end
		publication_sequence = publication_sequence + 1
	end
	function owner.pending() return busy or retiring or uncertain_pair or delivery_held or release_claims ~= nil or #held > 0 or transaction.pending() end
	acquire = function()
		for _, port in ipairs(ports) do
			local retained = false
			for _, existing in ipairs(held) do if existing == port then retained = true end end
			local called, acquired = true, true
			if not retained or port.pair then called, acquired = pcall(port.acquire, owner) end
			if port.pair then
				local observed, exact = pcall(combinations.owns_configuration, owner)
				if not observed or type(exact) ~= "boolean" then uncertain_pair = true; return false end
				if exact and not retained then held[#held + 1] = port end
				if not called or acquired ~= true or not exact then return false end
				local fenced, receipt = pcall(combinations.acquire_delivery_fence, owner)
				local identified, own_fence = pcall(combinations.owns_delivery_fence, owner)
				if not identified or type(own_fence) ~= "boolean" then uncertain_pair = true; return false end
				delivery_held = own_fence
				if not fenced or receipt ~= true or not own_fence then return false end
			else
				if not called or acquired ~= true then return false end
				if not retained then held[#held + 1] = port end
			end
		end
		retiring = true
		local called, stopped = pcall(parameters.stop_programs)
		if not called or stopped ~= true then return false end
		retiring = false
		return true
	end
	local function perform(mode, rows)
		if owner.pending() or (rows == nil and mode ~= "clear" and mode ~= "recommended")
			or rows ~= nil and options.only ~= nil then return false end
		busy = true
		local observed, paused = pcall(options.is_paused)
		if not observed or paused ~= false then busy = false; return false end
		editing = rows ~= nil
		if editing and edit_source then
			local checked, current = pcall(edit_source.guard)
			if not checked or current ~= true then busy = false; return false, "source_changed" end
		end
		local admitted, accepted = pcall(acquire)
		if not admitted or accepted ~= true then
			if not retiring then release() end
			busy = false
			return false, "shortcut configuration acquisition refused"
		end
		-- Pair/keyboard dispatch and captured programs stay fenced before any
		-- source publication; no failed native ACK can authorize a candidate.
		local called, committed, detail = pcall(function()
			next_transaction()
			if rows ~= nil then return transaction.apply_updates("shortcuts", rows) end
			return transaction.apply("shortcuts", mode)
		end)
		local released = true
		if not transaction.pending() then released = release() end
		busy = false
		return called and committed == true and released == true, called and detail or committed
	end
	function owner.apply(mode) return perform(mode) end
	function owner.capture_editor_inventory()
		if owner.pending() then return nil, "unavailable" end
		local called, inventory, receipt = pcall(editor_inventory.capture)
		if not called then return nil, "unavailable" end
		return inventory, receipt
	end
	function owner.editor_source_current(receipt)
		local called, current = pcall(editor_inventory.current, receipt)
		return called and current == true
	end
	--- Keeps GUI readiness separate from actual native physical delivery.
	--- @return boolean available Strict native capability acknowledgement.
	function owner.physical_delivery_available()
		return PhysicalAvailability.ready(keyboard.physical_delivery_available)
	end
	function owner.edit(rows, receipt)
		rows = PhysicalAvailability.capture_updates(rows)
		if rows == nil then return false, "save_failed" end
		if not owner.physical_delivery_available()
			and PhysicalAvailability.requires_delivery(rows, "gesture_parameters", parameters.split_action_parameter_key) then
			return false, "unavailable"
		end
		if receipt ~= nil then
			local called, expected = pcall(editor_inventory.expected_source, receipt)
			if not called or not expected then return false, "source_changed" end
			edit_source = expected
		end
		local committed, detail = perform("edit", rows)
		edit_source = options.expected_source
		if committed ~= true then return false, detail == "source_changed" and detail or "save_failed" end
		return true
	end
	function owner.retry_restore()
		if busy then return false end
		busy = true
		if uncertain_pair then
			local observed, exact = pcall(combinations.owns_configuration, owner)
			if not observed or type(exact) ~= "boolean" then busy = false; return false end
			uncertain_pair = false
			if exact then held[#held + 1] = pair_port end
		end
		if retiring then
			local called, stopped = pcall(parameters.stop_programs)
			if not called or stopped ~= true then busy = false; return false end
			retiring = false
		end
		local called, restored = pcall(transaction.retry_restore)
		if not called or restored ~= true then busy = false; return false end
		local settled = release()
		busy = false
		return settled == true
	end
	--- Undoes the last commit under the same native and program ownership.
	function owner.revert()
		if owner.pending() then return false, "shortcut configuration is already owned" end
		busy = true
		local observed, paused = pcall(options.is_paused)
		if not observed or paused ~= false then busy = false; return false end
		local admitted, accepted = pcall(acquire)
		if not admitted or accepted ~= true then
			if not retiring then release() end
			busy = false; return false
		end
		local called, reverted, detail = pcall(transaction.revert)
		local released = true
		if not transaction.pending() then released = release() end
		busy = false
		return called and reverted == true and released == true, detail
	end
	function owner.release()
		if owner.pending() then return false end
		transaction.release()
		return true
	end
	return owner
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

--- Retains the native editor issuer and any refused edit debt across windows.
--- @param is_paused function Current native pause getter.
--- @return table|nil owner The still-owned editor scope, or closed refusal.
function M.editor_owner(is_paused)
	if _editor_busy or type(is_paused) ~= "function" then return nil end
	_editor_busy = true
	local called, result = pcall(function()
		if is_paused() ~= false then return nil end
		local path = require("infra.config_paths").config("config.toml")
		if type(path) ~= "string" or path == "" then return nil end
		if _editor_owner and _editor_owner.pending() and _editor_owner.retry_restore() ~= true then return nil end
		if is_paused() ~= false or require("infra.config_paths").config("config.toml") ~= path then return nil end
		if _editor_owner and _editor_path ~= path then
			_editor_owner.release()
			_editor_owner, _editor_path, _editor_pause = nil, nil, nil
		end
		_editor_pause = is_paused
		if not _editor_owner then
			_sequence = _sequence + 1
			local owner = M.new({ path = path,
				backup_path = path .. ".physical-shortcuts-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. _sequence .. ".bak",
				is_paused = function() return _editor_pause and _editor_pause() end })
			if is_paused() ~= false or require("infra.config_paths").config("config.toml") ~= path then
				owner.release()
				return nil
			end
			_editor_owner, _editor_path = owner, path
		end
		return _editor_owner
	end)
	_editor_busy = false
	return called and result or nil
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
