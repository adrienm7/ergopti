--- keyboard/engine/keys/combination_engine.lua

--- Native effect ownership for the shared ordered-pair policy. The underlying
--- tap-hold engine retains modifier reference counts and live layer ownership.
local Policy = require("tap_hold.engine.key_combinations")
local Engine = require("platform.remap.tap_hold_engine")
local ConfigOwner = require("shortcuts.engine.key_combinations")
local AiActions = require("shortcuts.engine.ai_actions")
local settings_current = ConfigOwner.buffered_settings_current
local M = {}
local input_issuers = setmetatable({}, { __mode = "k" })
local input_receipts = setmetatable({}, { __mode = "k" })
local engine_input_ports = { arm = Engine.arm_one_shot, state = Engine.input_arm_state, clear = Engine.clear_input_arm }
local BASE_INPUT_PORT_NAMES = { "process", "tick", "activity", "handles", "release_all", "take_custody", "output_holder",
	"combination_hold", "combination_release", "combination_first_available", "combination_lift", "combination_restore", "arm_one_shot", "input_arm_state", "clear_input_arm",
	"set_roll_origin_capture", "commit_roll_origin", "take_roll_origins" }
local OWNER_INPUT_PORT_NAMES = { "process", "tick", "activity", "activate", "configure", "set_tap_holds_enabled",
	"begin_delivery", "end_delivery", "release_all", "ack_retirement", "take_custody", "output_holder" }
