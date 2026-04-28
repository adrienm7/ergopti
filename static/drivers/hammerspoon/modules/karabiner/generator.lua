--- modules/karabiner/generator.lua

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
--- 1. CapsWord Priority: capsword.json is loaded first so CapsWord activation
---    always takes precedence over any tap/hold or combo rule that shares the
---    same key — without this ordering, RCmd+CapsLock combos could steal the
---    event before CapsWord's simultaneous matcher fires.
--- 2. Physical State Tracking: every tap/hold rule sets ke_held_<key_code>=1
---    on key_down and clears it on key_up, letting combo and sentinel rules
---    distinguish real physical presses from emulated tap outputs.
--- 3. Sticky-Equivalent Companions: when a key's tap/hold pair is
---    sticky_X/X, companion manipulators fire the base modifier immediately
---    whenever another modifier-class key is already held, so combined chords
---    like Cmd+(sticky-shift key) work without entering the sticky path.
--- 4. Merge-Preserve: only complex_modifications is replaced; devices, fn keys,
---    simple_modifications, and global KE flags survive every regeneration.
--- ==============================================================================

local M = {}

local hs       = hs
local Logger   = require("lib.logger")
local Keycodes = require("lib.keycodes")

local LOG = "karabiner"

-- Sanity references — Karabiner JSON is built with string sentinels ("f18",
-- "f19", "f20") consumed by Karabiner Elements directly, but the numeric
-- keycodes that the receiving Hammerspoon modules dispatch on must stay aligned
-- with lib.keycodes. Touching those constants surfaces a stale literal here.
local _F18_NUMERIC = Keycodes.F18_KARABINER_BACKSPACE
local _F19_NUMERIC = Keycodes.F19_KARABINER_RETURN
local _F20_NUMERIC = Keycodes.F20_KARABINER_ESCAPE

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
-- These values must match the KEYCODE_F18/F19/F20 constants consumed by
-- modules/shortcuts/script_control.lua.
local SCRIPT_CONTROL_HOLDER_KEY     = "right_command"
local SCRIPT_CONTROL_SENTINEL_SLOTS = {
	{ from_key = "delete_or_backspace", sentinel = "f18", slot_label = "backspace" },
	{ from_key = "return_or_enter",     sentinel = "f19", slot_label = "return"    },
	{ from_key = "escape",              sentinel = "f20", slot_label = "escape"    },
}




-- ========================================
-- ========================================
-- ======= 1/ Helpers and Constants =======
-- ========================================
-- ========================================

--- Loads and parses a JSON file. Logs an error and returns nil on any failure.
--- @param path string Absolute path to the JSON file.
--- @return table|nil Decoded table, or nil.
local function load_json_file(path)
	local fh = io.open(path, "r")
	if not fh then
		Logger.error(LOG, "Cannot open file '%s'.", path)
		return nil
	end
	local raw = fh:read("*a")
	fh:close()
	local ok, data = pcall(hs.json.decode, raw)
	if not ok or type(data) ~= "table" then
		Logger.error(LOG, "Cannot decode JSON from '%s': %s.", path, tostring(data))
		return nil
	end
	return data
end

--- Builds an index of action id → action definition.
--- @param available_actions table List of action definitions.
--- @return table Map of id → action definition.
local function build_action_index(available_actions)
	local index = {}
	for _, action in ipairs(available_actions) do
		index[action.id] = action
	end
	return index
end

--- Returns true when two karabiner_to arrays produce identical JSON output.
--- Used to detect tap == hold (in which case to_if_alone is omitted).
--- @param a table First karabiner_to array.
--- @param b table Second karabiner_to array.
--- @return boolean
local function same_output(a, b)
	return hs.json.encode(a) == hs.json.encode(b)
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


-- ===============================================
-- ===== 2.1) Sticky Companion Manipulators =====
-- ===============================================

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


