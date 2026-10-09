--- platform/remap/key_combination_engine.lua

--- Native effect ownership for the shared ordered-pair policy. The underlying
--- tap-hold engine retains modifier reference counts and live layer ownership.
local Policy = require("tap_hold.key_combinations")
local Engine = require("platform.remap.tap_hold_engine")
local ConfigOwner = require("modules.shortcuts.key_combinations")
local settings_current = ConfigOwner.buffered_settings_current
local M = {}
local input_issuers = setmetatable({}, { __mode = "k" })
local input_receipts = setmetatable({}, { __mode = "k" })
local engine_input_ports = { arm = Engine.arm_one_shot, state = Engine.input_arm_state, clear = Engine.clear_input_arm, caps = Engine.arm_caps_word, caps_ack = Engine.ack_caps_word }
local BASE_INPUT_PORT_NAMES = { "process", "tick", "activity", "handles", "release_all", "take_custody", "output_holder",
	"combination_hold", "combination_release", "combination_first_available", "combination_lift", "combination_restore", "arm_one_shot", "input_arm_state", "clear_input_arm", "arm_caps_word", "ack_caps_word" }
local OWNER_INPUT_PORT_NAMES = { "process", "tick", "activity", "activate", "configure", "set_tap_holds_enabled",
	"begin_delivery", "end_delivery", "release_all", "ack_retirement", "take_custody", "output_holder" }
