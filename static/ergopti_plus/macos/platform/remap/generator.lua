--- platform/remap/generator.lua

--- ==============================================================================
--- MODULE: Karabiner JSON Generator
--- DESCRIPTION:
--- Builds the full Karabiner-Elements complex_modifications JSON from
--- in-memory state: tap/hold rules, modifier combo rules, script-control
--- sentinel rules, and always-on static rule files. Also handles merging the
--- generated section into the existing karabiner.json (preserving all KE UI
--- settings) and deploying the result to the KE config directory.
---
--- FEATURES & RATIONALE:
--- 1. CapsWord Priority: platform/remap/data/capsword.json is loaded first so CapsWord
---    activation always takes precedence over any tap/hold or combo rule that shares
---    the same key — without this ordering, RCmd+CapsLock combos could steal the
---    event before CapsWord’s simultaneous matcher fires.
--- 2. Physical State Tracking: every tap/hold rule sets ke_held_<key_code>=1
---    on key_down and clears it on key_up, letting combo and sentinel rules
---    distinguish real physical presses from emulated tap outputs.
--- 3. Sticky-Equivalent Companions: when a key's tap/hold pair is
---    sticky_X/X, companion manipulators fire the base modifier immediately
---    whenever another modifier-class key is already held, so combined chords
---    like Cmd+(sticky-shift key) work without entering the sticky path.
--- 4. Mode-Gated Merge: every manipulator carries one generation mode and one
---    irreversible revocation condition; regeneration replaces only exact
---    managed rule tags while preserving personal rules, parameters, profiles,
---    devices, mappings, virtual HID settings, and global Karabiner preferences.
--- ==============================================================================

local M = {}

local hs         = hs
local Logger     = require("infra.logger")
local Keycodes   = require("infra.keycodes")
local FileSystem = require("adapters.file_system")
local LeaseContract = require("platform.remap.lease_contract")
local LegacyReleaseFixtures = require("platform.remap.legacy_release_fixtures")
local ActionCatalogue = require("platform.remap.action_catalogue")

local LOG = "karabiner"

local MANAGED_TAG_LABEL      = "ErgoptiPlus managed"
local MANAGED_MODE_NORMAL    = "normal"
local MANAGED_MODE_PAUSE     = "pause"

local LEGACY_PARAMETER_TAP = "basic.to_if_alone_timeout_milliseconds"
local LEGACY_PARAMETER_SIMULTANEOUS = "basic.simultaneous_threshold_milliseconds"

-- Always-on rule files loaded in order after CapsWord (which is loaded first
-- separately to guarantee the highest priority in the KE rule engine).
local ALWAYS_ON_RULES = {
	"layer_keys.json",  -- Navigation mappings (letter→arrow, number→F-key…)
	"combos.json",      -- 2-letter combo mappings (e.g. Esc on R Cmd + R Ctrl)
}

-- Maps a sticky variant id to its plain base-modifier action id.
-- When a key's tap slot is sticky_X and hold slot is X (or vice-versa) the key
-- is "fully remapped to X" — companion manipulators emit the base modifier
-- immediately whenever another modifier-class key is physically held.
local STICKY_TO_BASE_ACTION = {
	sticky_shift             = "shift",
	sticky_ctrl              = "ctrl",
	sticky_cmd               = "cmd",
	sticky_option            = "alt",
	sticky_cmd_shift         = "cmd_shift",
	sticky_cmd_option        = "cmd_option",
	sticky_cmd_ctrl          = "cmd_ctrl",
	sticky_option_shift      = "option_shift",
	sticky_option_ctrl       = "option_ctrl",
	sticky_ctrl_shift        = "ctrl_shift",
	sticky_cmd_option_shift  = "cmd_option_shift",
	sticky_cmd_option_ctrl   = "cmd_option_ctrl",
	sticky_cmd_shift_ctrl    = "cmd_shift_ctrl",
	sticky_option_shift_ctrl = "option_shift_ctrl",
	sticky_hyper             = "hyper",
}

-- Physical keys considered as "modifier carriers" for companion-manipulator
-- matching. When any of these is held (tracked via ke_held_<key_code>=1) and
-- the user presses a sticky-equivalent key, the base modifier fires immediately.
local MODIFIER_CLASS_KEY_CODES = {
	"left_command", "right_command",
	"left_control",
	"left_option",
	"left_shift", "right_shift",
	"fn",
	"caps_lock",
}

