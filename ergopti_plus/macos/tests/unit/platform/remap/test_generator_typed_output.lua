--- tests/unit/platform/remap/test_generator_typed_output.lua

--- ==============================================================================
--- MODULE: What The Generated Karabiner Rules Type
--- DESCRIPTION:
--- Builds the real rule graph from the shipped catalogues (actions.json,
--- tap_hold_keys.json, mod_combos.json, the static rule files and the shared
--- defaults), then replays key presses through the Karabiner v16.0.0 model in
--- tests/support/karabiner_model.lua. Each case asserts the output a user
--- gets, so a rule that is well-formed JSON but types the wrong thing fails.
--- ==============================================================================

local helpers        = require("tests.helpers")
local KarabinerModel = require("tests.support.karabiner_model")
local SourceFile     = require("tests.support.source_file")

local TOKEN    = "0123456789abcdef0123456789abcdef"
local DATA_DIR = helpers.driver_root() .. "platform/remap/data/"

-- Every physical key a user holds as a modifier: the keys whose tap-hold rules
-- accept any held modifier.
local MODIFIER_KEYS = {
	"left_command", "right_command", "left_control", "left_option",
	"left_shift", "right_shift", "fn", "caps_lock",
}

--- Returns a copy of a flat table.
--- @param source table Table to copy.
--- @return table copy
local function copy(source)
	local result = {}
	for key, value in pairs(source) do result[key] = value end
	return result
end

