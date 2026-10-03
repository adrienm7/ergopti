--- tests/support/karabiner_model.lua

--- ==============================================================================
--- MODULE: Karabiner Basic-Manipulator Model
--- DESCRIPTION:
--- Replays how the pinned Karabiner-Elements v16.0.0 core turns a generated
--- rule graph into output events, so generator tests assert what the user
--- types rather than the JSON shape meant to produce it. Every step models one
--- piece of src/share/manipulator in that release:
---   - types/from_modifiers_definition.hpp test_modifiers: a mandatory "any"
---     matches every state and claims every pressed flag; otherwise each
---     mandatory modifier must be pressed and, without an optional "any", no
---     other flag may be.
---   - manipulator_manager.hpp: a physical key reaches the output, and raises
---     its flag there, only after every manipulator passed it.
---   - manipulators/basic/basic.hpp key_down: the claimed flags are lifted
---     around `to` and pressed again at once, unless the LAST `to` entry is a
---     modifier key (event_sender.hpp is_last_to_event_modifier_key_event,
---     which reads the unfiltered list). Only the last posted entry stays held.
---   - basic.hpp key_up: deferred releases, then to_if_alone with the key-down
---     flags restored and the claimed flags lifted around it, then
---     to_after_key_up. Any key_down ends every pending tap (unset_alone).
---     Every key of a simultaneous chord belongs to one manipulation: the
---     first release posts that half, or the last one under key_up_when
---     "all", and the last release posts simultaneous_options.to_after_key_up.
---   - event_sender.hpp filter_and_replace_events: an entry whose own
---     conditions fail is dropped before anything is posted.
---   - from_event_definition.hpp test_key_order: a chord's key_down_order
---     `strict` takes its keys in the listed order, `strict_inverse` in the
---     reverse one, and `insensitive` (the default) in any order.
---   - modifier_flag_manager.hpp is_pressed reports Caps Lock pressed while the
---     lock is on (seed it through options.flags), and base.hpp turns lifting
---     or pressing a claimed Caps Lock into a sticky Caps Lock change, which
---     key_event_dispatcher.hpp sends to macOS as a Caps Lock key press: each
---     is recorded as a "lock" emission of caps_lock.
--- Held-down and delayed-action timers use an explicit advance() clock; both
--- cancel at another key-down and are retired at their owner's key-up, matching
--- basic.hpp and its to_if_held_down.hpp / to_delayed_action.hpp helpers.
--- Lazy modifier dispatch, keyboard repeat and sticky-modifier flag
--- bookkeeping are not modelled: the flags recorded for a key are the
--- modifier_flag_manager state an application reads at that key's key_down,
--- and Engine:held names the output keys left down, which macOS repeats.
--- ==============================================================================

local M = {}

-- modifier_definition.hpp get_modifier_flags: the flags each `modifiers`
-- name stands for. A to-event modifier presses the first one.
local FLAGS_BY_MODIFIER = {
	any           = {},
	caps_lock     = { "caps_lock" },
	command       = { "left_command", "right_command" },
	control       = { "left_control", "right_control" },
	fn            = { "fn" },
	option        = { "left_option", "right_option" },
	shift         = { "left_shift", "right_shift" },
	left_command  = { "left_command" },
	left_control  = { "left_control" },
	left_option   = { "left_option" },
	left_shift    = { "left_shift" },
	right_command = { "right_command" },
	right_control = { "right_control" },
	right_option  = { "right_option" },
	right_shift   = { "right_shift" },
}

-- modifier_flag_manager.hpp make_modifier_flags: every flag the manager reports.
M.FLAGS = {
	"caps_lock",
	"left_control", "left_shift", "left_option", "left_command",
	"right_control", "right_shift", "right_option", "right_command",
	"fn",
}

-- momentary_switch_event.hpp make_modifier_flag: the key codes that raise a
-- flag of their own. Caps Lock is a lock, not one of them.
local MODIFIER_KEY_CODES = {
	left_control = true, left_shift = true, left_option = true, left_command = true,
	right_control = true, right_shift = true, right_option = true, right_command = true,
	fn = true,
}
M.MODIFIER_KEY_CODES = MODIFIER_KEY_CODES

