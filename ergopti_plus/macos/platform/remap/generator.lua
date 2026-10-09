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
--- 3. One Rule Per Key: a tap/hold key has a single manipulator, whatever else
---    is held. Its hold sends the hold action at key_down and its tap stays a
---    tap, so a one-shot (sticky_X) tapped under a held modifier still arms;
---    nothing gated on another held key may take the press before it.
--- 4. Mode-Gated Merge: every manipulator carries one generation mode and one
---    irreversible revocation condition; regeneration replaces only exact
---    managed rule tags while preserving personal rules, parameters, profiles,
---    devices, mappings, virtual HID settings, and global Karabiner preferences.
--- 5. Exact-Modifier Triggers: an action marked `exact_modifiers` in
---    actions.json is a Hammerspoon trigger told apart only by its modifiers,
---    so every rule sending one claims and lifts all held modifiers but Caps
---    Lock around it (exact_modifier_manipulators), and a hold on the same key
---    keeps them.
--- ==============================================================================

local M = {}

local hs         = hs
local Logger     = require("infra.logger")
local Keycodes   = require("infra.keycodes")
local FileSystem = require("adapters.file_system")
local JsonCodec  = require("adapters.json_codec")
local LeaseContract = require("platform.remap.lease_contract")
local LegacyReleaseFixtures = require("platform.remap.legacy_release_fixtures")
local ActionCatalogue = require("platform.remap.action_catalogue")
local ControlSignals = require("keymap.control_signals")
local NavLayer = require("platform.remap.nav_layer")
local ScriptChordRules = require("platform.remap.script_chord_rules")
local Defaults = require("platform.remap.defaults")

local LOG = "karabiner"

-- The ownership marker is part of the pure lease contract: the integration
-- switch removes exactly the rules that carry it, so there is one parser.
local MANAGED_MODE_NORMAL    = LeaseContract.MANAGED_MODE_NORMAL
local MANAGED_MODE_PAUSE     = LeaseContract.MANAGED_MODE_PAUSE
local managed_description_prefix = LeaseContract.managed_description_prefix
local parse_managed_description  = LeaseContract.parse_managed_description

local LEGACY_PARAMETER_TAP = "basic.to_if_alone_timeout_milliseconds"
local LEGACY_PARAMETER_SIMULTANEOUS = "basic.simultaneous_threshold_milliseconds"

-- Always-on rule files loaded in order after CapsWord (which is loaded first
-- separately to guarantee the highest priority in the KE rule engine) and after
-- the navigation layer, which platform/remap/nav_layer.lua generates.
local ALWAYS_ON_RULES = {
	"combos.json",      -- 2-letter combo mappings (e.g. Esc on R Cmd + R Ctrl)
}

-- The navigation layer every release up to the generated one appended verbatim.
-- It is no longer deployed: it is the anchor that proves an older, unleased
-- ErgoptiPlus block in karabiner.json, which the legacy migration then removes.
local LEGACY_LAYER_KEYS_FILE = "legacy_layer_keys.json"

-- The kind of merge refusal the user can resolve from the app: untagged rules
-- carrying a historical ErgoptiPlus signature that no released block proves.
M.REFUSAL_LEGACY_CONFLICTS = "legacy_conflicts"

-- The eight modifier keys: Shift, Control, Option and Command on each side.
local ACTUAL_MODIFIER_KEY_CODES = {
	left_option  = true, right_option  = true,
	left_command = true, right_command = true,
	left_control = true, right_control = true,
	left_shift   = true, right_shift   = true,
}

-- Key codes a `to` entry counts as a modifier key: every one that raises a
-- flag, fn included (Karabiner's momentary_switch_event make_modifier_flag).
-- from.modifiers accepts each of them, fn too, and consumes it when mandatory.
-- Caps Lock is a lock, not one of them.
local FLAG_KEY_CODES = { fn = true }
for key_code in pairs(ACTUAL_MODIFIER_KEY_CODES) do FLAG_KEY_CODES[key_code] = true end

-- Karabiner's wildcard modifier name. In `optional` it lets any held modifier
-- through; in `mandatory` it matches every state and claims every pressed flag,
-- Caps Lock included, so Karabiner lifts them all around the rule's output.
local ANY_MODIFIER = "any"

-- Karabiner's name for the Caps Lock flag. modifier_flag_manager reports it
-- pressed while the lock is on, and lifting a claimed Caps Lock posts Caps Lock
-- key presses to macOS (base.hpp make_lazy_modifier_key_event, then
-- key_event_dispatcher), toggling the lock around the rule.
local CAPS_LOCK_MODIFIER = "caps_lock"

-- Every other flag a hand can hold, each claimed by a manipulator of its own
-- (see exact_modifier_manipulators), so no rule has to claim Caps Lock.
local HAND_MODIFIER_FLAGS = {
	"left_shift", "right_shift", "left_control", "right_control",
	"left_option", "right_option", "left_command", "right_command", "fn",
}

-- Trailing `to` entry Karabiner never posts: its condition is always false.
-- Its only effect is to make the unfiltered list end with a non-modifier key.
local NEVER_POSTED_KEY_CODE   = "vk_none"
local NEVER_POSTED_EXPRESSION = "0"

-- Physical key and sentinel outputs of the three historical script-control
-- rules (Return, Backspace, Escape), which the legacy graph proof below
-- reconstructs. The rules deployed now are the shared script chords of
-- platform/remap/script_chord_rules.lua, the Delete slot included.
local SCRIPT_CONTROL_HOLDER_KEY     = ScriptChordRules.HOLDER_KEY
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
local LAYER_ACTIVE_OFF_VALUE   = 0
local LAYER_NAV_SENTINEL_NAME  = Keycodes.to_name(Keycodes.F20_LAYER_NAV_ENTERED)
-- Its pair, emitted by every event list that turns the layer off, so
-- Hammerspoon knows when the layer is no longer held: it runs the layer's
-- wheel bindings, which Karabiner cannot take, only in between.
local LAYER_EXIT_SENTINEL_NAME = Keycodes.to_name(Keycodes.F19_LAYER_NAV_EXITED)

-- The tap-hold keys the navigation layer swallows while another key holds it,
-- by key id, with the tap that makes them so (their hold being the layer):
-- left Command tapping Backspace, the twin of Windows' LAlt (nav_layer.ahk,
-- "Fix when LAlt triggers the layer") and Linux's. Passed through, it is a
-- Command under every chord of the layer (J gives Cmd+Left).
local SWALLOWED_ON_LAYER = { left_command = { tap = "backspace" } }

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
	-- The rules built from this data are edited in place (generation gate,
	-- timings): the codec's tree gives each manipulator its own tables.
	local data, decode_err = JsonCodec.decode(raw)
	if type(data) ~= "table" then
		Logger.error(LOG, "Cannot decode JSON from '%s': %s.", path, tostring(decode_err or data))
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
--- leave a partially gated configuration in the caller's table. A rule,
--- manipulator or conditions list reached twice would take the gate twice
--- (hs.json.decode shares equal JSON values, see adapters/json_codec.lua):
--- it is refused here, where the graph is built, instead of deploying a
--- manipulator with duplicated gates.
--- @param rules table Independently owned raw rule graph.
--- @return boolean|nil valid Identity and shape validation receipt.
--- @return string|nil error_message Validation failure.
local function validate_managed_rule_graph(rules)
	if not is_dense_array(rules) then return nil, "managed rules must be a dense array" end

	local gated = {}
	for rule_index, rule in ipairs(rules) do
		if type(rule) ~= "table" then
			return nil, string.format("managed rule %d must be a table", rule_index)
		end
		if gated[rule] then
			return nil, string.format("managed rule %d is the same table as an earlier rule", rule_index)
		end
		gated[rule] = true
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
			if gated[manipulator] or (manipulator.conditions ~= nil and gated[manipulator.conditions]) then
				return nil, string.format(
					"managed rule %d manipulator %d shares a table with an earlier manipulator",
					rule_index,
					manipulator_index
				)
			end
			gated[manipulator] = true
			if manipulator.conditions ~= nil then gated[manipulator.conditions] = true end
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
	return true
end

