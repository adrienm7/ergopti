--- infra/key_combinations_scope.lua

--- Ordered-pair edits use the shared conditional publisher and acknowledged
--- inverse. Pair input stays fenced until both source and delivery ACKs settle.
local Transaction = require("config_scope_transaction")
local Shared = require("tap_hold.key_combinations")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local KeyPath = require("toml_codec.key_path")
local Updates = require("shortcuts.physical_availability")
local M = {}
local retained, sequence, session_busy = nil, 0, false
--- Creates one exact ordered-pair publication owner. Native and source
--- inverses retain their lease until literal acknowledgement.
--- @param options table Canonical path, backup, pause and owner ports.
--- @return table owner Edit, inverse and retained-debt controls.
function M.new(options)
	assert(type(options) == "table" and type(options.is_paused) == "function")
	local combinations = options.combinations or require("modules.shortcuts.key_combinations")
	local parameters = options.parameters or require("modules.gestures.manager")
	for _,name in ipairs({"acquire_configuration","release_configuration","acquire_delivery_fence","owns_delivery_fence","release_delivery_fence","owns_configuration","configuration_domain","validate_slot","configuration_snapshot","configuration_source","configuration_source_matches","capture_edit_source","configuration_candidate","apply_configuration"}) do
		assert(type(combinations[name]) == "function", "combination configuration owner is incomplete")
	end
	local manifest = options.manifest or require("infra.manifest_reader")
	local function declared()
		if type(manifest.find_entry_by_path) ~= "function" then return false end
		local entry = manifest.find_entry_by_path("category_enabled.key_combinations")
		return type(entry) == "table" and entry.type == "boolean" and entry.default == true
	end
	local gate_value, frame, published_frame, publication_acked
	local chord_operations, no_op_frame
	local function chord_declared()
		if type(manifest.find_entry_by_path) ~= "function" or type(manifest.sparse_operation) ~= "function" then return false end
		local delay = manifest.find_entry_by_path("mod_combos.simultaneous_threshold_ms")
		local symmetry = manifest.find_entry_by_path("mod_combos.symmetric")
		return type(delay) == "table" and delay.type == "number"
			and type(symmetry) == "table" and symmetry.type == "boolean"
	end
	local owner, pair_held, parameter_held, busy, acquisition_debt, retiring = {}, false, false, false, false, false
	local function identify_parameters()
		local called, snapshot = pcall(parameters.parameter_configuration_snapshot, owner)
		if not called or (snapshot ~= nil and type(snapshot) ~= "table") then
			error("Parameter lease identity is unknown.")
		end
		parameter_held = type(snapshot) == "table"
	end
	local fence_held = false
	local function acquire()
		local called, acquired = pcall(combinations.acquire_configuration,owner)
		local identified, exact = pcall(combinations.owns_configuration,owner)
		if not identified or type(exact) ~= "boolean" then error("Combination lease identity is unknown.") end
		pair_held = exact == true
		if not called or acquired ~= true or not pair_held then return false end
		called, acquired = pcall(combinations.acquire_delivery_fence,owner)
		local fenced, owned = pcall(combinations.owns_delivery_fence,owner)
		if not fenced or type(owned) ~= "boolean" then error("Combination delivery fence identity is unknown.") end
		fence_held = owned
		if not called or acquired ~= true or not fence_held then return false end
		if not parameter_held then
			called, acquired = pcall(parameters.acquire_parameter_configuration,owner)
			identify_parameters()
			if not called or acquired ~= true or not parameter_held then return false end
		end
		retiring = true
		local stopped, receipt = pcall(parameters.stop_programs)
		if not stopped or receipt ~= true then return false end
		retiring = false
		return true
	end
	local function release(expected)
		local document = expected and (expected.status == "ok" and Codec.decode(expected.content) or {})
		local function detached_source()
			local receipt = combinations.capture_edit_source(owner)
			if type(receipt) ~= "table" or receipt.path ~= expected.path or receipt.status ~= expected.status
				or receipt.content ~= expected.content or receipt.guard() ~= true then return false end
			return true
		end
		local function current()
			if expected == nil then return true end
			local source_current = pair_held and combinations.configuration_source_matches(owner,expected) == true
				or not pair_held and detached_source()
			return source_current and parameters.parameter_configuration_matches(parameter_held and owner or nil,
				document,function() return true end) == true
		end
		-- Keep parameters fenced across the final native installation callback.
		if pair_held then
			if not current() then return false end
			local called, accepted = pcall(combinations.release_configuration,owner)
			if not called or accepted ~= true then return false end
			pair_held = false
		end
		if parameter_held then
			if not current() then return false end
			local called, accepted = pcall(parameters.release_parameter_configuration,owner)
			if not called or accepted ~= true then
				-- A refused terminal parameter release must keep pair input fenced.
				pcall(combinations.acquire_configuration,owner)
				local identified, exact = pcall(combinations.owns_configuration,owner)
				if not identified or type(exact) ~= "boolean" then acquisition_debt = true
				else pair_held = exact end
				return false
			end
			parameter_held = false
		end
		if expected then
			-- Capture private parameter currency before native source callbacks,
			-- then check it after their final guard has returned.
			local guard = parameters.capture_parameter_source_guard(document,function() return true end)
			if type(guard) ~= "function" or not detached_source() or guard() ~= true then return false end
		end
		if fence_held then
			-- All native/source callbacks precede this private-only terminal ACK.
			if combinations.release_delivery_fence(owner) ~= true then return false end
			fence_held = false
		end
		return true
	end
	local function parameter_row(key)
		local binding, action = parameters.split_action_parameter_key(key)
		return type(binding) == "string" and combinations.configuration_domain(binding) == Shared.BINDING_SCOPE
			and type(action) == "string" and type(parameters.get_action_parameter_spec(action)) == "string", action
	end
	local function capture(source)
		local pairs = combinations.configuration_snapshot(owner)
		local params = parameters.parameter_configuration_snapshot(owner)
		frame = combinations.configuration_source(owner)
		if type(pairs) ~= "table" or type(params) ~= "table" or type(frame) ~= "table" or type(source) ~= "table"
			or frame.path ~= options.path or frame.status ~= source.status
			or (frame.status == "ok" and frame.content ~= source.content) then return nil end
		local document = frame.status == "ok" and Codec.decode(frame.content) or {}
		if parameters.parameter_configuration_matches(owner,document,function() return true end) ~= true
			or combinations.configuration_source_matches(owner,frame) ~= true then return nil end
		return { pairs = pairs, parameters = params }
	end
	local function install(snapshot)
		if not pair_held or not parameter_held then return false end
		if combinations.apply_configuration(owner,snapshot.pairs) ~= true then return false end
		return parameters.apply_parameter_configuration(owner,snapshot.parameters) == true
	end
	local transaction = Transaction.new({path=options.path,backup_path=options.backup_path,
		files=options.files or require("adapters.file_system"),manifest={scope_plan=function(scope,mode,...)
			if scope == "key_combinations_gate" then
				assert(mode == "configured" and type(gate_value) == "boolean")
				return { presets = {}, operations = {manifest.sparse_operation("category_enabled.key_combinations",gate_value)} }
			end
			if scope == "key_combinations_chord" then
				assert(mode == "configured" and type(chord_operations) == "table")
				return {presets={},operations=chord_operations}
			end
			return manifest.scope_plan(scope,mode,...)
		end},
		owned_paths=function()
			if type(combinations.configuration_entries) ~= "function" then return {} end
			local paths = {}
			local function dynamic(path)
				-- Declared scalar features are already planned by the manifest; only
				-- its dynamic leaves belong in the runtime-owned path inventory.
				if type(manifest.find_entry_by_path)~="function" or manifest.find_entry_by_path(path)==nil then
					paths[#paths+1]=path
				end
			end
			for _,entry in ipairs(combinations.configuration_entries()) do
				dynamic(Shared.TAP_SECTION.."."..entry.id)
				dynamic(Shared.HOLD_SECTION.."."..entry.id)
				dynamic(KeyPath.render({"mod_combos","config",entry.id,"combo"}))
			end
			local params = parameters.parameter_configuration_snapshot(owner)
			for key in pairs(params or {}) do
				if parameter_row(key) then paths[#paths+1] = KeyPath.render({"gesture_parameters",key}) end
			end
			return paths
		end,owners={action_parameter_domain=function(path)
			local parts=KeyPath.parse(path,true)
			return parts and #parts==2 and parts[1]=="gesture_parameters" and parameter_row(parts[2]) and "combination" or nil
		end},capture=capture,restore=install,
		prepare_batch=function(target,rows,files)
			local prepared, detail, candidate, source = Writer.prepare_batch(target,rows,files)
			local expected = options.expected_source
			if expected and (target ~= expected.path or type(source) ~= "table" or source.status ~= expected.status
				or (source.status == "ok" and source.content ~= expected.content)) then
				return false,"Combination editor source changed."
			end
			return prepared,detail,candidate,source
		end,
		validate_update=function(scope,row)
			if scope ~= "shortcuts" or row.intent ~= nil then return false end
			if row.section == Shared.TAP_SECTION or row.section == Shared.HOLD_SECTION then
				if combinations.configuration_domain(Shared.BINDING_SCOPE.."__"..row.key) ~= "combination" then return false end
				local kind = row.section == Shared.TAP_SECTION and "tap" or "hold"
				return row.delete == true or combinations.validate_slot(kind,row.key,row.value) == true
			end
			local parts=KeyPath.parse(row.section,true)
			if parts and #parts==3 and parts[1]=="mod_combos" and parts[2]=="config" and row.key=="combo" then
				return chord_declared() and combinations.configuration_domain(Shared.BINDING_SCOPE.."__"..parts[3]) == "combination"
					and (row.delete == true or combinations.validate_slot("combo",parts[3],row.value) == true)
			end
			if row.section == "gesture_parameters" then
				local owned,action = parameter_row(row.key)
				return owned and (row.delete == true or parameters.validate_action_parameter(action,row.value) == true)
			end
			return false
		end,
		apply=function(config,updates,_,candidate_bytes)
			if options.is_paused() ~= false then return false end
			local candidate = { pairs = combinations.configuration_candidate(config,true),
				parameters = parameters.parameter_configuration_snapshot(owner) }
			if type(candidate.parameters) ~= "table" then return false end
			for _,row in ipairs(updates) do
				if row.section == "gesture_parameters" then candidate.parameters[row.key] = row.delete and nil or row.value end
			end
			if combinations.configuration_source_matches(owner,frame) ~= true then return false end
			if install(candidate) ~= true then return false end
			if combinations.configuration_source_matches(owner,frame) ~= true then return false end
			published_frame = {path=options.path,status="ok",content=candidate_bytes}
			return true
		end,
		after_publish=function()
			publication_acked = true
			return release(published_frame)
		end,
		before_restore=function() return acquire() end,
		after_restore=function() return release(publication_acked and frame or nil) end,
	})
	function owner.pending() return busy or acquisition_debt or retiring or fence_held or transaction.pending() end
	--- Publishes only known ordered tap/hold slots and their action parameters.
	--- @param rows table Dense detached canonical string assignments/deletions.
	--- @return boolean committed
	local function perform(operation)
		if owner.pending() then return false end
		busy = true
		no_op_frame = nil
		local observed, paused = pcall(options.is_paused)
		if not observed or paused ~= false then busy = false; return false end
		if options.expected_source then
			local checked, current = pcall(options.expected_source.guard)
			if not checked or current ~= true then busy = false; return false end
		end
		local admitted, acquired = pcall(acquire)
		if not admitted or acquired ~= true then
			acquisition_debt = not admitted or pair_held or parameter_held or fence_held or retiring
			busy = false
			return false,"Combination configuration acquisition refused."
		end
		local called, committed = pcall(operation)
		if not transaction.pending() and (pair_held or parameter_held or fence_held) then
			local released, settled = pcall(release,called and committed==true and no_op_frame or nil)
			if not released or settled ~= true then acquisition_debt = true end
		end
		busy = false
		if called and committed == true and not acquisition_debt then return true end
		return false,"Combination configuration publication refused."
	end
	function owner.edit(rows)
		rows=Updates.capture_updates(rows)
		if rows==nil then return false end
		return perform(function() return transaction.apply_updates("shortcuts",rows) end)
	end
	function owner.set_enabled(enabled)
		if type(enabled) ~= "boolean" or type(manifest.sparse_operation) ~= "function" or not declared() then return false end
		return perform(function()
			gate_value = enabled
			return transaction.apply("key_combinations_gate","configured")
		end)
	end
	--- Publishes typed Linux settings through the same retained native/file inverse.
	--- Neutral defaults remain sparse; no operation changes either master switch.
	function owner.set_chord_settings(values)
		if not chord_declared() or type(values) ~= "table" or getmetatable(values) ~= nil then return false end
		for key in pairs(values) do if key ~= "simultaneous_threshold_ms" and key ~= "combo_symmetric" then return false end end
		local called, settings = pcall(Shared.chord_settings,values)
		if not called then return false end
		return perform(function()
			chord_operations = {
				manifest.sparse_operation("mod_combos.simultaneous_threshold_ms",settings.simultaneous_threshold_ms),
				manifest.sparse_operation("mod_combos.symmetric",settings.combo_symmetric),
			}
			return transaction.apply("key_combinations_chord","configured")
		end)
	end
	--- Plans from the currently held canonical file, never cached menu slots.
	function owner.copy_taps_to_chords()
		if not chord_declared() or type(combinations.configuration_entries) ~= "function"
			or type(combinations.chord_settings) ~= "function" then return false end
		return perform(function()
			local captured = combinations.configuration_source(owner)
			if type(captured) ~= "table" then return false end
			local plan = Shared.plan_chord_copy(captured.status=="ok" and captured.content or "",{
				entries=combinations.configuration_entries(),settings=combinations.chord_settings(),tap_section=Shared.TAP_SECTION,
				is_action=function(action)
					-- Every known participant must be admitted by the actual source owner.
					for _,entry in ipairs(combinations.configuration_entries()) do
						if combinations.validate_slot("combo",entry.id,action) ~= true then return false end
					end
					return true
				end,
			})
			if combinations.configuration_source_matches(owner,captured) ~= true then return false end
			if plan.changes == 0 then
				local doc=captured.status=="ok" and Codec.decode(captured.content) or {}
				if parameters.parameter_configuration_matches(owner,doc,function() return true end)~=true
					or combinations.configuration_source_matches(owner,captured)~=true then return false end
				no_op_frame=captured
				return true
			end
			chord_operations=plan.rows
			return transaction.apply("key_combinations_chord","configured")
		end)
	end
	--- Clears/restores only declared known pair leaves; unknown records stay intact.
	function owner.apply(mode)
		if (mode ~= "clear" and mode ~= "recommended") or not chord_declared() then return false end
		return perform(function() return transaction.apply("key_combinations",mode) end)
	end
	--- Settles the original exact tokens; no successor may replace their debt.
	--- @return boolean settled
	function owner.retry_restore()
		if busy then return false end
		busy = true
		if retiring then
			local stopped, receipt = pcall(parameters.stop_programs)
			if not stopped or receipt ~= true then busy = false; return false end
			retiring = false
		end
		if acquisition_debt and not transaction.pending() then
			local identified, exact = pcall(combinations.owns_configuration,owner)
			if not identified or type(exact) ~= "boolean" then busy = false; return false end
			pair_held = exact
			local known = pcall(identify_parameters)
			if not known then busy = false; return false end
		end
		local called, settled = pcall(transaction.retry_restore)
		if called and settled == true and (pair_held or parameter_held or fence_held) then
			local released, retired = pcall(release); settled = released and retired == true
		end
		if called and settled == true then acquisition_debt = false end
		busy = false
		return called and settled == true
	end
	function owner.revert()
		if owner.pending() then return false end
		busy = true
		local observed,paused = pcall(options.is_paused)
		if not observed or paused ~= false then busy = false; return false end
		local called,reverted = pcall(transaction.revert)
		busy = false
		return called and reverted == true
	end
	function owner.release()
		if owner.pending() or pair_held or parameter_held or fence_held then return false end
		transaction.release(); return true
	end
	return owner
end
--- Retains exact compensation/acquisition debt across picker sessions. A fresh
--- edit cannot replace its private native token while retirement is unresolved.
--- @param rows table Dense canonical slot and parameter assignments.
--- @param is_paused function Current daemon pause getter.
--- @return boolean committed

local function session(is_paused,expected_source)
	if type(is_paused) ~= "function" or is_paused() ~= false then return nil end
	if retained and retained.pending() and retained.retry_restore() ~= true then return nil end
	if retained and retained.release() ~= true then return nil end
	sequence = sequence + 1
	local path = require("infra.config_paths").config("config.toml")
	retained = M.new({path=path,backup_path=path..".combinations-"..os.date("%Y%m%d-%H%M%S").."-"..sequence..".bak",is_paused=is_paused,expected_source=expected_source})
	return retained
end

local function operate(is_paused,expected_source,apply)
	if session_busy then return false end
	session_busy = true
	local called, committed = pcall(function()
		local owner = session(is_paused,expected_source)
		return owner ~= nil and apply(owner) == true
	end)
	session_busy = false
	return called and committed == true
end
--- Retries only the retained owner before a new menu source is captured.
--- No successor allocation or publication is permitted during recovery.
--- @return boolean settled
function M.retry_restore()
	if session_busy then return false end
	session_busy = true
	local called, settled = pcall(function()
		return retained == nil or not retained.pending() or retained.retry_restore() == true
	end)
	session_busy = false
	return called and settled == true
end
function M.edit(rows,is_paused,expected_source)
	rows=Updates.capture_updates(rows);if rows==nil then return false end
	return operate(is_paused,expected_source,function(owner) return owner.edit(rows) end)
end
function M.set_enabled(enabled,is_paused,expected_source)
	return operate(is_paused,expected_source,function(owner) return owner.set_enabled(enabled) end)
end
function M.set_chord_settings(values,is_paused,expected_source)
	if type(values)~="table" or getmetatable(values)~=nil then return false end
	for key in pairs(values) do if key~="simultaneous_threshold_ms" and key~="combo_symmetric" then return false end end
	local called,detached=pcall(Shared.chord_settings,values);if not called then return false end
	values=detached
	return operate(is_paused,expected_source,function(owner) return owner.set_chord_settings(values) end)
end
function M.copy_taps_to_chords(is_paused,expected_source)
	return operate(is_paused,expected_source,function(owner) return owner.copy_taps_to_chords() end)
end
function M.apply(mode,is_paused,expected_source)
	return operate(is_paused,expected_source,function(owner) return owner.apply(mode) end)
end
return M
