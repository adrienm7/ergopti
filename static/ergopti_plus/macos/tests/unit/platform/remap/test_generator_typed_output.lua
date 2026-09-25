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
	}
	-- The native TOML codec is absent from the headless runner; the catalogues
	-- read here are JSON and the shared defaults use the pure-Lua reader.
	local toml_stub = { encode = function() return "" end, decode = function() return {} end }
	package.loaded["toml_codec"] = toml_stub
	package.loaded["infra.toml.codec"] = toml_stub

	local Config    = helpers.load_with_stubs("platform.remap.config")
	local Generator = helpers.load_with_stubs("platform.remap.generator")

	local actions = assert(Config.load_available_actions(DATA_DIR .. "actions.json"))
	local keys    = assert(Config.load_tap_hold_keys(DATA_DIR .. "tap_hold_keys.json"))
	local combos  = assert(Config.load_mod_combos(DATA_DIR .. "mod_combos.json"))
	local non_canonical = Config.compute_non_canonical_combos(combos)
	local by_id = {}
	for _, action in ipairs(actions) do by_id[action.id] = action end

	--- Builds the shipped defaults with some assignments replaced.
	--- @param tap_holds table|nil Key id → { tap, hold }.
	--- @param mod_combos table|nil Combo id → { combo, tap, hold }.
	--- @return table rules The generated complex_modifications rules.
	local function build(tap_holds, mod_combos)
		local state = Config.build_default_state(keys, combos)
		for id, slots in pairs(tap_holds or {}) do state.tap_hold_config[id] = copy(slots) end
		for id, slots in pairs(mod_combos or {}) do state.mod_combos_config[id] = copy(slots) end
		local config, err = Generator.build_karabiner_json(
			state, actions, keys, combos, non_canonical, DATA_DIR, TOKEN)
		assert(config, "generation failed: " .. tostring(err))
		return config.profiles[1].complex_modifications.rules
	end

	--- Starts a Karabiner model on an ACTIVE lease.
	--- @param rules table Generated rules.
	--- @return table engine
	local function engine_for(rules)
		return KarabinerModel.new(rules, {
			variables = { [Generator.mode_variable_name(TOKEN)] = 1 },
		})
	end



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

				helpers.it("tapping " .. sticky.id .. " under each held modifier key arms it", function()
					local rules = build({ right_option = { tap = sticky.id, hold = base.id } })
					for _, held in ipairs(MODIFIER_KEYS) do
						local engine = engine_for(rules)
						engine:down(held)
						engine:clear()
						engine:tap("right_option")
						local armed = false
						for _, emission in ipairs(engine:emissions()) do
							if emission.phase == "tap" and type(emission.event.sticky_modifier) == "table" then
								armed = true
							end
						end
						helpers.assert_true(armed,
							"with " .. held .. " held, a tap of the " .. sticky.id .. " key must arm the one-shot")
					end
				end)

				helpers.it("holding the " .. sticky.id .. " key holds " .. base.id .. " under each held modifier key", function()
					local rules = build({ right_option = { tap = sticky.id, hold = base.id } })
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

	helpers.describe("a key with only a tap types it at key down, like the native key (tap-only-key-types-its-tap)", function()
		helpers.it("every tap-hold key types its tap alone at key down, keeps it down to repeat, and adds nothing on release", function()
			for _, key_def in ipairs(keys) do
				local key_code = key_def.from.key_code
				local rules = build({ [key_def.id] = { tap = "delete_fwd", hold = "none" } })
				for _, within_timeout in ipairs({ true, false }) do
					local engine = engine_for(rules)
					engine:down(key_code)
					helpers.assert_eq(table.concat(keys_posted(engine), ","), "delete_forward",
						key_code .. " with no hold must type its tap alone when pressed")
					helpers.assert_true(engine:held().delete_forward == true,
						key_code .. " must keep its tap down while held, so it auto-repeats")
					engine:up(key_code, within_timeout)
					helpers.assert_eq(table.concat(keys_posted(engine), ","), "delete_forward",
						key_code .. " must type nothing more on release")
				end
			end
		end)

		helpers.it("every tap-hold key keeps its tap when the next key goes down before its release", function()
			-- Fast typing overlaps presses. Karabiner drops a pending to_if_alone
			-- on any later key_down, so a tap typed on release would be lost.
			for _, key_def in ipairs(keys) do
				local key_code = key_def.from.key_code
				local rules = build({ [key_def.id] = { tap = "delete_fwd", hold = "none" } })
				local engine = engine_for(rules)
				engine:down(key_code)
				engine:down("a")
				engine:up(key_code, true)
				engine:up("a", true)
				helpers.assert_eq(table.concat(keys_posted(engine), ","), "delete_forward,a",
					key_code .. " followed by an overlapping key must type both")
			end
		end)

		helpers.it("a key with neither slot stays the native key", function()
			for _, key_def in ipairs(keys) do
				local key_code = key_def.from.key_code
				local rules = build({ [key_def.id] = { tap = "none", hold = "none" } })
				local engine = engine_for(rules)
				engine:down(key_code)
				helpers.assert_eq(table.concat(keys_posted(engine), ","), key_code,
					key_code .. " with no assignment must go down as itself")
			end
		end)
	end)
end)