-- simultaneous_options.hpp key_order: the chord key orders Karabiner accepts.
-- from_event_definition.hpp test_key_order matches `strict` against the
-- listed order, `strict_inverse` against the reverse one, and any order else.
local KEY_DOWN_ORDERS = { insensitive = true, strict = true, strict_inverse = true }





-- ==========================================
-- ==========================================
-- ======= 1/ Matching and Conditions =======
-- ==========================================
-- ==========================================

--- Returns the flags one `modifiers` name stands for, failing on an unknown name.
--- @param modifier string Karabiner modifier name.
--- @return table flags Ordered flag names.
local function flags_of(modifier)
	local flags = FLAGS_BY_MODIFIER[modifier]
	assert(flags ~= nil, "unmodelled Karabiner modifier '" .. tostring(modifier) .. "'")
	return flags
end

--- Reports whether a dense list holds a value.
--- @param list table|nil Candidate list.
--- @param value any Value to find.
--- @return boolean found
local function contains(list, value)
	for _, item in ipairs(list or {}) do
		if item == value then return true end
	end
	return false
end

--- Models from_modifiers_definition::test_modifiers.
--- @param modifiers table|nil The manipulator's `from.modifiers`.
--- @param pressed table Set of pressed flag names.
--- @return table|nil claimed Set of flags the manipulator claims, nil when it does not match.
function M.test_modifiers(modifiers, pressed)
	modifiers = modifiers or {}
	local claimed = {}
	if contains(modifiers.mandatory, "any") then
		for _, flag in ipairs(M.FLAGS) do
			if pressed[flag] then claimed[flag] = true end
		end
		return claimed
	end

	local allowed = {}
	for _, modifier in ipairs(modifiers.mandatory or {}) do
		local found = nil
		for _, flag in ipairs(flags_of(modifier)) do
			allowed[flag] = true
			if found == nil and pressed[flag] then found = flag end
		end
		if found == nil then return nil end
		claimed[found] = true
	end
	if not contains(modifiers.optional, "any") then
		for _, modifier in ipairs(modifiers.optional or {}) do
			for _, flag in ipairs(flags_of(modifier)) do allowed[flag] = true end
		end
		for _, flag in ipairs(M.FLAGS) do
			if pressed[flag] and not allowed[flag] then return nil end
		end
	end
	return claimed
end

--- Evaluates one manipulator or to-event condition.
--- @param condition table Karabiner condition.
--- @param variables table Variable name → value; unset variables read 0.
--- @return boolean holds
local function condition_holds(condition, variables)
	if condition.type == "variable_if" or condition.type == "variable_unless" then
		local value = variables[condition.name]
		if value == nil then value = 0 end
		if condition.type == "variable_if" then return value == condition.value end
		return value ~= condition.value
	end
	if condition.type == "expression_if" or condition.type == "expression_unless" then
		local value = tonumber(condition.expression)
		assert(value ~= nil, "unmodelled Karabiner expression '" .. tostring(condition.expression) .. "'")
		if condition.type == "expression_if" then return value ~= 0 end
		return value == 0
	end
	error("unmodelled Karabiner condition type '" .. tostring(condition.type) .. "'")
end

--- Evaluates a condition list; an absent list always holds.
--- @param conditions table|nil Karabiner conditions.
--- @param variables table Variable name → value.
--- @return boolean holds
local function conditions_hold(conditions, variables)
	for _, condition in ipairs(conditions or {}) do
		if not condition_holds(condition, variables) then return false end
	end
	return true
end

