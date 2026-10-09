--- tests/unit/platform/remap/test_generator_typing_rollover.lua

--- ==============================================================================
--- MODULE: Typing Priority In Generated Karabiner Rules
--- DESCRIPTION:
--- Replays the actual generated graph through the pinned Karabiner model.
--- A typing key rolled into the next press types its native tap, before that
--- press and without its configured hold modifier. Slow holds remain available.
--- ==============================================================================

local helpers = require("tests.helpers")
local Model = require("tests.support.karabiner_model")
local Lease = require("platform.remap.lease_contract")
local TOKEN = "0123456789abcdef0123456789abcdef"
local KEYS = { "escape", "tab", "return_or_enter", "spacebar", "delete_or_backspace" }

helpers.with_fresh_modules({ "platform.remap.generator", "adapters.file_system", "infra.logger" }, function()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	local Generator = helpers.load_with_stubs("platform.remap.generator")
	local actions = {
		{ id = "none", label = "None", karabiner_to = {} },
		{ id = "shift", label = "Shift", karabiner_to = { { key_code = "left_shift" } } },
		{ id = "layer", label = "Navigation", karabiner_to = {
			{ set_variable = { name = "layer_active", value = 1 } },
		}, karabiner_to_after_key_up = { { set_variable = { name = "layer_active", value = 0 } } } },
		{ id = "ctrl", label = "Control", karabiner_to = { { key_code = "left_control" } } },
		{ id = "other", label = "Other", karabiner_to = { { key_code = "f2" } } },
	}

	--- Generates one real tap-hold key with optional per-key timing and tap.
	--- @param key string Karabiner key code.
	--- @param timeout number|nil Per-key threshold.
	--- @param tap string|nil Tap action; defaults to native.
	--- @return table engine
	local function engine(key, timeout, tap, hold)
		local config, err, legacy = Generator.build_karabiner_json({
			tap_hold_config = { [key] = { tap = tap or "none", hold = hold or "shift", timeout_ms = timeout } },
			mod_combos_config = {}, tap_hold_timeout_ms = 200,
			simultaneous_threshold_ms = 100, combo_symmetric = false,
		}, actions, { { id = key, label = key, from = { key_code = key, modifiers = { optional = { "any" } } } } },
			{}, {}, helpers.driver_root() .. "platform/remap/data/", TOKEN)
		helpers.assert_nil(err)
		return Model.new(config.profiles[1].complex_modifications.rules, {
			variables = { [Generator.mode_variable_name(TOKEN)] = 1 },
		}), legacy
	end

	--- Just the keys an application observes, dropping ledger and variable events.
	--- @param model table Karabiner model.
	--- @return table key names
	local function typed(model)
		local out = {}
		for _, event in ipairs(model:emissions()) do
			if event.key_code and not Model.MODIFIER_KEY_CODES[event.key_code] then
				out[#out + 1] = event.key_code
			end
		end
		return out
	end

	helpers.describe("typing priority for native tap-hold keys", function()
		for _, key in ipairs(KEYS) do
			helpers.it("typing-rollover " .. key .. " precedes the next letter without its hold", function()
				local model = engine(key)
				model:down(key)
				helpers.assert_eq(model:pressed(), {}, "typing must not raise the hold at key-down")
				model:down("a")
				helpers.assert_eq(typed(model), { key, "a" })
				helpers.assert_eq(model:pressed(), {})
				model:up(key, true)
				model:up("a", true)
				helpers.assert_eq(typed(model), { key, "a" }, "release must not type the tap twice")
			end)
			helpers.it("typing-rollover " .. key .. " alone types once and cancels pending timers", function()
				local model = engine(key)
				model:down(key)
				model:advance(199)
				model:up(key, true)
				model:advance(500)
				helpers.assert_eq(typed(model), { key })
				helpers.assert_eq(model:pressed(), {})
			end)
			helpers.it("typing-rollover " .. key .. " long hold activates exactly at its threshold", function()
				local model = engine(key)
				model:down(key)
				model:advance(199)
				helpers.assert_eq(model:pressed(), {})
				model:advance(1)
				helpers.assert_eq(model:pressed(), { left_shift = true })
				model:down("a")
				model:up("a", true)
				model:up(key, true)
				helpers.assert_eq(typed(model), { "a" }, "a long hold must never type a delayed tap")
				helpers.assert_eq(model:pressed(), {})
			end)
			helpers.it("typing-rollover " .. key .. " canceled hold never appears later", function()
				local model = engine(key)
				model:down(key)
				model:advance(10)
				model:down("a")
				model:advance(500)
				helpers.assert_eq(typed(model), { key, "a" })
				helpers.assert_eq(model:pressed(), {})
				model:up("a", true)
				model:up(key, true)
			end)
			helpers.it("typing-rollover " .. key .. " uses the per-key threshold for tap and both timers", function()
				local model = engine(key, 350)
				model:down(key)
				model:advance(349)
				helpers.assert_eq(model:pressed(), {})
				model:advance(1)
				helpers.assert_eq(model:pressed(), { left_shift = true })
				model:up(key, true)
				helpers.assert_eq(typed(model), {})
				helpers.assert_eq(model:pressed(), {})
			end)

		end
		helpers.it("typing-rollover custom taps retain their explicit action rather than becoming native", function()
			local model = engine("spacebar", nil, "other")
			model:tap("spacebar")
			helpers.assert_eq(typed(model), { "f2" })
			helpers.assert_eq(model:pressed(), {})
		end)
		helpers.it("typing-rollover other catalogue keys retain immediate modifier holds", function()
			local model = engine("caps_lock")
			model:down("caps_lock")
			helpers.assert_eq(model:pressed(), { left_shift = true })
			model:up("caps_lock", false)
			helpers.assert_eq(model:pressed(), {})
		end)
		helpers.it("typing-rollover timed Control hold preserves an already held physical Shift", function()
			local model = engine("spacebar", nil, nil, "ctrl")
			model:down("left_shift")
			model:down("spacebar")
			model:advance(200)
			helpers.assert_eq(model:pressed(), { left_shift = true, left_control = true })
			model:up("spacebar", true)
			helpers.assert_eq(model:pressed(), { left_shift = true })
			model:up("left_shift", true)
			helpers.assert_eq(model:pressed(), {})
		end)

		helpers.it("typing-rollover a pending layer key never releases a layer enabled by another owner", function()
			local model = engine("spacebar", nil, nil, "layer")
			local layer = Lease.runtime_variable_name("layer_active", TOKEN)
			model:down("spacebar")
			model:down("a")
			model.variables[layer] = 1
			model:up("spacebar", true)
			helpers.assert_eq(model.variables[layer], 1, "no inactive hold may clear someone else's layer")
			model:up("a", true)
		end)
		helpers.it("typing-rollover an activated layer is released and its activation marker reset", function()
			local model = engine("spacebar", nil, nil, "layer")
			local layer = Lease.runtime_variable_name("layer_active", TOKEN)
			model:down("spacebar")
			model:advance(200)
			helpers.assert_eq(model.variables[layer], 1)
			model:up("spacebar", true)
			helpers.assert_eq(model.variables[layer], 0)
			for name, value in pairs(model.variables) do
				if name ~= Generator.mode_variable_name(TOKEN) then
					helpers.assert_eq(value, 0, "every physical/hold marker must be reset: " .. name)
				end
			end
			helpers.assert_eq(typed(model), { "f20", "f19" },
				"only the layer bridge activation/release keys are emitted, never the native tap")
		end)
		helpers.it("typing-rollover another key's release never cancels a pending hold", function()
			local model = engine("spacebar")
			model:down("a")
			model:down("spacebar")
			model:up("a", true)
			model:advance(200)
			helpers.assert_eq(model:pressed(), { left_shift = true })
			model:up("spacebar", true)
			helpers.assert_eq(typed(model), { "a" })
			helpers.assert_eq(model:pressed(), {})
		end)

		for _, interrupted in ipairs({ "off", "paused", "revoked" }) do
			helpers.it("typing-rollover a timer cannot activate a hold after its generation is " .. interrupted, function()
				local model = engine("spacebar")
				model:down("spacebar")
				local variables = Lease.variables(TOKEN)
				if interrupted == "revoked" then model.variables[variables.revoked] = 1
				else model.variables[variables.mode] = interrupted == "off" and 0 or 2 end
				model:advance(200)
				helpers.assert_eq(model:pressed(), {}, "a saved timer must re-check current generation authority")
				model:up("spacebar", true)
				helpers.assert_eq(model:pressed(), {})
			end)
		end
		helpers.it("typing-rollover historical recognition retains the original immediate-hold graph", function()
			local _, legacy = engine("spacebar")
			local found = 0
			for _, rule in ipairs(legacy) do
				for _, manipulator in ipairs(rule.manipulators) do
					if manipulator.from.key_code == "spacebar" and manipulator.to_if_alone
						and manipulator.to_if_alone[1].key_code == "spacebar" then
						found = found + 1
						helpers.assert_nil(manipulator.to_if_held_down, "the historic fingerprint must remain pre-timer")
						local shifted = false
						for _, event in ipairs(manipulator.to) do shifted = shifted or event.key_code == "left_shift" end
						helpers.assert_true(shifted, "historical holds were immediate")
					end
				end
			end
			helpers.assert_true(found > 0, "the legacy graph must contain Space's old rule")
		end)

	end)
end)