-- ==================================
-- ===== 2.2) Main Tap/Hold Rule =====
-- ==================================

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
--- @return table Karabiner rule object.
local function build_tap_hold_rule(key_def, tap_action, hold_action, action_index)
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
		-- so the physical press is not consumed
		to_events[#to_events + 1] = { key_code = key_code }
		manipulator.to              = to_events
		manipulator.to_after_key_up = after_key_up_tail

		return {
			description  = string.format("%s: passthrough (variable tracked)", key_def.label),
			manipulators = { manipulator },
		}
	end

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

	local from = combo_def.from
	if combo_symmetric then
		from = { simultaneous = combo_def.from.simultaneous }
		if type(combo_def.from.simultaneous_options) == "table" then
			local opts = {}
			for k, v in pairs(combo_def.from.simultaneous_options) do
				if k ~= "key_down_order" then opts[k] = v end
			end
			if next(opts) then from.simultaneous_options = opts end
		end
		if combo_def.from.modifiers then from.modifiers = combo_def.from.modifiers end
	end

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
--- (backspace | return | escape) into F18 / F19 / F20 respectively.
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
					to = { { key_code = slot.sentinel } },
				},
			},
		}
	end
	return rules
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
---
--- @param state table Current module state (_state from init.lua).
--- @param available_actions table List from Config.load_available_actions.
--- @param tap_hold_keys table List from Config.load_tap_hold_keys.
--- @param mod_combos table List from Config.load_mod_combos.
--- @param non_canonical table Set from Config.compute_non_canonical_combos.
--- @param self_dir string Directory containing data/ (init.lua's directory).
--- @return table Karabiner config table ready for hs.json.encode.
function M.build_karabiner_json(state, available_actions, tap_hold_keys, mod_combos, non_canonical, self_dir)
	local action_index = build_action_index(available_actions)
	local all_rules    = {}
	local none_action  = action_index["none"] or { label = "none", karabiner_to = {} }


	-- CapsWord must be first — it must match before any modifier combo or
	-- tap/hold rule so that RCmd+CapsLock activates CapsWord regardless of
	-- whatever else is mapped to those keys.
	local capsword_rule = load_json_file(self_dir .. "data/capsword.json")
	if capsword_rule then
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
		local rule = load_json_file(self_dir .. "data/" .. fname)
		if rule then
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

		local rule = build_tap_hold_rule(key_def, tap_action, hold_action, action_index)
		if rule then all_rules[#all_rules + 1] = rule end
	end


	local timeout_ms      = state.tap_hold_timeout_ms
	local simultaneous_ms = state.simultaneous_threshold_ms
	Logger.debug(LOG, "Building config: tap/hold=%d ms, simultaneous=%d ms, symmetric=%s, %d rule(s).",
		timeout_ms, simultaneous_ms, tostring(state.combo_symmetric), #all_rules)

	return {
		profiles = {
			{
				complex_modifications = {
					-- Global timeouts apply to ALL rules uniformly without per-manipulator overrides.
					-- simultaneous_threshold_milliseconds controls how long KE waits after the first
					-- key before giving up on a combo.
					parameters = {
						["basic.to_if_alone_timeout_milliseconds"]    = timeout_ms,
						["basic.simultaneous_threshold_milliseconds"] = simultaneous_ms,
					},
					rules = all_rules,
				},
				devices              = { { identifiers = { is_keyboard = true }, simple_modifications = {} } },
				name                 = "Default profile",
				selected             = true,
				virtual_hid_keyboard = { country_code = 0, keyboard_type_v2 = "ansi" },
			}
		}
	}
end

--- Merges HS-generated complex_modifications into the existing karabiner.json,
--- preserving every other KE UI setting (devices, fn_function_keys,
--- simple_modifications, global flags, etc.) in the selected profile.
--- Falls back to the raw HS config when the existing file is absent or invalid.
--- @param hs_config table The profile structure returned by build_karabiner_json.
--- @param karabiner_out string Absolute path to the live karabiner.json.
--- @return table The merged configuration ready to be JSON-encoded.
function M.merge_into_existing_config(hs_config, karabiner_out)
	local fh = io.open(karabiner_out, "r")
	if not fh then
		Logger.debug(LOG, "No existing karabiner.json — writing fresh HS config.")
		return hs_config
	end
	local raw = fh:read("*a")
	fh:close()

	local ok, existing = pcall(hs.json.decode, raw)
	if not ok or type(existing) ~= "table" then
		Logger.warn(LOG, "Existing karabiner.json is not valid JSON — overwriting from scratch.")
		return hs_config
	end

	local hs_profile = hs_config.profiles and hs_config.profiles[1]
	if not hs_profile then return hs_config end

	if type(existing.profiles) ~= "table" or #existing.profiles == 0 then
		-- No profiles yet — write HS config wholesale but keep any global section
		existing.profiles = hs_config.profiles
		return existing
	end

	-- Target the selected profile; fall back to the first one
	local target_idx = 1
	for i, profile in ipairs(existing.profiles) do
		if profile.selected then target_idx = i; break end
	end

	-- Overwrite only complex_modifications so KE UI device/fn-key settings survive
	existing.profiles[target_idx].complex_modifications = hs_profile.complex_modifications
	Logger.debug(LOG, "Merged HS rules into profile %d of existing karabiner.json.", target_idx)
	return existing
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
function M.deploy_file(src, dst)
	Logger.trace(LOG, "Deploy: '%s' → '%s'…", src, dst)

	-- Read source — fail fast before touching the destination
	local src_fh = io.open(src, "r")
	if not src_fh then
		Logger.error(LOG, "Deploy aborted — source not readable: '%s'.", src)
		return false, "source file not found: " .. src
	end
	local content = src_fh:read("*a")
	src_fh:close()
	Logger.debug(LOG, "Deploy: read %d byte(s) from source.", #content)

	local parent = dst:match("^(.*)/[^/]+$")

	-- S1: direct write — works for regular paths and Unix symlinks
	local dst_fh = io.open(dst, "w")
	if dst_fh then
		dst_fh:write(content)
		dst_fh:close()
		Logger.done(LOG, "Deploy S1 (direct write) succeeded: '%s'.", dst)
		return true, "ok"
	end
	Logger.debug(LOG, "Deploy S1 failed — destination not directly writable: '%s'.", dst)

	-- S2: parent directory may not exist yet — create it then retry
	if parent then
		local mkdir_out, _, _, mkdir_rc = hs.execute(
			string.format("/bin/mkdir -p '%s' 2>&1", parent:gsub("'", "'\\''"))
		)
		Logger.debug(LOG, "Deploy S2 mkdir -p rc=%s: %s",
			tostring(mkdir_rc), (mkdir_out or ""):gsub("%s+$", ""))
		dst_fh = io.open(dst, "w")
		if dst_fh then
			dst_fh:write(content)
			dst_fh:close()
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

return M