--- Reports whether the last unfiltered `to` entry is a modifier key.
--- @param events table|nil The manipulator's `to`.
--- @return boolean modifier
local function last_is_modifier_key(events)
	local last = type(events) == "table" and events[#events] or nil
	return type(last) == "table" and MODIFIER_KEY_CODES[last.key_code] == true
end





-- ================================
-- ================================
-- ======= 2/ Output Engine =======
-- ================================
-- ================================

local Engine = {}
Engine.__index = Engine

--- Creates an engine over one rule graph.
--- @param rules table The profile's complex_modifications rules.
--- @param options table|nil { variables = {name → value}, flags = {flag, …} held from the start }.
--- @return table engine
function M.new(rules, options)
	options = options or {}
	local engine = setmetatable({
		rules     = rules,
		variables = {},
		counts    = {},
		sessions  = {},
		emitted   = {},
		now       = 0,
	}, Engine)
	for name, value in pairs(options.variables or {}) do engine.variables[name] = value end
	for _, flag in ipairs(options.flags or {}) do engine.counts[flag] = 1 end
	return engine
end

--- Returns the set of flags currently pressed in the output.
--- @return table pressed Flag name → true.
function Engine:pressed()
	local set = {}
	for _, flag in ipairs(M.FLAGS) do
		if (self.counts[flag] or 0) > 0 then set[flag] = true end
	end
	return set
end

--- Returns every event posted so far, in order.
--- @return table emitted { phase, event, key_code, flags } records.
function Engine:emissions()
	return self.emitted
end

--- Forgets the events posted so far.
function Engine:clear()
	self.emitted = {}
end

--- Returns one variable's current value; unset variables read 0.
--- @param name string Variable name.
--- @return any value
function Engine:variable(name)
	local value = self.variables[name]
	if value == nil then return 0 end
	return value
end

--- Returns the output keys held down until a physical key is released: the
--- last posted `to` entry of each active manipulation and every key no
--- manipulator took, which macOS auto-repeats while they stay down.
--- @return table held Key code → true.
function Engine:held()
	local set = {}
	for physical_key, session in pairs(self.sessions) do
		if session.passthrough then set[physical_key] = true end
		for _, key_code in ipairs(session.deferred or {}) do set[key_code] = true end
	end
	return set
end

--- Adds a signed amount to one flag's press count.
--- @param engine table Engine.
--- @param flag string Flag name.
--- @param delta integer Signed change.
local function change(engine, flag, delta)
	engine.counts[flag] = (engine.counts[flag] or 0) + delta
end

--- Records one posted event with the flags an application reads with it.
--- @param engine table Engine.
--- @param phase string "down", "tap" or "up".
--- @param event table Posted to-event.
local function record(engine, phase, event)
	engine.emitted[#engine.emitted + 1] = {
		phase    = phase,
		event    = event,
		key_code = event.key_code,
		flags    = engine:pressed(),
	}
end

--- Returns the flags a to-event's own `modifiers` press.
--- @param event table To-event.
--- @return table flags Flag names.
local function modifier_events(event)
	local flags = {}
	for _, modifier in ipairs(event.modifiers or {}) do
		local first = flags_of(modifier)[1]
		if first ~= nil then flags[#flags + 1] = first end
	end
	return flags
end

--- Drops the entries whose own conditions fail, as filter_and_replace_events does.
--- @param engine table Engine.
--- @param events table|nil To-event list.
--- @return table kept Entries that will be posted.
local function filtered(engine, events)
	local kept = {}
	for _, event in ipairs(events or {}) do
		if conditions_hold(event.conditions, engine.variables) then kept[#kept + 1] = event end
	end
	return kept
end

--- Posts one entry that is not a key: variables change, the rest is recorded.
--- @param engine table Engine.
--- @param phase string Phase label.
--- @param event table To-event.
local function post_other(engine, phase, event)
	local variable = event.set_variable
	if type(variable) == "table" and variable.value ~= nil then
		engine.variables[variable.name] = variable.value
	end
	record(engine, phase, event)
end

--- Models post_events_at_key_down: only the last posted entry stays held.
--- @param engine table Engine.
--- @param events table|nil The manipulator's `to`.
--- @param session table Active manipulation.
local function post_to(engine, events, session)
	local kept = filtered(engine, events)
	for index, event in ipairs(kept) do
		if event.key_code ~= nil then
			local modifiers = modifier_events(event)
			local modifier_key = MODIFIER_KEY_CODES[event.key_code] == true
				or event.key_code == "caps_lock"
			local last = index == #kept
			for _, flag in ipairs(modifiers) do change(engine, flag, 1) end
			if MODIFIER_KEY_CODES[event.key_code] then change(engine, event.key_code, 1) end
			record(engine, "down", event)
			if last and event["repeat"] ~= false then
				session.deferred[#session.deferred + 1] = event.key_code
			elseif MODIFIER_KEY_CODES[event.key_code] then
				change(engine, event.key_code, -1)
			end
			for _, flag in ipairs(modifiers) do
				if last and modifier_key then
					session.deferred_flags[#session.deferred_flags + 1] = flag
				else
					change(engine, flag, -1)
				end
			end
		else
			post_other(engine, "down", event)
		end
	end
end

--- Models post_extra_to_events: every key is pressed and released at once.
--- @param engine table Engine.
--- @param phase string "tap" or "up".
--- @param events table|nil To-event list.
local function post_extra(engine, phase, events)
	for _, event in ipairs(filtered(engine, events)) do
		if event.key_code ~= nil then
			local modifiers = modifier_events(event)
			for _, flag in ipairs(modifiers) do change(engine, flag, 1) end
			if MODIFIER_KEY_CODES[event.key_code] then change(engine, event.key_code, 1) end
			record(engine, phase, event)
			if MODIFIER_KEY_CODES[event.key_code] then change(engine, event.key_code, -1) end
			for _, flag in ipairs(modifiers) do change(engine, flag, -1) end
		else
			post_other(engine, phase, event)
		end
	end
end

--- Models post_from_mandatory_modifiers_key_up: lifts each claimed flag still pressed.
--- @param engine table Engine.
--- @param session table Active manipulation.
local function lift_claimed(engine, session)
	for _, flag in ipairs(M.FLAGS) do
		if session.claimed[flag] and not session.lifted[flag] and (engine.counts[flag] or 0) > 0 then
			change(engine, flag, -1)
			session.lifted[flag] = true
			if flag == "caps_lock" then record(engine, "lock", { key_code = flag }) end
		end
	end
end

--- Models post_from_mandatory_modifiers_key_down: presses the lifted flags again.
--- @param engine table Engine.
--- @param session table Active manipulation.
local function press_lifted(engine, session)
	for flag in pairs(session.lifted) do
		change(engine, flag, 1)
		if flag == "caps_lock" then record(engine, "lock", { key_code = flag }) end
	end
	session.lifted = {}
end

--- Posts an extra event with the flags captured at the original key-down.
--- @param engine table Engine.
--- @param session table Active manipulation.
--- @param phase string Emission phase.
--- @param events table|nil To-event list.
local function post_saved_extra(engine, session, phase, events)
	local restored = {}
	for _, flag in ipairs(M.FLAGS) do
		local count = engine.counts[flag] or 0
		if session.key_down_flags[flag] and count <= 0 then restored[flag] = 1 - count
		elseif not session.key_down_flags[flag] and count > 0 then restored[flag] = -count end
		if restored[flag] then change(engine, flag, restored[flag]) end
	end
	lift_claimed(engine, session)
	post_extra(engine, phase, events)
	press_lifted(engine, session)
	for flag, delta in pairs(restored) do change(engine, flag, -delta) end
end

--- Releases the output previously held by one manipulation.
--- @param engine table Engine.
--- @param session table Active manipulation.
local function release_held(engine, session)
	for _, key in ipairs(session.deferred) do
		if MODIFIER_KEY_CODES[key] then change(engine, key, -1) end
	end
	session.deferred = {}
	for _, flag in ipairs(session.deferred_flags) do change(engine, flag, -1) end
	session.deferred_flags = {}
end

-- Manipulators by physical key, in rule order, for each rule graph, so find()
-- scans only one key's candidates. Weak keys release an index with its graph.
local KEY_INDEX = setmetatable({}, { __mode = "k" })

--- Returns the per-key manipulator index of one rule graph.
--- @param rules table The profile's complex_modifications rules.
--- @return table index Key code → manipulators, in rule order.
local function key_index(rules)
	local index = KEY_INDEX[rules]
	if index ~= nil then return index end
	index = {}
	for _, rule in ipairs(rules) do
		for _, manipulator in ipairs(rule.manipulators or {}) do
			local from = manipulator.from or {}
			if from.key_code ~= nil and from.simultaneous == nil then
				local list = index[from.key_code] or {}
				list[#list + 1] = manipulator
				index[from.key_code] = list
			end
		end
	end
	KEY_INDEX[rules] = index
	return index
end

--- Finds the manipulator Karabiner runs for one key: the first, in rule order,
--- whose key, modifiers and conditions all match.
--- @param key_code string Physical key.
--- @return table|nil manipulator
--- @return table|nil claimed Flags it claims.
function Engine:find(key_code)
	local pressed = self:pressed()
	for _, manipulator in ipairs(key_index(self.rules)[key_code] or {}) do
		local claimed = M.test_modifiers(manipulator.from.modifiers, pressed)
		if claimed ~= nil and conditions_hold(manipulator.conditions, self.variables) then
			return manipulator, claimed
		end
	end
	return nil
end

--- Starts one manipulation: lifts the claimed flags and posts `to`.
--- @param engine table Engine.
--- @param manipulator table Matched manipulator.
--- @param claimed table Flags it claims.
--- @return table session
local function start_session(engine, manipulator, claimed)
	local session = {
		manipulator    = manipulator,
		claimed        = claimed,
		lifted         = {},
		deferred       = {},
		deferred_flags = {},
		key_down_flags = engine:pressed(),
		alone          = true,
		key_down_at    = engine.now,
	}
	lift_claimed(engine, session)
	post_to(engine, manipulator.to, session)
	if not last_is_modifier_key(manipulator.to) then press_lifted(engine, session) end
	local parameters = manipulator.parameters or {}
	if manipulator.to_if_held_down then
		session.held_due = engine.now + assert(parameters["basic.to_if_held_down_threshold_milliseconds"])
	end
	if manipulator.to_delayed_action then
		session.delayed_due = engine.now + assert(parameters["basic.to_delayed_action_delay_milliseconds"])
	end
	return session
end

--- Advances the pinned timer callbacks, preserving event order at their due time.
--- @param milliseconds number Finite non-negative elapsed time.
function Engine:advance(milliseconds)
	assert(type(milliseconds) == "number" and milliseconds >= 0 and milliseconds < math.huge)
	local target = self.now + milliseconds
	while true do
		local next_session, kind, due
		for _, session in pairs(self.sessions) do
			for _, candidate in ipairs({ "held_due", "delayed_due" }) do
				local time = session[candidate]
				if time and time <= target and (due == nil or time < due) then
					next_session, kind, due = session, candidate, time
				end
			end
		end
		if not next_session then break end
		self.now = due
		next_session[kind] = nil
		local manipulator = next_session.manipulator
		if kind == "held_due" then
			release_held(self, next_session)
			press_lifted(self, next_session)
			lift_claimed(self, next_session)
			post_to(self, manipulator.to_if_held_down, next_session)
			if not last_is_modifier_key(manipulator.to_if_held_down) then press_lifted(self, next_session) end
		else
			post_saved_extra(self, next_session, "timer", manipulator.to_delayed_action.to_if_invoked)
		end
	end
	self.now = target
end

--- Presses one physical key.
--- @param key_code string Physical key.
--- @return table|nil manipulator The manipulator that took it, nil when it passed through.
function Engine:down(key_code)
	assert(self.sessions[key_code] == nil, key_code .. " is already down")
	for _, session in pairs(self.sessions) do
		session.alone = false
		session.held_due = nil
		if session.delayed_due then
			session.delayed_due = nil
			post_saved_extra(self, session, "tap", session.manipulator.to_delayed_action.to_if_canceled)
		end
	end
	local manipulator, claimed = self:find(key_code)
	if manipulator == nil then
		if MODIFIER_KEY_CODES[key_code] then change(self, key_code, 1) end
		record(self, "down", { key_code = key_code })
		self.sessions[key_code] = { passthrough = true, alone = true }
		return nil
	end
	self.sessions[key_code] = start_session(self, manipulator, claimed)
	return manipulator
end

--- Presses a simultaneous chord, its keys in the given order within the
--- threshold. Every chord key then belongs to one manipulation, which each
--- key's release updates (see Engine:up).
--- @param keys table Physical keys, in press order.
--- @return table|nil manipulator The chord manipulator that took them.
function Engine:chord(keys)
	for _, key_code in ipairs(keys) do
		assert(self.sessions[key_code] == nil, key_code .. " is already down")
	end
	for _, session in pairs(self.sessions) do session.alone = false end
	local pressed = self:pressed()
	for _, rule in ipairs(self.rules) do
		for _, manipulator in ipairs(rule.manipulators or {}) do
			local from = manipulator.from or {}
			local simultaneous = from.simultaneous
			if type(simultaneous) == "table" and #simultaneous == #keys then
				local options = from.simultaneous_options or {}
				local order = options.key_down_order or "insensitive"
				assert(KEY_DOWN_ORDERS[order], "unmodelled Karabiner key_down_order '" .. tostring(order) .. "'")
				local matches = true
				for index, entry in ipairs(simultaneous) do
					if order == "strict" then
						matches = matches and entry.key_code == keys[index]
					elseif order == "strict_inverse" then
						matches = matches and entry.key_code == keys[#keys + 1 - index]
					else
						matches = matches and contains(keys, entry.key_code)
					end
				end
				local claimed = matches and M.test_modifiers(from.modifiers, pressed) or nil
				if claimed ~= nil and conditions_hold(manipulator.conditions, self.variables) then
					local session = start_session(self, manipulator, claimed)
					session.remaining = {}
					session.key_up_when = options.key_up_when or "any"
					session.to_after_all_up = options.to_after_key_up
					for _, key_code in ipairs(keys) do
						session.remaining[key_code] = true
						self.sessions[key_code] = session
					end
					return manipulator
				end
			end
		end
	end
	return nil
end

--- Posts the key_up half of one manipulation, once.
--- @param engine table Engine.
--- @param session table Active manipulation.
--- @param within_timeout boolean Released before the manipulator's to_if_alone timeout.
local function post_key_up(engine, session, within_timeout)
	local manipulator = session.manipulator
	release_held(engine, session)
	press_lifted(engine, session)

	if manipulator.to_if_alone ~= nil and session.alone and within_timeout then
		post_saved_extra(engine, session, "tap", manipulator.to_if_alone)
	end

	if manipulator.to_after_key_up ~= nil then
		lift_claimed(engine, session)
		post_extra(engine, "up", manipulator.to_after_key_up)
		press_lifted(engine, session)
	end
end

--- Releases one physical key. A chord key's release follows basic.hpp for
--- `simultaneous` manipulations: it is consumed; the first release posts the
--- key_up half (held `to` entries, to_if_alone, to_after_key_up) unless
--- key_up_when is "all" and a chord key is still down; the last release posts
--- simultaneous_options.to_after_key_up.
--- @param key_code string Physical key.
--- @param within_timeout boolean Released before the manipulator's to_if_alone timeout.
function Engine:up(key_code, within_timeout)
	local session = assert(self.sessions[key_code], key_code .. " is not down")
	self.sessions[key_code] = nil
	if session.manipulator and session.manipulator.to_if_held_down then
		local limit = session.manipulator.parameters["basic.to_if_alone_timeout_milliseconds"]
		within_timeout = within_timeout and self.now - session.key_down_at < limit
	end
	if session.passthrough then
		if MODIFIER_KEY_CODES[key_code] then change(self, key_code, -1) end
		return
	end

	local all_up = true
	if session.remaining ~= nil then
		session.remaining[key_code] = nil
		all_up = next(session.remaining) == nil
		if session.key_up_when == "all" and not all_up then return end
	end
	if not session.key_up_posted then
		session.key_up_posted = true
		post_key_up(self, session, within_timeout)
	end
	if all_up and session.to_after_all_up ~= nil then
		lift_claimed(self, session)
		post_extra(self, "up", session.to_after_all_up)
		press_lifted(self, session)
	end
end

--- Presses and quickly releases one key alone: a tap.
--- @param key_code string Physical key.
--- @return table|nil manipulator The manipulator that took it.
function Engine:tap(key_code)
	local manipulator = self:down(key_code)
	self:up(key_code, true)
	return manipulator
end

return M
