--- tests/unit/meta/test_tap_hold_loader.lua

--- ==============================================================================
--- MODULE: Tap-Hold Configuration Rules
--- DESCRIPTION:
--- The user's tap_hold.toml laid over the shared defaults, with the Windows
--- loader's rules. The kanata path merged field by field and kept both a
--- default modifier and a chosen layer, so choosing the navigation layer on
--- CapsLock left it Ctrl; "none" could not clear a hold either.
--- ==============================================================================

local helpers = require("tests.helpers")
local Config = require("platform.remap.tap_hold_loader")

local DEFAULTS = require("infra.paths").shared("tap_hold/defaults.toml")

--- Loads the defaults with a user file holding `text`.
local function load(text)
	local path = os.tmpname()
	local fh = assert(io.open(path, "w"))
	fh:write(require("tests.support.tap_hold_fixture").with_preset(text))
	fh:close()
	local loaded = Config.load(DEFAULTS, path)
	os.remove(path)
	return loaded
end

helpers.describe("tap-hold config: the user file over the shared defaults", function()

	helpers.it("keeps every key neutral when the user file is absent", function()
		local loaded = Config.load(DEFAULTS, "/nonexistent/tap_hold.toml")
		helpers.assert_eq(loaded.enabled, false)
		helpers.assert_nil(next(loaded.keys))
		helpers.assert_nil(loaded.user_error)
	end)

	helpers.it("changes one field and keeps the others", function()
		local loaded = load('[tap_hold.keys.left_shift]\ntap_action = "paste"\n')
		helpers.assert_eq(loaded.keys.left_shift.tap_action, "paste")
		helpers.assert_eq(loaded.keys.left_shift.hold_modifier, "shift")
		helpers.assert_eq(loaded.keys.left_ctrl.tap_action, "paste", "other keys keep their defaults")
	end)

	helpers.it("drops the default modifier when a layer is chosen, and the reverse", function()
		local loaded = load('[tap_hold.keys.caps_lock]\nhold_layer = "nav"\n[tap_hold.keys.left_alt]\nhold_modifier = "alt"\n')
		helpers.assert_eq(loaded.keys.caps_lock.hold_layer, "nav")
		helpers.assert_nil(loaded.keys.caps_lock.hold_modifier, "CapsLock is the layer, no longer Ctrl")
		helpers.assert_eq(loaded.keys.left_alt.hold_modifier, "alt")
		helpers.assert_nil(loaded.keys.left_alt.hold_layer)
	end)

	helpers.it("lets an empty hold clear the default one", function()
		local loaded = load('[tap_hold.keys.caps_lock]\nhold_modifier = ""\n')
		helpers.assert_eq(loaded.keys.caps_lock.hold_modifier, "")
	end)

	helpers.it("starts from no key when defaults are not inherited", function()
		local loaded = load('[tap_hold]\ninherit_defaults = false\n')
		helpers.assert_nil(next(loaded.keys), "Disable all leaves no tap-hold")
	end)

	helpers.it("reads the feature switch", function()
		helpers.assert_true(not load('[tap_hold]\nenabled = false\n').enabled)
	end)

	helpers.it("falls back to 0.2 s for a threshold out of range", function()
		local loaded = load('[tap_hold.keys.left_shift]\ntime_activation_seconds = 30\n')
		helpers.assert_eq(loaded.keys.left_shift.time_activation_seconds, Config.FALLBACK_THRESHOLD_SECONDS)
	end)

	helpers.it("disables a key with a field of the wrong type", function()
		local loaded = load('[tap_hold.keys.left_shift]\ntap_action = 3\n')
		helpers.assert_eq(loaded.keys.left_shift.enabled, false)
	end)

	helpers.it("warns once about a key or field it does not have, and applies the rest (config-outdated-tap-hold)", function()
		local Logger = require("logger.shim")
		local real_error, real_warn, errors, warnings = Logger.error, Logger.warn, {}, {}
		Logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		Logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		local path = os.tmpname()
		local ok, err = pcall(function()
			local fh = assert(io.open(path, "w"))
			fh:write(require("tests.support.tap_hold_fixture").with_preset(
				'[tap_hold.keys.retired_key]\nhold_layer = "nav"\n'
					.. '[tap_hold.keys.left_shift]\nretired_field = 1\ntime_activation_seconds = 0.3\n'))
			fh:close()
			local loaded = Config.load(DEFAULTS, path)
			helpers.assert_nil(loaded.keys.retired_key, "a key the engine cannot remap is left out")
			helpers.assert_nil(loaded.keys.left_shift.retired_field, "an unknown field is left out")
			helpers.assert_eq(loaded.keys.left_shift.time_activation_seconds, 0.3, "the rest of the key applies")
			helpers.assert_eq(errors, {}, "outdated entries are never an ERROR")
			local text = table.concat(warnings, "\n")
			helpers.assert_eq(#warnings, 2, text)
			helpers.assert_contains(text, "'tap_hold.keys.retired_key' in '" .. path .. "'")
			helpers.assert_contains(text, "'tap_hold.keys.left_shift.retired_field' in '" .. path .. "'")
			Config.load(DEFAULTS, path)
			helpers.assert_eq(#warnings, 2, "a reload does not name them again")
		end)
		Logger.error, Logger.warn = real_error, real_warn
		os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("keeps a bad value of the shipped defaults an ERROR (config-outdated-tap-hold-shipped)", function()
		-- A shipped-data bug is not the user's outdated entry: it must stay loud.
		local shipped = assert(io.open(DEFAULTS, "rb"))
		local text = shipped:read("*a")
		shipped:close()
		local broken, replaced = text:gsub('(%[tap_hold%.keys%.caps_lock%][^%[]-hold_modifier%s*=%s*)"ctrl"', '%1"hyper"', 1)
		helpers.assert_eq(replaced, 1, "the fixture edits the shipped caps_lock hold")
		local defaults_path, user_path = os.tmpname(), os.tmpname()
		local Logger = require("logger.shim")
		local real_error, real_warn, errors, warnings = Logger.error, Logger.warn, {}, {}
		Logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		Logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		local ok, err = pcall(function()
			local fh = assert(io.open(defaults_path, "wb"))
			fh:write(broken)
			fh:close()
			fh = assert(io.open(user_path, "wb"))
			fh:write("[tap_hold]\nenabled = true\ninherit_defaults = true\n")
			fh:close()
			local loaded = Config.load(defaults_path, user_path)
			helpers.assert_nil(loaded.keys.caps_lock.hold_modifier, "the bad hold is still dropped")
			helpers.assert_eq(#errors, 1, table.concat(errors, " | "))
			helpers.assert_contains(errors[1], "hyper")
			helpers.assert_contains(errors[1], defaults_path)
			for _, line in ipairs(warnings) do
				helpers.assert_true(line:find("hyper", 1, true) == nil, "not reported as the user's entry: " .. line)
			end
		end)
		Logger.error, Logger.warn = real_error, real_warn
		os.remove(defaults_path)
		os.remove(user_path)
		if not ok then error(err, 0) end
	end)

	helpers.it("reports a malformed user file and keeps every key neutral", function()
		local loaded = load('[tap_hold.keys.left_shift\ntap_action = "paste"\n')
		helpers.assert_eq(loaded.user_error, "malformed")
		helpers.assert_eq(loaded.enabled, false)
		helpers.assert_nil(next(loaded.keys))
	end)

end)

-- A hold spelled any other way than the picker's id used to reach the engine
-- as is: 'altgr', 'AltGr' or 'Ctrl + Shift' matched no modifier and the key
-- had no hold at all, without a word, and a valid but reordered combination
-- held its modifiers while the tray showed no hold.
helpers.describe("tap-hold config: the spellings of a hold", function()

	local Engine = require("platform.remap.tap_hold_engine")
	local HoldOptions = require("tap_hold.hold_options")

	--- The modifier codes the engine presses when `key_id` goes down.
	local function held_codes(keys, key_id)
		local engine = Engine.new({ keys = keys, tap_min_ms = 50, one_shot_timeout_ms = 2000, key_text = function() return nil end,
			plan_text = function() return nil end, one_shot_result = function() return nil end, })
		local codes = {}
		for _, event in ipairs(engine:process(Engine.KEY_CODES[key_id], 1, 0) or {}) do
			codes[#codes + 1] = event.code
		end
		return codes
	end

	--- Loads `hold_modifier = value` on AltGr and captures the errors and
	--- warnings logged.
	local function load_hold(field, value)
		local Logger = require("logger.shim")
		local real_error, real_warn, errors = Logger.error, Logger.warn, {}
		Logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		Logger.warn = Logger.error
		local ok, loaded = pcall(load, '[tap_hold.keys.alt_gr]\n' .. field .. ' = "' .. value .. '"\n')
		Logger.error, Logger.warn = real_error, real_warn
		if not ok then error(loaded, 0) end
		return loaded, errors
	end

	helpers.it("reads the other spellings of a modifier as its id", function()
		for spelling, id in pairs({
			altgr = "alt_gr", AltGr = "alt_gr", ALT_GR = "alt_gr", ralt = "alt_gr",
			["Ctrl + Shift"] = "ctrl+shift", ["shift+ctrl"] = "ctrl+shift", ["ctrl shift"] = "ctrl+shift",
			["Win + AltGr + Ctrl"] = "ctrl+alt_gr+win", LCtrl = "ctrl", [" + "] = "",
		}) do
			local loaded, errors = load_hold("hold_modifier", spelling)
			helpers.assert_eq(loaded.keys.alt_gr.hold_modifier, id, "'" .. spelling .. "'")
			helpers.assert_true(loaded.keys.alt_gr.enabled ~= false, "'" .. spelling .. "' is accepted")
			helpers.assert_eq(errors, {}, "'" .. spelling .. "' is not an error")
		end
	end)

	helpers.it("takes the other spellings from the shared picker alone (hold-alias-single-source)", function()
		local bare = { modifiers = { "ctrl", "alt_gr" } }
		helpers.assert_nil((HoldOptions.canonical_modifier("altgr", bare)), "no alias table, no alias")
		helpers.assert_nil((HoldOptions.canonical_modifier("lctrl", bare)), "no alias table, no alias")
		local picker = { modifiers = { "ctrl", "alt_gr" },
			modifier_aliases = { gr = "alt_gr" }, left_modifier_aliases = { leftctrl = "ctrl" } }
		helpers.assert_eq(HoldOptions.canonical_modifier("GR + LeftCtrl", picker), "ctrl+alt_gr",
			"the picker's aliases are the ones read")
		local shipped = Config.load(DEFAULTS, nil).hold_picker
		helpers.assert_eq(shipped.modifier_aliases, { altgr = "alt_gr", ralt = "alt_gr" })
		helpers.assert_eq(shipped.left_modifier_aliases, { lctrl = "ctrl", lshift = "shift", lalt = "alt", lwin = "win" })
	end)

	helpers.it("holds every picker option however it is ordered or cased", function()
		local picker = Config.load(DEFAULTS, nil).hold_picker
		local modifier_options = 0
		for _, option in ipairs(HoldOptions.build(picker)) do
			if option.kind == "modifier" then
				modifier_options = modifier_options + 1
				local parts = {}
				for part in option.id:gmatch("[^+]+") do table.insert(parts, 1, part:upper()) end
				local reversed = table.concat(parts, " + ")
				local loaded = load_hold("hold_modifier", reversed)
				helpers.assert_eq(loaded.keys.alt_gr.hold_modifier, option.id, "'" .. reversed .. "'")
				local expected = {}
				for part in option.id:gmatch("[^+]+") do
					helpers.assert_not_nil(Engine.MODIFIER_CODES[part], "the engine can hold " .. part)
					expected[#expected + 1] = Engine.MODIFIER_CODES[part]
				end
				helpers.assert_eq(held_codes(loaded.keys, "alt_gr"), expected, "'" .. reversed .. "' holds " .. option.id)
			end
		end
		helpers.assert_eq(modifier_options, 31, "every combination of the five shipped modifiers")
	end)

	helpers.it("reads a layer in any case", function()
		local loaded = load_hold("hold_layer", " NAV ")
		helpers.assert_eq(loaded.keys.alt_gr.hold_layer, "nav")
	end)

	-- Windows (ResolveHoldModifierKey) drops such a hold and keeps the tap: a
	-- CapsLock with an unknown hold still types Enter there, and here it went
	-- back to toggling Caps Lock (unknown-hold-keeps-tap).
	helpers.it("warns once about an unknown modifier or layer, and keeps the key's tap (unknown-hold-keeps-tap)", function()
		for _, case in ipairs({
			{ "hold_modifier", "hyper" }, { "hold_modifier", "ctrl+alt gr" }, { "hold_modifier", "none" },
			{ "hold_layer", "sym" },
		}) do
			local Logger = require("logger.shim")
			local real_error, real_warn, errors, warnings = Logger.error, Logger.warn, {}, {}
			Logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
			Logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
			local ok, loaded = pcall(load, '[tap_hold.keys.caps_lock]\n' .. case[1] .. ' = "' .. case[2] .. '"\n')
			Logger.error, Logger.warn = real_error, real_warn
			if not ok then error(loaded, 0) end
			local caps = loaded.keys.caps_lock
			helpers.assert_true(caps.enabled ~= false, case[2] .. " leaves the key on")
			helpers.assert_eq(caps.tap_action, "enter", case[2] .. " keeps the tap")
			helpers.assert_nil(caps.hold_modifier, case[2] .. " holds no modifier")
			helpers.assert_nil(caps.hold_layer, case[2] .. " holds no layer")
			helpers.assert_eq(errors, {}, case[2] .. " is an outdated value, never an ERROR")
			helpers.assert_eq(#warnings, 1, case[2] .. " is reported")
			helpers.assert_contains(warnings[1], case[2])
			helpers.assert_contains(warnings[1], "tap_hold.keys.caps_lock." .. case[1])
			local engine = Engine.new({ keys = loaded.keys, tap_min_ms = 50, one_shot_timeout_ms = 2000,
				key_text = function() return nil end, plan_text = function() return nil end, one_shot_result = function() return nil end, })
			-- A tap and no hold: Enter at key-down (tap-no-hold-instant), no Ctrl.
			local out = engine:process(Engine.KEY_CODES.caps_lock, 1, 0)
			helpers.assert_eq(#out, 2, case[2] .. ": the key still types Enter, and holds nothing")
			helpers.assert_eq(out[1].code, 28, case[2] .. ": the key still types Enter")
			helpers.assert_eq(#engine:process(Engine.KEY_CODES.caps_lock, 0, 100), 0)
		end
	end)

end)

-- The first-run wizard's re-run pre-checked every key and imported over the
-- user's own settings: it now shows what this report says is in force.
helpers.describe("tap-hold config: the wizard's report of a folder", function()

	--- Reports on a user file holding `text` exactly.
	local function report(text)
		local path = os.tmpname()
		local fh = assert(io.open(path, "w"))
		fh:write(text)
		fh:close()
		local result, err = Config.key_report(DEFAULTS, path)
		os.remove(path)
		return result, err
	end

	helpers.it("reports a folder without a tap-hold file as neutral", function()
		helpers.assert_eq(Config.key_report(DEFAULTS, "/nonexistent/tap_hold.toml"), { enabled = false, keys = {} })
	end)

	helpers.it("tells an imported key from one the user set, and reads the switch", function()
		local result = report('[tap_hold]\nenabled = true\n'
			.. '[tap_hold.keys.caps_lock]\ntime_activation_seconds = 0.35\ntap_action = "enter"\nhold_modifier = "ctrl"\n'
			.. '[tap_hold.keys.left_alt]\ntime_activation_seconds = 0.3\ntap_action = "backspace"\nhold_layer = "nav"\n'
			.. '[tap_hold.keys.left_ctrl]\ntap_action = "paste"\nhold_modifier = "ctrl"\n'
			.. '[tap_hold.keys.tab]\nenabled = false\n')
		helpers.assert_eq(result, { enabled = true, keys = {
			caps_lock = "recommended",
			left_alt = "customised",
			left_ctrl = "recommended",
			tab = "customised",
		} }, "a key with another delay or turned off is the user's own setting; one that behaves as the preset is not")
	end)

	helpers.it("reads every inherited key as the recommendation", function()
		local result = report('[tap_hold]\nenabled = false\ninherit_defaults = true\n'
			.. '[tap_hold.keys.left_shift]\ntap_action = "paste"\n')
		helpers.assert_eq(result.enabled, false)
		helpers.assert_eq(result.keys.left_shift, "customised")
		helpers.assert_eq(result.keys.caps_lock, "recommended")
		helpers.assert_eq(result.keys.tab, "recommended")
	end)

	helpers.it("refuses a malformed file rather than report it neutral", function()
		local result, err = report('[tap_hold.keys.left_shift\ntap_action = "paste"\n')
		helpers.assert_nil(result)
		helpers.assert_type(err, "string")
	end)

end)