--- Applies the exact lease after the raw graph has passed identity validation.
--- @param rules table Independently owned rule graph.
--- @param token string Canonical lease token.
--- @param mode string Normal or paused mode.
--- @return table|nil rules
--- @return string|nil error_message
local function gate_managed_rules(rules, token, mode)
	if not LeaseContract.is_valid_token(token) then
		return nil, LeaseContract.invalid_token_error(token)
	end
	if mode ~= MANAGED_MODE_NORMAL and mode ~= MANAGED_MODE_PAUSE then
		return nil, "managed rule mode must be 'normal' or 'pause'"
	end
	local valid, validation_err = validate_managed_rule_graph(rules)
	if not valid then return nil, validation_err end
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
			-- Timer callbacks outlive the original match. They must consult live
			-- authority before starting a hold after pause, revocation or shutdown.
			for _, event in ipairs(manipulator.to_if_held_down or {}) do
				event.conditions = event.conditions or {}
				event.conditions[#event.conditions + 1] = { type = "variable_if", name = mode_name, value = mode_value }
				event.conditions[#event.conditions + 1] = { type = "variable_if", name = revoked_name, value = 0 }
			end
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
--- The simultaneous threshold is one user-visible global for every managed rule;
--- only personal rules outside this generated graph retain a local threshold.
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
					if manipulator.to_if_held_down and manipulator.to_delayed_action then
						local threshold = manipulator.parameters["basic.to_if_alone_timeout_milliseconds"]
						manipulator.parameters["basic.to_if_held_down_threshold_milliseconds"] = threshold
						manipulator.parameters["basic.to_delayed_action_delay_milliseconds"] = threshold
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

--- Returns true when an event sets layer_active to its "off" value.
--- @param ev table A karabiner event entry.
--- @return boolean
local function is_layer_deactivation_event(ev)
	if type(ev) ~= "table" or type(ev.set_variable) ~= "table" then return false end
	return ev.set_variable.name  == LAYER_ACTIVE_VAR_NAME
	   and ev.set_variable.value == LAYER_ACTIVE_OFF_VALUE
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

--- Mutates the available_actions list so every event list that turns the
--- navigation layer off (a hold's karabiner_to_after_key_up, an explicit layer
--- off's karabiner_to) emits the F19 exit sentinel right before the variable,
--- as F20 precedes the one that turns it on. Karabiner holds only the last
--- entry of a `to` list until the key is released: the sentinel is never that
--- entry, so it is tapped, and an action that kept nothing down still keeps
--- nothing down.
---
--- Idempotent: a deactivation already preceded by the sentinel is left alone.
--- @param available_actions table List of action definitions (mutated in place).
local function insert_nav_layer_exit_sentinel(available_actions)
	local patched = 0
	for _, action in ipairs(available_actions) do
		for _, field in ipairs({ "karabiner_to", "karabiner_to_after_key_up" }) do
			local events = action[field]
			local index = nil
			if type(events) == "table" then
				for i, ev in ipairs(events) do
					if index == nil and is_layer_deactivation_event(ev) then index = i end
				end
			end
			local previous = index and events[index - 1] or nil
			if index and not (type(previous) == "table" and previous.key_code == LAYER_EXIT_SENTINEL_NAME) then
				table.insert(events, index, { key_code = LAYER_EXIT_SENTINEL_NAME })
				patched = patched + 1
			end
		end
	end
	if patched > 0 then
		Logger.info(LOG, "Inserted the F19 exit sentinel into %d nav-layer-deactivating event list(s).", patched)
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

--- Removes, in place, every F19 exit sentinel event from a rule graph copy:
--- releases before the sentinel deployed the same graph without it, and the
--- legacy compatibility graph must be theirs exactly.
--- @param value table A deep copy of generated rules.
local function strip_exit_sentinels(value)
	if type(value) ~= "table" then return end
	local count = #value
	if count > 0 then
		local kept = {}
		for index = 1, count do
			local item = value[index]
			if not (type(item) == "table" and item.key_code == LAYER_EXIT_SENTINEL_NAME) then
				kept[#kept + 1] = item
			end
			value[index] = nil
		end
		for index, item in ipairs(kept) do value[index] = item end
	end
	for _, nested in pairs(value) do strip_exit_sentinels(nested) end
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

--- Quotes one value for a POSIX shell command.
--- @param value any Value to quote.
--- @return string quoted Single-quoted shell token.
local function sq(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Builds one physical-key ledger event for the Hammerspoon bridge.
--- A fresh table is returned for every manipulator so Karabiner rule graphs do
--- not retain aliases while press and release ownership remain symmetrical.
--- @param key_code string Physical Karabiner key code.
--- @param release boolean Whether to emit the U: release marker.
--- @return table event Karabiner shell_command event.
local function physical_kc_ledger_event(key_code, release)
	local payload = release and ("U:" .. tostring(key_code)) or tostring(key_code)
	return {
		shell_command = string.format(
			"echo %s >> %s",
			sq(payload),
			sq(KE_PHYSICAL_KC_LOG)
		),
	}
end

--- Reports whether any given action is told apart from another only by its
--- modifiers (actions.json `exact_modifiers`): Hammerspoon binds its trigger
--- as an exact-match hotkey, so one added modifier runs another action.
--- @param ... table Resolved action definitions.
--- @return boolean exact Whether one of them is such an action.
local function has_exact_modifier_action(...)
	for index = 1, select("#", ...) do
		local action = select(index, ...)
		if type(action) == "table" and action.exact_modifiers == true then return true end
	end
	return false
end

--- Reports whether a `from.modifiers` lets any held modifier through.
--- @param modifiers table|nil Karabiner from.modifiers.
--- @return boolean open Whether `optional` contains "any".
local function accepts_any_held_modifier(modifiers)
	for _, name in ipairs(type(modifiers) == "table" and modifiers.optional or {}) do
		if name == ANY_MODIFIER then return true end
	end
	return false
end

--- Returns the manipulators that replace one whose output is a trigger
--- Hammerspoon tells apart only by its modifiers, removing every modifier the
--- hand holds from that output.
---
--- Karabiner v16 sends a tap with the modifiers held at key_down, so a held
--- Shift turned bare F17 (cycle_windows_in_app) into Shift+F17
--- (alt_tab_windows). A mandatory modifier is claimed, and basic.hpp lifts the
--- claimed flags around `to`, to_if_alone and to_after_key_up, so the trigger
--- goes out with its own modifiers only. A mandatory "any" would claim every
--- pressed flag, Caps Lock included while the lock is on, and lifting Caps Lock
--- toggles it for macOS around every such rule. The rule therefore becomes one
--- manipulator per held hand flag (mandatory that flag, optional Caps Lock),
--- one for no held flag, and a mandatory "any" last for two flags or more, the
--- only case left that still claims Caps Lock while it is on. Each keeps the
--- flags the rule already claimed (a combo consuming its holder's AltGr).
---
--- basic.hpp presses the lifted flags again right after `to` only when the
--- last `to` entry is not a modifier key (event_sender.hpp
--- is_last_to_event_modifier_key_event), but only the last posted entry stays
--- held. A hold sending a modifier would thus lose the hand's modifiers until
--- release: Shift, then a key holding Cmd, then Z would type Cmd+Z. A trailing
--- entry whose condition never holds settles both: filter_and_replace_events
--- drops it before posting, so the modifier stays held, while the check reads
--- the unfiltered list and the hand's modifiers come back at once.
---
--- A rule whose `from` already claims a modifier keeps it lifted through the
--- hold by design and gets no trailer; the hand's other modifiers are lifted
--- with it. A rule that lets only Caps Lock through never sees another held
--- modifier and is left as is. Karabiner lifts one press per claimed flag, so
--- a flag two held keys both press (CapsLock and Fn both holding Cmd) stays
--- down once: no rule can remove it.
--- @param manipulator table Manipulator; never mutated.
--- @return table manipulators Replacement list, in match order.
local function exact_modifier_manipulators(manipulator)
	local from = manipulator.from
	if not accepts_any_held_modifier(from.modifiers) then return { manipulator } end
	local own = type(from.modifiers.mandatory) == "table" and from.modifiers.mandatory or {}

	--- Preserves hand modifiers after either immediate or timed hold output.
	--- @param events table|nil To-event list.
	--- @return table|nil output
	local function with_restore_trailer(events)
		local last = type(events) == "table" and events[#events] or nil
		if #own ~= 0 or type(last) ~= "table" or not FLAG_KEY_CODES[last.key_code] then return events end
		local extended = deep_copy(events)
		extended[#extended + 1] = {
			key_code   = NEVER_POSTED_KEY_CODE,
			conditions = { { type = "expression_if", expression = NEVER_POSTED_EXPRESSION } },
		}
		return extended
	end
	local to = with_restore_trailer(manipulator.to)
	local held = with_restore_trailer(manipulator.to_if_held_down)

	--- Builds one variant whose `from` requires the given modifiers.
	--- @param modifiers table Karabiner from.modifiers.
	--- @return table variant Fresh manipulator sharing no table with the others.
	local function variant(modifiers)
		local copy = deep_copy(manipulator)
		copy.from.modifiers = modifiers
		copy.to = deep_copy(to)
		copy.to_if_held_down = deep_copy(held)
		return copy
	end

	local owned = {}
	for _, name in ipairs(own) do owned[name] = true end
	local variants = {
		variant({ mandatory = #own > 0 and deep_copy(own) or nil, optional = { CAPS_LOCK_MODIFIER } }),
	}
	for _, flag in ipairs(HAND_MODIFIER_FLAGS) do
		if not owned[flag] then
			local mandatory = deep_copy(own)
			mandatory[#mandatory + 1] = flag
			variants[#variants + 1] = variant({ mandatory = mandatory, optional = { CAPS_LOCK_MODIFIER } })
		end
	end
	variants[#variants + 1] = variant({ mandatory = { ANY_MODIFIER } })
	return variants
end





-- ========================================
-- ========================================
-- ======= 2/ Tap/Hold Rule Builder =======
-- ========================================
-- ========================================

--- Rewrites deployed control output after historical migration snapshots exist.
--- The simple sticky Shift payload becomes a tagged F20; compound stickies keep
--- their native semantics. All F20 emitters claim hand modifiers so navigation
--- can never inherit the one-shot tag from keys the user happens to hold.
--- @param rules table Owned production rule graph.
local function rewrite_control_output(rules)
	local function rewrite(value)
		-- Capture historical graphs above this boundary. Only the deployed graph
		-- notifies the current watcher, before each variable edge and before the
		-- last held key; exact hand-modifier variants keep tags unambiguous.
		local index = 1
		while index <= #value do
			local event = value[index]
			local variable = type(event) == "table" and event.set_variable or nil
			if type(variable) == "table" and variable.name == "capsword"
				and (variable.value == 0 or variable.value == 1) then
				local signal = variable.value == 1 and "capsword_activated" or "capsword_deactivated"
				table.insert(value, index, {
					key_code = LAYER_NAV_SENTINEL_NAME,
					modifiers = ControlSignals.modifiers_for(signal),
					["repeat"] = false,
				})
				index = index + 1
			end
			index = index + 1
		end
		local emits_control = value.key_code == LAYER_NAV_SENTINEL_NAME
		if emits_control then value["repeat"] = false end
		local sticky_index, sticky_count = nil, 0
		for index, event in ipairs(value) do
			if type(event) == "table" and event.sticky_modifier then
				sticky_count = sticky_count + 1
				if deep_equal(event.sticky_modifier, { left_shift = "toggle" }) then sticky_index = index end
			end
		end
		if sticky_count == 1 and sticky_index then
			local replacement = deep_copy(value[sticky_index])
			replacement.sticky_modifier = nil
			replacement.key_code = LAYER_NAV_SENTINEL_NAME
			replacement.modifiers = ControlSignals.one_shot_modifiers()
			value[sticky_index] = replacement
		end
		for _, nested in pairs(value) do
			if type(nested) == "table" and rewrite(nested) then emits_control = true end
		end
		return emits_control
	end
	for _, rule in ipairs(rules) do
		local manipulators = {}
		for _, manipulator in ipairs(rule.manipulators or {}) do
			local prepared = deep_copy(manipulator)
			local variants = rewrite(prepared) and exact_modifier_manipulators(prepared) or { manipulator }
			for _, variant in ipairs(variants) do manipulators[#manipulators + 1] = variant end
		end
		rule.manipulators = manipulators
	end
end

local NATIVE_TAP_ONLY_KEYS = {
	left_shift = true, left_control = true, right_shift = true, right_command = true, fn = true,
}

--- Keeps native modifier chords available when only their tap is configured.
--- @param key_code string Physical key.
--- @param tap_action table Configured tap.
--- @param hold_action table Configured hold, never mutated.
--- @return table effective_hold Runtime hold with the original configuration identity.
local function native_tap_only_hold(key_code, tap_action, hold_action)
	if NATIVE_TAP_ONLY_KEYS[key_code] and #(tap_action.karabiner_to or {}) > 0
		and #(hold_action.karabiner_to or {}) == 0 then
		return { id = hold_action.id, label = hold_action.label, karabiner_to = { { key_code = key_code } } }
	end
	return hold_action
end

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
--- Priority variants suppress only taps explicitly blocked by the Windows
--- contract. Their hold and physical tracking still follow the normal rule.
--- @param key_def table Entry from TAP_HOLD_KEYS.
--- @param tap_action table Resolved action definition for the tap slot.
--- @param hold_action table Resolved action definition for the hold slot.
--- @param tap_timeout_ms number|nil Per-key tap/hold threshold override in ms; nil inherits the global.
--- @param typing_priority boolean|nil False only when reconstructing historical rules.
--- @return table Karabiner rule object.
local function build_tap_hold_rule(key_def, tap_action, hold_action, tap_timeout_ms, typing_priority)
	hold_action = native_tap_only_hold(key_def.from.key_code, tap_action, hold_action)
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

	-- Append the physical key_code name to the bridge log on every key_down so
	-- Hammerspoon can credit the correct physical key in the heatmap instead of
	-- the remapped output key that the event tap would otherwise observe.
	to_events[#to_events + 1] = physical_kc_ledger_event(key_code, false)

	-- Append a release marker on key_up so the bridge can compute the hold
	-- duration and split kc_hold counts into tap (≤ HOLD_THRESHOLD_MS) and
	-- hold (> threshold). Format: "U:<key_code>" — the "U:" prefix is the
	-- bridge's discriminator; bare "<key_code>" lines remain press events.
	after_key_up_tail[#after_key_up_tail + 1] = physical_kc_ledger_event(key_code, true)

	-- A key with a tap and no hold has nothing to wait for: it sends its tap at
	-- key_down, where the last entry stays held and auto-repeats, like the
	-- native key it replaces and like the Windows tap-only hotkeys. As a
	-- to_if_alone it would type only on a release inside the tap timeout, and
	-- any key_down arriving first would drop it (basic.hpp unset_alone_if_needed),
	-- losing keys in fast typing. It never sends the physical key as well, which
	-- typed two keys for one tap. A "none" tap under a hold stays the native key,
	-- typed on release.
	local key_down_action = hold_action
	local rollover_hold_var
	if #hold_to == 0 then
		key_down_action = tap_action
		for _, ev in ipairs(tap_to) do to_events[#to_events + 1] = ev end
	elseif typing_priority ~= false and Defaults.rollover_keys[key_def.id] and
		same_output((#tap_to > 0) and tap_to or { { key_code = key_code } }, { { key_code = key_code } })
		and not same_output(tap_to, hold_to) then
		-- Karabiner cancels both timers at the next key-down. The canceled
		-- branch emits the native tap first; a slow isolated hold still works.
		rollover_hold_var = var_name .. "_rollover_hold"
		to_events[#to_events + 1] = set_var_event(rollover_hold_var, 0)
		local native_tap = { { key_code = key_code } }
		manipulator.to_if_alone = native_tap
		manipulator.to_delayed_action = { to_if_canceled = native_tap }
		manipulator.to_if_held_down = { set_var_event(rollover_hold_var, 1) }
		for _, ev in ipairs(hold_to) do
			manipulator.to_if_held_down[#manipulator.to_if_held_down + 1] = deep_copy(ev)
		end
	else
		for _, ev in ipairs(hold_to) do to_events[#to_events + 1] = ev end
		local effective_tap_to = (#tap_to > 0) and tap_to or { { key_code = key_code } }
		-- to_if_alone only when tap output differs from hold output
		if not same_output(effective_tap_to, hold_to) then
			manipulator.to_if_alone = effective_tap_to
		end
	end
	manipulator.to = to_events

	-- A key whose hold is the navigation layer stands down while the layer is
	-- on, as every driver's does: pressed while another key holds the layer,
	-- the layer's own mapping takes it (layer_keys.json runs before this rule),
	-- the swallower below takes a key in SWALLOWED_ON_LAYER, and any other key
	-- matches no rule, so macOS types it and repeats it. Matching here held the
	-- layer a second time, typed the tap only on a quick release, and its
	-- release switched the layer off under the key still holding it.
	local swallower
	if activates_nav_layer(hold_to) then
		manipulator.conditions = {
			{ type = "variable_unless", name = LAYER_ACTIVE_VAR_NAME, value = LAYER_ACTIVE_ON_VALUE },
		}
		local swallowed = SWALLOWED_ON_LAYER[key_def.id]
		if swallowed and tap_action.id == swallowed.tap then
			-- Only the physical press is recorded, for the heatmap: nothing is
			-- held, typed or tracked as held, and Karabiner routes the release to
			-- this manipulator too.
			swallower = {
				type            = "basic",
				from            = deep_copy(key_def.from),
				conditions      = {
					{ type = "variable_if", name = LAYER_ACTIVE_VAR_NAME, value = LAYER_ACTIVE_ON_VALUE },
				},
				to              = { physical_kc_ledger_event(key_code, false) },
				to_after_key_up = { physical_kc_ledger_event(key_code, true) },
			}
		end
	end

	-- Per-key tap/hold threshold override. Karabiner honours
	-- basic.to_if_alone_timeout_milliseconds at the manipulator level, overriding
	-- the complex_modifications global. nil/0 inherits the single global value, so
	-- there is no duplicated per-key literal when the user has not customised it.
	if tap_timeout_ms and tap_timeout_ms > 0 then
		manipulator.parameters = { ["basic.to_if_alone_timeout_milliseconds"] = tap_timeout_ms }
	end

	-- Merge the key-down action's own to_after_key_up (e.g. layer release) with
	-- set_variable=0
	if key_down_action.karabiner_to_after_key_up then
		for _, ev in ipairs(key_down_action.karabiner_to_after_key_up) do
			local release = deep_copy(ev)
			if rollover_hold_var then
				release.conditions = release.conditions or {}
				release.conditions[#release.conditions + 1] = {
					type = "variable_if", name = rollover_hold_var, value = 1,
				}
			end
			after_key_up_tail[#after_key_up_tail + 1] = release
		end
	end
	if rollover_hold_var then after_key_up_tail[#after_key_up_tail + 1] = set_var_event(rollover_hold_var, 0) end
	manipulator.to_after_key_up = after_key_up_tail
	local manipulators = { manipulator }
	if has_exact_modifier_action(tap_action, hold_action) then
		manipulators = exact_modifier_manipulators(manipulator)
	end
	-- Fn is the Windows left-Control position (Paste); the macOS Control
	-- key has its own Cut action and must not inherit these thumb blockers.
	if key_code == "fn" and manipulator.to_if_alone then
		local blocked = {}
		for _, blocker in ipairs({ "caps_lock", "left_command" }) do
			for _, variant in ipairs(manipulators) do
				local copy = deep_copy(variant)
				copy.to_if_alone = nil
				copy.conditions = copy.conditions or {}
				copy.conditions[#copy.conditions + 1] = {
					type = "variable_if", name = held_var_name(blocker), value = 1,
				}
				blocked[#blocked + 1] = copy
			end
		end
		for _, variant in ipairs(manipulators) do blocked[#blocked + 1] = variant end
		manipulators = blocked
	end
	if swallower then table.insert(manipulators, 1, swallower) end

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

--- Returns the events a tap/hold key's own rule keeps down, without typing,
--- while the key is held: its hold, or the key itself for a modifier key with
--- neither slot, which its passthrough rule presses. A key whose rule types at
--- key_down (its tap, or a native non-modifier key) keeps nothing down.
--- @param key_code string Physical key.
--- @param tap_action table Resolved action for the key's tap slot.
--- @param hold_action table Resolved action for the key's hold slot.
--- @return table events `to` events kept down, possibly empty.
local function held_key_events(key_code, tap_action, hold_action)
	local hold_to = hold_action.karabiner_to or {}
	if #hold_to > 0 then return hold_to end
	if #(tap_action.karabiner_to or {}) == 0 and FLAG_KEY_CODES[key_code] then
		return { { key_code = key_code } }
	end
	return {}
end

--- Builds the variable-based rule for the tap / hold slots of a combo.
--- Matches k2 physically while k1 is held (via ke_held_k1=1) and splits
--- output by press duration (to_if_alone for tap, to for hold).
---
--- When only the tap slot is set, it fires at k2's key_down, as the tap of a
--- key with no hold does (build_tap_hold_rule): there is nothing to wait for,
--- it repeats while k2 is held, and no later key_down can drop it, as Karabiner
--- v16 drops a pending to_if_alone (basic.hpp unset_alone_if_needed). A
--- modifier held before k2, k1's included, would not cancel a to_if_alone:
--- that source clears it only for a key_down arriving after k2's, and restores
--- the key-down flags around it.
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
		-- Tap only: nothing to wait for, so it fires at key_down and repeats
		manip.to = tap_to
	end

	-- A chord whose action keeps a key down leaves k1 held without its held
	-- keys (build_chord_manipulator), and a manipulator requiring them would let
	-- k2 fall through to its own rule. The same manipulator without them takes
	-- that press: with nothing of k1's down, there is nothing to consume. The
	-- last exact-modifier variant, a mandatory "any", already matches then.
	local manipulators = { manip }
	if has_exact_modifier_action(tap_action, hold_action) then
		manipulators = exact_modifier_manipulators(manip)
	elseif k1_mandatory and #k1_mandatory > 0 then
		local unheld = deep_copy(manip)
		unheld.from.modifiers = { optional = { "any" } }
		manipulators[#manipulators + 1] = unheld
	end

	return {
		description  = string.format(
			"%s (%s→%s): %s (tap) / %s (hold) [var-based]",
			combo_def.label, k1, k2, tap_action.label, hold_action.label
		),
		manipulators = manipulators,
	}
end



-- ================================
-- ===== 3.2) Chord Slot Rule =====
-- ================================

--- Returns the simultaneous_options a chord rule starts from: a copy of the
--- combo's own, without key_down_order in symmetric mode so A+B and B+A both
--- match.
--- @param combo_def table Entry from MOD_COMBOS.
--- @param combo_symmetric boolean Whether A+B == B+A for this config.
--- @return table options Fresh table the caller may extend.
local function chord_simultaneous_options(combo_def, combo_symmetric)
	local options = {}
	for k, v in pairs(combo_def.from.simultaneous_options or {}) do
		if not (combo_symmetric and k == "key_down_order") then options[k] = v end
	end
	return options
end

-- Karabiner's simultaneous key_down_order values that fix which chord key goes
-- down first: `strict` the listed order, `strict_inverse` the reverse one
-- (from_event_definition.hpp test_key_order).
local KEY_ORDER_STRICT         = "strict"
local KEY_ORDER_STRICT_INVERSE = "strict_inverse"

--- Returns the state a tap/hold key's own rule gives the key while it is
--- held: the events it keeps down (held_key_events), the events its key_up
--- sends to undo them, and whether the key has a hold.
--- @param key_code string Physical key.
--- @param tap_action table Resolved action for the key's tap slot.
--- @param hold_action table Resolved action for the key's hold slot.
--- @return table held { to = events at key_down, after = events at key_up, has_hold = boolean }
local function held_key_state(key_code, tap_action, hold_action)
	hold_action = native_tap_only_hold(key_code, tap_action, hold_action)
	local has_hold = #(hold_action.karabiner_to or {}) > 0
	return {
		to       = held_key_events(key_code, tap_action, hold_action),
		after    = has_hold and hold_action.karabiner_to_after_key_up or {},
		has_hold = has_hold,
	}
end

-- A key without a tap/hold rule keeps nothing down when pressed.
local NOTHING_HELD = { to = {}, after = {}, has_hold = false }

--- Reports whether a `to` list leaves a key down: Karabiner keeps only the last
--- posted entry down, and only when it is a key.
--- @param events table To-event list.
--- @return boolean keeps
local function keeps_key_down(events)
	local last = events[#events]
	return type(last) == "table" and last.key_code ~= nil
end

--- Builds the chord manipulator for one press order of a modifier combo.
---
--- The chord takes the key_down of both keys, so the own tap/hold rule of the
--- key pressed first never runs for that press. While that key stays down, it
--- must still read as held: the manipulator sets its held variable, which the
--- hold-then-tap rules starting on it test, and sends its hold's momentary
--- events (a layer). simultaneous_options.to_after_key_up undoes both once
--- both keys are up, so releasing the first key while the other stays down
--- leaves them on until that one is released too.
---
--- Karabiner keeps only the last `to` entry down. When the first key keeps
--- nothing down (no hold, or a layer), the chord's action takes that place,
--- so a key repeats and a modifier stays held while the chord is held. When
--- the action keeps nothing down, the first key's held key (its modifier
--- hold, or itself as a bare modifier key) goes last, and key_up_when "all"
--- keeps it down until that key is released too. When both keep a key down:
---   - a modifier action (Cmd+Shift) stays held; pressed once, it would do
---     nothing;
---   - a plain-key action after one of the eight modifier keys goes out once,
---     and that key stays the modifier it is held for, its held key last under
---     key_up_when "all", as when it is held first;
---   - a plain-key action after any other key (Escape, Tab, Caps Lock, fn,
---     Space, Return, Backspace) stays down and repeats, as those chords did
---     before chords of modifier keys could fire.
--- In the last two cases the first key's held key comes back only with its
--- next press; until then its held variable alone marks it held, which the
--- hold-then-tap rules starting on it still answer (build_tap_hold_combo_rule).
--- @param combo_def table Entry from MOD_COMBOS.
--- @param combo_to table Combo (chord) output events.
--- @param combo_action table Combo action definition.
--- @param options table simultaneous_options of this order; extended here.
--- @param first_key string Key this order presses first.
--- @param first_held table held_key_state of first_key.
--- @return table manipulator
local function build_chord_manipulator(combo_def, combo_to, combo_action, options, first_key, first_held)
	local to = { set_var_event(held_var_name(first_key), 1) }
	local action_last = combo_to[#combo_to]
	local action_is_modifier = keeps_key_down(combo_to) and FLAG_KEY_CODES[action_last.key_code] == true
	if not keeps_key_down(first_held.to) then
		for _, ev in ipairs(first_held.to) do to[#to + 1] = ev end
		for _, ev in ipairs(combo_to) do to[#to + 1] = ev end
	elseif not keeps_key_down(combo_to)
		or (ACTUAL_MODIFIER_KEY_CODES[first_key] and not action_is_modifier) then
		for _, ev in ipairs(combo_to) do to[#to + 1] = ev end
		for _, ev in ipairs(first_held.to) do to[#to + 1] = ev end
		options.key_up_when = "all"
	else
		for _, ev in ipairs(first_held.to) do
			if ev.key_code == nil then to[#to + 1] = ev end
		end
		for _, ev in ipairs(combo_to) do to[#to + 1] = ev end
	end

	local after_both_up = { set_var_event(held_var_name(first_key), 0) }
	for _, ev in ipairs(first_held.after) do after_both_up[#after_both_up + 1] = ev end
	options.to_after_key_up = after_both_up

	-- Shallow-copy the combo's `from` so the shared MOD_COMBOS entry is never
	-- mutated by the adjustments below.
	local from = {}
	for k, v in pairs(combo_def.from) do from[k] = v end
	from.simultaneous_options = options

	-- Karabiner v16 tests a chord's modifiers on its first key's key_down, before
	-- either chord key reaches the output: manipulator_manager.hpp posts a key
	-- only once every manipulator has passed it. The chord's own keys are thus
	-- never among the flags it tests, and never leak into what it sends, so
	-- requiring them as mandatory made every chord of a modifier key unreachable.
	-- `optional: any` lets the chord fire under an unrelated held modifier, as its
	-- tap/hold sibling does; modifiers the combo declares itself are kept.
	local modifiers = { optional = { "any" } }
	if type(from.modifiers) == "table" then
		for k, v in pairs(from.modifiers) do modifiers[k] = v end
		modifiers.optional = { "any" }
	end
	from.modifiers = modifiers

	local manip = { type = "basic", from = from, to = to }
	if combo_action.karabiner_to_after_key_up then
		manip.to_after_key_up = combo_action.karabiner_to_after_key_up
	end
	return manip
end

--- Reports whether holding k1 then tapping k2 already types what a chord
--- pressed k1 first would, so its manipulator would add nothing but its wait:
--- the combo action is the tap slot's action and k1 has a hold, so its own rule
--- types nothing at key_down (a key with no hold types its tap or itself
--- there). The hold-then-tap rule only reads k1 first, so a chord pressed k2
--- first is never redundant. Without the manipulator, pressing k1 no longer
--- waits the simultaneous threshold for a partner.
--- @param tap_action table Resolved action for the tap slot.
--- @param combo_action table Resolved action for the combo slot.
--- @param k1_held table held_key_state of k1.
--- @return boolean redundant
local function chord_is_redundant(tap_action, combo_action, k1_held)
	if tap_action.id == nil or tap_action.id ~= combo_action.id then return false end
	return k1_held.has_hold
end

--- Builds the chord rule for the combo slot of a modifier combo, on KE's
--- simultaneous matcher and the global basic.simultaneous_threshold_milliseconds
--- window. The combo's own key_down_order (strict: k1 first) holds unless
--- symmetric mode strips it; either key may then go first, and the key pressed
--- first is the one left held, so each order gets a manipulator of its own
--- (strict, strict_inverse) restoring that key.
--- @param combo_def table Entry from MOD_COMBOS.
--- @param tap_action table Resolved action for the tap slot.
--- @param combo_action table Combo action definition.
--- @param combo_symmetric boolean Whether A+B == B+A for this config.
--- @param k1 string First key of the combo.
--- @param k2 string Second key of the combo.
--- @param held_of table Key code → held_key_state.
--- @return table|nil Karabiner rule object, or nil when no manipulator is left.
local function build_chord_combo_rule(combo_def, tap_action, combo_action, combo_symmetric, k1, k2, held_of)
	local combo_to = combo_action.karabiner_to or {}
	if #combo_to == 0 then return nil end

	local base = chord_simultaneous_options(combo_def, combo_symmetric)
	local orders = {}
	if base.key_down_order ~= KEY_ORDER_STRICT_INVERSE then
		orders[#orders + 1] = { key_down_order = KEY_ORDER_STRICT, first = k1 }
	end
	if base.key_down_order ~= KEY_ORDER_STRICT then
		orders[#orders + 1] = { key_down_order = KEY_ORDER_STRICT_INVERSE, first = k2 }
	end

	local manipulators = {}
	for _, order in ipairs(orders) do
		local first_held = held_of[order.first] or NOTHING_HELD
		if not (order.first == k1 and chord_is_redundant(tap_action, combo_action, first_held)) then
			local options = deep_copy(base)
			options.key_down_order = order.key_down_order
			local manip = build_chord_manipulator(
				combo_def, combo_to, combo_action, options, order.first, first_held)
			local variants = { manip }
			if has_exact_modifier_action(combo_action) then variants = exact_modifier_manipulators(manip) end
			for _, variant in ipairs(variants) do manipulators[#manipulators + 1] = variant end
		end
	end
	if #manipulators == 0 then return nil end

	return {
		description  = string.format("%s: %s [chord]", combo_def.label, combo_action.label),
		manipulators = manipulators,
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
--- @param held_of table Key code → held_key_state.
--- @return table List of zero, one, or two Karabiner rule objects.
local function build_combo_rules(combo_def, tap_action, hold_action, combo_action, k1_mandatory, combo_symmetric, held_of)
	local tap_to   = tap_action.karabiner_to   or {}
	local hold_to  = hold_action.karabiner_to  or {}

	local sim = combo_def.from and combo_def.from.simultaneous
	local k1  = sim and sim[1] and sim[1].key_code
	local k2  = sim and sim[2] and sim[2].key_code
	if not k1 or not k2 then return {} end

	local rules = {}
	-- Chord rule first: a simultaneous press wins over the hold-then-tap path
	local chord_rule = build_chord_combo_rule(
		combo_def, tap_action, combo_action, combo_symmetric, k1, k2, held_of)
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
--- AltGr+Enter / Backspace / Delete / Escape keep emitting their sentinels
--- (consumed by modules/shortcuts/script_control.lua) while every other remap
--- is off, for the slots whose action is a script-management one: any other
--- slot, like an unassigned one, leaves the chord to the system while paused.
--- While paused the remap layer is OFF, so the user reaches these shortcuts with the
--- REAL option key — option+Enter / option+Backspace / option+Escape. The rules gate
--- ONLY on the side-agnostic real "option" key and deliberately do NOT include a
--- right_command variant: the user does not press the real rcmd while paused, and a
--- right_command+Backspace/Escape rule would shadow native macOS chords (e.g.
--- Cmd+Delete = delete-to-line-start). One rule per slot (F-H6).
--- @param lease_token string Canonical generation token shared with the watchdog.
--- @param script_chords table|nil The script chords' plan (script_chord_rules.lua);
---   nil deploys those of an empty configuration.
--- @return table|nil rules List of managed Karabiner rules (one per paused slot).
--- @return string|nil error_message Validation failure.
function M.build_paused_script_control_rules(lease_token, script_chords)
	if not LeaseContract.is_valid_token(lease_token) then
		local err = LeaseContract.invalid_token_error(lease_token)
		Logger.error(LOG, "Cannot build paused script-control rules: %s.", err)
		return nil, err
	end
	local built, rules = pcall(ScriptChordRules.paused, script_chords)
	if not built then
		local err = "script chords: " .. tostring(rules)
		Logger.error(LOG, "Cannot build paused script-control rules: %s.", err)
		return nil, err
	end
	local managed, err = gate_managed_rules(rules, lease_token, MANAGED_MODE_PAUSE)
	if not managed then Logger.error(LOG, "Cannot gate paused script-control rules: %s.", err) end
	return managed, err
end





-- ==========================================
-- ==========================================
-- ======= 5/ Assembly and Deployment =======
-- ==========================================
-- ==========================================

--- Returns the modifier flags a held key's rule keeps down: each held entry's
--- modifier key and every modifier it carries (Cmd+Shift holds both), fn
--- included.
--- @param held table held_key_state of the key.
--- @return table|nil flags Key codes, nil when the key holds none.
local function held_flag_keys(held)
	local flags = {}
	for _, ev in ipairs(held.to) do
		if ev.key_code and FLAG_KEY_CODES[ev.key_code] then
			flags[#flags + 1] = ev.key_code
			for _, modifier in ipairs(ev.modifiers or {}) do
				if FLAG_KEY_CODES[modifier] then flags[#flags + 1] = modifier end
			end
		end
	end
	if #flags == 0 then return nil end
	return flags
end

--- The key-combination rules of a graph whose Tap-Holds are off, as
--- replacements for the rules built with the Tap-Holds on: every key whose own
--- tap-hold rule is dropped is native again, so the chords restore and the
--- hold slots consume what that native key holds, and a key 1 whose tap or
--- hold slot reads its held variable gets, in place of its dropped rule, one
--- that only tracks that variable and passes the key through.
--- @param combo_builds table { rules, combo_def, k1, tap_action, hold_action, combo_action } per combo.
--- @param dropped_keys table Key code → { rule, key_def } of each tap-hold rule the switch drops.
--- @param key_held_state table Key code → held_key_state of its configured rule.
--- @param none_action table The "none" action.
--- @param combo_symmetric boolean Whether A+B == B+A for this config.
--- @return table replaced Rule → the rules generated in its place (empty to drop it).
local function combination_rules_without_tap_holds(combo_builds, dropped_keys, key_held_state, none_action,
		combo_symmetric)
	local held_of = {}
	for key_code, held in pairs(key_held_state) do held_of[key_code] = held end
	for key_code in pairs(dropped_keys) do
		held_of[key_code] = held_key_state(key_code, none_action, none_action)
	end
	local replaced = {}
	local reads_held_variable = {}
	for _, build in ipairs(combo_builds) do
		local held = build.k1 and held_of[build.k1]
		local rebuilt = build_combo_rules(build.combo_def, build.tap_action, build.hold_action,
			build.combo_action, held and held_flag_keys(held), combo_symmetric, held_of)
		if #build.rules == 0 then
			-- A combo with no rule has neither a tap/hold slot nor a chord its
			-- first key's hold could make redundant: native keys add nothing.
			if #rebuilt > 0 then
				error("combination '" .. tostring(build.combo_def.id) .. "' has rules only with Tap-Holds off")
			end
		else
			replaced[build.rules[1]] = rebuilt
			for index = 2, #build.rules do replaced[build.rules[index]] = {} end
		end
		if build.k1 and (#(build.tap_action.karabiner_to or {}) > 0
				or #(build.hold_action.karabiner_to or {}) > 0) then
			reads_held_variable[build.k1] = true
		end
	end
	for key_code in pairs(reads_held_variable) do
		local own = dropped_keys[key_code]
		if own then
			replaced[own.rule] = { build_tap_hold_rule(own.key_def, none_action, none_action, nil) }
		end
	end
	return replaced
end

--- Whether the key-combination rules are generated for a state.
---
--- The one place that rule lives: `mod_combos_enabled` is the persisted
--- [mod_combos] enabled flag, the only switch the combinations follow, as on
--- Windows (decision of 2026-09-29). Absent, it is on: a file that never set it
--- keeps the combinations it generated with the Tap-Holds on.
--- @param state table Remap state (mod_combos_enabled).
--- @return boolean
function M.key_combinations_enabled(state)
	if type(state) ~= "table" then error("key_combinations_enabled needs a remap state", 2) end
	if type(state.mod_combos_enabled) == "boolean" then return state.mod_combos_enabled end
	if state.mod_combos_enabled ~= nil then
		error("mod_combos_enabled must be a boolean or absent, got " .. type(state.mod_combos_enabled), 2)
	end
	return true
end

--- Assembles the full Karabiner JSON structure from current state.
---
--- Rule priority order (highest → lowest):
---   1. CapsWord (must win against any combo or tap/hold sharing its keys)
---   2. Dynamic modifier combo rules (before the navigation layer)
---   3. Script-control sentinel rules
---   4. The navigation layer (state.nav_layer), then the always-on combos
---   5. Dynamic tap/hold manipulators
---   6. Pause-only script-control rules (mutually exclusive with 1–5)
---
--- @param state table Current module state (_state from init.lua); state.nav_layer
---   is { bindings, registry } from platform/remap/nav_layer.lua, nil for none.
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

	-- Inject the F20 and F19 sentinels into every action that turns the nav
	-- layer on or off BEFORE indexing, so all downstream rule builders
	-- (tap/hold, combo, etc.) inherit them.
	prepend_nav_layer_sentinel(available_actions)
	insert_nav_layer_exit_sentinel(available_actions)

	local action_index, prepared_catalogue_err = ActionCatalogue.index_by_id(available_actions)
	if prepared_catalogue_err then
		Logger.error(LOG, "Cannot build Karabiner config: %s.", prepared_catalogue_err)
		return nil, prepared_catalogue_err
	end
	local all_rules    = {}
	local none_action  = action_index["none"] or { label = "none", karabiner_to = {} }
	local legacy_static_anchors = {}
	-- Rules owned by the Tap-Holds feature switch. The right-Command tap/hold
	-- is deliberately not one: it carries AltGr and the held variable the
	-- script-control sentinels need, so switching Tap-Holds off (like a pause)
	-- must never cost the user the way back.
	local tap_hold_feature_rules = {}
	local legacy_tap_hold_rules = {}
	-- Rules owned by the key-combinations switch (M.key_combinations_enabled).
	-- They were Tap-Holds feature rules until the combinations got a switch
	-- of their own, under Shortcuts.
	local key_combination_rules = {}
	-- What each combo was built from, and each per-key rule the Tap-Holds
	-- switch owns, so the combinations can be rebuilt for native keys when the
	-- Tap-Holds are off (combination_rules_without_tap_holds).
	local combo_builds = {}
	local tap_hold_rule_of = {}


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


	-- Build a lookup: key_code → the modifier flags its own rule keeps down while
	-- held (held_key_events): each entry's modifier key and every modifier it
	-- carries (Cmd+Shift holds both), fn included. When a key acts as k1
	-- (holder) in a combo, those flags are down while the combo rule fires.
	-- Listing them as mandatory in the rule's from matcher consumes them so they
	-- do not leak into output events. The whole state each key's rule gives a
	-- held key is recorded too: a chord that takes a key's key_down restores
	-- what it can of it.
	local key_held_modifiers = {}
	local key_held_state = {}
	for _, key_def in ipairs(tap_hold_keys) do
		local cfg       = state.tap_hold_config[key_def.id] or {}
		local hold_act  = action_index[cfg.hold or "none"] or none_action
		local tap_act   = action_index[cfg.tap or "none"] or none_action
		local held      = held_key_state(key_def.from.key_code, tap_act, hold_act)
		key_held_state[key_def.from.key_code] = held
		key_held_modifiers[key_def.from.key_code] = held_flag_keys(held)
	end


	-- Dynamic modifier combo manipulators (after CapsWord, before the navigation
	-- layer so a user-defined combo involving a layer-remapped key matches the
	-- combo first).
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
			k1_mandatory, state.combo_symmetric, key_held_state
		)
		for _, rule in ipairs(generated) do
			all_rules[#all_rules + 1] = rule
			key_combination_rules[rule] = true
			Logger.debug(LOG, "  → rule: %s", rule.description)
		end
		combo_builds[#combo_builds + 1] = {
			rules = generated, combo_def = combo_def, k1 = k1_key,
			tap_action = tap_action, hold_action = hold_action, combo_action = combo_action,
		}

		::continue::
	end


	-- Script-control sentinel rules (placed after combos so a user-configured
	-- rcmd+bsp/ret/esc combo takes precedence over the sentinel when both exist).
	-- These rely on ke_held_right_command being set by the rcmd tap/hold rule.
	-- The three historical rules stand here while the legacy graph below is
	-- captured; the script chords that run now then take their place.
	local historical_script_rules = {}
	for _, rule in ipairs(build_script_control_sentinel_rules()) do
		all_rules[#all_rules + 1] = rule
		historical_script_rules[rule] = true
	end


	-- The navigation layer, generated from the user's layers.toml. No file (or a
	-- file binding nothing) is no rule: the keys keep their normal behaviour.
	-- Every older release put its static layer at this position, which the
	-- historical graph below reproduces.
	local nav_layer_position = #all_rules
	local nav_rule = nil
	if state.nav_layer ~= nil then
		local nav_ok, built = pcall(NavLayer.build_rule, state.nav_layer.bindings, state.nav_layer.registry)
		if not nav_ok then
			local err = "navigation layer: " .. tostring(built)
			Logger.error(LOG, "Cannot build Karabiner config: %s.", err)
			return nil, err
		end
		nav_rule = built
		if nav_rule then all_rules[#all_rules + 1] = nav_rule end
	end
	local legacy_layer_keys = load_json_file(shared_dir .. LEGACY_LAYER_KEYS_FILE)
	if legacy_layer_keys then
		legacy_static_anchors.layer_keys = legacy_layer_keys
	else
		Logger.warn(LOG, "Legacy layer anchor not found: '%s' — older blocks cannot be proven.",
			LEGACY_LAYER_KEYS_FILE)
	end

	-- Always-on rules (complex logic that cannot be expressed as tap / hold).
	-- CapsWord is already at the top of all_rules — skipped here intentionally.
	for _, fname in ipairs(ALWAYS_ON_RULES) do
		local rule = load_json_file(shared_dir .. fname)
		if rule then
			if fname == "combos.json" then
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
		local rule = build_tap_hold_rule(key_def, tap_action, hold_action, per_key_ms)
		if rule then
			all_rules[#all_rules + 1] = rule
			-- Historical ownership evidence must retain the pre-timer graph.
			legacy_tap_hold_rules[rule] = build_tap_hold_rule(key_def, tap_action, hold_action, per_key_ms, false)
			if key_def.from.key_code ~= SCRIPT_CONTROL_HOLDER_KEY then
				tap_hold_feature_rules[rule] = true
				tap_hold_rule_of[key_def.from.key_code] = { rule = rule, key_def = key_def }
			end
		end
	end

	-- Capture the exact historical rule graph before the new manipulator-local
	-- timings, ownership tags, and atomic mode gates mutate it. Individual members
	-- are non-owning compatibility hints: deletion requires reconstruction and
	-- proof of the complete contiguous historical block.
	-- An older release generated the same graph with its static navigation layer
	-- where this one generates the layer from layers.toml.
	local legacy_available_actions = detach_runtime_variable_actions(available_actions)
	local legacy_rules = {}
	for index, rule in ipairs(all_rules) do
		if rule ~= nav_rule then
			local legacy_rule = deep_copy(legacy_tap_hold_rules[rule] or rule)
			strip_exit_sentinels(legacy_rule)
			legacy_rules[#legacy_rules + 1] = legacy_rule
		end
		if index == nav_layer_position and legacy_layer_keys then
			legacy_rules[#legacy_rules + 1] = deep_copy(legacy_layer_keys)
		end
	end
	if nav_layer_position == 0 and legacy_layer_keys then
		table.insert(legacy_rules, 1, deep_copy(legacy_layer_keys))
	end
	for _, paused_rule in ipairs(build_raw_paused_script_control_rules()) do
		legacy_rules[#legacy_rules + 1] = deep_copy(paused_rule)
	end

	-- Only a script chord that runs an action keeps its sentinel rule: an
	-- unassigned slot, or every slot while the chords' switch is off, leaves
	-- the key combination to the system (script-chords-three-os-2026-09-30).
	local chords_ok, chord_rules = pcall(ScriptChordRules.running, state.script_chords,
		held_var_name(SCRIPT_CONTROL_HOLDER_KEY))
	if not chords_ok then
		local err = "script chords: " .. tostring(chord_rules)
		Logger.error(LOG, "Cannot build Karabiner config: %s.", err)
		return nil, err
	end
	local with_chords = {}
	for _, rule in ipairs(all_rules) do
		if not historical_script_rules[rule] then
			with_chords[#with_chords + 1] = rule
		elseif chord_rules then
			for _, chord_rule in ipairs(chord_rules) do with_chords[#with_chords + 1] = chord_rule end
			chord_rules = nil
		end
	end
	all_rules = with_chords

	-- Tap-Holds or key combinations switched off: drop that feature's rules
	-- after the legacy capture above, which must keep describing the complete
	-- historical graph. Keys then behave natively while every stored assignment
	-- stays untouched. The two switches are independent: with the Tap-Holds
	-- off, the combinations are rebuilt for native keys, and the var-based tap
	-- and hold slots of a pair, which read key 1's held variable, get a rule
	-- that sets it in place of key 1's own tap-hold rule.
	local tap_holds_on = state.tap_holds_enabled ~= false
	local combinations_on = M.key_combinations_enabled(state)
	if not tap_holds_on or not combinations_on then
		local replaced = {}
		if not tap_holds_on and combinations_on then
			local built_ok, built = pcall(combination_rules_without_tap_holds, combo_builds, tap_hold_rule_of,
				key_held_state, none_action, state.combo_symmetric)
			if not built_ok then
				local err = "key combinations without Tap-Holds: " .. tostring(built)
				Logger.error(LOG, "Cannot build Karabiner config: %s.", err)
				return nil, err
			end
			replaced = built
		end
		local kept = {}
		for _, rule in ipairs(all_rules) do
			local replacement = replaced[rule]
			if replacement then
				for _, replacement_rule in ipairs(replacement) do kept[#kept + 1] = replacement_rule end
			else
				local dropped = (not tap_holds_on and tap_hold_feature_rules[rule])
					or (not combinations_on and key_combination_rules[rule])
				if not dropped then kept[#kept + 1] = rule end
			end
		end
		Logger.info(LOG, "Switched off (tap-holds %s, key combinations %s): %d feature rule(s) not generated.",
			tap_holds_on and "on" or "off", combinations_on and "on" or "off", #all_rules - #kept)
		all_rules = kept
	end

	-- Native control expansion detaches manipulators, so reject aliased source
	-- graphs first instead of accidentally hiding the decoder's identity error.
	local control_graph_valid, control_graph_err = validate_managed_rule_graph(all_rules)
	if not control_graph_valid then return nil, control_graph_err end
	rewrite_control_output(all_rules)

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

	local paused_rules, pause_err = M.build_paused_script_control_rules(lease_token, state.script_chords)
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
--- the action payload. Sticky/base ids selected the companion rules historical
--- releases emitted; `none` participates in combo emission, so neither may be
--- canonicalised.
--- @param action_id any Candidate action id.
--- @return boolean semantic Whether identity itself affects generation.
local function has_generator_semantic_action_id(action_id)
	return action_id == "none" or LegacyReleaseFixtures.selects_sticky_companions(action_id)
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

--- Validates catalogue string fields. Actions retain distinct label candidates;
--- other catalogues require globally unique labels. Unused action ambiguity is
--- not ownership evidence and cannot block unrelated personal rules.
--- @param items table Dense catalogue array.
--- @param field string String field used as the key.
--- @param catalogue_name string Diagnostic catalogue name.
--- @param allow_equivalent_action_aliases boolean|nil Coalesce exact non-semantic action aliases.
--- @return table|nil index Unique item lookup, or action-label candidate buckets.
--- @return string|nil error_message Validation failure.
local function unique_catalogue_index(items, field, catalogue_name, allow_equivalent_action_aliases)
	if not is_dense_array(items) then return nil, catalogue_name .. " must be a dense array" end
	local index = {}
	for item_index, item in ipairs(items) do
		local key = type(item) == "table" and item[field] or nil
		if type(key) ~= "string" or key == "" then
			return nil, string.format("%s item %d lacks a non-empty %s", catalogue_name, item_index, field)
		end
		if allow_equivalent_action_aliases then
			local candidates = index[key] or {}
			local equivalent = false
			for _, candidate in ipairs(candidates) do
				if equivalent_legacy_action_alias(candidate, item) then
					equivalent = true
					break
				end
			end
			if not equivalent then candidates[#candidates + 1] = item end
			index[key] = candidates
		else
			if index[key] then
				return nil, string.format("%s has duplicate %s '%s'", catalogue_name, field, key)
			end
			index[key] = item
		end
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

--- Resolves only one proven-equivalent action class. A historical rule which
--- references a label shared by distinct native outputs remains unproven, even
--- when its output happens to resemble one of them.
--- @param action_by_label table Validated label-to-candidate buckets.
--- @param label string Historical description label.
--- @return table|nil action The sole equivalent class, otherwise nil.
local function resolve_legacy_action_label(action_by_label, label)
	local candidates = action_by_label[label]
	if type(candidates) ~= "table" or #candidates ~= 1 then return nil end
	return candidates[1]
end

--- Parses the action pair encoded by a historical rule description.
--- @param description string Existing rule description.
--- @param prefix string Exact generator-owned prefix.
--- @param action_by_label table Validated label-to-candidate buckets.
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
	local tap_action = resolve_legacy_action_label(action_by_label, tap_label)
	local hold_action = resolve_legacy_action_label(action_by_label, hold_label)
	if not tap_action or not hold_action then
		return nil, "legacy action-pair description names an unknown or ambiguous action"
	end
	return { tap = tap_action, hold = hold_action }
end

--- Reconstructs one tap/hold setting from its historical rule.
--- @param rule table Historical rule candidate.
--- @param key_def table Tap/hold catalogue entry at this fixed position.
--- @param action_by_label table Validated label-to-candidate buckets.
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
				local action = resolve_legacy_action_label(prepared.action_by_label, action_label)
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

--- Describes the legacy-signature refusal as data, so a caller can offer the
--- removal without parsing the diagnostic.
--- @param conflicts table Dense cross-profile conflict array.
--- @return table refusal { kind, count, descriptions, conflicts }.
local function legacy_conflict_refusal(conflicts)
	local descriptions = {}
	local locations = {}
	for index, conflict in ipairs(conflicts) do
		descriptions[index] = conflict.description
		locations[index] = {
			profile_index = conflict.profile_index,
			rule_index = conflict.rule_index,
			description = conflict.description,
		}
	end
	return {
		kind = M.REFUSAL_LEGACY_CONFLICTS,
		count = #conflicts,
		descriptions = descriptions,
		conflicts = locations,
	}
end

--- Validates every existing profile, then classifies the rules of each one.
--- The merge and the legacy cleanup both read their verdicts from here, so
--- the cleanup removes exactly the rules the merge refuses.
--- @param existing table Decoded karabiner.json tree.
--- @param target_index integer Index of the selected profile.
--- @param incoming_rules table Rules the selected profile receives.
--- @param legacy_context table|nil Historical reconstruction context.
--- @return table|nil classified_profiles Profile index -> { existing_rules, incoming_rules, removal_set }.
--- @return table|string conflicts_or_error Dense conflict array, or the refusal.
--- @return integer|nil failing_profile Profile whose historical proof failed.
local function classify_existing_profiles(existing, target_index, incoming_rules, legacy_context)
	-- Validate every profile before mutating any of them. Stale managed rules may
	-- live in an inactive profile and become active again after a user switch
	for profile_index, profile in ipairs(existing.profiles) do
		local complex = profile.complex_modifications
		if complex ~= nil and type(complex) ~= "table" then
			return nil, string.format(
				"existing profile %d complex_modifications must be a table",
				profile_index
			)
		end
		if type(complex) == "table"
			and complex.rules ~= nil
			and not is_dense_array(complex.rules) then
			return nil, string.format(
				"existing profile %d complex_modifications.rules must be a table",
				profile_index
			)
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
		if not prepared_legacy then return nil, context_err end
	end

	local classified_profiles = {}
	local signature_conflicts = {}
	for profile_index, profile in ipairs(existing.profiles) do
		local is_selected = profile_index == target_index
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
				if not removal_set then return nil, classify_err, profile_index end
				for _, conflict in ipairs(profile_conflicts) do
					conflict.profile_index = profile_index
					signature_conflicts[#signature_conflicts + 1] = conflict
				end
				classified_profiles[profile_index] = {
					existing_rules = existing_rules or {},
					incoming_rules = is_selected and incoming_rules or {},
					removal_set = removal_set,
				}
			end
		end
	end
	return classified_profiles, signature_conflicts
end

--- Lists every untagged rule the merge refuses as a historical ErgoptiPlus
--- signature, in every profile, with the merge's own validation.
--- @param existing table Decoded karabiner.json tree (adapters.json_codec).
--- @param legacy_context table Fourth return value from build_karabiner_json.
--- @return table|nil conflicts Dense { profile_index, rule_index, description, reasons } array.
--- @return string|nil error_message Why the file cannot be classified.
function M.find_legacy_signature_conflicts(existing, legacy_context)
	if type(legacy_context) ~= "table" then
		return nil, "legacy migration context must be a table"
	end
	local selected_profile, target_index_or_err = find_unique_selected_profile(existing, "existing")
	if not selected_profile then return nil, target_index_or_err end
	local classified, conflicts_or_err = classify_existing_profiles(
		existing,
		target_index_or_err,
		{},
		legacy_context
	)
	if not classified then return nil, conflicts_or_err end
	return conflicts_or_err
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
--- @return table|nil refusal On a legacy-signature refusal only:
---   { kind = M.REFUSAL_LEGACY_CONFLICTS, count, descriptions, conflicts }.
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

	-- A tree: the merge edits the selected profile in place, and equal lists
	-- elsewhere in the file must not be edited with it.
	local existing = JsonCodec.decode(raw)
	if type(existing) ~= "table" then
		local err = "existing karabiner.json is not valid JSON"
		Logger.error(LOG, "Merge aborted: %s.", err)
		return nil, err
	end

	local selected_profile, target_index_or_err = find_unique_selected_profile(existing, "existing")
	if not selected_profile then
		Logger.error(LOG, "Merge aborted: %s.", target_index_or_err)
		return nil, target_index_or_err
	end

	local classified_profiles, conflicts_or_err, failing_profile = classify_existing_profiles(
		existing,
		target_index_or_err,
		generated_complex.rules,
		legacy_context
	)
	if not classified_profiles then
		if failing_profile then
			Logger.error(LOG, "Merge aborted in profile %d: %s.", failing_profile, conflicts_or_err)
		else
			Logger.error(LOG, "Merge aborted: %s.", conflicts_or_err)
		end
		return nil, conflicts_or_err
	end
	local signature_conflicts = conflicts_or_err
	if #signature_conflicts > 0 then
		local detail = format_legacy_signature_conflicts(signature_conflicts)
		Logger.error(LOG, "Merge aborted: %s.", detail)
		return nil, detail, nil, nil, legacy_conflict_refusal(signature_conflicts)
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
--- @return table|nil refusal The merge's structured legacy-signature refusal,
---   nil for every other result.
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

	local merge_ok, merged, merge_err, source_snapshot, merge_changed, merge_refusal = pcall(
		M.merge_into_existing_config,
		hs_config,
		karabiner_out,
		legacy_fingerprints,
		legacy_context
	)
	if not merge_ok or type(merged) ~= "table" then
		local detail = "merge failed: " .. tostring(merge_ok and merge_err or merged)
		Logger.error(LOG, "Karabiner deploy aborted — %s.", detail)
		local refusal = merge_ok and type(merge_refusal) == "table"
			and merge_refusal.kind == M.REFUSAL_LEGACY_CONFLICTS and merge_refusal or nil
		return false, detail, 1, refusal
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