-- Actual modifier key_codes as a lookup set (fn and caps_lock excluded — they
-- are not held modifiers in KE's from-field sense).
local ACTUAL_MODIFIER_KEY_CODES = {
	left_option  = true, right_option  = true,
	left_command = true, right_command = true,
	left_control = true, right_control = true,
	left_shift   = true, right_shift   = true,
}

-- Physical key and sentinel outputs for the script-control rules.
-- These values must match the F13/F14/F15 sentinel constants consumed by
-- modules/shortcuts/script_control.lua.
local SCRIPT_CONTROL_HOLDER_KEY     = "right_command"
-- Synthetic modifier KE stamps onto every emitted F13/F14/F15 sentinel. HS reads
-- it off the EVENT itself (modules/shortcuts/script_control.lua) to confirm a
-- genuine sentinel without depending on the live keyboard modifier state — which
-- is unreliable: the paused rules gate on a MANDATORY modifier that KE consumes,
-- so by the time HS polls, nothing is held (the second AltGr+Enter could not
-- un-pause). A bare physical F13/F14/F15 press carries no such flag, so this stays
-- a valid genuine-vs-stray discriminator.
-- Two-modifier tag (left_control + left_shift) instead of lone left_control so that
-- a physical Ctrl+F15 (flags.ctrl only, no shift) cannot misfire as a genuine
-- sentinel — that was the M-6 / F-CRIT-1-residual misfire. left_control alone is
-- indistinguishable from a real Ctrl+F15 keypress; requiring BOTH modifiers makes
-- the tag pair unforgeable by any ordinary keyboard interaction.
local SCRIPT_CONTROL_SENTINEL_TAGS  = { "left_control", "left_shift" }
local SCRIPT_CONTROL_SENTINEL_SLOTS = {
	{ from_key = "delete_or_backspace", sentinel = Keycodes.to_name(Keycodes.F14_KARABINER_BACKSPACE), slot_label = "backspace" },
	{ from_key = "return_or_enter",     sentinel = Keycodes.to_name(Keycodes.F13_KARABINER_RETURN),    slot_label = "return"    },
	{ from_key = "escape",              sentinel = Keycodes.to_name(Keycodes.F15_KARABINER_ESCAPE),    slot_label = "escape"    },
}

-- Karabiner variable name and value that signal the navigation layer is being
-- activated. Any action whose karabiner_to sets this variable must first emit
-- the F20 sentinel so Hammerspoon can distinguish "user is entering the nav
-- layer" from "user pressed a real key that should dismiss the tooltip".
local LAYER_ACTIVE_VAR_NAME    = "layer_active"
local LAYER_ACTIVE_ON_VALUE    = 1
local LAYER_NAV_SENTINEL_NAME  = Keycodes.to_name(Keycodes.F20_LAYER_NAV_ENTERED)

-- Append-only log file consumed by modules/keylogger/kc_bridge.lua.
-- Each line written by the shell_command is: "<physical_key_code_name>\n"
-- so Hammerspoon can map the name back to a numeric kc and record true
-- physical key frequency — bypassing the Karabiner remap layer.
-- Lives under <config_dir>/metrics/ so the user can relocate everything by
-- pointing ConfigDirPath elsewhere; bridge reader resolves the same path.
local KE_PHYSICAL_KC_LOG
do
	local mp = require("infra.config_paths")
	local d  = mp.get_config_dir()
	if not d:match("[/\\]$") then d = d .. "/" end
	KE_PHYSICAL_KC_LOG = d .. "metrics/karabiner_kc.log"
	-- Parent dir created lazily by deploy_json_file() or when keylogger starts;
	-- no mkdir here to avoid creating metrics/ when the feature is off
end





-- ========================================
-- ========================================
-- ======= 1/ Helpers and Constants =======
-- ========================================
-- ========================================

--- Loads and parses a JSON file. Logs an error and returns nil on any failure.
--- @param path string Absolute path to the JSON file.
--- @return table|nil Decoded table, or nil.
local function load_json_file(path)
	local raw = FileSystem.read(path)
	if not raw then
		Logger.error(LOG, "Cannot open file '%s'.", path)
		return nil
	end
	local ok, data = pcall(hs.json.decode, raw)
	if not ok or type(data) ~= "table" then
		Logger.error(LOG, "Cannot decode JSON from '%s': %s.", path, tostring(data))
		return nil
	end
	return data
end

--- Verifies that a table is a dense one-based JSON array.
--- Empty arrays and objects are indistinguishable after JSON decoding and are
--- accepted; any named key or numeric hole is rejected before an ipairs merge
--- could silently discard user data.
--- @param value any Candidate array.
--- @return boolean dense Whether all keys form the range 1..n.
local function is_dense_array(value)
	if type(value) ~= "table" then return false end
	local count = 0
	local maximum = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
		count = count + 1
		if key > maximum then maximum = key end
	end
	return maximum == count
end

--- Builds the exact Karabiner variable name for one generation's atomic mode.
--- @param token string Canonical 32-character lowercase hexadecimal token.
--- @return string|nil variable_name Generation-scoped variable name.
--- @return string|nil error_message Validation failure.
function M.mode_variable_name(token)
	return LeaseContract.mode_variable_name(token)
end

--- Builds the exact irreversible fence variable for one generation.
--- @param token string Canonical 32-character lowercase hexadecimal token.
--- @return string|nil variable_name Generation-scoped tombstone name.
--- @return string|nil error_message Validation failure.
function M.revoked_variable_name(token)
	return LeaseContract.revoked_variable_name(token)
end

--- Builds the exact rule-description prefix owned by ErgoptiPlus.
--- @param token string Canonical generation token.
--- @param mode string Managed mode (`normal` or `pause`).
--- @return string prefix Exact prefix including its trailing space.
local function managed_description_prefix(token, mode)
	return string.format("[%s:%s:%s] ", MANAGED_TAG_LABEL, token, mode)
end

--- Parses only canonical ErgoptiPlus ownership markers.
--- Lua patterns have no alternation or fixed-count quantifier, so the broad
--- capture is followed by explicit length, mode, and prefix checks.
--- @param description any Rule description candidate.
--- @return string|nil token Canonical token when the prefix is exact.
--- @return string|nil mode Canonical managed mode when the prefix is exact.
local function parse_managed_description(description)
	if type(description) ~= "string" then return nil end
	local token, mode = description:match(
		"^%[ErgoptiPlus managed:([0-9a-f]+):([a-z]+)%] "
	)
	if not LeaseContract.is_valid_token(token) then return nil end
	if mode ~= MANAGED_MODE_NORMAL and mode ~= MANAGED_MODE_PAUSE then return nil end
	local expected = managed_description_prefix(token, mode)
	if description:sub(1, #expected) ~= expected then return nil end
	return token, mode
end

local VARIABLE_CONDITION_TYPES = {
	variable_if = true,
	variable_unless = true,
}

--- Visits every Karabiner runtime-variable producer and consumer in a rule graph.
--- Nested delayed actions are included; unrelated `name` fields are ignored.
--- Shared action tables are visited once and cyclic input cannot recurse forever.
--- @param value any Rule graph node.
--- @param visitor function Callback fn(holder, name, path) -> boolean, error.
--- @param path string|nil Diagnostic path.
--- @param seen table|nil Already-visited table identities.
--- @return boolean valid Whether every visited reference was accepted.
--- @return string|nil error_message Visitor rejection.
local function walk_runtime_variable_references(value, visitor, path, seen)
	if type(value) ~= "table" then return true end
	seen = seen or {}
	if seen[value] then return true end
	seen[value] = true
	path = path or "rules"

	if type(value.set_variable) == "table" and type(value.set_variable.name) == "string" then
		local ok, err = visitor(value.set_variable, value.set_variable.name, path .. ".set_variable")
		if ok == false then return false, err end
	end
	if VARIABLE_CONDITION_TYPES[value.type] and type(value.name) == "string" then
		local ok, err = visitor(value, value.name, path .. ".condition")
		if ok == false then return false, err end
	end

	for key, nested in pairs(value) do
		if type(nested) == "table" then
			local ok, err = walk_runtime_variable_references(
				nested,
				visitor,
				path .. "." .. tostring(key),
				seen
			)
			if not ok then return false, err end
		end
	end
	return true
end

--- Rewrites every driver-owned bare runtime name to one exact generation.
--- Stock Karabiner variables are deliberately left untouched.
--- @param rules table Validated raw managed rule graph.
--- @param token string Canonical generation token.
--- @return boolean scoped Whether every owned reference was scoped.
--- @return string|nil error_message Validation failure.
local function scope_runtime_variable_references(rules, token)
	return walk_runtime_variable_references(rules, function(holder, name, path)
		if LeaseContract.is_managed_variable_name(name) then
			return false, string.format(
				"%s already claims reserved generation variable '%s'",
				path,
				name
			)
		end
		if not LeaseContract.is_runtime_logical_name(name) then return true end
		local scoped_name, scope_err = LeaseContract.runtime_variable_name(name, token)
		if not scoped_name then return false, path .. ": " .. tostring(scope_err) end
		holder.name = scoped_name
		return true
	end)
end

--- Proves that no bare or foreign Ergopti runtime reference can be deployed.
--- @param rule table One centrally gated managed rule.
--- @param token string Token declared by the rule tag.
--- @return boolean valid Whether every runtime reference uses the exact token.
--- @return string|nil error_message Validation failure.
local function validate_scoped_runtime_references(rule, token)
	return walk_runtime_variable_references(rule, function(_holder, name, path)
		if LeaseContract.is_runtime_logical_name(name) then
			return false, string.format("%s retains bare Ergopti runtime variable '%s'", path, name)
		end
		if not LeaseContract.is_runtime_variable_namespace_name(name) then return true end
		local _logical_name, runtime_token = LeaseContract.parse_runtime_variable_name(name)
		if runtime_token ~= token then
			return false, string.format(
				"%s contains foreign or malformed Ergopti runtime variable '%s'",
				path,
				name
			)
		end
		return true
	end)
end

--- Adds one exact atomic mode and tombstone condition to every manipulator.
--- Validation completes before mutation so malformed generated data cannot
--- leave a partially gated configuration in the caller's table.
--- @param rules table Rules generated for one pause mode.
--- @param token string Canonical generation token.
--- @param mode string Managed mode (`normal` or `pause`).
--- @return table|nil rules The same list after central gating.
--- @return string|nil error_message Validation failure.
local function gate_managed_rules(rules, token, mode)
	if not LeaseContract.is_valid_token(token) then
		return nil, LeaseContract.invalid_token_error(token)
	end
	if mode ~= MANAGED_MODE_NORMAL and mode ~= MANAGED_MODE_PAUSE then
		return nil, "managed rule mode must be 'normal' or 'pause'"
	end
	if not is_dense_array(rules) then return nil, "managed rules must be a dense array" end

	for rule_index, rule in ipairs(rules) do
		if type(rule) ~= "table" then
			return nil, string.format("managed rule %d must be a table", rule_index)
		end
		if type(rule.description) ~= "string" or rule.description == "" then
			return nil, string.format("managed rule %d must have a non-empty description", rule_index)
		end
		if not is_dense_array(rule.manipulators) or #rule.manipulators == 0 then
			return nil, string.format("managed rule %d must contain manipulators", rule_index)
		end
		for manipulator_index, manipulator in ipairs(rule.manipulators) do
			if type(manipulator) ~= "table" then
				return nil, string.format(
					"managed rule %d manipulator %d must be a table",
					rule_index,
					manipulator_index
				)
			end
			if manipulator.conditions ~= nil and not is_dense_array(manipulator.conditions) then
				return nil, string.format(
					"managed rule %d manipulator %d conditions must be a table",
					rule_index,
					manipulator_index
				)
			end
			for condition_index, condition in ipairs(manipulator.conditions or {}) do
				if type(condition) ~= "table" then
					return nil, string.format(
						"managed rule %d manipulator %d condition %d must be a table",
						rule_index,
						manipulator_index,
						condition_index
					)
				end
				if LeaseContract.is_managed_variable_name(condition.name) then
					return nil, string.format(
						"managed rule %d manipulator %d already uses a reserved generation variable",
						rule_index,
						manipulator_index
					)
				end
			end
		end
	end
	local scoped, scope_err = scope_runtime_variable_references(rules, token)
	if not scoped then return nil, scope_err end

	local variables = LeaseContract.variables(token)
	local mode_name = variables.mode
	local revoked_name = variables.revoked
	local mode_value = mode == MANAGED_MODE_PAUSE
		and LeaseContract.MODE_PAUSED or LeaseContract.MODE_ACTIVE
	local prefix = managed_description_prefix(token, mode)
	for _, rule in ipairs(rules) do
		rule.description = prefix .. rule.description
		for _, manipulator in ipairs(rule.manipulators) do
			if manipulator.conditions == nil then manipulator.conditions = {} end
			manipulator.conditions[#manipulator.conditions + 1] = {
				type = "variable_if",
				name = mode_name,
				value = mode_value,
			}
			manipulator.conditions[#manipulator.conditions + 1] = {
				type = "variable_if",
				name = revoked_name,
				value = 0,
			}
		end
	end
	return rules
end

--- Returns whether a value can be emitted into an integer-typed Karabiner field.
--- @param value any Candidate value.
--- @return boolean valid Whether the value is an integer.
local function is_integer(value)
	return type(value) == "number" and value % 1 == 0
end

--- Returns whether a value is a strictly positive integer.
--- @param value any Candidate value.
--- @return boolean valid Whether the value is a strictly positive integer.
local function is_positive_integer(value)
	return is_integer(value) and value > 0
end

--- Applies ErgoptiPlus timing values at manipulator scope.
--- Existing profile-level parameters belong to the user and may affect personal
--- rules, so managed tap/hold and simultaneous rules carry their own values.
--- A per-key tap timeout already present on a manipulator remains authoritative.
--- @param rules table Ungated ErgoptiPlus rules.
--- @param tap_hold_timeout_ms number Default tap/hold timeout.
--- @param simultaneous_threshold_ms number Simultaneous chord threshold.
--- @return table|nil rules The same list after timing injection.
--- @return string|nil error_message Validation failure.
local function apply_managed_timing_parameters(
	rules,
	tap_hold_timeout_ms,
	simultaneous_threshold_ms
)
	if not is_positive_integer(tap_hold_timeout_ms) then
		return nil, "tap/hold timeout must be a positive integer"
	end
	if not is_positive_integer(simultaneous_threshold_ms) then
		return nil, "simultaneous threshold must be a positive integer"
	end

	for rule_index, rule in ipairs(rules) do
		if type(rule) ~= "table" or not is_dense_array(rule.manipulators) then
			return nil, string.format("managed rule %d has invalid manipulators", rule_index)
		end
		for manipulator_index, manipulator in ipairs(rule.manipulators) do
			if type(manipulator) ~= "table" then
				return nil, string.format(
					"managed rule %d manipulator %d must be a table",
					rule_index,
					manipulator_index
				)
			end
			local has_tap = type(manipulator.to_if_alone) == "table"
			local has_simultaneous = type(manipulator.from) == "table"
				and type(manipulator.from.simultaneous) == "table"
			if has_tap or has_simultaneous then
				if manipulator.parameters ~= nil and type(manipulator.parameters) ~= "table" then
					return nil, string.format(
						"managed rule %d manipulator %d parameters must be a table",
						rule_index,
						manipulator_index
					)
				end
				if manipulator.parameters == nil then manipulator.parameters = {} end
				if has_tap then
					local tap_timeout = manipulator.parameters["basic.to_if_alone_timeout_milliseconds"]
					if tap_timeout == nil then
						manipulator.parameters["basic.to_if_alone_timeout_milliseconds"] = tap_hold_timeout_ms
					elseif not is_positive_integer(tap_timeout) then
						return nil, string.format(
							"managed rule %d manipulator %d tap/hold timeout must be a positive integer",
							rule_index,
							manipulator_index
						)
					end
				end
				if has_simultaneous then
					manipulator.parameters["basic.simultaneous_threshold_milliseconds"] = simultaneous_threshold_ms
				end
			end
		end
	end
	return rules
end

--- Returns true when an event sets layer_active to its "on" value.
--- @param ev table A karabiner_to event entry.
--- @return boolean
local function is_layer_activation_event(ev)
	if type(ev) ~= "table" or type(ev.set_variable) ~= "table" then return false end
	return ev.set_variable.name  == LAYER_ACTIVE_VAR_NAME
	   and ev.set_variable.value == LAYER_ACTIVE_ON_VALUE
end

--- Returns true when a karabiner_to array activates the navigation layer.
--- @param to_events table List of karabiner_to events.
--- @return boolean
local function activates_nav_layer(to_events)
	if type(to_events) ~= "table" then return false end
	for _, ev in ipairs(to_events) do
		if is_layer_activation_event(ev) then return true end
	end
	return false
end

--- Mutates the available_actions list so every action that activates the
--- navigation layer (set_variable layer_active=1) emits the F20 sentinel as its
--- very first karabiner_to event. This guarantees that no matter which physical
--- key the user binds to such an action (cmd, space-hold, tab-hold, caps_lock,
--- etc.), Hammerspoon receives F20 before any layer key is consumed.
---
--- Idempotent: re-runs are safe because we skip actions whose first event is
--- already the F20 sentinel.
--- @param available_actions table List of action definitions (mutated in place).
local function prepend_nav_layer_sentinel(available_actions)
	local patched = 0
	for _, action in ipairs(available_actions) do
		local to_events = action.karabiner_to
		if type(to_events) == "table" and activates_nav_layer(to_events) then
			local first = to_events[1]
			local already_has_sentinel =
				type(first) == "table"
				and first.key_code == LAYER_NAV_SENTINEL_NAME
			if not already_has_sentinel then
				table.insert(to_events, 1, { key_code = LAYER_NAV_SENTINEL_NAME })
				patched = patched + 1
				Logger.debug(LOG, "Action '%s': prepended F20 sentinel to nav-layer activation.",
					tostring(action.id))
			end
		end
	end
	if patched > 0 then
		Logger.info(LOG, "Prepended F20 sentinel to %d nav-layer-activating action(s).", patched)
	end
end

--- Recursively copies a JSON-compatible value without retaining table aliases.
--- Legacy graph hints must remain in their historical pre-lease form while
--- timing and generation gates mutate the deployed rule graph in place.
--- @param value any Value to copy.
--- @return any copy Structurally independent copy.
local function deep_copy(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, nested in pairs(value) do
		copy[deep_copy(key)] = deep_copy(nested)
	end
	return copy
end

--- Copies only catalogue actions whose runtime-variable references will be
--- rewritten or whose navigation output receives the F20 sentinel. All other
--- immutable catalogue rows stay shared, avoiding a full 673-action copy while
--- guaranteeing that regeneration never tokenizes the caller's cached source.
--- @param available_actions table Canonical cached action catalogue.
--- @return table prepared Per-build action list with mutable rows detached.
local function detach_runtime_variable_actions(available_actions)
	local prepared = {}
	for index, action in ipairs(available_actions or {}) do
		local requires_copy = false
		walk_runtime_variable_references(action, function(_holder, name)
			if LeaseContract.is_runtime_logical_name(name)
				or LeaseContract.is_managed_variable_name(name) then
				requires_copy = true
			end
			return true
		end, "available_actions[" .. tostring(index) .. "]")
		prepared[index] = requires_copy and deep_copy(action) or action
	end
	return prepared
end

--- Recursively compares two values for structural equality.
--- Lua table iteration order is non-deterministic, so hs.json.encode(a) ==
--- hs.json.encode(b) can produce false negatives when two logically identical
--- tables happen to iterate in different key orders (karabiner-generator-json-dedup).
--- @param a any First value.
--- @param b any Second value.
--- @return boolean
local function deep_equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do
		if not deep_equal(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

--- Returns true when two karabiner_to arrays are structurally identical.
--- Used to detect tap == hold (in which case to_if_alone is omitted).
--- @param a table First karabiner_to array.
--- @param b table Second karabiner_to array.
--- @return boolean
local function same_output(a, b)
	return deep_equal(a, b)
end

--- Returns the name of the "physically held" Karabiner variable for a given key.
--- Every tap/hold rule sets this variable to 1 on key_down and clears it on
--- key_up, so downstream rules can condition on the PHYSICAL state of a key —
--- bypassing the tap/hold transform that would otherwise replace it.
--- @param key_code string Karabiner key_code (e.g. "right_command").
--- @return string Variable name used in set_variable / variable_if.
local function held_var_name(key_code)
	return "ke_held_" .. key_code
end

--- Returns a set_variable event object.
--- @param name string Variable name.
--- @param value number Value to set (typically 0 or 1).
--- @return table Karabiner event with set_variable.
local function set_var_event(name, value)
	return { set_variable = { name = name, value = value } }
end

--- Detects a sticky-equivalent tap/hold pair and returns the base action id.
--- Pairs considered equivalent:
---   • STICKY_TO_BASE_ACTION[tap] == hold  (sticky tap, base hold)
---   • STICKY_TO_BASE_ACTION[hold] == tap  (base tap, sticky hold)
--- @param tap_id string Tap slot action id.
--- @param hold_id string Hold slot action id.
--- @return string|nil Base modifier action id or nil if the pair is not equivalent.
local function detect_sticky_base(tap_id, hold_id)
	if STICKY_TO_BASE_ACTION[tap_id]  == hold_id then return hold_id end
	if STICKY_TO_BASE_ACTION[hold_id] == tap_id  then return tap_id  end
	return nil
end





-- ========================================
-- ========================================
-- ======= 2/ Tap/Hold Rule Builder =======
-- ========================================
-- ========================================



-- ==============================================
-- ===== 2.1) Sticky Companion Manipulators =====
-- ==============================================

--- Builds the companion manipulators for a "fully remapped" sticky-equivalent key.
--- One manipulator per modifier-class tracked variable (except the key itself).
--- Each matches when its variable is 1 and fires `to = [set_var_self=1, base_to…]`
--- immediately (no to_if_alone), so the combined modifier chord appears the
--- instant the second key is pressed.
--- @param key_def table Entry from TAP_HOLD_KEYS.
--- @param base_to table karabiner_to events for the base modifier action.
--- @param var_name string Tracking variable name for the key itself.
--- @return table List of manipulators (may be empty if key is the only modifier-class key).
local function build_sticky_companion_manipulators(key_def, base_to, var_name)
	local manipulators = {}
	local self_key     = key_def.from.key_code

	for _, mod_key in ipairs(MODIFIER_CLASS_KEY_CODES) do
		if mod_key ~= self_key then
			local to_events = { set_var_event(var_name, 1) }
			for _, ev in ipairs(base_to) do to_events[#to_events + 1] = ev end

			manipulators[#manipulators + 1] = {
				type        = "basic",
				from        = key_def.from,
				conditions  = {
					{ type = "variable_if", name = held_var_name(mod_key), value = 1 },
				},
				to              = to_events,
				to_after_key_up = { set_var_event(var_name, 0) },
			}
		end
	end

	return manipulators
end



-- ===================================
-- ===== 2.2) Main Tap/Hold Rule =====
-- ===================================

--- Builds a Karabiner rule table for a single tap / hold key.
---
--- The manipulator ALWAYS tracks physical state via ke_held_<key_code>:
---   • set to 1 on key_down (prepended to to)
---   • cleared to 0 on key_up (prepended to to_after_key_up)
---
--- When both slots are "none", a minimal rule is still emitted that tracks the
--- variable and re-emits the original key — keys used purely as combo triggers
--- still get physical-press tracking without any user-visible behaviour change.
---
--- When tap/hold is sticky-equivalent (sticky_X paired with X), companion
--- manipulators are inserted BEFORE the main manipulator so that pressing the
--- key while another modifier is held emits the base modifier immediately.
--- @param key_def table Entry from TAP_HOLD_KEYS.
--- @param tap_action table Resolved action definition for the tap slot.
--- @param hold_action table Resolved action definition for the hold slot.
--- @param action_index table id → action map (required for sticky-equivalent companion rules).
--- @param tap_timeout_ms number|nil Per-key tap/hold threshold override in ms; nil inherits the global.
--- @return table Karabiner rule object.
local function build_tap_hold_rule(key_def, tap_action, hold_action, action_index, tap_timeout_ms)
	local tap_to   = tap_action.karabiner_to  or {}
	local hold_to  = hold_action.karabiner_to or {}
	local key_code = key_def.from.key_code
	local var_name = held_var_name(key_code)

	local manipulator = { type = "basic", from = key_def.from }

	-- Variable tracking always runs first on key_down / key_up
	local to_events         = { set_var_event(var_name, 1) }
	local after_key_up_tail = { set_var_event(var_name, 0) }

	if #tap_to == 0 and #hold_to == 0 then
		-- Both slots "none" — still track the variable, re-emit the original key
		-- so the physical press is not consumed. No shell_command needed: HS will
		-- see the original keycode directly and log it through the normal path.
		to_events[#to_events + 1] = { key_code = key_code }
		manipulator.to              = to_events
		manipulator.to_after_key_up = after_key_up_tail

		return {
			description  = string.format("%s: passthrough (variable tracked)", key_def.label),
			manipulators = { manipulator },
		}
	end

	-- POSIX-safe quoting helper: wraps a string in single quotes and escapes any
	-- embedded single quotes so neither key_code nor the log path can be used
	-- for shell injection (e.g. a config dir containing an apostrophe).
	local function sq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

	-- Append the physical key_code name to the bridge log on every key_down so
	-- Hammerspoon can credit the correct physical key in the heatmap instead of
	-- the remapped output key that the event tap would otherwise observe.
	to_events[#to_events + 1] = {
		shell_command = string.format(
			"echo %s >> %s",
			sq(key_code),
			sq(KE_PHYSICAL_KC_LOG)
		),
	}

	-- Append a release marker on key_up so the bridge can compute the hold
	-- duration and split kc_hold counts into tap (≤ HOLD_THRESHOLD_MS) and
	-- hold (> threshold). Format: "U:<key_code>" — the "U:" prefix is the
	-- bridge's discriminator; bare "<key_code>" lines remain press events.
	after_key_up_tail[#after_key_up_tail + 1] = {
		shell_command = string.format(
			"echo %s >> %s",
			sq("U:" .. tostring(key_code)),
			sq(KE_PHYSICAL_KC_LOG)
		),
	}

	-- When one slot is "none", fall through to the original key for that slot
	local passthrough       = { { key_code = key_code } }
	local effective_tap_to  = (#tap_to  > 0) and tap_to  or passthrough
	local effective_hold_to = (#hold_to > 0) and hold_to or passthrough

	for _, ev in ipairs(effective_hold_to) do to_events[#to_events + 1] = ev end
	manipulator.to = to_events

	-- to_if_alone only when tap output differs from hold output
	if not same_output(effective_tap_to, effective_hold_to) then
		manipulator.to_if_alone = effective_tap_to
	end

	-- Per-key tap/hold threshold override. Karabiner honours
	-- basic.to_if_alone_timeout_milliseconds at the manipulator level, overriding
	-- the complex_modifications global. nil/0 inherits the single global value, so
	-- there is no duplicated per-key literal when the user has not customised it.
	if tap_timeout_ms and tap_timeout_ms > 0 then
		manipulator.parameters = { ["basic.to_if_alone_timeout_milliseconds"] = tap_timeout_ms }
	end

	-- Merge hold action's own to_after_key_up (e.g. layer release) with set_variable=0
	if hold_action.karabiner_to_after_key_up then
		for _, ev in ipairs(hold_action.karabiner_to_after_key_up) do
			after_key_up_tail[#after_key_up_tail + 1] = ev
		end
	end
	manipulator.to_after_key_up = after_key_up_tail

	-- Sticky-equivalent detection (sticky_X paired with X). When present, inject
	-- companion manipulators that fire the base modifier immediately as soon as
	-- another modifier-class key is held physically. KE picks the first matching
	-- manipulator, so companions MUST come before the main manipulator.
	local manipulators = { manipulator }
	local base_id      = detect_sticky_base(tap_action.id, hold_action.id)
	if base_id and action_index then
		local base_action = action_index[base_id]
		local base_to     = base_action and base_action.karabiner_to or nil
		if base_to and #base_to > 0 then
			local companions = build_sticky_companion_manipulators(key_def, base_to, var_name)
			if #companions > 0 then
				-- Prepend companions so they take priority over the main manipulator
				local combined = {}
				for _, m in ipairs(companions)   do combined[#combined + 1] = m end
				for _, m in ipairs(manipulators) do combined[#combined + 1] = m end
				manipulators = combined
				Logger.debug(LOG, "Tap/hold '%s' sticky-equivalent to '%s' — %d companion(s) added.",
					key_def.id, base_id, #companions)
			end
		end
	end

	return {
		description  = string.format(
			"%s: %s (tap) / %s (hold)",
			key_def.label, tap_action.label, hold_action.label
		),
		manipulators = manipulators,
	}
end





-- ==============================================
-- ==============================================
-- ======= 3/ Modifier Combo Rule Builder =======
-- ==============================================
-- ==============================================



-- ===================================
-- ===== 3.1) Tap/Hold Slot Rule =====
-- ===================================

--- Builds the variable-based rule for the tap / hold slots of a combo.
--- Matches k2 physically while k1 is held (via ke_held_k1=1) and splits
--- output by press duration (to_if_alone for tap, to for hold).
---
--- When only the tap slot is set, fires immediately on key_down (not via
--- to_if_alone) — this enables auto-repeat and avoids a KE edge case where
--- to_if_alone does not reliably fire when another modifier is already held.
---
--- Tap/hold slots are per-direction: symmetry is NOT auto-mirrored here because
--- tap/hold behaviour is legitimately asymmetric (rcmd-first vs. lcmd-first).
--- @param combo_def table Entry from MOD_COMBOS.
--- @param tap_to table Tap output events (may be empty).
--- @param hold_to table Hold output events (may be empty).
--- @param tap_action table Tap action definition.
--- @param hold_action table Hold action definition.
--- @param k1 string First key (holder).
--- @param k2 string Second key (trigger).
--- @param k1_mandatory table|nil Modifier key_codes held by k1's hold action.
--- @return table|nil Karabiner rule object, or nil when both slots are empty.
local function build_tap_hold_combo_rule(combo_def, tap_to, hold_to, tap_action, hold_action, k1, k2, k1_mandatory)
	if #tap_to == 0 and #hold_to == 0 then return nil end

	-- When k1's hold action holds a modifier (e.g. right_command → right_option),
	-- that modifier is active when this rule fires. Listing it as mandatory consumes
	-- it so it does NOT pass through to the output events.
	local from_modifiers
	if k1_mandatory and #k1_mandatory > 0 then
		from_modifiers = { mandatory = k1_mandatory, optional = { "any" } }
	else
		from_modifiers = { optional = { "any" } }
	end

	local conditions = {
		{ type = "variable_if", name = held_var_name(k1), value = 1 },
	}
	-- Merge action-level extra conditions (e.g. capsword=0 guard on the capsword action)
	local extra = tap_action.karabiner_rule_conditions
	if type(extra) == "table" then
		for _, cond in ipairs(extra) do
			conditions[#conditions + 1] = cond
		end
	end

	local manip = {
		type = "basic",
		from = { key_code = k2, modifiers = from_modifiers },
		conditions = conditions,
	}

	if #hold_to > 0 and #tap_to > 0 and not same_output(tap_to, hold_to) then
		-- Both distinct: split by press duration via tap_hold timeout
		manip.to          = hold_to
		manip.to_if_alone = tap_to
		if hold_action.karabiner_to_after_key_up then
			manip.to_after_key_up = hold_action.karabiner_to_after_key_up
		end
	elseif #hold_to > 0 then
		-- Hold only (or tap == hold): immediate fire on key_down
		manip.to = hold_to
		if hold_action.karabiner_to_after_key_up then
			manip.to_after_key_up = hold_action.karabiner_to_after_key_up
		end
	else
		-- Tap only: fire immediately on key_down for reliable auto-repeat
		manip.to = tap_to
	end

	return {
		description  = string.format(
			"%s (%s→%s): %s (tap) / %s (hold) [var-based]",
			combo_def.label, k1, k2, tap_action.label, hold_action.label
		),
		manipulators = { manip },
	}
end



-- ================================
-- ===== 3.2) Chord Slot Rule =====
-- ================================

--- Builds the chord rule for the combo slot of a modifier combo.
--- Uses KE's simultaneous matcher with the global
--- basic.simultaneous_threshold_milliseconds window. key_down_order: strict
--- requires k1 before k2 unless symmetric mode is on, in which case the order
--- is stripped so A+B and B+A match identically.
--- @param combo_def table Entry from MOD_COMBOS.
--- @param combo_to table Combo (chord) output events.
--- @param combo_action table Combo action definition.
--- @param combo_symmetric boolean Whether A+B == B+A for this config.
--- @return table|nil Karabiner rule object, or nil when combo_to is empty.
local function build_chord_combo_rule(combo_def, combo_to, combo_action, combo_symmetric)
	if #combo_to == 0 then return nil end

	-- Shallow-copy the combo's `from` so the shared MOD_COMBOS entry is never
	-- mutated by the adjustments below.
	local from = {}
	for k, v in pairs(combo_def.from) do from[k] = v end

	if combo_symmetric and type(from.simultaneous_options) == "table" then
		-- Symmetric config: strip key_down_order so A+B and B+A match identically.
		local opts = {}
		for k, v in pairs(from.simultaneous_options) do
			if k ~= "key_down_order" then opts[k] = v end
		end
		from.simultaneous_options = next(opts) and opts or nil
	end

	-- KE gotcha: a `simultaneous` trigger made of MODIFIER keys (e.g. right_command
	-- + left_command) raises those keys' own modifier flags the instant the first
	-- key goes down. KE rejects any undeclared modifier by default, so without an
	-- `optional: any` allowance the chord fails to match and silently falls through
	-- to the single-key tap rule (left_command tap → a bare backspace), degrading
	-- ⌥⌫ "delete word left" to one backspace. Allow any incidental modifier —
	-- exactly what the tap/hold sibling rule already does — while preserving any
	-- explicit modifiers the combo declared.
	--
	-- `optional` alone only fixes MATCHING: KE passes optional modifiers THROUGH to
	-- the output, so a chord's own held flags leak into the emitted event. For a
	-- command-pair chord (right_command + left_command) whose output is ⌥⌫
	-- (option+backspace), the leaked ⌘ turns it into ⌘⌥⌫ — and ⌘⌫
	-- "delete-to-line-start" overrides ⌥⌫ "delete-word-left", so the chord does
	-- nothing useful. Its right_command+left_option sibling escaped the bug only
	-- because a leaked ⌘ is inert for ⌥⌦ "delete-word-right". Declare the chord's
	-- OWN modifier keys as `mandatory` so KE CONSUMES their flags (removing them
	-- from the output) — the very mechanism the k1_mandatory tap/hold path already
	-- relies on — while `optional: any` still absorbs unrelated incidental flags.
	local chord_mandatory = {}
	if type(from.simultaneous) == "table" then
		for _, sk in ipairs(from.simultaneous) do
			if sk.key_code and ACTUAL_MODIFIER_KEY_CODES[sk.key_code] then
				chord_mandatory[#chord_mandatory + 1] = sk.key_code
			end
		end
	end

	local modifiers = { optional = { "any" } }
	if #chord_mandatory > 0 then
		modifiers.mandatory = chord_mandatory
	end
	if type(from.modifiers) == "table" then
		for k, v in pairs(from.modifiers) do modifiers[k] = v end
		modifiers.optional = { "any" }
		-- A combo that declares its own mandatory modifiers wins over the computed
		-- set; otherwise keep the chord-key flags we just gathered.
		if not from.modifiers.mandatory and #chord_mandatory > 0 then
			modifiers.mandatory = chord_mandatory
		end
	end
	from.modifiers = modifiers

	local manip = { type = "basic", from = from, to = combo_to }
	if combo_action.karabiner_to_after_key_up then
		manip.to_after_key_up = combo_action.karabiner_to_after_key_up
	end

	return {
		description  = string.format("%s: %s [chord]", combo_def.label, combo_action.label),
		manipulators = { manip },
	}
end



-- =======================================
-- ===== 3.3) Combined Rule Assembly =====
-- =======================================

--- Builds all Karabiner rules for a single modifier combo (up to two rules:
--- one chord rule for the combo slot, one variable-based rule for tap/hold).
--- Chord rule is emitted FIRST so a simultaneous press wins over hold-then-tap.
--- @param combo_def table Entry from MOD_COMBOS.
--- @param tap_action table Resolved action for tap slot.
--- @param hold_action table Resolved action for hold slot.
--- @param combo_action table Resolved action for combo slot.
--- @param k1_mandatory table|nil Modifier key_codes held by k1.
--- @param combo_symmetric boolean Whether A+B == B+A.
--- @return table List of zero, one, or two Karabiner rule objects.
local function build_combo_rules(combo_def, tap_action, hold_action, combo_action, k1_mandatory, combo_symmetric)
	local tap_to   = tap_action.karabiner_to   or {}
	local hold_to  = hold_action.karabiner_to  or {}
	local combo_to = combo_action.karabiner_to or {}

	local sim = combo_def.from and combo_def.from.simultaneous
	local k1  = sim and sim[1] and sim[1].key_code
	local k2  = sim and sim[2] and sim[2].key_code
	if not k1 or not k2 then return {} end

	local rules = {}
	-- Chord rule first: a simultaneous press wins over the hold-then-tap path
	local chord_rule = build_chord_combo_rule(combo_def, combo_to, combo_action, combo_symmetric)
	if chord_rule then rules[#rules + 1] = chord_rule end

	local th_rule = build_tap_hold_combo_rule(combo_def, tap_to, hold_to, tap_action, hold_action, k1, k2, k1_mandatory)
	if th_rule then rules[#rules + 1] = th_rule end

	return rules
end





-- ===========================================
-- ===========================================
-- ======= 4/ Script Control Sentinels =======
-- ===========================================
-- ===========================================

--- Builds the three sentinel rules that translate physical right_command +
--- (backspace | return | escape) into the F13/F14/F15 sentinels declared in
--- SCRIPT_CONTROL_SENTINEL_SLOTS.
---
--- The variable_if guard on ke_held_right_command ensures these rules only fire
--- for PHYSICAL presses — tap outputs from the rule engine bypass further rule
--- matching and can never activate them by accident.
--- @return table List of Karabiner rule objects.
local function build_script_control_sentinel_rules()
	local rules = {}
	for _, slot in ipairs(SCRIPT_CONTROL_SENTINEL_SLOTS) do
		rules[#rules + 1] = {
			description  = string.format(
				"Script control: physical rcmd + %s → %s",
				slot.from_key, slot.sentinel
			),
			manipulators = {
				{
					type = "basic",
					from = {
						key_code  = slot.from_key,
						modifiers = { optional = { "any" } },
					},
					conditions = {
						{
							type  = "variable_if",
							name  = held_var_name(SCRIPT_CONTROL_HOLDER_KEY),
							value = 1,
						},
					},
					to = { { key_code = slot.sentinel, modifiers = SCRIPT_CONTROL_SENTINEL_TAGS } },
				},
			},
		}
	end
	return rules
end


--- Builds the historical, ungated pause-only script-control rule graph.
--- Kept separate so first-upgrade migration can fingerprint the exact config
--- that older builds deployed while paused.
--- @return table rules One raw rule per script-control slot.
local function build_raw_paused_script_control_rules()
	local rules = {}
	for _, slot in ipairs(SCRIPT_CONTROL_SENTINEL_SLOTS) do
		rules[#rules + 1] = {
			description  = string.format(
				"Paused script control: option + %s → %s",
				slot.from_key, slot.sentinel
			),
			manipulators = {
				{
					type = "basic",
					from = {
						key_code  = slot.from_key,
						modifiers = { mandatory = { "option" }, optional = { "any" } },
					},
					to = { { key_code = slot.sentinel, modifiers = SCRIPT_CONTROL_SENTINEL_TAGS } },
				},
			},
		}
	end
	return rules
end

--- Builds the self-contained script-control rules active only while paused.
--- The normal sentinel rules condition on ke_held_right_command, but every normal
--- rule requires the generation-scoped mode to be ACTIVE. These
--- pause-only rules gate DIRECTLY on the physical modifier, so
--- AltGr+Enter / Backspace / Escape keep emitting F13 / F14 / F15 (consumed by
--- modules/shortcuts/script_control.lua) while every other remap is off, so
--- the script-control shortcuts stay identical and working while paused.
--- While paused the remap layer is OFF, so the user reaches these shortcuts with the
--- REAL option key — option+Enter / option+Backspace / option+Escape. The rules gate
--- ONLY on the side-agnostic real "option" key and deliberately do NOT include a
--- right_command variant: the user does not press the real rcmd while paused, and a
--- right_command+Backspace/Escape rule would shadow native macOS chords (e.g.
--- Cmd+Delete = delete-to-line-start). One rule per slot (F-H6).
--- @param lease_token string Canonical generation token shared with the watchdog.
--- @return table|nil rules List of managed Karabiner rules (one per slot).
--- @return string|nil error_message Validation failure.
function M.build_paused_script_control_rules(lease_token)
	if not LeaseContract.is_valid_token(lease_token) then
		local err = LeaseContract.invalid_token_error(lease_token)
		Logger.error(LOG, "Cannot build paused script-control rules: %s.", err)
		return nil, err
	end
	local rules = build_raw_paused_script_control_rules()
	local managed, err = gate_managed_rules(rules, lease_token, MANAGED_MODE_PAUSE)
	if not managed then Logger.error(LOG, "Cannot gate paused script-control rules: %s.", err) end
	return managed, err
end





-- ==========================================
-- ==========================================
-- ======= 5/ Assembly and Deployment =======
-- ==========================================
-- ==========================================

--- Assembles the full Karabiner JSON structure from current state.
---
--- Rule priority order (highest → lowest):
---   1. CapsWord (must win against any combo or tap/hold sharing its keys)
---   2. Dynamic modifier combo rules (before layer_keys)
---   3. Script-control sentinel rules
---   4. Always-on static rules (layer_keys, combos)
---   5. Dynamic tap/hold manipulators
---   6. Pause-only script-control rules (mutually exclusive with 1–5)
---
--- @param state table Current module state (_state from init.lua).
--- @param available_actions table List from Config.load_available_actions.
--- @param tap_hold_keys table List from Config.load_tap_hold_keys.
--- @param mod_combos table List from Config.load_mod_combos.
--- @param non_canonical table Set from Config.compute_non_canonical_combos.
--- @param shared_dir string Path to platform/remap/data/ containing the JSON data files.
--- @param lease_token string Canonical generation token shared with the watchdog.
--- @return table|nil config Karabiner config table ready for hs.json.encode.
--- @return string|nil error_message Validation or assembly failure.
--- @return table|nil legacy_rules Non-owning pre-lease compatibility hints.
--- @return table|nil legacy_context State-independent inputs used to prove an older generated graph.
function M.build_karabiner_json(
	state,
	available_actions,
	tap_hold_keys,
	mod_combos,
	non_canonical,
	shared_dir,
	lease_token
)
	if not LeaseContract.is_valid_token(lease_token) then
		local err = LeaseContract.invalid_token_error(lease_token)
		Logger.error(LOG, "Cannot build Karabiner config: %s.", err)
		return nil, err
	end
	local _, catalogue_err = ActionCatalogue.index_by_id(available_actions)
	if catalogue_err then
		Logger.error(LOG, "Cannot build Karabiner config: %s.", catalogue_err)
		return nil, catalogue_err
	end
	available_actions = detach_runtime_variable_actions(available_actions)

	-- Inject F20 sentinel into every nav-layer-activating action BEFORE indexing,
	-- so all downstream rule builders (tap/hold, combo, etc.) inherit the sentinel.
	prepend_nav_layer_sentinel(available_actions)

	local action_index, prepared_catalogue_err = ActionCatalogue.index_by_id(available_actions)
	if prepared_catalogue_err then
		Logger.error(LOG, "Cannot build Karabiner config: %s.", prepared_catalogue_err)
		return nil, prepared_catalogue_err
	end
	local all_rules    = {}
	local none_action  = action_index["none"] or { label = "none", karabiner_to = {} }
	local legacy_static_anchors = {}


	-- CapsWord must be first — it must match before any modifier combo or
	-- tap/hold rule so that RCmd+CapsLock activates CapsWord regardless of
	-- whatever else is mapped to those keys.
	local capsword_rule = load_json_file(shared_dir .. "capsword.json")
	if capsword_rule then
		legacy_static_anchors.capsword = deep_copy(capsword_rule)
		all_rules[#all_rules + 1] = capsword_rule
	else
		Logger.warn(LOG, "capsword.json not found — CapsWord will be inactive.")
	end


	-- Build a lookup: key_code → modifier key_codes held by its hold action.
	-- When a key acts as k1 (holder) in a combo, its hold-action modifiers are
	-- virtually held while the combo rule fires. Listing them as mandatory in the
	-- rule's from matcher consumes them so they do not leak into output events.
	local key_held_modifiers = {}
	for _, key_def in ipairs(tap_hold_keys) do
		local cfg       = state.tap_hold_config[key_def.id] or {}
		local hold_id   = cfg.hold or "none"
		local hold_act  = action_index[hold_id] or none_action
		local held_mods = {}
		for _, ev in ipairs(hold_act.karabiner_to or {}) do
			if ev.key_code and ACTUAL_MODIFIER_KEY_CODES[ev.key_code] then
				held_mods[#held_mods + 1] = ev.key_code
			end
		end
		if #held_mods > 0 then
			key_held_modifiers[key_def.from.key_code] = held_mods
		end
	end


	-- Dynamic modifier combo manipulators (after CapsWord, before layer_keys so
	-- a user-defined combo involving a layer-remapped key matches the combo first).
	for _, combo_def in ipairs(mod_combos) do
		-- Skip combos handled outside KE (menu_hidden = handled by Hammerspoon directly)
		if combo_def.menu_hidden then goto continue end

		local cfg      = state.mod_combos_config[combo_def.id] or {}
		local tap_id   = (type(cfg) == "table" and cfg.tap)   or "none"
		local hold_id  = (type(cfg) == "table" and cfg.hold)  or "none"
		local combo_id = (type(cfg) == "table" and cfg.combo) or "none"

		-- Symmetric mode: only the chord slot is shared. Non-canonical halves still
		-- emit their own per-direction tap/hold rules (legitimate asymmetry).
		local is_non_canonical = non_canonical[combo_def.id] == true
		if state.combo_symmetric and is_non_canonical then
			combo_id = "none"
		end

		local tap_action   = action_index[tap_id]   or none_action
		local hold_action  = action_index[hold_id]  or none_action
		local combo_action = action_index[combo_id] or none_action

		local has_any_action = (tap_id ~= "none") or (hold_id ~= "none") or (combo_id ~= "none")
		if has_any_action then
			Logger.debug(LOG, "Combo '%s': tap=%s, hold=%s, combo=%s (non_canonical=%s).",
				combo_def.id, tap_id, hold_id, combo_id, tostring(is_non_canonical))
		end

		local sim_keys     = combo_def.from and combo_def.from.simultaneous
		local k1_key       = sim_keys and sim_keys[1] and sim_keys[1].key_code
		local k1_mandatory = k1_key and key_held_modifiers[k1_key]

		local generated = build_combo_rules(
			combo_def, tap_action, hold_action, combo_action,
			k1_mandatory, state.combo_symmetric
		)
		for _, rule in ipairs(generated) do
			all_rules[#all_rules + 1] = rule
			Logger.debug(LOG, "  → rule: %s", rule.description)
		end

		::continue::
	end


	-- Script-control sentinel rules (placed after combos so a user-configured
	-- rcmd+bsp/ret/esc combo takes precedence over the sentinel when both exist).
	-- These rely on ke_held_right_command being set by the rcmd tap/hold rule.
	for _, rule in ipairs(build_script_control_sentinel_rules()) do
		all_rules[#all_rules + 1] = rule
	end


	-- Always-on rules (complex logic that cannot be expressed as tap / hold).
	-- CapsWord is already at the top of all_rules — skipped here intentionally.
	for _, fname in ipairs(ALWAYS_ON_RULES) do
		local rule = load_json_file(shared_dir .. fname)
		if rule then
			if fname == "layer_keys.json" then
				legacy_static_anchors.layer_keys = deep_copy(rule)
			elseif fname == "combos.json" then
				legacy_static_anchors.combos = deep_copy(rule)
			end
			all_rules[#all_rules + 1] = rule
		else
			Logger.warn(LOG, "Always-on rule file not found: '%s' — skipped.", fname)
		end
	end


	-- Dynamic tap / hold manipulators
	for _, key_def in ipairs(tap_hold_keys) do
		local cfg         = state.tap_hold_config[key_def.id] or {}
		local tap_id      = cfg.tap  or "none"
		local hold_id     = cfg.hold or "none"
		local tap_action  = action_index[tap_id]
		local hold_action = action_index[hold_id]

		if not tap_action then
			Logger.warn(LOG, "Unknown tap action '%s' for key '%s' — falling back to none.", tap_id, key_def.id)
			tap_action = none_action
		end
		if not hold_action then
			Logger.warn(LOG, "Unknown hold action '%s' for key '%s' — falling back to none.", hold_id, key_def.id)
			hold_action = none_action
		end

		-- Per-key tap/hold threshold override (nil = inherit the global parameter).
		local per_key_ms = tonumber(cfg.timeout_ms)
		if per_key_ms and per_key_ms <= 0 then
			per_key_ms = nil
		elseif cfg.timeout_ms ~= nil and not is_integer(per_key_ms) then
			local err = string.format(
				"tap/hold timeout for key '%s' must be an integer number of milliseconds",
				tostring(key_def.id)
			)
			Logger.error(LOG, "Cannot build Karabiner config: %s.", err)
			return nil, err
		end
		local rule = build_tap_hold_rule(key_def, tap_action, hold_action, action_index, per_key_ms)
		if rule then all_rules[#all_rules + 1] = rule end
	end

	-- Capture the exact historical rule graph before the new manipulator-local
	-- timings, ownership tags, and atomic mode gates mutate it. Individual members
	-- are non-owning compatibility hints: deletion requires reconstruction and
	-- proof of the complete contiguous historical block.
	local legacy_available_actions = detach_runtime_variable_actions(available_actions)
	local legacy_rules = deep_copy(all_rules)
	for _, paused_rule in ipairs(build_raw_paused_script_control_rules()) do
		legacy_rules[#legacy_rules + 1] = deep_copy(paused_rule)
	end

	-- A single deployed config contains both pause states. Pause and resume only
	-- toggle the generation-scoped variable; they never rewrite karabiner.json
	local timeout_ms = state.tap_hold_timeout_ms
	local simultaneous_ms = state.simultaneous_threshold_ms
	local timed_rules, timing_err = apply_managed_timing_parameters(
		all_rules,
		timeout_ms,
		simultaneous_ms
	)
	if not timed_rules then
		Logger.error(LOG, "Cannot apply managed Karabiner timings: %s.", timing_err)
		return nil, timing_err
	end
	all_rules = timed_rules

	local managed_normal, normal_err = gate_managed_rules(
		all_rules,
		lease_token,
		MANAGED_MODE_NORMAL
	)
	if not managed_normal then
		Logger.error(LOG, "Cannot gate normal Karabiner rules: %s.", normal_err)
		return nil, normal_err
	end
	all_rules = managed_normal

	local paused_rules, pause_err = M.build_paused_script_control_rules(lease_token)
	if not paused_rules then return nil, pause_err end
	for _, rule in ipairs(paused_rules) do all_rules[#all_rules + 1] = rule end


	Logger.debug(LOG, "Building config: tap/hold=%d ms, simultaneous=%d ms, symmetric=%s, %d rule(s).",
		timeout_ms, simultaneous_ms, tostring(state.combo_symmetric), #all_rules)

	local config = {
		profiles = {
			{
				complex_modifications = {
					rules = all_rules,
				},
				devices              = { { identifiers = { is_keyboard = true }, simple_modifications = {} } },
				name                 = "Default profile",
				selected             = true,
				virtual_hid_keyboard = { country_code = 0, keyboard_type_v2 = "ansi" },
			}
		}
	}
	local legacy_context = {
		-- Merge consumes this context synchronously. Keep the immutable catalogues by
		-- reference instead of copying hundreds of actions on every regeneration;
		-- candidate reconstruction makes its own copies before any mutation.
		available_actions = legacy_available_actions,
		tap_hold_keys = tap_hold_keys,
		mod_combos = mod_combos,
		non_canonical = non_canonical,
		shared_dir = shared_dir,
		static_anchors = legacy_static_anchors,
		script_control_slots = deep_copy(SCRIPT_CONTROL_SENTINEL_SLOTS),
		physical_log_path = KE_PHYSICAL_KC_LOG,
	}
	return config, nil, legacy_rules, legacy_context
end

--- Finds the one explicitly selected profile without guessing.
--- @param config table Karabiner root configuration.
--- @param label string Name used in validation errors.
--- @return table|nil profile The selected profile.
--- @return integer|string|nil profile_index Selected index, or an error string.
local function find_unique_selected_profile(config, label)
	if type(config) ~= "table" then return nil, label .. " config must be a table" end
	if not is_dense_array(config.profiles) or #config.profiles == 0 then
		return nil, label .. " config must contain profiles"
	end

	local selected_profile = nil
	local selected_index = nil
	local selected_count = 0
	for index, profile in ipairs(config.profiles) do
		if type(profile) ~= "table" then
			return nil, string.format("%s profile %d must be a table", label, index)
		end
		if profile.selected == true then
			selected_count = selected_count + 1
			selected_profile = profile
			selected_index = index
		end
	end
	if selected_count ~= 1 then
		return nil, string.format(
			"%s config must contain exactly one selected profile, found %d",
			label,
			selected_count
		)
	end
	return selected_profile, selected_index
end

--- Counts one exact Karabiner condition on a manipulator.
--- @param manipulator table Karabiner manipulator.
--- @param name string Variable name.
--- @param value number Expected value.
--- @return integer count Exact matching condition count.
local function count_variable_condition(manipulator, name, value)
	local count = 0
	for _, condition in ipairs(manipulator.conditions or {}) do
		if type(condition) == "table"
			and condition.type == "variable_if"
			and condition.name == name
			and condition.value == value then
			count = count + 1
		end
	end
	return count
end

--- Validates that the incoming block contains only centrally gated managed rules.
--- An empty block is valid and means remove every stale ErgoptiPlus rule without
--- installing a replacement, which is the non-destructive disable operation.
--- @param rules table Incoming generated rules.
--- @return boolean valid Whether every non-empty rule is safe to insert.
--- @return string|nil error_message Validation failure.
local function validate_incoming_managed_rules(rules)
	if not is_dense_array(rules) then
		return false, "generated managed rules must be a dense array"
	end
	local generation_token = nil
	for rule_index, rule in ipairs(rules) do
		if type(rule) ~= "table" then
			return false, string.format("generated rule %d must be a table", rule_index)
		end
		local token, mode = parse_managed_description(rule.description)
		if not token then
			return false, string.format("generated rule %d lacks an exact managed tag", rule_index)
		end
		if generation_token and generation_token ~= token then
			return false, "generated managed rules must use one generation token"
		end
		generation_token = token
		if not is_dense_array(rule.manipulators) or #rule.manipulators == 0 then
			return false, string.format("generated rule %d must contain manipulators", rule_index)
		end

		local variables = LeaseContract.variables(token)
		local mode_name = variables.mode
		local revoked_name = variables.revoked
		local expected_mode = mode == MANAGED_MODE_PAUSE
			and LeaseContract.MODE_PAUSED or LeaseContract.MODE_ACTIVE
		for manipulator_index, manipulator in ipairs(rule.manipulators) do
			if type(manipulator) ~= "table" or not is_dense_array(manipulator.conditions) then
				return false, string.format(
					"generated rule %d manipulator %d lacks managed conditions",
					rule_index,
					manipulator_index
				)
			end
			for _, condition in ipairs(manipulator.conditions) do
				if type(condition) ~= "table" then
					return false, string.format(
						"generated rule %d manipulator %d contains an invalid condition",
						rule_index,
						manipulator_index
					)
				end
				local _runtime_logical, runtime_token =
					LeaseContract.parse_runtime_variable_name(condition.name)
				if runtime_token and runtime_token ~= token then
					return false, string.format(
						"generated rule %d manipulator %d contains a foreign runtime condition",
						rule_index,
						manipulator_index
					)
				elseif LeaseContract.is_managed_variable_name(condition.name)
					and not runtime_token then
					local is_exact_mode = condition.type == "variable_if"
						and condition.name == mode_name
						and condition.value == expected_mode
					local is_exact_revoked = condition.type == "variable_if"
						and condition.name == revoked_name
						and condition.value == 0
					if not is_exact_mode and not is_exact_revoked then
						return false, string.format(
							"generated rule %d manipulator %d contains a foreign managed condition",
							rule_index,
							manipulator_index
						)
					end
				end
			end
			local runtime_ok, runtime_err = validate_scoped_runtime_references(
				manipulator,
				token
			)
			if not runtime_ok then
				return false, string.format(
					"generated rule %d manipulator %d: %s",
					rule_index,
					manipulator_index,
					tostring(runtime_err)
				)
			end
			if count_variable_condition(manipulator, mode_name, expected_mode) ~= 1
				or count_variable_condition(manipulator, mode_name, LeaseContract.MODE_OFF) ~= 0
				or count_variable_condition(manipulator, mode_name,
					expected_mode == LeaseContract.MODE_ACTIVE
						and LeaseContract.MODE_PAUSED or LeaseContract.MODE_ACTIVE) ~= 0
				or count_variable_condition(manipulator, revoked_name, 0) ~= 1
				or count_variable_condition(manipulator, revoked_name, 1) ~= 0 then
				return false, string.format(
					"generated rule %d manipulator %d has inconsistent managed conditions",
					rule_index,
					manipulator_index
				)
			end
		end
	end
	return true
end

--- Validates non-owning pre-lease hints supplied by build_karabiner_json.
--- No individual hint is ever sufficient evidence for deletion.
--- Fingerprints may remove existing rules by deep equality, so accepting a
--- managed tag, malformed rule graph, or reserved variable would broaden the
--- ownership boundary and risk claiming user configuration.
--- @param rules table|nil Exact historical rule fingerprints.
--- @return boolean valid Whether the hint list is structurally safe.
--- @return string|nil error_message Validation failure.
local function validate_legacy_rule_fingerprints(rules)
	if rules == nil then return true end
	if not is_dense_array(rules) then
		return false, "legacy rule fingerprints must be a dense array"
	end
	for rule_index, rule in ipairs(rules) do
		if type(rule) ~= "table"
			or type(rule.description) ~= "string"
			or rule.description == "" then
			return false, string.format(
				"legacy rule fingerprint %d must have a non-empty description",
				rule_index
			)
		end
		if parse_managed_description(rule.description) then
			return false, string.format(
				"legacy rule fingerprint %d must be untagged",
				rule_index
			)
		end
		if not is_dense_array(rule.manipulators) or #rule.manipulators == 0 then
			return false, string.format(
				"legacy rule fingerprint %d must contain manipulators",
				rule_index
			)
		end
		local references_ok, references_err = walk_runtime_variable_references(
			rule,
			function(_holder, name, path)
				if LeaseContract.is_managed_variable_name(name) then
					return false, string.format(
						"legacy rule fingerprint %d contains managed variable '%s' at %s",
						rule_index,
						name,
						path
					)
				end
				return true
			end,
			"legacy_rules[" .. tostring(rule_index) .. "]"
		)
		if not references_ok then return false, references_err end
		for manipulator_index, manipulator in ipairs(rule.manipulators) do
			if type(manipulator) ~= "table"
				or (manipulator.conditions ~= nil
					and not is_dense_array(manipulator.conditions)) then
				return false, string.format(
					"legacy rule fingerprint %d manipulator %d is malformed",
					rule_index,
					manipulator_index
				)
			end
			for _, condition in ipairs(manipulator.conditions or {}) do
				if type(condition) ~= "table"
					or LeaseContract.is_managed_variable_name(condition.name) then
					return false, string.format(
						"legacy rule fingerprint %d manipulator %d contains a managed condition",
						rule_index,
						manipulator_index
					)
				end
			end
		end
	end
	return true
end

--- Reports whether a string starts with an exact byte sequence.
--- @param value any Candidate string.
--- @param prefix string Required prefix.
--- @return boolean matches Whether the prefix is exact.
local function starts_with(value, prefix)
	return type(value) == "string" and value:sub(1, #prefix) == prefix
end

--- Reports whether a string ends with an exact byte sequence.
--- @param value any Candidate string.
--- @param suffix string Required suffix.
--- @return boolean matches Whether the suffix is exact.
local function ends_with(value, suffix)
	return type(value) == "string" and value:sub(-#suffix) == suffix
end

--- Reports whether an action id changes generated structure independently of
--- the action payload. Sticky/base ids participate in companion-rule selection;
--- `none` participates in combo emission, so neither may be canonicalised.
--- @param action_id any Candidate action id.
--- @return boolean semantic Whether identity itself affects generation.
local function has_generator_semantic_action_id(action_id)
	if action_id == "none" or STICKY_TO_BASE_ACTION[action_id] ~= nil then return true end
	for _, base_id in pairs(STICKY_TO_BASE_ACTION) do
		if action_id == base_id then return true end
	end
	return false
end

--- Accepts a duplicate localised label only when both actions are exact output
--- aliases and neither id has generator semantics. This covers the historical
--- `cmd_tab` -> `alt_tab_apps_list` compatibility alias without guessing between
--- genuinely different actions that happen to translate to the same label.
--- @param first table First action.
--- @param second table Second action.
--- @return boolean equivalent Whether either id regenerates the same graph.
local function equivalent_legacy_action_alias(first, second)
	if type(first) ~= "table" or type(second) ~= "table" then return false end
	if has_generator_semantic_action_id(first.id) or has_generator_semantic_action_id(second.id) then
		return false
	end
	for key, value in pairs(first) do
		if key ~= "id" and not deep_equal(value, second[key]) then return false end
	end
	for key, value in pairs(second) do
		if key ~= "id" and not deep_equal(value, first[key]) then return false end
	end
	return true
end

--- Builds a unique string-field index and rejects ambiguous catalogue labels.
--- @param items table Dense catalogue array.
--- @param field string String field used as the key.
--- @param catalogue_name string Diagnostic catalogue name.
--- @param allow_equivalent_action_aliases boolean|nil Coalesce exact non-semantic action aliases.
--- @return table|nil index Unique item lookup.
--- @return string|nil error_message Validation failure.
local function unique_catalogue_index(items, field, catalogue_name, allow_equivalent_action_aliases)
	if not is_dense_array(items) then return nil, catalogue_name .. " must be a dense array" end
	local index = {}
	for item_index, item in ipairs(items) do
		local key = type(item) == "table" and item[field] or nil
		if type(key) ~= "string" or key == "" then
			return nil, string.format("%s item %d lacks a non-empty %s", catalogue_name, item_index, field)
		end
		if index[key]
			and not (allow_equivalent_action_aliases
				and equivalent_legacy_action_alias(index[key], item)) then
			return nil, string.format("%s has duplicate %s '%s'", catalogue_name, field, key)
		end
		if not index[key] then index[key] = item end
	end
	return index
end

--- Validates the old generator's profile-level timing signature.
--- These two keys were written by the pre-lease generator as a complete
--- parameters table. Extra or missing keys make ownership ambiguous.
--- @param parameters any Existing complex-modification parameters.
--- @return boolean matches Whether the table is the exact historical shape.
local function has_exact_legacy_parameters(parameters)
	if type(parameters) ~= "table" then return false end
	local key_count = 0
	for key in pairs(parameters) do
		if key ~= LEGACY_PARAMETER_TAP and key ~= LEGACY_PARAMETER_SIMULTANEOUS then return false end
		key_count = key_count + 1
	end
	return key_count == 2
		and is_positive_integer(parameters[LEGACY_PARAMETER_TAP])
		and is_positive_integer(parameters[LEGACY_PARAMETER_SIMULTANEOUS])
end

--- Prepares and validates state-independent inputs for legacy graph proof.
--- @param context any Fourth return value from build_karabiner_json.
--- @return table|nil prepared Validated proof inputs and lookup indices.
--- @return string|nil error_message Validation failure.
local function prepare_legacy_context(context)
	if type(context) ~= "table" then return nil, "legacy migration context must be a table" end
	if type(context.shared_dir) ~= "string" or context.shared_dir == "" then
		return nil, "legacy migration context requires a shared data directory"
	end
	if type(context.non_canonical) ~= "table" then
		return nil, "legacy migration context requires a non-canonical combo set"
	end
	if not is_dense_array(context.script_control_slots) or #context.script_control_slots ~= 3 then
		return nil, "legacy migration context requires three script-control slots"
	end
	if type(context.physical_log_path) ~= "string" or context.physical_log_path == "" then
		return nil, "legacy migration context requires the historical physical-key log path"
	end

	local action_by_label, action_err = unique_catalogue_index(
		context.available_actions,
		"label",
		"legacy action catalogue",
		true
	)
	if not action_by_label then return nil, action_err end
	local key_by_label, key_err = unique_catalogue_index(
		context.tap_hold_keys,
		"label",
		"legacy tap/hold catalogue"
	)
	if not key_by_label then return nil, key_err end
	local combo_by_label, combo_err = unique_catalogue_index(
		context.mod_combos,
		"label",
		"legacy combo catalogue"
	)
	if not combo_by_label then return nil, combo_err end

	local action_id_seen = {}
	for _, action in ipairs(context.available_actions) do
		if type(action.id) ~= "string" or action.id == "" or action_id_seen[action.id] then
			return nil, "legacy action catalogue has a missing or duplicate id"
		end
		action_id_seen[action.id] = true
	end
	local combo_index_by_id = {}
	for combo_index, combo in ipairs(context.mod_combos) do
		if type(combo.id) ~= "string" or combo.id == "" or combo_index_by_id[combo.id] then
			return nil, "legacy combo catalogue has a missing or duplicate id"
		end
		combo_index_by_id[combo.id] = combo_index
	end

	local anchors = context.static_anchors
	if type(anchors) ~= "table" then
		return nil, "legacy migration context requires static rule anchors"
	end
	local capsword = anchors.capsword
	local layer_keys = anchors.layer_keys
	local combos = anchors.combos
	if not capsword or not layer_keys or not combos then
		return nil, "legacy migration context has incomplete static rule anchors"
	end

	return {
		available_actions = context.available_actions,
		tap_hold_keys = context.tap_hold_keys,
		mod_combos = context.mod_combos,
		non_canonical = context.non_canonical,
		shared_dir = context.shared_dir,
		script_control_slots = context.script_control_slots,
		physical_log_path = context.physical_log_path,
		action_by_label = action_by_label,
		key_by_label = key_by_label,
		combo_by_label = combo_by_label,
		combo_index_by_id = combo_index_by_id,
		capsword = capsword,
		layer_keys = layer_keys,
		combos = combos,
	}
end

--- Parses the action pair encoded by a historical rule description.
--- @param description string Existing rule description.
--- @param prefix string Exact generator-owned prefix.
--- @param action_by_label table Unique action lookup.
--- @return table|nil pair Resolved tap and hold actions.
--- @return string|nil error_message Parse failure.
local function parse_legacy_action_pair(description, prefix, action_by_label)
	local suffix = " (hold)"
	local delimiter = " (tap) / "
	if not starts_with(description, prefix) or not ends_with(description, suffix) then
		return nil, "legacy action-pair description has an invalid envelope"
	end
	local body = description:sub(#prefix + 1, #description - #suffix)
	local split_at = body:find(delimiter, 1, true)
	if not split_at or body:find(delimiter, split_at + #delimiter, true) then
		return nil, "legacy action-pair description is ambiguous"
	end
	local tap_label = body:sub(1, split_at - 1)
	local hold_label = body:sub(split_at + #delimiter)
	local tap_action = action_by_label[tap_label]
	local hold_action = action_by_label[hold_label]
	if not tap_action or not hold_action then
		return nil, "legacy action-pair description names an unknown action"
	end
	return { tap = tap_action, hold = hold_action }
end

--- Reconstructs one tap/hold setting from its historical rule.
--- @param rule table Historical rule candidate.
--- @param key_def table Tap/hold catalogue entry at this fixed position.
--- @param action_by_label table Unique action lookup.
--- @return table|nil config Reconstructed tap, hold, and optional timeout.
--- @return string|nil error_message Parse failure.
local function parse_legacy_tap_hold_rule(rule, key_def, action_by_label)
	if type(rule) ~= "table" or type(rule.description) ~= "string"
		or not is_dense_array(rule.manipulators) or #rule.manipulators == 0 then
		return nil, "legacy tap/hold rule is malformed"
	end
	local passthrough = key_def.label .. ": passthrough (variable tracked)"
	if rule.description == passthrough then
		return { tap = "none", hold = "none" }
	end
	local pair, pair_err = parse_legacy_action_pair(
		rule.description,
		key_def.label .. ": ",
		action_by_label
	)
	if not pair then return nil, pair_err end

	local main = rule.manipulators[#rule.manipulators]
	local timeout_ms = nil
	if main.parameters ~= nil then
		if type(main.parameters) ~= "table" then return nil, "legacy tap/hold parameters are malformed" end
		timeout_ms = main.parameters[LEGACY_PARAMETER_TAP]
		if type(timeout_ms) ~= "number" or timeout_ms <= 0 then
			return nil, "legacy per-key timeout is invalid"
		end
	end
	return { tap = pair.tap.id, hold = pair.hold.id, timeout_ms = timeout_ms }
end

--- Parses one historical combo rule description without trusting its output.
--- The reconstructed state is later re-generated and structurally compared,
--- so a same-description modified rule never proves ownership.
--- @param rule table Historical combo rule candidate.
--- @param prepared table Validated migration context.
--- @return table|nil parsed Combo index, id, kind, and action ids.
--- @return string|nil error_message Parse failure.
local function parse_legacy_combo_rule(rule, prepared)
	if type(rule) ~= "table" or type(rule.description) ~= "string" then
		return nil, "legacy combo rule is malformed"
	end
	local description = rule.description
	local matches = {}
	for combo_index, combo_def in ipairs(prepared.mod_combos) do
		if not combo_def.menu_hidden then
			local chord_prefix = combo_def.label .. ": "
			local chord_suffix = " [chord]"
			if starts_with(description, chord_prefix) and ends_with(description, chord_suffix) then
				local action_label = description:sub(#chord_prefix + 1, #description - #chord_suffix)
				local action = prepared.action_by_label[action_label]
				if action then
					matches[#matches + 1] = {
						combo_index = combo_index,
						combo_id = combo_def.id,
						kind = "chord",
						combo = action.id,
					}
				end
			end

			local simultaneous = type(combo_def.from) == "table" and combo_def.from.simultaneous or nil
			local first_key = type(simultaneous) == "table" and simultaneous[1] and simultaneous[1].key_code
			local second_key = type(simultaneous) == "table" and simultaneous[2] and simultaneous[2].key_code
			if first_key and second_key then
				local pair_prefix = string.format(
					"%s (%s→%s): ",
					combo_def.label,
					first_key,
					second_key
				)
				local pair_suffix = " [var-based]"
				if starts_with(description, pair_prefix) and ends_with(description, pair_suffix) then
					local pair_description = description:sub(1, #description - #pair_suffix)
					local pair = parse_legacy_action_pair(
						pair_description,
						pair_prefix,
						prepared.action_by_label
					)
					if pair then
						matches[#matches + 1] = {
							combo_index = combo_index,
							combo_id = combo_def.id,
							kind = "tap_hold",
							tap = pair.tap.id,
							hold = pair.hold.id,
						}
					end
				end
			end
		end
	end
	if #matches ~= 1 then return nil, "legacy combo description is unknown or ambiguous" end
	return matches[1]
end

--- Reconstructs the old state encoded by one candidate normal-rule block.
--- @param rules table Candidate rules beginning with the CapsWord anchor.
--- @param script_index integer Relative index of the first script-control rule.
--- @param parameters table Exact historical timing table.
--- @param prepared table Validated migration context.
--- @return table|nil state Reconstructed generator state.
--- @return string|nil error_message Parse failure.
local function reconstruct_legacy_state(rules, script_index, parameters, prepared)
	local tap_hold_config = {}
	local tap_start = script_index + #prepared.script_control_slots + 2
	for key_index, key_def in ipairs(prepared.tap_hold_keys) do
		local config, config_err = parse_legacy_tap_hold_rule(
			rules[tap_start + key_index - 1],
			key_def,
			prepared.action_by_label
		)
		if not config then return nil, config_err end
		tap_hold_config[key_def.id] = config
	end

	local mod_combos_config = {}
	local last_combo_index = 0
	local last_kind = nil
	for rule_index = 2, script_index - 1 do
		local parsed, parsed_err = parse_legacy_combo_rule(rules[rule_index], prepared)
		if not parsed then return nil, parsed_err end
		if parsed.combo_index < last_combo_index
			or (parsed.combo_index == last_combo_index
				and (last_kind ~= "chord" or parsed.kind ~= "tap_hold")) then
			return nil, "legacy combo rules violate generator order"
		end
		local config = mod_combos_config[parsed.combo_id]
		if not config then
			config = { tap = "none", hold = "none", combo = "none" }
			mod_combos_config[parsed.combo_id] = config
		end
		if parsed.kind == "chord" then
			if config.combo ~= "none" then return nil, "legacy combo chord is duplicated" end
			config.combo = parsed.combo
		else
			if config.tap ~= "none" or config.hold ~= "none" then
				return nil, "legacy combo tap/hold rule is duplicated"
			end
			config.tap = parsed.tap
			config.hold = parsed.hold
		end
		last_combo_index = parsed.combo_index
		last_kind = parsed.kind
	end

	return {
		enabled = true,
		tap_hold_config = tap_hold_config,
		mod_combos_config = mod_combos_config,
		tap_hold_timeout_ms = parameters[LEGACY_PARAMETER_TAP],
		sticky_timeout_ms = 1,
		simultaneous_threshold_ms = parameters[LEGACY_PARAMETER_SIMULTANEOUS],
		combo_symmetric = false,
	}
end

--- Verifies one candidate normal block against every immutable release schema
--- and both historical symmetry modes. This never calls the current generator.
--- @param rules table Candidate block.
--- @param script_index integer Relative first script-control index.
--- @param parameters table Exact historical timing table.
--- @param prepared table Validated migration context.
--- @param release_ids table Release schemas sharing the observed sentinel graph.
--- @return boolean proven Whether the entire block is a generator output.
local function proves_legacy_normal_block(rules, script_index, parameters, prepared, release_ids)
	local state = reconstruct_legacy_state(rules, script_index, parameters, prepared)
	if not state then return false end
	for _, release_id in ipairs(release_ids) do
		for _, combo_symmetric in ipairs({ false, true }) do
			local expected = LegacyReleaseFixtures.build_normal_candidate(
				release_id,
				state,
				combo_symmetric,
				prepared
			)
			if expected and LegacyReleaseFixtures.graph_equal(rules, expected) then return true end
		end
	end
	return false
end

--- Reports whether an exact rule sequence begins at one index.
--- @param rules table Existing rule array.
--- @param start_index integer Candidate first index.
--- @param expected table Expected rule sequence.
--- @return boolean matches Whether every rule is deeply equal.
local function exact_rule_sequence_at(rules, start_index, expected)
	if start_index < 1 or start_index + #expected - 1 > #rules then return false end
	for offset, rule in ipairs(expected) do
		if not deep_equal(rules[start_index + offset - 1], rule) then return false end
	end
	return true
end

--- Finds the one unambiguous, fully re-generated historical block in a profile.
--- Personal rules may surround the block, but any interleaving breaks the proof.
--- @param rules table Existing profile rules.
--- @param complex table Existing complex_modifications object.
--- @param prepared table Validated migration context.
--- @return table|nil range Proven inclusive start/end indices, or nil.
--- @return string|nil error_message Ambiguous proof failure.
local function find_proven_legacy_block(rules, complex, prepared)
	local candidates = {}
	local candidate_keys = {}
	local function add_candidate(first, last)
		local key = tostring(first) .. ":" .. tostring(last)
		if not candidate_keys[key] then
			candidate_keys[key] = true
			candidates[#candidates + 1] = { first = first, last = last }
		end
	end

	if has_exact_legacy_parameters(complex.parameters) then
		for _, script_set in ipairs(LegacyReleaseFixtures.script_control_rule_sets(prepared)) do
			local script_rules = script_set.rules
			for script_start = 2, #rules do
				if exact_rule_sequence_at(rules, script_start, script_rules)
					and deep_equal(rules[script_start + #script_rules], prepared.layer_keys)
					and deep_equal(rules[script_start + #script_rules + 1], prepared.combos) then
					local block_end = script_start + #script_rules + 1 + #prepared.tap_hold_keys
					if block_end <= #rules then
						for block_start = 1, script_start - 1 do
							if deep_equal(rules[block_start], prepared.capsword) then
								local candidate = {}
								for index = block_start, block_end do
									candidate[#candidate + 1] = rules[index]
								end
								local relative_script_index = script_start - block_start + 1
								if proves_legacy_normal_block(
									candidate,
									relative_script_index,
									complex.parameters,
									prepared,
									script_set.release_ids
								) then
									add_candidate(block_start, block_end)
								end
							end
						end
					end
				end
			end
		end
	elseif complex.parameters == nil then
		for _, paused_set in ipairs(LegacyReleaseFixtures.paused_rule_sets(prepared)) do
			for start_index = 1, #rules do
				if exact_rule_sequence_at(rules, start_index, paused_set.rules) then
					add_candidate(start_index, start_index + #paused_set.rules - 1)
				end
			end
		end
	end

	if #candidates > 1 then return nil, "multiple historical ErgoptiPlus blocks match" end
	return candidates[1]
end

--- Describes every historical ErgoptiPlus signature carried by an untagged
--- rule. Detection is deliberately conservative: a false match aborts without
--- writing, whereas a missed legacy rule would remain active after a crash.
--- @param rule any Existing rule candidate.
--- @param prepared table Validated migration context.
--- @return table reasons Dense diagnostic reason array; empty means personal.
local function legacy_ergopti_signature_reasons(rule, prepared)
	local reasons = {}
	if type(rule) ~= "table" or type(rule.description) ~= "string" then return reasons end
	if deep_equal(rule, prepared.capsword) then
		reasons[#reasons + 1] = "matches the historical CapsWord anchor"
	elseif deep_equal(rule, prepared.layer_keys) then
		reasons[#reasons + 1] = "matches the historical layer-key anchor"
	elseif deep_equal(rule, prepared.combos) then
		reasons[#reasons + 1] = "matches the historical combo anchor"
	elseif LegacyReleaseFixtures.is_exact_release_control_rule(rule, prepared) then
		reasons[#reasons + 1] = "matches a historical script-control rule"
	end

	local found_variable = false
	local found_log = false
	local seen = {}
	local function collect_runtime_signatures(value)
		if type(value) ~= "table" or seen[value] then return end
		seen[value] = true
		if type(value.name) == "string" and starts_with(value.name, "ke_held_") then
			found_variable = true
		end
		if type(value.shell_command) == "string"
			and value.shell_command:find("karabiner_kc.log", 1, true) then
			found_log = true
		end
		for _, nested in pairs(value) do collect_runtime_signatures(nested) end
	end
	collect_runtime_signatures(rule)
	if found_variable then reasons[#reasons + 1] = "uses a ke_held_* variable" end
	if found_log then
		reasons[#reasons + 1] = "references karabiner_kc.log in a shell command"
	end
	return reasons
end

--- Classifies every removable rule before the merge mutates an output table.
--- @param existing_rules table Existing profile rules.
--- @param complex table Existing complex_modifications object.
--- @param prepared table|nil State-independent migration context.
--- @return table|nil removal_set Indices proven to be managed.
--- @return string|nil error_message Historical proof failure.
--- @return table conflicts Unowned signature conflicts in this rule array.
local function classify_managed_rules(existing_rules, complex, prepared)
	local removal_set = {}
	local conflicts = {}
	if prepared then
		local proven_range, range_err = find_proven_legacy_block(
			existing_rules,
			complex,
			prepared
		)
		if range_err then return nil, range_err end
		if proven_range then
			for index = proven_range.first, proven_range.last do removal_set[index] = true end
		end
	end

	for index, rule in ipairs(existing_rules) do
		local token = type(rule) == "table" and parse_managed_description(rule.description) or nil
		if token then removal_set[index] = true end
	end

	if prepared then
		for index, rule in ipairs(existing_rules) do
			if not removal_set[index] then
				local reasons = legacy_ergopti_signature_reasons(rule, prepared)
				if #reasons > 0 then
					conflicts[#conflicts + 1] = {
						rule_index = index,
						description = tostring(rule.description),
						reasons = reasons,
					}
				end
			end
		end
	end
	return removal_set, nil, conflicts
end

--- Formats one actionable refusal for every unowned historical signature.
--- @param conflicts table Dense cross-profile conflict array.
--- @return string detail Single complete remediation diagnostic.
local function format_legacy_signature_conflicts(conflicts)
	local items = {}
	for _, conflict in ipairs(conflicts) do
		items[#items + 1] = string.format(
			"profile %d rule %d ('%s'): %s",
			conflict.profile_index,
			conflict.rule_index,
			conflict.description,
			table.concat(conflict.reasons, ", ")
		)
	end
	local noun = #conflicts == 1 and "rule" or "rules"
	return string.format(
		"%d ambiguous legacy ErgoptiPlus %s: %s. No personal configuration was modified; rename the personal signature if the rule is user-owned, or remove stale ErgoptiPlus rules, then regenerate",
		#conflicts,
		noun,
		table.concat(items, "; ")
	)
end

--- Replaces exact managed rules while preserving personal-rule order.
--- The replacement block occupies the first stale managed position; if no
--- managed or exact historical block exists, it is appended after every
--- personal rule.
--- @param existing_rules table Rules in the user's selected profile.
--- @param incoming_rules table Validated rules for the new generation.
--- @param removal_set table Indices proven to be managed.
--- @return table merged_rules Non-destructive merged rule list.
local function merge_managed_rule_block(existing_rules, incoming_rules, removal_set)
	local retained = {}
	local insertion_index = nil
	for index, rule in ipairs(existing_rules) do
		if removal_set[index] then
			if not insertion_index then insertion_index = #retained + 1 end
		else
			retained[#retained + 1] = rule
		end
	end
	if not insertion_index then insertion_index = #retained + 1 end

	local merged = {}
	for index = 1, insertion_index - 1 do merged[#merged + 1] = retained[index] end
	for _, rule in ipairs(incoming_rules) do merged[#merged + 1] = rule end
	for index = insertion_index, #retained do merged[#merged + 1] = retained[index] end
	return merged
end

--- Merges generated ErgoptiPlus rules into a user's Karabiner configuration.
--- Existing files must decode and contain exactly one selected profile; any
--- ambiguity fails closed so regeneration cannot erase personal state. Only
--- descriptions carrying the exact managed prefix and a complete, reconstructed
--- historical block are removed. Individual legacy fingerprints never establish
--- ownership. All globals,
--- profiles, profile parameters, devices, simple/fn mappings, virtual-HID
--- settings, complex-modification parameters, and personal rules are preserved.
--- A missing file returns the validated generated config unchanged and never
--- injects stock Karabiner UI preferences.
--- @param hs_config table Structure returned by build_karabiner_json, or a selected profile with an empty rules list for disable cleanup.
--- @param karabiner_out string Absolute path to the live karabiner.json.
--- @param legacy_fingerprints table|nil Non-owning third return value from build_karabiner_json.
--- @param legacy_context table|nil Fourth return value from build_karabiner_json.
--- @return table|nil config Merged configuration ready to be JSON-encoded.
--- @return string|nil error_message Validation or read failure.
--- @return table|nil source_snapshot Exact classified source used for the merge.
--- @return boolean|nil changed Whether managed rules differ from the source.
function M.merge_into_existing_config(
	hs_config,
	karabiner_out,
	legacy_fingerprints,
	legacy_context
)
	if type(karabiner_out) ~= "string" or karabiner_out == "" then
		local err = "karabiner output path must be a non-empty string"
		Logger.error(LOG, "Merge aborted: %s.", err)
		return nil, err
	end

	local generated_profile, generated_index_or_err = find_unique_selected_profile(
		hs_config,
		"generated"
	)
	if not generated_profile then
		Logger.error(LOG, "Merge aborted: %s.", generated_index_or_err)
		return nil, generated_index_or_err
	end
	local generated_complex = generated_profile.complex_modifications
	if type(generated_complex) ~= "table" or type(generated_complex.rules) ~= "table" then
		local err = "generated selected profile must contain complex_modifications.rules"
		Logger.error(LOG, "Merge aborted: %s.", err)
		return nil, err
	end
	local valid_rules, rules_err = validate_incoming_managed_rules(generated_complex.rules)
	if not valid_rules then
		Logger.error(LOG, "Merge aborted: %s.", rules_err)
		return nil, rules_err
	end
	if legacy_fingerprints == nil then legacy_fingerprints = {} end
	local valid_legacy, legacy_err = validate_legacy_rule_fingerprints(legacy_fingerprints)
	if not valid_legacy then
		Logger.error(LOG, "Merge aborted: %s.", legacy_err)
		return nil, legacy_err
	end

	local read_ok, raw, read_status, read_detail = pcall(
		FileSystem.read_with_status,
		karabiner_out
	)
	if not read_ok then
		local err = "existing karabiner.json read raised: " .. tostring(raw)
		Logger.error(LOG, "Merge aborted: %s.", err)
		return nil, err
	end
	if read_status == "absent" then
		Logger.debug(LOG, "No existing karabiner.json — using generated managed config unchanged.")
		return hs_config, nil, { status = "absent" }, true
	end
	if read_status ~= "ok" or type(raw) ~= "string" then
		local err = "existing karabiner.json could not be read: "
			.. tostring(read_detail or read_status or "invalid read result")
		Logger.error(LOG, "Merge aborted: %s.", err)
		return nil, err
	end

	local decode_ok, existing = pcall(hs.json.decode, raw)
	if not decode_ok or type(existing) ~= "table" then
		local err = "existing karabiner.json is not valid JSON"
		Logger.error(LOG, "Merge aborted: %s.", err)
		return nil, err
	end

	local selected_profile, target_index_or_err = find_unique_selected_profile(existing, "existing")
	if not selected_profile then
		Logger.error(LOG, "Merge aborted: %s.", target_index_or_err)
		return nil, target_index_or_err
	end

	-- Validate every profile before mutating any of them. Stale managed rules may
	-- live in an inactive profile and become active again after a user switch
	for profile_index, profile in ipairs(existing.profiles) do
		local complex = profile.complex_modifications
		if complex ~= nil and type(complex) ~= "table" then
			local err = string.format(
				"existing profile %d complex_modifications must be a table",
				profile_index
			)
			Logger.error(LOG, "Merge aborted: %s.", err)
			return nil, err
		end
		if type(complex) == "table"
			and complex.rules ~= nil
			and not is_dense_array(complex.rules) then
			local err = string.format(
				"existing profile %d complex_modifications.rules must be a table",
				profile_index
			)
			Logger.error(LOG, "Merge aborted: %s.", err)
			return nil, err
		end
	end

	-- State-independent reconstruction is needed for every untagged rule. An exact
	-- current-state fingerprint is only a candidate fragment, never ownership
	-- proof by itself: only the complete historical block may be removed.
	-- A fully migrated config therefore avoids rebuilding catalogue indices on
	-- every settings/layout regeneration.
	local needs_legacy_reconstruction = false
	if legacy_context ~= nil then
		for _, profile in ipairs(existing.profiles) do
			local complex = profile.complex_modifications
			for _, rule in ipairs(type(complex) == "table" and complex.rules or {}) do
				local token = type(rule) == "table"
					and parse_managed_description(rule.description) or nil
				if not token then
					needs_legacy_reconstruction = true
					break
				end
			end
			if needs_legacy_reconstruction then break end
		end
	end

	local prepared_legacy = nil
	if needs_legacy_reconstruction then
		local context_err
		prepared_legacy, context_err = prepare_legacy_context(legacy_context)
		if not prepared_legacy then
			Logger.error(LOG, "Merge aborted: %s.", context_err)
			return nil, context_err
		end
	end

	local classified_profiles = {}
	local signature_conflicts = {}
	for profile_index, profile in ipairs(existing.profiles) do
		local is_selected = profile_index == target_index_or_err
		local complex = profile.complex_modifications
		if complex == nil and is_selected then complex = {} end
		if complex then
			local existing_rules = complex.rules
			if existing_rules ~= nil or is_selected then
				local removal_set, classify_err, profile_conflicts = classify_managed_rules(
					existing_rules or {},
					complex,
					prepared_legacy
				)
				if not removal_set then
					Logger.error(LOG, "Merge aborted in profile %d: %s.", profile_index, classify_err)
					return nil, classify_err
				end
				for _, conflict in ipairs(profile_conflicts) do
					conflict.profile_index = profile_index
					signature_conflicts[#signature_conflicts + 1] = conflict
				end
				classified_profiles[profile_index] = {
					existing_rules = existing_rules or {},
					incoming_rules = is_selected and generated_complex.rules or {},
					removal_set = removal_set,
				}
			end
		end
	end
	if #signature_conflicts > 0 then
		local detail = format_legacy_signature_conflicts(signature_conflicts)
		Logger.error(LOG, "Merge aborted: %s.", detail)
		return nil, detail
	end

	local changed = false
	for profile_index, classified in pairs(classified_profiles) do
		local profile = existing.profiles[profile_index]
		local merged_rules = merge_managed_rule_block(
			classified.existing_rules,
			classified.incoming_rules,
			classified.removal_set
		)
		if not deep_equal(merged_rules, classified.existing_rules) then
			if profile.complex_modifications == nil then profile.complex_modifications = {} end
			profile.complex_modifications.rules = merged_rules
			changed = true
		end
	end
	Logger.debug(
		LOG,
		"Merged %d managed rule(s) with %d validated non-owning legacy hint(s) into selected profile %d without changing personal settings.",
		#generated_complex.rules,
		#legacy_fingerprints,
		target_index_or_err
	)
	return existing, nil, { status = "ok", content = raw }, changed
end

--- Re-reads, merges, encodes, and publishes the current Karabiner config.
--- The exact bytes read for the merge remain the publication precondition, so a
--- stock Karabiner or editor write that lands after the read is never overwritten.
--- Stock and personal Karabiner processes are never restarted or signalled.
--- @param hs_config table Valid generated managed configuration.
--- @param karabiner_out string Absolute path to the live karabiner.json.
--- @param legacy_fingerprints table|nil Non-owning legacy fingerprints.
--- @param legacy_context table|nil Historical reconstruction context.
--- @return boolean deployed Whether the current merge was published.
--- @return string detail Human-readable result or failure.
--- @return integer attempts Number of publication attempts made.
function M.merge_and_deploy_config(
	hs_config,
	karabiner_out,
	legacy_fingerprints,
	legacy_context
)
	local prepare_parent = FileSystem.prepare_parent_for_create
	if type(prepare_parent) ~= "function" then
		local detail = "parent preparation failed: filesystem capability is unavailable"
		Logger.error(LOG, "Karabiner deploy aborted — %s.", detail)
		return false, detail, 1
	end
	local prepare_ok, prepared, prepare_detail = pcall(prepare_parent, karabiner_out)
	if not prepare_ok or prepared ~= true then
		local detail = "parent preparation failed: "
			.. tostring(prepare_ok and prepare_detail or prepared)
		Logger.error(LOG, "Karabiner deploy aborted — %s.", detail)
		return false, detail, 1
	end

	local merge_ok, merged, merge_err, source_snapshot, merge_changed = pcall(
		M.merge_into_existing_config,
		hs_config,
		karabiner_out,
		legacy_fingerprints,
		legacy_context
	)
	if not merge_ok or type(merged) ~= "table" then
		local detail = "merge failed: " .. tostring(merge_ok and merge_err or merged)
		Logger.error(LOG, "Karabiner deploy aborted — %s.", detail)
		return false, detail, 1
	end
	if type(source_snapshot) ~= "table"
		or (source_snapshot.status ~= "ok" and source_snapshot.status ~= "absent")
		or (source_snapshot.status == "ok" and type(source_snapshot.content) ~= "string") then
		local detail = "merge failed: exact source snapshot is missing"
		Logger.error(LOG, "Karabiner deploy aborted — %s.", detail)
		return false, detail, 1
	end
	if type(merge_changed) ~= "boolean" then
		local detail = "merge failed: semantic change verdict is missing"
		Logger.error(LOG, "Karabiner deploy aborted — %s.", detail)
		return false, detail, 1
	end
	if merge_changed == false then
		local read_ok, current, current_status, current_detail = pcall(
			FileSystem.read_with_status,
			karabiner_out
		)
		if not read_ok or current_status ~= source_snapshot.status
			or (current_status == "ok" and current ~= source_snapshot.content) then
			local reason
			if not read_ok then
				reason = "read raised: " .. tostring(current)
			elseif current_status ~= source_snapshot.status then
				reason = tostring(current_detail or current_status)
			else
				reason = "exact bytes differ"
			end
			local detail = "source changed before unchanged confirmation: " .. tostring(reason)
			Logger.error(LOG, "Karabiner deploy aborted — %s.", detail)
			return false, detail, 0
		end
		Logger.debug(
			LOG,
			"Karabiner managed rules are unchanged; publication skipped after exact source revalidation."
		)
		return true, "unchanged", 0
	end

	local encode_ok, content = pcall(hs.json.encode, merged, true)
	if not encode_ok or type(content) ~= "string" then
		local detail = "JSON encode failed: " .. tostring(content)
		Logger.error(LOG, "Karabiner deploy aborted — %s.", detail)
		return false, detail, 1
	end

	local call_ok, deployed, deploy_detail = pcall(
		M.deploy_string,
		content,
		karabiner_out,
		source_snapshot
	)
	if not call_ok or deployed ~= true then
		local detail = "write failed: " .. tostring(call_ok and deploy_detail or deployed)
		Logger.error(LOG, "Karabiner deploy aborted — %s.", detail)
		return false, detail, 1
	end

	return true, deploy_detail or "ok", 1
end

--- Deploys a file to its destination using two strategies.
---
--- S1 — direct io.open: works for regular paths and Unix symlinks.
--- S2 — mkdir + io.open retry: covers fresh Karabiner installs where
---       ~/.config/karabiner/ was never created.
---
--- @param src string Source path (real POSIX path, not an alias).
--- @param dst string Destination path.
--- @return boolean success, string detail Human-readable result.
--- Writes `content` directly to `dst`, creating parent directories if needed.
--- Two strategies: direct write (S1), then mkdir + retry (S2).
--- @param content string The string content to write.
--- @param dst string Absolute destination path.
--- @param expected_source table|nil Exact source snapshot for derived content;
---        nil only when `content` is independent of the destination's old bytes.
--- @return boolean, string ok, detail.
function M.deploy_string(content, dst, expected_source)
	Logger.trace(LOG, "Deploy: writing %d byte(s) → '%s'…", #content, dst)

	local parent = dst:match("^(.*)/[^/]+$")
	local conditional = type(expected_source) == "table"
	local writer = conditional and FileSystem.write_if_unchanged or FileSystem.write
	if type(writer) ~= "function" then
		local detail = conditional
			and "conditional filesystem writer is unavailable"
			or "filesystem writer is unavailable"
		Logger.error(LOG, "Deploy aborted — %s.", detail)
		return false, detail
	end
	local function publish_once()
		if conditional then return writer(dst, content, expected_source) end
		return writer(dst, content)
	end

	-- S1: direct write via port FileSystem — works for regular paths and symlinks
	local written, write_detail = publish_once()
	if written == true then
		Logger.done(LOG, "Deploy S1 (direct write) succeeded: '%s'.", dst)
		return true, "ok"
	end
	if conditional then
		local detail = tostring(write_detail or "source changed before publication")
		Logger.error(LOG, "Deploy aborted — conditional publication refused for '%s': %s.", dst, detail)
		return false, detail
	end
	Logger.debug(LOG, "Deploy S1 failed — destination not directly writable: '%s'.", dst)

	-- S2: parent directory may not exist yet — create it then retry
	if parent then
		local mkdir_out, _, _, mkdir_rc = hs.execute(
			string.format("/bin/mkdir -p '%s' 2>&1", parent:gsub("'", "'\\''"))
		)
		Logger.debug(LOG, "Deploy S2 mkdir -p rc=%s: %s",
			tostring(mkdir_rc), (mkdir_out or ""):gsub("%s+$", ""))
		if publish_once() == true then
			Logger.done(LOG, "Deploy S2 (mkdir + write) succeeded: '%s'.", dst)
			return true, "ok"
		end
		Logger.debug(LOG, "Deploy S2 failed — still not writable after mkdir: '%s'.", dst)
	end

	-- Both strategies exhausted — surface a clear error with actionable context.
	-- Common causes: Finder alias (convert to Unix symlink), permission denied,
	-- or Karabiner config directory living at an unexpected path.
	local detail = "cannot open destination for writing: " .. dst
	Logger.error(LOG, "Deploy aborted — %s.", detail)
	Logger.error(LOG, "Tip: if '%s' is a Finder alias, replace it with a Unix symlink:", dst)
	Logger.error(LOG, "  ln -sfn /real/karabiner/dir '%s'", parent or dst)
	return false, detail
end

--- Reads `src` then delegates to `deploy_string`. Kept for callers that still
--- have a file path rather than an in-memory string.
--- @param src string Absolute source path.
--- @param dst string Absolute destination path.
--- @return boolean, string ok, detail.
function M.deploy_file(src, dst)
	Logger.trace(LOG, "Deploy: '%s' → '%s'…", src, dst)

	local content = FileSystem.read(src)
	if not content then
		Logger.error(LOG, "Deploy aborted — source not readable: '%s'.", src)
		return false, "source file not found: " .. src
	end
	Logger.debug(LOG, "Deploy: read %d byte(s) from source.", #content)

	return M.deploy_string(content, dst, nil)
end

--- Exposes the resolved KC physical log path so karabiner/init can create
--- the parent directory at deploy time (not at module load time).
M.KE_PHYSICAL_KC_LOG = KE_PHYSICAL_KC_LOG

return M