local original_engine_ports = {}
for _, name in ipairs(BASE_INPUT_PORT_NAMES) do original_engine_ports[name] = rawget(Engine, name) end
local function append(out, rows) for _, row in ipairs(rows) do out[#out + 1] = row end end
function M.new(base, options, buffered_ports)
	assert(type(base) == "table" and type(options.capture) == "function" and type(options.capture_action) == "function")
	local owner, policy, generation, pending, retirement, acting = {}, nil, nil, nil, nil, false
	local presses, blocked, holds, serial = {}, {}, {}, 0
	local waiting, chords, chord_policy = nil, {}, nil
	local processing, buffer_request = nil, nil
	local original_by_code, acknowledged, runtime_guard = base.by_code, false, nil
	-- Retain this producer's dispatch and inverse functions before any callback.
	-- An input lease observes export changes; cleanup still uses its original issuer.
	local base_ports, base_raw_ports = {}, {}
	for _, name in ipairs(BASE_INPUT_PORT_NAMES) do
		base_ports[name], base_raw_ports[name] = base[name], rawget(base, name)
	end
	local epoch, disabled, delivery = 0, false, nil
	local input_revision = 0
	local input_frames = setmetatable({}, { __mode = "k" })
	local ids = {}; for id, code in pairs(Engine.KEY_CODES) do ids[code] = id end
	local function token(effect) return effect.source .. "\0" .. effect.pair_id end
	local function spec(id)
		local result = { mods = {} }
		if id == "nav" then result.layer = true; return result end
		for modifier in id:gmatch("[^+]+") do result.mods[#result.mods + 1] = assert(Engine.MODIFIER_CODES[modifier]) end
		return result
	end
	local function capture(callback, ...)
		local ok, guard = pcall(callback, ...)
		if not ok or type(guard) ~= "function" then return nil end
		return function()
			local admitted, current = pcall(guard)
			return admitted and current == true
		end
	end
	local function physical(receipt)
		return type(receipt) == "table" and receipt.ready == true and receipt.physical == true
			and type(receipt.source) == "string" and receipt.source ~= "" and type(receipt.generation) == "number"
	end
	local function frame(rows, action, binding, lifted, guard, receipt)
		serial = serial + 1
		local exact = { rows = rows, serial = serial, action = action, lifted = lifted, epoch = epoch }
		pending = exact
		local result = { owned = true }
		function result.delivery_current()
			if not guard or guard() ~= true then return false end
			return pending == exact and not retirement and not disabled and not acting and epoch == exact.epoch and serial == exact.serial
		end
		function result.ack(accepted)
			if pending ~= exact or accepted ~= true or retirement or delivery then return false end
			pending = nil; return true
		end
		local function current_frame(current)
			return not retirement and not disabled and not pending and not acting and not delivery
				and epoch == exact.epoch and serial == exact.serial and generation == receipt.generation
				and physical(current) and current.source == receipt.source and current.generation == receipt.generation
		end
		function result.admit(current)
			if not current_frame(current) or not guard or guard() ~= true then return false end
			return current_frame(current)
		end
		function result.run(callback, current)
			if not action or not result.admit(current) then return false end
			acting = true
			local ok = pcall(callback, action, binding)
			acting = false
			return ok
		end
		function result.restore(current)
			if not result.admit(current) then return {}, nil end
			local restored = base_ports.combination_restore(base, lifted)
			if #restored == 0 then return restored, nil end
			return restored, frame(restored, nil, nil, nil, guard, receipt)
		end
		input_frames[result] = { action = action, epoch = epoch, guard = guard, receipt = receipt }
		return result
	end
	local function retired_frame(replay)
		local exact = retirement
		return { owned = true, orphans = exact.orphans, replay = replay == true, ack = function(accepted) return owner:ack_retirement(accepted, exact.rows) end,
			restore = function() return {}, nil end }
	end
local function revoke_event(code, source)
		local consumed = base.held[code] or base.layer_keys[code] or base.instant_down[code]
			or base.native_keys[code] or base.one_shot_swallowed[code]
			or policy and policy.owns(ids[code] or tostring(code), source)
		return owner:release_all(), nil, nil, retired_frame(not consumed)
	end
	function owner.has_combinations() return true end
	function owner.take_custody() return base_ports.take_custody(base) end
	function owner.output_holder(_, row) return base_ports.output_holder(base, row) end
	function owner.activate()
		if retirement or acting or pending or delivery or processing or next(base.key_refs) or next(base.held) then return false end
		policy, generation, retirement, acknowledged, runtime_guard, disabled, epoch = nil, nil, nil, false, nil, false, epoch + 1
		waiting, chords, chord_policy = nil, {}, nil
		return true
	end
	function owner.configure(_, selected, receivers)
		if retirement or acting or pending or delivery or processing or next(base.key_refs) or next(base.held) then return false end
		if type(selected) ~= "table" or type(selected.capture) ~= "function" or type(selected.capture_action) ~= "function" then return false end
		options, buffered_ports, chord_policy = selected, receivers, nil; epoch = epoch + 1; return true
	end
	function owner.set_tap_holds_enabled(_, enabled)
		if next(base.held) or next(base.key_refs) or acting or pending then return false end
		base.by_code = enabled and original_by_code or {}; input_revision = input_revision + 1; return true
	end
	function owner.begin_delivery(_, rows)
		if delivery or acting or processing or retirement and retirement.rows ~= rows then return nil end
		local token = {}; delivery = { token = token, retirement = retirement, epoch = epoch }; return token
	end
	function owner.end_delivery(_, token)
		if not delivery or token ~= delivery.token or token == nil then return false end
		local previous = delivery; delivery = nil
		return retirement == previous.retirement and epoch == previous.epoch
	end
	function owner.handles(_, code) return base:handles(code) or ids[code] ~= nil end
	local function process_ordered(code, value, at_ms, receipt)
		if acting or delivery or pending then return owner:release_all(), nil, nil, retired_frame() end
		if retirement then return {} end
		if disabled then return base_ports.process(base, code, value, at_ms, receipt) end
		if not physical(receipt) then return base_ports.process(base, code, value, at_ms, receipt) end
		if generation ~= nil and generation ~= receipt.generation then return revoke_event(code, receipt.source) end
		local source = receipt.source
		if value == 1 then
			if presses[code] and presses[code] ~= source then
				blocked[source .. "\0" .. code] = true
				if policy then policy.activity() end
				return {}
			end
			presses[code] = source
		elseif blocked[source .. "\0" .. code] then
			if value == 0 then blocked[source .. "\0" .. code] = nil end
			if policy then policy.activity() end
			return {}
		end
		local guard = policy and runtime_guard or capture(options.capture)
		if not guard or guard() ~= true then
			if policy then return revoke_event(code, receipt.source) end
			if value == 0 then presses[code] = nil end
			return base_ports.process(base, code, value, at_ms, receipt)
		end
		if not policy then
			generation, runtime_guard = receipt.generation, guard
			local configured = {}; for key, setting in pairs(options) do configured[key] = setting end
			configured.generation = generation
			policy = Policy.new(configured)
		end
		local unavailable = {}
		for id, first_code in pairs(Engine.KEY_CODES) do
			local state = base.held[first_code]
			unavailable[id] = presses[first_code] ~= source or state and state.undecided == true
		end
		local result = policy.process({ key = ids[code] or tostring(code), value = value, at_ms = at_ms,
			physical = true, source = source, generation = generation, revision = options.revision, blocked_first = unavailable })
		if value == 0 then presses[code] = nil end
		if not result.consumed then return base_ports.process(base, code, value, at_ms, receipt) end
		local rows, action, binding, lifted, action_guard = {}, nil, nil, nil, guard
		for _, effect in ipairs(result.effects) do
			local exact = token(effect)
			if effect.kind == "take_first" then
				local first = base.held[Engine.KEY_CODES[effect.first]]
				if first then first.cancelled = true end
			elseif effect.kind == "take_hold" then
				local generated, hold = base_ports.combination_hold(base, spec(effect.hold))
				holds[exact] = hold; append(rows, generated)
			elseif effect.kind == "release_hold" then
				local hold = holds[exact]
				if hold then append(rows, base_ports.combination_release(base, hold)); holds[exact] = nil end
			elseif effect.kind == "tap" then
				action, binding = effect.tap, effect.binding
				action_guard = capture(options.capture_action, binding, action)
				if action_guard and action_guard() == true then
					local released; released, lifted = base_ports.combination_lift(base, Engine.KEY_CODES[effect.first]); append(rows, released)
				else action, binding = nil, nil end
			end
		end
		return rows, action, binding, frame(rows, action, binding, lifted, action_guard, receipt)
	end

	local function receiver_current(token, held)
		if type(buffered_ports) ~= "table" or type(buffered_ports.buffered_input_current) ~= "function" then return false end
		local called, current = pcall(buffered_ports.buffered_input_current,token,held)
		return called and current == true
	end
	local function source_settings_current()
		return package.loaded["modules.shortcuts.key_combinations"]==ConfigOwner
			and rawget(ConfigOwner,"buffered_settings_current")==settings_current
			and type(settings_current)=="function" and settings_current(options)==true
	end
	local function capture_original(code, at_ms)
		if type(buffered_ports) ~= "table" or type(buffered_ports.capture_buffered_input) ~= "function" then return nil end
		local request={code=code,at_ms=at_ms,processing=processing}
		buffer_request=request
		local called, token = pcall(buffered_ports.capture_buffered_input,owner,code,at_ms)
		buffer_request=nil
		if request.processing ~= processing then return nil end
		return called and type(token)=="table" and receiver_current(token,true) and token or nil
	end
	local function choose(first, second, elapsed)
		if not chord_policy and options.chords and options.chord_settings then
			local pairs = {}
			for _,a in ipairs(options.keys) do for _,b in ipairs(options.keys) do
				if a~=b then pairs[#pairs+1]={id=Policy.pair(a,b),first=a,second=b} end
			end end
			chord_policy = Policy.chord_policy({pairs=pairs,chords=options.chords,settings=options.chord_settings})
		end
		return chord_policy and chord_policy.choose(first,second,elapsed) or nil
	end
	local function candidate(code)
		if not ids[code] or not options.chords or not options.chord_settings or next(presses) or next(chords)
			or not source_settings_current()
			or base_ports.combination_first_available(base,code) ~= true then return false end
		for _, second in ipairs(options.keys) do if choose(ids[code],second,0) then return true end end
		return false
	end
	local function pending_current(first, held)
		return receiver_current(first.token,held) and first.guard() == true and source_settings_current()
			and receiver_current(first.token,held) and not retirement and not disabled and epoch==first.epoch
	end
	local function withdraw(code, source)
		local consumed = waiting and waiting.code == code and waiting.receipt.source == source or chords[source.."\0"..code] ~= nil
		local rows = owner:release_all()
		return rows,nil,nil,retired_frame(not consumed)
	end
	local function fallback(first, now_ms)
		waiting = nil
		local rows,action,binding = process_ordered(first.code,1,first.at_ms,first.receipt)
		rows = rows or {{code=first.code,value=1,physical=true}}
		if first.cancelled and base.held[first.code] then base.held[first.code].cancelled=true end
		local due = base_ports.tick(base,now_ms)
		for _, row in ipairs(due) do
			if row.tap ~= nil then action,binding=row.tap,row.binding else rows[#rows+1]=row end
		end
		if not pending_current(first,false) then return owner:release_all(),nil,nil,retired_frame() end
		local guard=function() return pending_current(first,false) end
		local owned=frame(rows or {},action,binding,nil,guard,first.receipt)
		owned.buffered=first.token
		return rows or {},action,binding,owned
	end
	local function process_buffered(code,value,at_ms,receipt)
		if retirement or disabled or acting or delivery or pending then return process_ordered(code,value,at_ms,receipt) end
		local taken = physical(receipt) and chords[receipt.source.."\0"..code]
		if taken then
			if not receiver_current(taken.first.token,false) or taken.first.guard()~=true then return withdraw(code,receipt.source) end
			if value==0 then
				chords[receipt.source.."\0"..code]=nil
				taken.down[code]=nil
			end
			return {}
		end
		if waiting then
			local first=waiting
			if not physical(receipt) or receipt.generation~=first.receipt.generation or not pending_current(first,false) then
				return withdraw(code,type(receipt)=="table" and receipt.source or "")
			end
			local selection = value==1 and receipt.source==first.receipt.source and receiver_current(first.token,true)
				and choose(ids[first.code],ids[code],at_ms-first.at_ms) or nil
			if selection then
				local second=capture_original(code,at_ms)
				local guard=capture(options.capture_chord,selection.binding,selection.action)
				if second and guard and guard()==true and pending_current(first,true) and receiver_current(second,true) then
					waiting=nil
					local state={first=first,second=second,down={[first.code]=true,[code]=true}}
					chords[receipt.source.."\0"..first.code],chords[receipt.source.."\0"..code]=state,state
					local owned_guard=function()
						return guard()==true and pending_current(first,false) and receiver_current(second,false)
					end
					local owned=frame({},selection.action,selection.binding,nil,owned_guard,first.receipt)
					owned.buffered=first.token
					return {},selection.action,selection.binding,owned
				end
			end
			local rows,action,binding,owned=fallback(first,at_ms)
			if owned and owned.buffered then owned.replay=true end
			return rows,action,binding,owned
		end
		if physical(receipt) and value==1 and candidate(code) then
			local guard=capture(options.capture)
			local token=capture_original(code,at_ms)
			if token and guard and guard()==true and source_settings_current() and receiver_current(token,true) and not retirement and not disabled then
				generation, runtime_guard = receipt.generation, guard
				waiting={code=code,at_ms=at_ms,receipt=receipt,token=token,guard=guard,epoch=epoch,
					deadline=at_ms+options.chord_settings.simultaneous_threshold_ms}
				return {}
			end
		end
		return process_ordered(code,value,at_ms,receipt)
	end
	function owner.process(_,code,value,at_ms,receipt)
		if processing then return owner:release_all(),nil,nil,retired_frame() end
		local exact={}; processing=exact
		local called,rows,action,binding,owned=pcall(process_buffered,code,value,at_ms,receipt)
		processing,buffer_request=nil,nil
		if not called then error(rows,0) end
		if retirement and not owned then return retirement.rows,nil,nil,retired_frame() end
		return rows,action,binding,owned
	end
	function owner.tick(_, at_ms)
		if retirement or pending or acting or delivery or processing then return {} end
		if disabled then return base_ports.tick(base, at_ms) end
		if waiting then
			local first=waiting
			if not pending_current(first,false) then return {{owned_rows=owner:release_all(),frame=retired_frame()}} end
			if at_ms>first.deadline then
				local rows,action,binding,owned=fallback(first,at_ms)
				return {{owned_rows=rows,tap=action,binding=binding,frame=owned}}
			end
			return {}
		end
		if policy then
			local guard = runtime_guard
			if not guard or guard() ~= true then return { { owned_rows = owner:release_all(), frame = retired_frame() } } end
		end
		return base_ports.tick(base, at_ms)
	end
	function owner.activity()
		-- Pointer activity cannot positively match a pending keyboard chord.
		if waiting then waiting.cancelled=true; waiting.deadline=waiting.at_ms-1 end
		if policy then policy.activity() end; base_ports.activity(base)
	end
	function owner.release_all()
		if retirement then return retirement.rows end
		local orphaned, unique = {}, {}
		if waiting then orphaned[#orphaned+1]=waiting.token; unique[waiting.token]=true end
		for _,state in pairs(chords) do
			for _,token in ipairs({state.first.token,state.second}) do
				if not unique[token] then unique[token]=true; orphaned[#orphaned+1]=token end
			end
		end
		local seen, rows = {}, base_ports.release_all(base)
		for _, row in ipairs(rows) do seen[row.code] = true end
		-- A failed lift/release still owns its physical UP obligation even after
		-- logical reference counts changed. Preserve these exact rows for retry.
		if pending then for _, row in ipairs(pending.rows) do
			if not seen[row.code] then rows[#rows + 1] = { code = row.code, value = 0 }; seen[row.code] = true end
		end end
		local policy_token
		if policy then local ignored; ignored, policy_token = policy.retire() end
		retirement = { rows = rows, token = {}, policy_token = policy_token, orphans=orphaned }
		return rows
	end
	function owner.ack_retirement(_, accepted, exact_rows)
		if not retirement or accepted ~= true or acting or delivery or processing or exact_rows and exact_rows ~= retirement.rows then return false end
		if policy and not policy.ack_retirement(retirement.policy_token, true) then return false end
		pending, holds, presses, blocked, acknowledged = nil, {}, {}, {}, true
		waiting, chords, chord_policy = nil, {}, nil
		policy, generation, runtime_guard, retirement, disabled, epoch = nil, nil, nil, nil, true, epoch + 1
		return true
	end
	local original_owner_ports = {}
	for _, name in ipairs(OWNER_INPUT_PORT_NAMES) do original_owner_ports[name] = rawget(owner, name) end
	local base_metatable = getmetatable(base)
	local input_record = {
		base = base, owner = owner, base_metatable = base_metatable,
		base_index = type(base_metatable) == "table" and rawget(base_metatable, "__index") or nil,
		base_ports = base_ports, base_raw_ports = base_raw_ports, owner_ports = original_owner_ports,
		epoch = function() return epoch end, input_revision = function() return input_revision end,
		available = function() return not retirement and not disabled end,
		buffer_request = function(code,at_ms)
			return processing~=nil and buffer_request~=nil and buffer_request.processing==processing
				and buffer_request.code==code and buffer_request.at_ms==at_ms and not retirement and not disabled
		end,
		guard = function(selected, action)
			local exact = input_frames[selected]
			if not exact or exact.action ~= action or (action ~= "one_shot_shift" and action ~= "caps_word") or not acting
				or pending or delivery or retirement or disabled or exact.epoch ~= epoch then return nil end
			local function current()
				return not retirement and not disabled and epoch == exact.epoch
					and generation == exact.receipt.generation and exact.guard and exact.guard() == true
					and not retirement and not disabled and epoch == exact.epoch
					and generation == exact.receipt.generation
			end
			return current
		end,
	}
	local owner_metatable = { __index = function(_, key) return base[key] end }
	input_record.owner_metatable, input_record.owner_index = owner_metatable, owner_metatable.__index
	input_issuers[owner] = input_record
	return setmetatable(owner, owner_metatable)
end

-- This final join reads only exact private issuer and original export facts.
local function input_issuer_current(record)
	if not record or not record.available() or package.loaded["platform.remap.tap_hold_engine"] ~= Engine
		or getmetatable(record.base) ~= record.base_metatable or record.base_index ~= Engine
		or rawget(record.base_metatable, "__index") ~= record.base_index
		or getmetatable(record.owner) ~= record.owner_metatable
		or rawget(record.owner_metatable, "__index") ~= record.owner_index then return false end
	for _, name in ipairs(BASE_INPUT_PORT_NAMES) do
		local port = original_engine_ports[name]
		if type(port) ~= "function" or rawget(Engine, name) ~= port
			or record.base_ports[name] ~= port or rawget(record.base, name) ~= record.base_raw_ports[name] then return false end
	end
	for _, name in ipairs(OWNER_INPUT_PORT_NAMES) do
		local port = record.owner_ports[name]
		if type(port) ~= "function" or rawget(record.owner, name) ~= port then return false end
	end
	return true
end

--- Captures only an actual installed-capable pair issuer, never a lookalike.
--- @param owner table Exact object created by this module.
--- @return table|nil receipt Opaque issuer identity; Hook supplies installation authority.
function M.capture_input_owner(owner)
	local record = input_issuers[owner]
	if not input_issuer_current(record) then return nil end
	local receipt, ports = {}, {}
	for _, name in ipairs(OWNER_INPUT_PORT_NAMES) do
		ports[name] = rawget(owner, name)
	end
	input_receipts[receipt] = { issuer = record, epoch = record.epoch(), ports = ports,
		owner_metatable = getmetatable(owner), input_revision = record.input_revision(),
		timeout = rawget(record.base, "one_shot_timeout_ms"),
		key_text = rawget(record.base, "key_text"), plan_text = rawget(record.base, "plan_text"),
		one_shot_result = rawget(record.base, "one_shot_result"),
		caps_word_plan = rawget(record.base, "caps_word_plan") }
	return receipt
end

--- Observes retained private issuer/epoch/port facts without an input or output IO.
--- @param receipt table Opaque issuer receipt.
--- @return boolean current
local function input_owner_current(receipt)
	local owned = input_receipts[receipt]
	if not owned or getmetatable(receipt) ~= nil or next(receipt) ~= nil
		or owned.epoch ~= owned.issuer.epoch() or owned.input_revision ~= owned.issuer.input_revision()
		or rawget(owned.issuer.base, "one_shot_timeout_ms") ~= owned.timeout or not input_issuer_current(owned.issuer)
		or getmetatable(owned.issuer.owner) ~= owned.owner_metatable
		or getmetatable(owned.issuer.base) ~= owned.issuer.base_metatable then return false end
	for _, name in ipairs(OWNER_INPUT_PORT_NAMES) do
		local port = owned.ports[name]
		if type(port) ~= "function" or rawget(owned.issuer.owner, name) ~= port then return false end
	end
	return Engine.arm_one_shot == engine_input_ports.arm and Engine.input_arm_state == engine_input_ports.state
		and Engine.clear_input_arm == engine_input_ports.clear and package.loaded["platform.remap.tap_hold_engine"] == Engine
		and rawget(owned.issuer.base, "key_text") == owned.key_text and rawget(owned.issuer.base, "plan_text") == owned.plan_text
		and rawget(owned.issuer.base, "one_shot_result") == owned.one_shot_result
		and rawget(owned.issuer.base, "caps_word_plan") == owned.caps_word_plan
		and Engine.arm_caps_word == engine_input_ports.caps and Engine.ack_caps_word == engine_input_ports.caps_ack
end

M.input_owner_current = input_owner_current

--- Retains only the actual admitted action frame's configuration guard.
--- @param receipt table Opaque issuer receipt.
--- @param frame table Exact acknowledged action frame.
--- @param action string Exact logical action.
--- @return function|nil guard
function M.capture_input_guard(receipt, frame, action)
	if not input_owner_current(receipt) then return nil end
	return input_receipts[receipt].issuer.guard(frame, action)
end

--- Applies only logical state; it neither reserves nor writes an output channel.
--- @param receipt table Opaque issuer receipt.
--- @param now_ms number Original event clock.
--- @param guard function Hook-owned source/currentness join.
--- @return boolean published
function M.arm_one_shot(receipt, now_ms, guard)
	if not input_owner_current(receipt) or type(guard) ~= "function" then return false end
	return engine_input_ports.arm(input_receipts[receipt].issuer.base, now_ms, guard)
end

--- Publishes the distinct persistent mode through an original action owner.
--- @param receipt table Original issuer receipt.
--- @param guard function Original Hook currentness guard.
--- @return boolean
function M.arm_caps_word(receipt, guard)
	if not input_owner_current(receipt) or type(guard) ~= "function" then return false end
	return engine_input_ports.caps(input_receipts[receipt].issuer.base, guard)
end

--- Completes only a matching prepared character batch after acknowledged delivery.
--- @param receipt table Original issuer receipt.
--- @param rows table Original prepared output rows.
--- @return boolean
function M.ack_caps_word(receipt, rows)
	if not input_owner_current(receipt) then return false end
	return engine_input_ports.caps_ack(input_receipts[receipt].issuer.base, rows)
end

--- Observes cleanup state only for the retained original issuer epoch.
--- @param receipt table Opaque issuer receipt.
--- @return string|nil state
function M.input_owner_state(receipt)
	local owned = input_receipts[receipt]
	if not owned or owned.epoch ~= owned.issuer.epoch() then return nil end
	return engine_input_ports.state(owned.issuer.base)
end

--- Cancels an unspent original arm; consumed output still requires native retirement.
--- @param receipt table Opaque issuer receipt.
--- @return boolean cleared
function M.clear_input_arm(receipt)
	local owned = input_receipts[receipt]
	if not owned or owned.epoch ~= owned.issuer.epoch() then return false end
	return engine_input_ports.clear(owned.issuer.base)
end
--- Observes only the original owner's live first-press acquisition role.
--- @param owner table Original installed producer.
--- @param code number Original event code.
--- @param at_ms number Original event clock.
--- @return boolean current
function M.buffered_request_current(owner,code,at_ms)
	local record=input_issuers[owner]
	return input_issuer_current(record) and record.buffer_request(code,at_ms)==true or false
end
return M