local original_engine_ports = {}
for _, name in ipairs(BASE_INPUT_PORT_NAMES) do original_engine_ports[name] = rawget(Engine, name) end
local function append(out, rows) for _, row in ipairs(rows) do out[#out + 1] = row end end

--- Copies a runtime projection that may only withdraw configured actions.
--- Original source options remain unchanged for their retained admission guards.
--- @param options table Original source-owned options.
--- @param projection table|nil Optional filtered tap and chord maps.
--- @return table|nil taps, table|nil chords
local function projected_maps(options, projection)
	if projection == nil then return options.taps, options.chords end
	assert(type(projection) == "table" and getmetatable(projection) == nil, "plain action projection required")
	local maps = {}
	for _, field in ipairs({ "taps", "chords" }) do
		local original, selected = options[field], projection[field]
		assert(original == nil and selected == nil or type(original) == "table" and type(selected) == "table",
			"projection must retain each source map")
		if original then
			assert(getmetatable(selected) == nil, "plain projected action map required")
			local copy = {}
			for pair, action in pairs(original) do
				local retained = selected[pair]
				assert(retained == action or retained == "none", "projection cannot replace a source action")
				copy[pair] = retained
			end
			for pair in pairs(selected) do assert(original[pair] ~= nil, "projection cannot add a source binding") end
			maps[field] = copy
		end
	end
	return maps.taps, maps.chords
end

--- Restricts cross-source collision isolation to configured runtime bindings.
--- @param options table Original source-owned options.
--- @param taps table|nil Runtime tap projection.
--- @param chords table|nil Runtime chord projection.
--- @return table codes Native codes participating in an active binding.
local function participating_codes(options, taps, chords)
	local codes = {}
	if options.enabled ~= true then return codes end
	for _, first in ipairs(options.keys) do
		for _, second in ipairs(options.keys) do
			if first ~= second then
				local pair = Policy.pair(first, second)
				if (taps and taps[pair] or Policy.NONE) ~= Policy.NONE
					or (options.holds and options.holds[pair] or Policy.NONE) ~= Policy.NONE
					or (options.chord_settings and chords and chords[pair] or Policy.NONE) ~= Policy.NONE then
					codes[Engine.KEY_CODES[first]], codes[Engine.KEY_CODES[second]] = true, true
				end
			end
		end
	end
	return codes
end

--- Copies an action map with the unarmed actions withdrawn (AI actions while
--- the AI is off), so the pair is not a pair at all and its keys keep their own
--- behaviour, instead of being claimed and refused.
--- @param map table|nil Pair -> action.
--- @param off boolean Whether the AI is off.
--- @return table|nil
local function armed_map(map, off)
	if map == nil or not off then return map end
	local copy = {}
	for pair, action in pairs(map) do copy[pair] = AiActions.is_ai_action(action) and Policy.NONE or action end
	return copy
end

function M.new(base, options, buffered_ports, projection, roll_ports)
	assert(type(base) == "table" and type(options.capture) == "function" and type(options.capture_action) == "function")
	local runtime_taps, runtime_chords = projected_maps(options, projection)
	local combination_codes = participating_codes(options, runtime_taps, runtime_chords)
	local owner, policy, generation, pending, retirement, acting = {}, nil, nil, nil, nil, false
	local presses, blocked, holds, serial = {}, {}, {}, 0
	local native_presses = {}
	local waiting, chords, chord_policy = nil, {}, nil
	local policy_ai_off = false -- the AI state the policy and chord policy were built for
	local processing, buffer_request = nil, nil
	local roll_guard, active_journal, install_roll, fallback_origin = nil, nil, nil, nil
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
	-- Keep the issuer's proof and both exports private.  Internal checks use
	-- sealed state; fresh checks are reserved for externally visible effects.
	local function capture_proof(callback, ...)
		local ok, proof = pcall(callback, ...)
		if not ok or type(proof) ~= "table" then return nil end
		local current, sealed = rawget(proof, "current"), rawget(proof, "sealed")
		if type(current) ~= "function" or type(sealed) ~= "function" then return nil end
		local function check(fn)
			if rawget(proof, "current") ~= current or rawget(proof, "sealed") ~= sealed then return false end
			local called, value = pcall(fn)
			return called and value == true and rawget(proof, "current") == current and rawget(proof, "sealed") == sealed
		end
		return { current = function() return check(current) end, sealed = function() return check(sealed) end }
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
			local ok, result = pcall(callback, action, binding)
			acting = false
			return ok and result ~= false
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
		if retirement or acting or pending or delivery or processing or active_journal or next(base.key_refs) or next(base.held) then return false end
		policy, generation, retirement, acknowledged, runtime_guard, disabled, epoch = nil, nil, nil, false, nil, false, epoch + 1
		waiting, chords, chord_policy = nil, {}, nil
		return true
	end
	function owner.configure(_, selected, receivers, selected_projection, selected_roll_ports)
		if retirement or acting or pending or delivery or processing or active_journal or next(base.key_refs) or next(base.held) then return false end
		if roll_ports and not selected_roll_ports then return false end
		if type(selected) ~= "table" or type(selected.capture) ~= "function" or type(selected.capture_action) ~= "function" then return false end
		local taps, selected_chords = projected_maps(selected, selected_projection)
		local old_options, old_receivers, old_chord_policy, old_roll_ports = options, buffered_ports, chord_policy, roll_ports
		options, buffered_ports, chord_policy, roll_ports = selected, receivers, nil, selected_roll_ports
		if roll_ports and install_roll() ~= true then
			options, buffered_ports, chord_policy, roll_ports = old_options, old_receivers, old_chord_policy, old_roll_ports
			return false
		end
		runtime_taps, runtime_chords = taps, selected_chords
		combination_codes = participating_codes(options, runtime_taps, runtime_chords)
		epoch = epoch + 1; return true
	end
	function owner.set_tap_holds_enabled(_, enabled)
		if next(base.held) or next(base.key_refs) or acting or pending or active_journal then return false end
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
		-- The AI switch changed: build the policies again from the first press
		-- with every key up, so the pairs follow the switch with no reload.
		if policy_ai_off ~= AiActions.off() and not next(presses) and not next(native_presses) and not waiting
			and not next(chords) and not next(base.held) then
			policy, generation, runtime_guard, chord_policy = nil, nil, nil, nil
			policy_ai_off = AiActions.off()
		end
		if not physical(receipt) then return base_ports.process(base, code, value, at_ms, receipt) end
		if generation ~= nil and generation ~= receipt.generation then return revoke_event(code, receipt.source) end
		local source = receipt.source
		local isolated = combination_codes[code] == true
		-- Unrelated physical presses belong to Hook's per-source aggregation.
		-- Retain them only to prevent a buffered chord starting while any is held.
		if not isolated then
			local stamp = source .. "\0" .. code
			if value == 1 then native_presses[stamp] = true
			elseif value == 0 then native_presses[stamp] = nil end
		elseif value == 1 then
			-- A blocked physical peer still owns its original DOWN even if
			-- the first source has since released.  Do not start another
			-- combination until all such source-specific paths retire.
			if next(blocked) and not presses[code] then
				blocked[source .. "\0" .. code] = { delegated = true }
				base_ports.activity(base)
				if policy then policy.activity() end
				return base_ports.process(base, code, value, at_ms, receipt)
			end
			if presses[code] and presses[code] ~= source then
				local delegated = base.held[code] ~= nil or base.instant_down[code] ~= nil
					or base.layer_keys[code] ~= nil or base.native_keys[code] ~= nil or base.passed_down[code] ~= nil
				blocked[source .. "\0" .. code] = { delegated = delegated }
				base_ports.activity(base)
				if policy then policy.activity() end
				if delegated then return base_ports.process(base, code, value, at_ms, receipt) end
				return {}
			end
			presses[code] = source
		elseif blocked[source .. "\0" .. code] then
			local owner = blocked[source .. "\0" .. code]
			if value == 0 then blocked[source .. "\0" .. code] = nil end
			if policy then policy.activity() end
			if owner.delegated then return base_ports.process(base, code, value, at_ms, receipt) end
			return {}
		elseif value == 0 and presses[code] and presses[code] ~= source then
			return {}
		end
		local guard = policy and runtime_guard or capture(options.capture)
		if not guard or guard() ~= true then
			if policy then return revoke_event(code, receipt.source) end
			if roll_ports then generation = receipt.generation end
			if isolated and value == 0 then presses[code] = nil end
			return base_ports.process(base, code, value, at_ms, receipt)
		end
		if not policy then
			generation, runtime_guard = receipt.generation, guard
			local configured = {}; for key, setting in pairs(options) do configured[key] = setting end
			policy_ai_off = AiActions.off()
			configured.taps = armed_map(runtime_taps, policy_ai_off)
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
		if isolated and value == 0 then presses[code] = nil end
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
		return package.loaded["shortcuts.engine.key_combinations"]==ConfigOwner
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
	local roll_binding
	local function roll_current()
		local saved = roll_binding
		if not saved or roll_ports ~= saved.ports or rawget(roll_ports, "capture_runtime") ~= saved.runtime
			or rawget(roll_ports, "capture_tap") ~= saved.tap or rawget(roll_ports, "current") ~= saved.current then return false end
		local ok, current = pcall(saved.current)
		return ok and current == true and roll_ports == saved.ports
			and rawget(roll_ports, "capture_runtime") == saved.runtime and rawget(roll_ports, "capture_tap") == saved.tap
			and rawget(roll_ports, "current") == saved.current
	end
	install_roll = function()
		if type(roll_ports) ~= "table" or type(roll_ports.capture_runtime) ~= "function"
			or type(roll_ports.capture_tap) ~= "function" or type(roll_ports.current) ~= "function" then return false end
		local previous = roll_binding
		roll_binding = { ports = roll_ports, runtime = roll_ports.capture_runtime, tap = roll_ports.capture_tap, current = roll_ports.current }
		local installed = base_ports.set_roll_origin_capture(base, function(code, at_ms)
			if not roll_current() then return nil end
			local created = false
			if not roll_guard then roll_guard = capture_proof(roll_binding.runtime); created = true end
			if not roll_guard or roll_guard.current() ~= true or not roll_current() then if created then roll_guard = nil end; return nil end
			local token
			if fallback_origin and fallback_origin.code == code and fallback_origin.at_ms == at_ms
				and receiver_current(fallback_origin.token, false) then token = fallback_origin.token
			else token = capture_original(code, at_ms) end
			if not token and created then roll_guard = nil end
			return token
		end, function(token)
			return roll_current() and roll_guard ~= nil and roll_guard.sealed() == true and receiver_current(token, false)
				and roll_current() and roll_guard.sealed() == true
		end)
		if installed ~= true then roll_binding = previous end
		return installed == true
	end
	if roll_ports and install_roll() ~= true then error("roll origin capture installation refused") end

	-- A roll's private cursor yields one independently acknowledged output/action
	-- step at a time. Public step tables are views, never the authority.
	local function journal_frame(journal)
		if active_journal or type(journal) ~= "table" or journal.refused or not roll_guard or not roll_current() then return nil end
		local exact = { steps = {}, counts = {}, index = 1, epoch = epoch, generation = generation, guard = roll_guard }
		for _, segment in ipairs(journal) do
			if type(segment) ~= "table" or type(segment.rows) ~= "table" or type(segment.origin) ~= "table"
				or not receiver_current(segment.origin, false) then return nil end
			local rows, facts = {}, {}
			for index, row in ipairs(segment.rows) do
				if type(row) ~= "table" then return nil end
				rows[index] = row
				facts[index] = { row = row, code = row.code, value = row.value, physical = row.physical, holder = row.holder, handoff = row.handoff }
			end
			local action_guard
			if type(segment.tap) == "string" then
				if type(segment.binding) ~= "string" then return nil end
				local capture_action = segment.binding:match("^tap_hold__") and roll_binding.tap
					or segment.binding:match("^combination__") and options.capture_action or nil
				if not capture_action then return nil end
				if segment.binding:match("^tap_hold__") then
					action_guard = capture_proof(capture_action, segment.binding, segment.tap)
				else
					local legacy = capture(capture_action, segment.binding, segment.tap)
					if legacy then action_guard = { current = legacy, sealed = roll_guard.sealed } end
				end
				if not action_guard or action_guard.current() ~= true then return nil end
			end
			local action_text = type(segment.tap) == "table" and segment.tap.type_text or nil
			exact.steps[#exact.steps + 1] = { rows = rows, facts = facts, token = segment.origin,
				tap = segment.tap, binding = segment.binding, action_guard = action_guard, action_text = action_text }
			exact.counts[segment.origin] = (exact.counts[segment.origin] or 0) + 1
		end
		if #exact.steps == 0 then return nil end
		active_journal = exact
		local public = { owned = true }
		local function current()
			return active_journal == exact and not retirement and not disabled and epoch == exact.epoch
				and generation == exact.generation and roll_guard == exact.guard and roll_current() and exact.guard.sealed() == true
		end
		function public.next()
			if not current() or exact.step then return nil, "refused" end
			local item = exact.steps[exact.index]
			if not item then
				active_journal = nil
				if exact.clear_roll then roll_guard = nil end
				return nil, "done"
			end
			if not receiver_current(item.token, false) then return nil, "refused" end
			local called, view = pcall(buffered_ports.buffered_input_view, item.token)
			if not called or type(view) ~= "table" or type(view.source) ~= "string" or view.physical_generation ~= exact.generation then return nil, "refused" end
			local step, methods
			local function shape()
				if not current() or not receiver_current(item.token, false) or not step
					or step.rows ~= item.rows or step.buffered ~= item.token or step.tap ~= item.tap or step.binding ~= item.binding
					or #item.rows ~= #item.facts then return false end
				if methods and (step.fresh ~= methods.fresh or step.ack ~= methods.ack or step.admit ~= methods.admit
					or step.run ~= methods.run or step.restore ~= methods.restore or step.finish ~= methods.finish
					or step.delivery_current ~= methods.delivery_current) then return false end
				if type(item.tap) == "table" and item.tap.type_text ~= item.action_text then return false end
				for index, row in ipairs(item.rows) do
					local fact = item.facts[index]
					if row ~= fact.row or row.code ~= fact.code or row.value ~= fact.value or row.physical ~= fact.physical
						or row.holder ~= fact.holder or row.handoff ~= fact.handoff then return false end
				end
				return not item.action_guard or item.action_guard.sealed() == true
			end
			step = frame(item.rows, item.tap, item.binding, nil, shape,
				{ source = view.source, generation = view.physical_generation, ready = true, physical = true })
			step.rows, step.buffered, step.tap, step.binding = item.rows, item.token, item.tap, item.binding
			local acknowledge, run = step.ack, step.run
			function step.ack(accepted)
				if not shape() or acknowledge(accepted) ~= true then return false end
				item.acknowledged = true; return true
			end
			function step.run(callback, receipt)
				if not item.acknowledged or item.attempted or not shape() then return false end
				item.attempted = true
				item.completed = run(callback, receipt) == true
				return item.completed
			end
			function step.finish(receipt)
				if exact.step ~= step or not item.acknowledged or item.tap ~= nil and not item.completed
					or pending or acting or delivery or not shape() or not physical(receipt)
					or receipt.source ~= view.source or receipt.generation ~= view.physical_generation then return false end
				exact.counts[item.token] = exact.counts[item.token] - 1
				if exact.counts[item.token] == 0 then
					local committed, empty = base_ports.commit_roll_origin(base, item.token)
					if committed ~= true then return false end
					if empty then exact.clear_roll = true end
				end
				exact.step, exact.index = nil, exact.index + 1
				return true
			end
			function step.fresh()
				return shape() and exact.guard.current() == true
					and (not item.action_guard or item.action_guard.current() == true) and shape()
			end
			methods = { fresh = step.fresh, ack = step.ack, admit = step.admit, run = step.run,
				restore = step.restore, finish = step.finish, delivery_current = step.delivery_current }
			exact.step = step
			return step
		end
		function public.abort()
			local rows = owner:release_all()
			return { rows = rows, frame = retired_frame() }
		end
		return public
	end
	local function choose(first, second, elapsed)
		if not chord_policy and runtime_chords and options.chord_settings then
			local pairs = {}
			for _,a in ipairs(options.keys) do for _,b in ipairs(options.keys) do
				if a~=b then pairs[#pairs+1]={id=Policy.pair(a,b),first=a,second=b} end
			end end
			policy_ai_off = AiActions.off()
			chord_policy = Policy.chord_policy({pairs=pairs,chords=armed_map(runtime_chords,policy_ai_off),settings=options.chord_settings})
		end
		return chord_policy and chord_policy.choose(first,second,elapsed) or nil
	end
	local function candidate(code)
		if not ids[code] or not runtime_chords or not options.chord_settings or next(presses) or next(native_presses) or next(chords)
			or next(blocked) or not source_settings_current()
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
		fallback_origin = { code = first.code, at_ms = first.at_ms, token = first.token }
		local called, rows, action, binding, produced = pcall(process_ordered, first.code, 1, first.at_ms, first.receipt)
		fallback_origin = nil
		if not called then error(rows, 0) end
		rows = rows or {{code=first.code,value=1,physical=true}}
		if first.cancelled and base.held[first.code] then base.held[first.code].cancelled=true end
		local due = base_ports.tick(base,now_ms)
		if #due == 1 and due[1].roll_journal then
			local journal = due[1].roll_journal
			if produced or journal.refused then return owner:release_all(), nil, nil, retired_frame(true) end
			if #rows > 0 or action ~= nil then
				table.insert(journal, 1, { rows = rows, tap = action, binding = binding, origin = first.token })
			end
			local sealed = journal_frame(journal)
			if not sealed then return owner:release_all(), nil, nil, retired_frame(true) end
			return {}, nil, nil, sealed
		end
		for _, row in ipairs(due) do
			if row.tap ~= nil then
				-- A legacy timer result carries no independent source receipt.  Do
				-- not silently overwrite an earlier action or invent authority to
				-- deliver both; roll timers use the owned journal above instead.
				if action ~= nil then return owner:release_all(), nil, nil, retired_frame(true) end
				action, binding = row.tap, row.binding
			else rows[#rows+1]=row end
		end
		if not pending_current(first,false) then return owner:release_all(),nil,nil,retired_frame() end
		local guard=function() return pending_current(first,false) end
		local owned=frame(rows or {},action,binding,nil,guard,first.receipt)
		owned.buffered=first.token
		return rows or {},action,binding,owned
	end
	local function process_buffered(code,value,at_ms,receipt)
		if active_journal then return owner:release_all(), nil, nil, retired_frame(true) end
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
			if owned and (owned.buffered or owned.next) then owned.replay=true end
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
		if owned and not owned.owned then
			if owned.refused then return owner:release_all(), nil, nil, retired_frame(true) end
			local sealed = journal_frame(owned)
			if not sealed then return owner:release_all(), nil, nil, retired_frame(true) end
			return {}, nil, nil, sealed
		end
		if retirement and not owned then return retirement.rows,nil,nil,retired_frame() end
		return rows,action,binding,owned
	end
	function owner.tick(_, at_ms)
		if retirement or pending or acting or delivery or processing or active_journal then return {} end
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
		local due = base_ports.tick(base, at_ms)
		if #due == 1 and due[1].roll_journal then
			local journal = due[1].roll_journal
			local sealed = not journal.refused and journal_frame(journal) or nil
			if not sealed then return { { owned_rows = owner:release_all(), frame = retired_frame() } } end
			return { { owned_rows = {}, frame = sealed } }
		end
		return due
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
		for _, token in ipairs(base_ports.take_roll_origins(base)) do
			if not unique[token] then unique[token]=true; orphaned[#orphaned+1]=token end
		end
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
		native_presses = {}
		waiting, chords, chord_policy, active_journal, roll_guard = nil, {}, nil, nil, nil
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
			if not exact or exact.action ~= action or action ~= "one_shot_shift" or not acting
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
		one_shot_result = rawget(record.base, "one_shot_result") }
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