--- Returns the sorted flag names of a set, for stable failure messages.
--- @param set table Flag name → true.
--- @return string names Comma-separated names.
local function names(set)
	local list = {}
	for name in pairs(set) do list[#list + 1] = name end
	table.sort(list)
	return table.concat(list, ",")
end

--- Returns the modifier flags an action's karabiner_to presses, whether as
--- keys, as their modifiers, or as sticky modifiers.
--- @param action table Catalogue action.
--- @return table flags Flag name → true.
local function action_flags(action)
	local flags = {}
	for _, event in ipairs(action.karabiner_to or {}) do
		if KarabinerModel.MODIFIER_KEY_CODES[event.key_code] then flags[event.key_code] = true end
		for _, modifier in ipairs(event.modifiers or {}) do flags[modifier] = true end
		for flag in pairs(event.sticky_modifier or {}) do flags[flag] = true end
	end
	return flags
end

--- Reports whether every entry of an action's output is a sticky modifier.
--- @param action table Catalogue action.
--- @return boolean sticky
local function is_sticky(action)
	local events = action.karabiner_to or {}
	if #events == 0 then return false end
	for _, event in ipairs(events) do
		if type(event.sticky_modifier) ~= "table" then return false end
	end
	return true
end

helpers.with_fresh_modules({
	"adapters.file_system",
	"infra.config_paths",
	"infra.keycodes",
	"infra.logger",
	"infra.toml.codec",
	"platform.remap.config",
	"platform.remap.generator",
	"toml_codec",
	"modules.keymap.control_sentinels",
	"adapters.synthetic_input",
}, function()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.config_paths"] = {
		get_config_dir = function() return "/tmp/ergopti_test" end,
	}
	package.loaded["infra.keycodes"] = {
		to_name                 = function(code) return "key_" .. tostring(code) end,
		F13_KARABINER_RETURN    = 105,
		F14_KARABINER_BACKSPACE = 107,
		F15_KARABINER_ESCAPE    = 113,
		F20_LAYER_NAV_ENTERED   = 90,
		F19_LAYER_NAV_EXITED    = 80,
	}
	-- The native TOML codec is absent from the headless runner; the catalogues
	-- read here are JSON and the shared defaults use the pure-Lua reader.
	local toml_stub = { encode = function() return "" end, decode = function() return {} end }
	package.loaded["toml_codec"] = toml_stub
	package.loaded["infra.toml.codec"] = toml_stub
	-- Every build re-reads the three static rule files, and the adapter's safe
	-- read cost more than the rest of a build: serve each file's real content,
	-- read once.
	local file_cache = {}
	local function read_once(path)
		if file_cache[path] == nil then file_cache[path] = SourceFile.read(path) end
		return file_cache[path]
	end
	package.loaded["adapters.file_system"] = {
		read = read_once,
		read_with_status = function(path) return read_once(path), "ok" end,
	}

	local Config    = helpers.load_with_stubs("platform.remap.config")
	local Generator = helpers.load_with_stubs("platform.remap.generator")

	local actions = assert(Config.load_available_actions(DATA_DIR .. "actions.json"))
	local keys    = assert(Config.load_tap_hold_keys(DATA_DIR .. "tap_hold_keys.json"))
	local combos  = assert(Config.load_mod_combos(DATA_DIR .. "mod_combos.json"))
	local non_canonical = Config.compute_non_canonical_combos(combos)
	-- The application receives only events not consumed by the actual keymap
	-- owner. Its diagnostic scheduler is inert unless a real listener fails.
	local diagnostics = {}
	package.loaded["adapters.synthetic_input"] = {
		defer_after_callback = function(reason, callback)
			diagnostics[#diagnostics + 1] = { reason = reason, callback = callback }
			return true
		end,
	}
	local ControlOwner = require("modules.keymap.control_sentinels")
	local NativeKeycodes = require("keycodes")
	local control_codes = {
		key_90 = NativeKeycodes.F20_LAYER_NAV_ENTERED,
		key_80 = NativeKeycodes.F19_LAYER_NAV_EXITED,
	}
	local by_id = {}
	for _, action in ipairs(actions) do by_id[action.id] = action end

	--- Builds the shipped defaults with some assignments replaced.
	--- @param tap_holds table|nil Key id → { tap, hold }.
	--- @param mod_combos table|nil Combo id → { combo, tap, hold }.
	--- @param symmetric boolean|nil Symmetric chord mode; nil keeps the default.
	--- @return table rules The generated complex_modifications rules.
	local function build(tap_holds, mod_combos, symmetric)
		local state = Config.build_recommended_state(keys, combos)
		for id, slots in pairs(tap_holds or {}) do state.tap_hold_config[id] = copy(slots) end
		for id, slots in pairs(mod_combos or {}) do state.mod_combos_config[id] = copy(slots) end
		if symmetric ~= nil then state.combo_symmetric = symmetric end
		local config, err = Generator.build_karabiner_json(
			state, actions, keys, combos, non_canonical, DATA_DIR, TOKEN)
		assert(config, "generation failed: " .. tostring(err))
		return config.profiles[1].complex_modifications.rules
	end

	--- Starts a Karabiner model on an ACTIVE lease.
	--- @param rules table Generated rules.
	--- @param flags table|nil Modifier flags already held, from any source.
	--- @return table engine
	local function engine_for(rules, flags)
		return KarabinerModel.new(rules, {
			variables = { [Generator.mode_variable_name(TOKEN)] = 1 },
			flags = flags,
		})
	end



	helpers.describe("one-shot Shift control output", function()
		helpers.it("emits a distinct tag while navigation stays bare under held Control+Option (one-shot-sentinel)", function()
			local rules = build()
			local nav = engine_for(rules, { "left_control", "left_option" })
			nav:down("left_command")
			local saw_nav = false
			for _, emission in ipairs(nav:emissions()) do
				if emission.key_code == "key_90" then
					saw_nav = true
					helpers.assert_eq(names(emission.flags), "", "navigation must not inherit the one-shot tag")
					helpers.assert_eq(emission.event["repeat"], false)
				end
			end
			helpers.assert_true(saw_nav)
			local shifted = engine_for(build({ right_option = { tap = "sticky_shift", hold = "shift" } }))
			shifted:tap("right_option")
			local saw_shift = false
			for _, emission in ipairs(shifted:emissions()) do
				if emission.key_code == "key_90" then
					saw_shift = true
					helpers.assert_eq(names(emission.flags), "left_control,left_option")
					helpers.assert_eq(emission.event["repeat"], false)
				end
			end
			helpers.assert_true(saw_shift)
		end)
	end)

	-- =============================================
	-- ===== 1) One-shot modifiers under holds =====
	-- =============================================

	helpers.describe("a one-shot tap under a held modifier arms it (sticky-tap-under-held-modifier)", function()
		-- Every sticky action pairs with the plain action that holds the same
		-- flags; that pairing is the class the removed companion rules covered.
		local pairs_found = 0
		for _, sticky in ipairs(actions) do
			if is_sticky(sticky) then
				local wanted = names(action_flags(sticky))
				local base = nil
				for _, candidate in ipairs(actions) do
					local events = candidate.karabiner_to or {}
					if candidate.holdable == true and #events == 1
						and KarabinerModel.MODIFIER_KEY_CODES[events[1].key_code]
						and names(action_flags(candidate)) == wanted then
						assert(base == nil, "two plain actions hold the flags of " .. sticky.id)
						base = candidate
					end
				end
				assert(base, "no plain action holds the flags of " .. sticky.id)
				pairs_found = pairs_found + 1
				local rules = build({ right_option = { tap = sticky.id, hold = base.id } })

				helpers.it("tapping " .. sticky.id .. " under each held modifier key arms it", function()
					for _, held in ipairs(MODIFIER_KEYS) do
						local engine = engine_for(rules)
						engine:down(held)
						engine:clear()
						engine:tap("right_option")
						local armed = false
						for _, emission in ipairs(engine:emissions()) do
							if sticky.id == "sticky_shift" then
								if emission.key_code == "key_90" then
									armed = emission.flags.left_control == true and emission.flags.left_option == true
								end
							elseif emission.phase == "tap" and type(emission.event.sticky_modifier) == "table" then
								armed = true
							end
						end
						helpers.assert_true(armed,
							"with " .. held .. " held, a tap of the " .. sticky.id .. " key must arm the one-shot")
					end
				end)

				helpers.it("holding the " .. sticky.id .. " key holds " .. base.id .. " under each held modifier key", function()
					for _, held in ipairs(MODIFIER_KEYS) do
						local engine = engine_for(rules)
						engine:down(held)
						engine:down("right_option")
						local pressed = engine:pressed()
						for flag in pairs(action_flags(base)) do
							helpers.assert_true(pressed[flag] == true,
								"with " .. held .. " held, holding the key must press " .. flag
									.. " (pressed: " .. names(pressed) .. ")")
						end
					end
				end)
			end
		end
		helpers.it("covers every sticky action of the catalogue", function()
			helpers.assert_true(pairs_found >= 15,
				"expected the fifteen sticky actions of actions.json, found " .. pairs_found)
		end)
	end)



	-- =================================
	-- ===== 2) Keys with one slot =====
	-- =================================

	--- Returns the key codes of the key events posted in one phase.
	--- @param engine table Model engine.
	--- @param phase string|nil Phase to keep; nil keeps every phase.
	--- @return table key_codes In posting order.
	local function keys_posted(engine, phase)
		local posted = {}
		for _, emission in ipairs(engine:emissions()) do
			if emission.key_code ~= nil and (phase == nil or emission.phase == phase) then
				posted[#posted + 1] = emission.key_code
			end
		end
		return posted
	end

	--- Gives every tap-hold key the same two slots.
	--- @param slots table { tap, hold }.
	--- @return table tap_holds Key id → slots.
	local function every_key(slots)
		local tap_holds = {}
		for _, key_def in ipairs(keys) do tap_holds[key_def.id] = slots end
		return tap_holds
	end

	--- Gives every modifier combo the same three slots.
	--- @param slots table { combo, tap, hold }.
	--- @return table mod_combos Combo id → slots.
	local function every_combo(slots)
		local mod_combos = {}
		for _, combo_def in ipairs(combos) do mod_combos[combo_def.id] = slots end
		return mod_combos
	end

	-- Windows preserves the native Shift, Control and AltGr modifiers even
	-- when their hold slot is empty. right_command is the macOS AltGr position.
	local native_tap_only = {
		left_shift = true, right_shift = true, left_control = true, right_command = true, fn = true,
	}

	helpers.describe("tap-only keys preserve native modifier chords and immediate ordinary taps (tap-only-key-types-its-tap)", function()
		-- Each key is pressed alone, so one graph serves every key.
		local tap_only = build(every_key({ tap = "delete_fwd", hold = "none" }))

		helpers.it("keeps the Fn tap blocked by the physical thumb state at press (tap-only-thumb-blocker)", function()
			local paste_key = assert(by_id.paste.karabiner_to[1].key_code, "Paste must resolve to a physical key")
			local disabled_combos = {}
			for _, combo in ipairs(combos) do
				disabled_combos[combo.id] = { combo = "none", tap = "none", hold = "none" }
			end
			for _, blocker in ipairs({ "caps_lock", "left_command" }) do
				local rules = build({
					fn = { tap = "paste", hold = "none" },
					[blocker] = { tap = "none", hold = "cmd" },
				}, disabled_combos)
				local engine = engine_for(rules)
				engine:down(blocker)
				engine:down("fn")
				helpers.assert_true(engine:held().fn == true, "the blocked tap must retain the native Fn hold")
				engine:up(blocker, true)
				engine:up("fn", true)
				for _, emission in ipairs(engine:emissions()) do
					helpers.assert_true(emission.key_code ~= paste_key, "releasing the blocker first must not resurrect Paste")
				end
				local alone = engine_for(rules)
				alone:tap("fn")
				local pasted = false
				for _, emission in ipairs(alone:emissions()) do
					if emission.key_code == paste_key then pasted = true end
				end
				helpers.assert_true(pasted, "an unblocked lone Fn must still paste")
			end
		end)

		helpers.it("ordinary taps repeat from key down while native modifiers reserve a quick lone release for the tap", function()
			for _, key_def in ipairs(keys) do
				local key_code = key_def.from.key_code
				for _, within_timeout in ipairs({ true, false }) do
					local engine = engine_for(tap_only)
					engine:down(key_code)
					local held_key = native_tap_only[key_code] and key_code or "delete_forward"
					helpers.assert_eq(table.concat(keys_posted(engine), ","), held_key,
						key_code .. " must preserve its Windows-equivalent down behavior")
					helpers.assert_true(engine:held()[held_key] == true,
						key_code .. " must retain its exact native modifier or repeating tap")
					engine:up(key_code, within_timeout)
					local expected = held_key
					if native_tap_only[key_code] and within_timeout then expected = expected .. ",delete_forward" end
					helpers.assert_eq(table.concat(keys_posted(engine), ","), expected,
						key_code .. " must emit only a qualifying native modifier tap on release")
				end
			end
		end)

		helpers.it("overlap keeps ordinary taps but uses native modifier chords without an extra tap", function()
			-- Fast typing overlaps presses. Karabiner drops a pending to_if_alone
			-- on any later key_down, so a tap typed on release would be lost.
			for _, key_def in ipairs(keys) do
				local key_code = key_def.from.key_code
				local engine = engine_for(tap_only)
				engine:down(key_code)
				engine:down("a")
				engine:up(key_code, true)
				engine:up("a", true)
				local expected = native_tap_only[key_code] and (key_code .. ",a") or "delete_forward,a"
				helpers.assert_eq(table.concat(keys_posted(engine), ","), expected,
					key_code .. " must preserve its native chord or both ordinary taps")
			end
		end)

		helpers.it("a key with neither slot stays the native key", function()
			local native = build(every_key({ tap = "none", hold = "none" }))
			for _, key_def in ipairs(keys) do
				local key_code = key_def.from.key_code
				local engine = engine_for(native)
				engine:down(key_code)
				helpers.assert_eq(table.concat(keys_posted(engine), ","), key_code,
					key_code .. " with no assignment must go down as itself")
			end
		end)
	end)



	-- ==============================
	-- ===== 3) Combo tap slots =====
	-- ==============================

	--- Returns the two keys of a modifier combo, holder first.
	--- @param combo_def table mod_combos.json entry.
	--- @return string first
	--- @return string second
	local function combo_keys(combo_def)
		local simultaneous = combo_def.from.simultaneous
		return simultaneous[1].key_code, simultaneous[2].key_code
	end

	--- Reports whether a manipulator is the hold-then-tap rule of a combo whose
	--- holder is `first`: only that rule reads the holder's held variable.
	--- @param manipulator table|nil Manipulator the model ran.
	--- @param first string Holder key.
	--- @return boolean combo_rule
	local function is_combo_rule(manipulator, first)
		local held_name = "ergopti_ke_held_" .. first .. "_" .. TOKEN
		for _, condition in ipairs(manipulator and manipulator.conditions or {}) do
			if condition.type == "variable_if" and condition.name == held_name and condition.value == 1 then
				return true
			end
		end
		return false
	end

	helpers.describe("a combo with only a tap types it at key down, like a key with only a tap (combo-tap-only-types-at-key-down)", function()
		-- Each ordered pair has its own rules, so one graph serves every combo.
		local tap_only = build(nil, every_combo({ combo = "none", tap = "delete_fwd", hold = "none" }))

		helpers.it("every combo with only a tap types it alone at the second key's key down, keeps it down to repeat, and adds nothing on release", function()
			local covered = 0
			for _, combo_def in ipairs(combos) do
				if not combo_def.menu_hidden then
					local first, second = combo_keys(combo_def)
					for _, within_timeout in ipairs({ true, false }) do
						local engine = engine_for(tap_only)
						engine:down(first)
						engine:clear()
						-- CapsWord's AltGr+CapsLock rule runs before every combo by design.
						if is_combo_rule(engine:down(second), first) then
							if within_timeout then covered = covered + 1 end
							helpers.assert_eq(table.concat(keys_posted(engine), ","), "delete_forward",
								combo_def.id .. ": a combo with no hold must type its tap when its second key goes down")
							helpers.assert_true(engine:held().delete_forward == true,
								combo_def.id .. ": a combo with no hold must keep its tap down while held, so it auto-repeats")
							engine:up(second, within_timeout)
							helpers.assert_eq(table.concat(keys_posted(engine), ","), "delete_forward",
								combo_def.id .. ": a combo with no hold must type nothing more on release")
						end
					end
				end
			end
			helpers.assert_true(covered >= 150,
				"the combo matrix must reach the combo rule for nearly every pair, reached " .. covered)
		end)

		helpers.it("every combo with only a tap keeps it when the next key goes down before its release", function()
			-- Karabiner drops a pending to_if_alone on any later key_down, so a combo
			-- tap typed on release would be lost in fast typing.
			for _, combo_def in ipairs(combos) do
				if not combo_def.menu_hidden then
					local first, second = combo_keys(combo_def)
					local engine = engine_for(tap_only)
					engine:down(first)
					engine:clear()
					if is_combo_rule(engine:down(second), first) then
						engine:down("a")
						engine:up(second, true)
						engine:up("a", true)
						helpers.assert_eq(keys_posted(engine)[1], "delete_forward",
							combo_def.id .. ": a combo tap followed by an overlapping key must still be typed")
					end
				end
			end
		end)

		helpers.it("a combo tap carries none of the modifiers its holder keeps down (combo-consumes-every-hold-modifier)", function()
			-- A hold such as Cmd+Shift keeps both flags down, a hold of fn keeps fn
			-- down, and a modifier key with neither slot, fn included, keeps its own
			-- flag down. The combo consumes what its holder keeps down, so its tap
			-- must carry none of it.
			local cases = {
				{ holder = "left_option", hold = "none", combo = "lopt_esc" },
				{ holder = "left_option", hold = "fn", combo = "lopt_esc" },
				{ holder = "tab", hold = "fn", combo = "tab_esc" },
				{ holder = "fn", hold = "none", combo = "fn_esc" },
			}
			local multi = 0
			for _, hold in ipairs(actions) do
				local events = hold.karabiner_to or {}
				if hold.holdable == true and #events == 1 and KarabinerModel.MODIFIER_KEY_CODES[events[1].key_code]
					and #(events[1].modifiers or {}) > 0 then
					multi = multi + 1
					cases[#cases + 1] = { holder = "left_option", hold = hold.id, combo = "lopt_esc" }
				end
			end
			helpers.assert_true(multi >= 11, "expected the multi-modifier holds of the catalogue, found " .. multi)
			for _, case in ipairs(cases) do
				local rules = build({ [case.holder] = { tap = "none", hold = case.hold } },
					{ [case.combo] = { combo = "none", tap = "delete_fwd", hold = "none" } })
				local engine = engine_for(rules)
				engine:down(case.holder)
				engine:clear()
				engine:tap("escape")
				local carried = {}
				for _, emission in ipairs(engine:emissions()) do
					if emission.key_code == "delete_forward" then carried[#carried + 1] = names(emission.flags) end
				end
				helpers.assert_eq(table.concat(carried, "|"), "",
					case.holder .. " holding " .. case.hold .. ", then Escape, must type the combo tap without its modifiers")
			end
		end)

		helpers.it("the default right Command + left Option deletes words forward while held (default-delete-word-repeats)", function()
			-- The default sets a tap and no hold, so the delete goes out at key down
			-- and stays down while held.
			local engine = engine_for(build())
			engine:down("right_command")
			engine:clear()
			engine:down("left_option")
			local posted = engine:emissions()
			helpers.assert_eq(table.concat(keys_posted(engine), ","), "delete_forward",
				"right Command + left Option must delete forward at key down")
			helpers.assert_eq(names(posted[#posted].flags), "left_option",
				"the forward delete must be the word-level Option variant, without AltGr")
			helpers.assert_true(engine:held().delete_forward == true,
				"the forward delete must stay down while held, so it auto-repeats")
			engine:up("left_option", true)
			helpers.assert_eq(table.concat(keys_posted(engine), ","), "delete_forward",
				"a quick release must not delete a second word")
		end)
	end)



	-- =====================
	-- ===== 4) Chords =====
	-- =====================

	--- Returns what an engine posted since its last clear, one line per key
	--- event with the flags an application reads with it.
	--- @param engine table Model engine.
	--- @return string typed
	local function typed(engine)
		local lines = {}
		for _, emission in ipairs(engine:emissions()) do
			if emission.key_code ~= nil then
				local code = control_codes[emission.key_code]
				if code then
					local flags = emission.flags
					local quartz = {
						ctrl = flags.left_control == true or flags.right_control == true,
						alt = flags.left_option == true or flags.right_option == true,
						cmd = flags.left_command == true or flags.right_command == true,
						shift = flags.left_shift == true or flags.right_shift == true,
						fn = flags.fn == true,
					}
					helpers.assert_true(ControlOwner.claim_key(code, emission.phase == "down", quartz),
						"a control event can leave the application comparison only when the real owner consumes it")
					helpers.assert_eq(#diagnostics, 0, "native control routing must not hide listener failures")
				else
					lines[#lines + 1] = emission.phase .. ":" .. emission.key_code .. "[" .. names(emission.flags) .. "]"
				end
			end
		end
		return table.concat(lines, " ")
	end

	helpers.describe("a chord fires, keeps its action down and leaves its first key held (chord-leaves-first-key-held)", function()
		-- Each ordered pair has its own rules, so one graph serves every combo.
		local chords = build(nil, every_combo({ combo = "delete_fwd", tap = "none", hold = "none" }))
		-- A tap slot different from the chord, so what k2 types under a held k1
		-- tells the hold-then-tap rule from k2's own rule.
		local both = build(nil, every_combo({ combo = "opt_backspace", tap = "opt_delete_fwd", hold = "none" }))
		local held_prefix = "ergopti_ke_held_"

		--- Reports whether a key is one of the eight modifier keys (fn is not).
		--- @param key_code string Physical key.
		--- @return boolean modifier_key
		local function is_modifier_key(key_code)
			return KarabinerModel.MODIFIER_KEY_CODES[key_code] == true and key_code ~= "fn"
		end

		--- Returns the variable that marks a key as physically held.
		--- @param key_code string Physical key.
		--- @return string name
		local function held_variable(key_code)
			return held_prefix .. key_code .. "_" .. TOKEN
		end

		--- Returns what holding `first` then tapping `second` twice types the
		--- second time, and what a letter then types, on the slow path.
		--- @param rules table Generated rules.
		--- @param first string Key held first.
		--- @param second string Key tapped under it.
		--- @return string second_typed
		--- @return string letter_typed
		--- @return boolean keeps_flags Whether holding `first` alone presses a flag.
		local function slow_path(rules, first, second)
			local slow = engine_for(rules)
			slow:down(first)
			local keeps_flags = next(slow:pressed()) ~= nil
			slow:tap(second)
			slow:clear()
			slow:tap(second)
			local second_typed = typed(slow)
			slow:clear()
			slow:tap("a")
			return second_typed, typed(slow), keeps_flags
		end

		--- Asserts that releasing every chord key leaves nothing behind.
		--- @param engine table Model engine with only `last` still down.
		--- @param keys_pressed table Both chord keys.
		--- @param last string Key released last.
		--- @param context string Failure context.
		local function assert_released(engine, keys_pressed, last, context)
			engine:up(last, true)
			for _, key_code in ipairs(keys_pressed) do
				helpers.assert_eq(engine:variable(held_variable(key_code)), 0,
					context .. ": releasing both keys must clear the held state of " .. key_code)
			end
			helpers.assert_eq(engine:variable("ergopti_layer_active_" .. TOKEN), 0,
				context .. ": releasing both keys must leave no layer on")
			helpers.assert_eq(names(engine:pressed()), "",
				context .. ": releasing both keys must leave no modifier down")
		end

		helpers.it("every combo chord fires when its two keys go down together (chord-matches-its-own-modifier-keys)", function()
			-- Karabiner tests a chord's modifiers on its first key's key_down, before
			-- either chord key has reached the output, so the chord's own keys can
			-- never be held there: requiring them made every modifier-key chord
			-- unreachable.
			for _, combo_def in ipairs(combos) do
				if not combo_def.menu_hidden then
					local first, second = combo_keys(combo_def)
					local engine = engine_for(chords)
					helpers.assert_not_nil(engine:chord({ first, second }),
						combo_def.id .. ": pressing " .. first .. " then " .. second .. " together must fire the chord")
					local actions_typed = {}
					for _, emission in ipairs(engine:emissions()) do
						if emission.key_code == "delete_forward" then
							actions_typed[#actions_typed + 1] = names(emission.flags)
						end
					end
					helpers.assert_eq(table.concat(actions_typed, "|"), "",
						combo_def.id .. ": the chord must type its action once, with none of its own keys held")
				end
			end
		end)

		helpers.it("a chord keeps a modifier action held, and a key action down to repeat unless its first key is a held modifier key (chord-action-stays-down)", function()
			local modifier_chords = build(nil, every_combo({ combo = "cmd_shift", tap = "none", hold = "none" }))
			for _, combo_def in ipairs(combos) do
				if not combo_def.menu_hidden then
					local first, second = combo_keys(combo_def)
					local held = engine_for(modifier_chords)
					held:chord({ first, second })
					helpers.assert_eq(names(held:pressed()), "left_command,left_shift",
						combo_def.id .. ": a chord holding Cmd+Shift must keep both down, and nothing of its first key")

					local first_flags = engine_for(chords)
					first_flags:down(first)
					local keeps_flags = next(first_flags:pressed()) ~= nil
					local engine = engine_for(chords)
					engine:chord({ first, second })
					if is_modifier_key(first) and keeps_flags then
						helpers.assert_true(engine:held().delete_forward ~= true,
							combo_def.id .. ": after a held modifier key, the chord's key goes out once")
						helpers.assert_eq(names(engine:pressed()), names(first_flags:pressed()),
							combo_def.id .. ": the modifier key must keep what it holds down")
					else
						helpers.assert_true(engine:held().delete_forward == true,
							combo_def.id .. ": a chord typing a key must keep it down, so it auto-repeats")
					end
				end
			end
		end)

		helpers.it("Caps Lock or Tab first: a key chord repeats and a modifier chord holds (chord-plain-first-key-keeps-action)", function()
			-- Caps Lock holds Cmd and Tab holds fn by default: their chords keep the
			-- action down, and the held modifier comes back with the next press.
			for _, combo_id in ipairs({ "caps_tab", "tab_esc" }) do
				local combo_def = nil
				for _, candidate in ipairs(combos) do
					if candidate.id == combo_id then combo_def = candidate end
				end
				local first, second = combo_keys(assert(combo_def, combo_id))
				local key_chord = engine_for(build(nil, { [combo_id] = { combo = "backspace", tap = "none", hold = "none" } }))
				key_chord:chord({ first, second })
				helpers.assert_eq(typed(key_chord), "down:delete_or_backspace[]",
					combo_id .. ": the chord must type Backspace alone")
				helpers.assert_true(key_chord:held().delete_or_backspace == true,
					combo_id .. ": the chord's Backspace must stay down, so it auto-repeats")
				local modifier_chord = engine_for(build(nil, { [combo_id] = { combo = "cmd_shift", tap = "none", hold = "none" } }))
				modifier_chord:chord({ first, second })
				helpers.assert_eq(names(modifier_chord:pressed()), "left_command,left_shift",
					combo_id .. ": the chord must hold Cmd+Shift")
			end
		end)

		helpers.it("after a chord, the second key again under the still-held first key types what holding it first types", function()
			for _, combo_def in ipairs(combos) do
				if not combo_def.menu_hidden then
					local first, second = combo_keys(combo_def)
					local context = combo_def.id .. " (" .. first .. " then " .. second .. ")"
					local slow_second = slow_path(both, first, second)

					local fast = engine_for(both)
					helpers.assert_not_nil(fast:chord({ first, second }), context .. ": the chord must fire")
					fast:up(second, true)
					helpers.assert_eq(fast:variable(held_variable(first)), 1,
						context .. ": the first key must read as held after the chord")
					fast:clear()
					fast:tap(second)
					helpers.assert_eq(typed(fast), slow_second,
						context .. ": pressing the second key again under the held first key")
					assert_released(fast, { first, second }, first, context)
				end
			end
		end)

		helpers.it("after a chord, a letter under the still-held first key has its held modifiers unless the chord keeps its action down (chord-first-key-modifiers)", function()
			-- Karabiner keeps one `to` entry down. A modifier key keeps it for its
			-- held modifiers when the action is a plain key; any other first key
			-- gives it to the action, and its held modifier comes back with its
			-- next press. An action that keeps nothing down leaves it to them.
			local leaves_room = build(nil, every_combo({ combo = "layer_off", tap = "opt_delete_fwd", hold = "none" }))
			local checked = 0
			for _, combo_def in ipairs(combos) do
				if not combo_def.menu_hidden then
					local first, second = combo_keys(combo_def)
					local context = combo_def.id .. " (" .. first .. " then " .. second .. ")"
					local _, slow_letter, keeps_flags = slow_path(both, first, second)

					local fast = engine_for(both)
					fast:chord({ first, second })
					fast:up(second, true)
					fast:clear()
					fast:tap("a")
					if keeps_flags and not is_modifier_key(first) then
						helpers.assert_eq(typed(fast), "down:a[]",
							context .. ": the chord's action took the place of the first key's held modifier")
					else
						helpers.assert_eq(typed(fast), slow_letter,
							context .. ": a letter under the held first key types as on the slow path")
					end

					if keeps_flags then
						checked = checked + 1
						local room_second, room_letter = slow_path(leaves_room, first, second)
						local room = engine_for(leaves_room)
						helpers.assert_not_nil(room:chord({ first, second }), context .. ": the chord must fire")
						room:up(second, true)
						room:clear()
						room:tap(second)
						helpers.assert_eq(typed(room), room_second,
							context .. ": the second key again, after a chord that keeps nothing down")
						room:clear()
						room:tap("a")
						helpers.assert_eq(typed(room), room_letter,
							context .. ": a letter keeps the first key's held modifiers after a chord that keeps nothing down")
						assert_released(room, { first, second }, first, context)
					end
				end
			end
			helpers.assert_true(checked >= 100, "the matrix must reach first keys holding a modifier, reached " .. checked)
		end)

		helpers.it("a chord under AltGr keeps AltGr for the letters typed after it", function()
			-- The reported case: right Command holds AltGr; after right Command +
			-- Tab together, a letter typed with right Command still down is AltGr's.
			local engine = engine_for(both)
			engine:chord({ "right_command", "tab" })
			engine:up("tab", true)
			engine:clear()
			engine:tap("a")
			helpers.assert_eq(typed(engine), "down:a[right_option]",
				"a letter typed under the still-held right Command must carry AltGr")
		end)

		helpers.it("in symmetric mode, a chord pressed in either order leaves the key pressed first held (chord-symmetric-restores-first-key)", function()
			local symmetric = build(nil, every_combo({ combo = "opt_backspace", tap = "opt_delete_fwd", hold = "none" }), true)
			local checked = 0
			for _, combo_def in ipairs(combos) do
				-- The canonical half of each pair owns the chord for both orders.
				if not combo_def.menu_hidden and not non_canonical[combo_def.id] then
					local k1, k2 = combo_keys(combo_def)
					for _, order in ipairs({ { k1, k2 }, { k2, k1 } }) do
						local first, second = order[1], order[2]
						local context = combo_def.id .. " (" .. first .. " then " .. second .. ", symmetric)"
						local slow_second = slow_path(symmetric, first, second)
						local fast = engine_for(symmetric)
						helpers.assert_not_nil(fast:chord(order), context .. ": the chord must fire")
						fast:up(second, true)
						helpers.assert_eq(fast:variable(held_variable(first)), 1,
							context .. ": the key pressed first must read as held")
						helpers.assert_eq(fast:variable(held_variable(second)), 0,
							context .. ": the released key must not read as held")
						fast:clear()
						fast:tap(second)
						helpers.assert_eq(typed(fast), slow_second,
							context .. ": pressing the other key again under the key pressed first")
						assert_released(fast, { first, second }, first, context)
						checked = checked + 1
					end
				end
			end
			helpers.assert_true(checked >= 170, "the symmetric matrix must press both orders of every pair, reached " .. checked)
		end)

		helpers.it("the shipped defaults emit no chord the hold-then-tap rule already types (redundant-chord-skipped)", function()
			-- A chord whose action is its combo's tap slot adds nothing when its first
			-- key has a hold, but makes that key wait for a partner on every press.
			local state = Config.build_recommended_state(keys, combos)
			local hold_of = {}
			for _, key_def in ipairs(keys) do
				hold_of[key_def.from.key_code] = (state.tap_hold_config[key_def.id] or {}).hold or "none"
			end
			local rules = build()
			local skipped = 0
			for _, combo_def in ipairs(combos) do
				local slots = state.mod_combos_config[combo_def.id] or {}
				local first, second = combo_keys(combo_def)
				if not combo_def.menu_hidden and slots.combo ~= nil and slots.combo ~= "none"
					and slots.combo == slots.tap and hold_of[first] ~= "none" then
					skipped = skipped + 1
					helpers.assert_nil(engine_for(rules):chord({ first, second }),
						combo_def.id .. ": the hold-then-tap rule already types " .. slots.combo)
				end
			end
			helpers.assert_true(skipped >= 5, "expected the five right Command defaults, found " .. skipped)
			for _, rule in ipairs(rules) do
				for _, manipulator in ipairs(rule.manipulators or {}) do
					local simultaneous = manipulator.from and manipulator.from.simultaneous
					helpers.assert_true(type(simultaneous) ~= "table" or simultaneous[1].key_code ~= "right_command",
						"right Command must not wait for a chord partner by default: " .. tostring(rule.description))
				end
			end
		end)
	end)



	-- ==========================================================
	-- ===== 5) Hammerspoon triggers told apart by modifiers =====
	-- ==========================================================

	-- Hammerspoon binds each of these triggers as an exact-match hotkey
	-- (platform/remap/watchers.lua), so a modifier added by the hand turns one
	-- action into another or into nothing.
	local TRIGGER_KEY = "f17"

	-- Every modifier flag a hand or a hold can have down when a rule fires.
	local HELD_FLAGS = {
		"left_shift", "right_shift", "left_control", "right_control", "left_option",
		"right_option", "left_command", "right_command", "fn",
	}

	-- Every state a rule can fire under: each flag alone, Caps Lock on alone and
	-- with each flag, and two flags at once.
	local HELD_STATES = {}
	for _, flag in ipairs(HELD_FLAGS) do HELD_STATES[#HELD_STATES + 1] = { flag } end
	HELD_STATES[#HELD_STATES + 1] = { "caps_lock" }
	for _, flag in ipairs(HELD_FLAGS) do HELD_STATES[#HELD_STATES + 1] = { "caps_lock", flag } end
	HELD_STATES[#HELD_STATES + 1] = { "left_shift", "left_control" }

	--- Returns the flags a trigger must carry under a held state: its own, and
	--- Caps Lock while the lock is on, since no rule may claim it.
	--- @param action table Trigger action.
	--- @param state table Held flags.
	--- @return string flags Sorted flag names.
	local function expected_flags(action, state)
		local flags = action_flags(action)
		for _, flag in ipairs(state) do
			if flag == "caps_lock" then flags.caps_lock = true end
		end
		return names(flags)
	end

	--- Reports whether an engine sent macOS a Caps Lock press.
	--- @param engine table Model engine.
	--- @return boolean toggled
	local function toggled_caps_lock(engine)
		for _, emission in ipairs(engine:emissions()) do
			if emission.key_code == "caps_lock" then return true end
		end
		return false
	end

	-- Hold slots of each shape: nothing, a modifier key, a modifier key with its
	-- own modifiers, and a layer.
	local HOLDS = { "none", "shift", "cmd_shift", "layer" }

	--- Returns the actions whose output is the shared trigger key.
	--- @return table triggers Catalogue actions.
	local function trigger_actions()
		local found = {}
		for _, action in ipairs(actions) do
			for _, event in ipairs(action.karabiner_to or {}) do
				if event.key_code == TRIGGER_KEY then found[#found + 1] = action end
			end
		end
		return found
	end

	--- Returns the flags every trigger posted by an engine carried.
	--- @param engine table Model engine.
	--- @return table flags_list One flag-name string per trigger posted.
	local function triggers_posted(engine)
		local posted = {}
		for _, emission in ipairs(engine:emissions()) do
			if emission.key_code == TRIGGER_KEY then posted[#posted + 1] = names(emission.flags) end
		end
		return posted
	end

	--- Reports whether a manipulator is the tap-hold rule of `key_code` itself.
	--- @param manipulator table|nil Manipulator the model ran.
	--- @param key_code string Physical key.
	--- @return boolean own
	local function is_own_rule(manipulator, key_code)
		local held_name = "ergopti_ke_held_" .. key_code .. "_" .. TOKEN
		for _, event in ipairs(manipulator and manipulator.to or {}) do
			local variable = event.set_variable
			if type(variable) == "table" and variable.name == held_name and variable.value == 1 then
				return true
			end
		end
		return false
	end

	--- Returns whether a tap-hold key's rule accepts any held modifier.
	--- @param key_def table tap_hold_keys.json entry.
	--- @return boolean open
	local function accepts_held_modifiers(key_def)
		for _, modifier in ipairs(key_def.from.modifiers and key_def.from.modifiers.optional or {}) do
			if modifier == "any" then return true end
		end
		return false
	end

	helpers.describe("a trigger told apart by modifiers carries only its own (exact-modifier-trigger)", function()
		local triggers = trigger_actions()

		helpers.it("marks every trigger action exact_modifiers in the catalogue", function()
			helpers.assert_true(#triggers >= 4, "expected the four F17 actions, found " .. #triggers)
			for _, action in ipairs(triggers) do
				helpers.assert_true(action.exact_modifiers == true,
					action.id .. " shares its trigger with other actions and must be marked exact_modifiers")
			end
		end)

		helpers.it("a tap-hold key taps each trigger bare under any held modifier, and its hold keeps them (caps-lock-never-claimed)", function()
			local covered = 0
			for _, action in ipairs(triggers) do
				for _, hold in ipairs(HOLDS) do
					-- Each key is pressed under seeded flags alone: one graph per pair.
					local rules = build(every_key({ tap = action.id, hold = hold }))
					for _, key_def in ipairs(keys) do
						if accepts_held_modifiers(key_def) then
							local key_code = key_def.from.key_code
							for _, state in ipairs(HELD_STATES) do
								local context = action.id .. " on " .. key_code .. " (hold " .. hold .. ") under "
									.. table.concat(state, "+")
								local engine = engine_for(rules, state)
								-- CapsWord's AltGr+CapsLock rule takes that chord first by design.
								if is_own_rule(engine:down(key_code), key_code) then
									covered = covered + 1
									for _, held in ipairs(state) do
										helpers.assert_true(engine:pressed()[held] == true,
											context .. ": the hold must keep " .. held .. " (pressed: "
												.. names(engine:pressed()) .. ")")
									end
									engine:up(key_code, true)
									helpers.assert_eq(table.concat(triggers_posted(engine), "|"), expected_flags(action, state),
										context .. ": the tap must send the trigger with its own modifiers only")
									helpers.assert_true(not toggled_caps_lock(engine),
										context .. ": the rule must never toggle Caps Lock")
								end
							end
						end
					end
				end
			end
			helpers.assert_true(covered >= 900, "the matrix must reach the key's own rule, reached " .. covered)
		end)

		helpers.it("a combo taps each trigger bare under any held modifier", function()
			-- Karabiner lifts one press per claimed flag. A flag the holder's own
			-- hold also presses is down twice and stays down once: two keys holding
			-- one modifier is a limit of the pinned core, not of these rules.
			for _, action in ipairs(triggers) do
				local rules = build(nil, every_combo({ combo = "none", tap = action.id, hold = "none" }))
				local holder_flags = {}
				for _, key_def in ipairs(keys) do
					local holder = engine_for(rules)
					holder:down(key_def.from.key_code)
					holder_flags[key_def.from.key_code] = holder:pressed()
				end
				local covered = 0
				for _, combo_def in ipairs(combos) do
					if not combo_def.menu_hidden then
						local first, second = combo_keys(combo_def)
						for _, state in ipairs(HELD_STATES) do
							local shared = false
							for _, held in ipairs(state) do shared = shared or holder_flags[first][held] == true end
							local context = action.id .. " on " .. combo_def.id .. " under " .. table.concat(state, "+")
							local engine = engine_for(rules, state)
							engine:down(first)
							if not shared and is_combo_rule(engine:down(second), first) then
								covered = covered + 1
								engine:up(second, true)
								helpers.assert_eq(table.concat(triggers_posted(engine), "|"), expected_flags(action, state),
									context .. ": the tap must send the trigger with its own modifiers only")
								helpers.assert_true(not toggled_caps_lock(engine),
									context .. ": the rule must never toggle Caps Lock")
							end
						end
					end
				end
				helpers.assert_true(covered >= 700, "the combo matrix reached only " .. covered .. " cases")
			end
		end)

		helpers.it("a chord sends each trigger bare under any held modifier", function()
			for _, action in ipairs(triggers) do
				local rules = build(nil, every_combo({ combo = action.id, tap = "none", hold = "none" }))
				for _, combo_def in ipairs(combos) do
					if not combo_def.menu_hidden then
						local first, second = combo_keys(combo_def)
						for _, state in ipairs(HELD_STATES) do
							local context = action.id .. " on " .. combo_def.id .. " under " .. table.concat(state, "+")
							local engine = engine_for(rules, state)
							helpers.assert_not_nil(engine:chord({ first, second }), context .. ": the chord must fire")
							helpers.assert_eq(table.concat(triggers_posted(engine), "|"), expected_flags(action, state),
								context .. ": the chord must send the trigger with its own modifiers only")
							helpers.assert_true(not toggled_caps_lock(engine),
								context .. ": the chord must never toggle Caps Lock")
						end
					end
				end
			end
		end)

		helpers.it("Shift held, then AltGr and a Tab tap cycles the app's windows (shift-altgr-tab)", function()
			-- The shipped defaults: left Shift holds Shift, right Command holds
			-- AltGr, and AltGr then a Tab tap is cycle_windows_in_app on bare F17.
			local engine = engine_for(build())
			engine:down("left_shift")
			engine:down("right_command")
			engine:clear()
			engine:tap("tab")
			helpers.assert_eq(table.concat(triggers_posted(engine), "|"), "",
				"Shift+F17 is alt_tab_windows: the held Shift must not reach the trigger")
		end)
	end)
end)
