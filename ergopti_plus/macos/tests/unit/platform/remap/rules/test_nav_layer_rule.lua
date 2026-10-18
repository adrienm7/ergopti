--- tests/unit/platform/remap/rules/test_nav_layer_rule.lua

--- ==============================================================================
--- MODULE: Generated Karabiner Navigation Layer Tests
--- DESCRIPTION:
--- The Karabiner navigation layer used to be data/layer_keys.json, appended
--- verbatim. It is now generated from the user's layers.toml by
--- platform/remap/nav_layer.lua. The hand-written file is kept, frozen, as
--- data/legacy_layer_keys.json; it is the independent oracle here: Ergopti's
--- recommended layer must generate exactly that layer, except for the
--- differences listed by hand in CANONICAL_CHANGES, each of which brings macOS
--- to the canonical layer.
---
--- COVERAGE:
--- 1. Golden (nav-layer-generated): recommended layer -> the hand-written layer
---    plus CANONICAL_CHANGES, manipulator for manipulator.
--- 2. One key: KeyT bound to F3 instead of F2 changes the t manipulators only.
--- 3. Contracts: every manipulator is gated on layer_active; no binding is no
---    rule; `none` swallows the key; a mouse button is a layer key; the wheel
---    and a repeat count have no Karabiner form, the wheel being the strokes
---    Hammerspoon posts (wheel_slots); every macOS call handler the
---    vocabulary declares is implemented; a layers.toml rejected as a whole
---    closes its START with an error and no SUCCESS.
--- 4. The generator deploys state.nav_layer in place of the static file and
---    still reads the frozen file as the legacy anchor.
--- 5. Fresh install (nav-layer-fresh-install-default): the recommended import
---    creates layers.toml with the preset's bytes where there is none, so the
---    loader then generates the layer; an existing file is never replaced, and
---    an undo removes only a file still holding the preset's bytes.
--- ==============================================================================

local helpers   = require("tests.helpers")
local Json      = require("json")
local TomlCodec = require("toml_codec")
local Layers    = require("keymap.layers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")
local NavLayer = helpers.load_with_stubs("platform.remap.nav_layer")

local LEGACY_PATH = helpers.driver_root() .. "/platform/remap/data/legacy_layer_keys.json"
local FKEYS_VAR = "system.use_fkeys_as_standard_function_keys"

-- What the recommended layer changes on macOS against the hand-written layer,
-- keyed like normalise() keys its entries; false means the entry is gone.
local CANONICAL_CHANGES = {
	-- CapsLock is Backspace and the right Alt (Option) key Escape, as on Windows.
	["caps_lock"] = "to=delete_or_backspace",
	["right_option"] = "to=escape",
	-- T and G send their function key in either top-row mode, like the number row.
	["t"] = false,
	["t|media"] = "to=f2[fn]",
	["t|standard"] = "to=f2",
	["g"] = false,
	["g|media"] = "to=f12[fn]",
	["g|standard"] = "to=f12",
	-- Maximize is a keystroke like every other: sent on key down.
	["n"] = "to=y[command,control,fn]",
	-- Virtual ISO itself maps the canonical HID Backquote target to Carbon 10.
	["tab"] = "to=grave_accent_and_tilde[command]",
}
-- Floor: the hand-written layer had 59 manipulators on 47 keys.
local MIN_ENTRIES = 50





-- ===================================
-- ===================================
-- ======= 1/ Data and helpers =======
-- ===================================
-- ===================================

--- Reads a whole file; raises when it cannot.
local function read_file(path)
	local fh, err = io.open(path, "rb")
	if not fh then error("cannot open " .. path .. ": " .. tostring(err)) end
	local content = fh:read("*a")
	fh:close()
	return content
end

local ctx = Layers.load_context({
	shared_root = helpers.shared(),
	json_decode = Json.decode,
	toml_decode = TomlCodec.decode,
	read_file   = read_file,
})
local recommended = read_file(helpers.shared("keymap/layers.recommended.toml"))

--- The navigation bindings a layer file resolves to on macOS; the file must load cleanly.
local function bindings_of(text)
	local result = Layers.load(text, "macos", ctx, TomlCodec.decode)
	helpers.assert_true(result.ok, "the layer file must resolve for macOS without an error")
	helpers.assert_not_nil(result.layers.nav, "the layer file must define the nav layer")
	return result.layers.nav
end

--- One Karabiner event as text: its key, then its modifiers sorted.
local function event_text(event)
	local name = event.key_code or event.consumer_key_code or event.pointing_button or "?"
	local mods = {}
	for _, mod in ipairs(event.modifiers or {}) do mods[#mods + 1] = mod end
	table.sort(mods)
	return #mods > 0 and (name .. "[" .. table.concat(mods, ",") .. "]") or name
end

--- Manipulators keyed by source key and top-row variant -> what they send.
--- Every manipulator must be gated on layer_active; the fn-key variant is read
--- from its second condition.
local function normalise(rule)
	local out, count = {}, 0
	for _, m in ipairs(rule.manipulators) do
		helpers.assert_eq(m.type, "basic")
		local gate = m.conditions and m.conditions[1]
		helpers.assert_true(gate and gate.type == "variable_if" and gate.name == "layer_active" and gate.value == 1,
			"every manipulator must fire only while layer_active == 1")
		helpers.assert_eq(m.from.modifiers and m.from.modifiers.optional and m.from.modifiers.optional[1], "any",
			"a layer key fires whatever modifier is held")
		local key = m.from.key_code or m.from.pointing_button
		local variant = m.conditions[2]
		if variant then
			helpers.assert_eq(variant.name, FKEYS_VAR)
			-- Karabiner mirrors the macOS setting as a boolean: a 1 would never match.
			helpers.assert_eq(variant.value, true, "the top-row mode is compared with true")
			key = key .. (variant.type == "variable_unless" and "|media" or "|standard")
		end
		local parts = {}
		for _, field in ipairs({ "to", "to_if_alone", "to_after_key_up" }) do
			if m[field] then
				local events = {}
				for i, event in ipairs(m[field]) do events[i] = event_text(event) end
				parts[#parts + 1] = field .. "=" .. table.concat(events, ",")
			end
		end
		helpers.assert_nil(out[key], "one manipulator per key and variant: " .. key)
		out[key] = table.concat(parts, " ")
		count = count + 1
	end
	return out, count
end





-- ==================================
-- ==================================
-- ======= 2/ Golden and edit =======
-- ==================================
-- ==================================

helpers.describe("Karabiner navigation layer generated from layers.toml", function()
	helpers.it("the recommended layer generates the hand-written layer made canonical (nav-layer-generated)", function()
		local expected, legacy_count = normalise(Json.decode(read_file(LEGACY_PATH)))
		helpers.assert_true(legacy_count >= MIN_ENTRIES, "the frozen layer holds only " .. legacy_count .. " manipulators")
		for key, change in pairs(CANONICAL_CHANGES) do
			if change == false then
				helpers.assert_not_nil(expected[key], "a listed removal must exist in the frozen layer: " .. key)
				expected[key] = nil
			else
				expected[key] = change
			end
		end
		local actual = normalise(NavLayer.build_rule(bindings_of(recommended), ctx.registry))
		for key, value in pairs(expected) do helpers.assert_eq(actual[key], value, "manipulator " .. key) end
		for key, value in pairs(actual) do
			helpers.assert_not_nil(expected[key], "unexpected manipulator " .. key .. " (" .. value .. ")")
		end
	end)

	helpers.it("editing one key of layers.toml changes that key only (nav-layer-generated)", function()
		local edited, replaced = recommended:gsub('"KeyT" = "keystroke:F2"', '"KeyT" = "keystroke:F3"')
		helpers.assert_eq(replaced, 1, "the preset must bind KeyT to F2 exactly once for this edit to mean anything")
		local before = normalise(NavLayer.build_rule(bindings_of(recommended), ctx.registry))
		local after = normalise(NavLayer.build_rule(bindings_of(edited), ctx.registry))
		local changed = {}
		for key, value in pairs(before) do
			if after[key] ~= value then changed[#changed + 1] = key end
		end
		for key in pairs(after) do
			if before[key] == nil then changed[#changed + 1] = key end
		end
		table.sort(changed)
		helpers.assert_eq(table.concat(changed, " "), "t|media t|standard", "only KeyT's manipulators change")
		helpers.assert_eq(after["t|media"], "to=f3[fn]")
		helpers.assert_eq(after["t|standard"], "to=f3")
	end)
end)





-- ==============================
-- ==============================
-- ======= 3/ Contracts =========
-- ==============================
-- ==============================

helpers.describe("Karabiner navigation layer contracts", function()
	helpers.it("binds nothing without a binding", function()
		helpers.assert_nil(NavLayer.build_rule({}, ctx.registry), "Karabiner refuses a rule with no manipulator")
	end)

	helpers.it("(navigation-native-case) leaves every unbound key and its case outside the layer rule", function()
		local rule = NavLayer.build_rule(bindings_of('[_meta]\nschema_version = 1\n[layers.nav.all]\n"KeyB" = "none"\n'), ctx.registry)
		local actual, count = normalise(rule)
		helpers.assert_eq(count, 1, "only the explicitly bound key may acquire a layer manipulator")
		helpers.assert_eq(actual.b, "to=vk_none")
		helpers.assert_nil(actual.a, "an unbound letter remains native, including genuine Shift/CapsLock case")
		helpers.assert_nil(actual.caps_lock, "navigation may not synthesize a CapsLock indicator")
		local actions = Json.decode(read_file(helpers.driver_root() .. "/platform/remap/data/actions.json"))
		local hold
		for _, action in ipairs(actions) do
			if action.id == "layer" then hold = action end
		end
		helpers.assert_not_nil(hold, "the real navigation hold action must exist")
		for _, field in ipairs({ "karabiner_to", "karabiner_to_after_key_up" }) do
			helpers.assert_eq(#hold[field], 1, "entry and release each have an explicit layer-variable event")
			for _, event in ipairs(hold[field]) do
				helpers.assert_nil(event.key_code, "layer entry/release must not inject a case-changing key")
				helpers.assert_nil(event.modifiers, "layer entry/release must not inject Shift")
			end
		end
	end)

	helpers.it("swallows a key bound to none and takes a mouse button as a layer key", function()
		local rule = NavLayer.build_rule(bindings_of('[_meta]\nschema_version = 1\n\n[layers.nav.all]\n'
			.. '"KeyB" = "none"\n"MouseBack" = "keystroke:alt+ArrowLeft"\n'), ctx.registry)
		local actual = normalise(rule)
		helpers.assert_eq(actual.b, "to=vk_none")
		helpers.assert_eq(actual.button4, "to=left_arrow[option]")
	end)

	helpers.it("the wheel and a repeat count have no Karabiner form", function()
		local wheel_only = bindings_of('[_meta]\nschema_version = 1\n\n[layers.nav.all]\n"WheelUp" = "vol_up"\n')
		helpers.assert_not_nil(wheel_only.WheelUp, "the loader takes the wheel as a macOS layer key (layer-wheel-slots)")
		helpers.assert_nil(NavLayer.build_rule(wheel_only, ctx.registry),
			"the wheel is Hammerspoon's to run: Karabiner gets no manipulator for it")
		helpers.assert_throws(function()
			NavLayer.build_rule({ Digit1 = { kind = "repeat_count", count = 1 } }, ctx.registry)
		end, "a repeat count does not exist on macOS")
	end)

	helpers.it("(layer-wheel-slots) the recommended wheel is volume up and down, posted as media keys", function()
		local slots = NavLayer.wheel_slots(bindings_of(recommended), ctx.registry)
		helpers.assert_eq(slots.vertical[1], { code = "WheelUp", strokes = { { system = "SOUND_UP" } } })
		helpers.assert_eq(slots.vertical[-1], { code = "WheelDown", strokes = { { system = "SOUND_DOWN" } } })
		helpers.assert_nil(next(slots.horizontal), "the recommended layer leaves the horizontal wheel scrolling")
	end)

	helpers.it("(layer-wheel-slots) an edited wheel slot sends its keystroke, and none swallows the turn", function()
		local slots = NavLayer.wheel_slots(bindings_of('[_meta]\nschema_version = 1\n\n[layers.nav.all]\n'
			.. '"WheelUp" = "keystroke:primary+ArrowUp"\n"WheelDown" = "none"\n"WheelLeft" = "mute"\n'), ctx.registry)
		helpers.assert_eq(slots.vertical[1].strokes, { { mods = { "cmd" }, keycode = ctx.registry.keys.ArrowUp.hs } })
		helpers.assert_eq(slots.vertical[-1].strokes, {}, "a direction bound to none is consumed and sends nothing")
		helpers.assert_eq(slots.horizontal[-1].strokes, { { system = "MUTE" } })
	end)

	helpers.it("(layer-wheel-slots) a binding a wheel turn cannot send leaves that direction scrolling", function()
		local slots = NavLayer.wheel_slots({ WheelUp = { kind = "call", handler = "tap_escape_hold_option_shift" } },
			ctx.registry)
		helpers.assert_nil(slots.vertical[1], "a tap/hold handler has no stroke to send per notch")
	end)

	helpers.it("routes brightness wheel turns and keys through genuine native media producers", function()
		local bindings = bindings_of('[_meta]\nschema_version = 1\n[layers.nav.all]\n'
			.. '"WheelUp" = "brightness_up"\n"WheelDown" = "brightness_down"\n"KeyJ" = "brightness_up"\n')
		local slots = NavLayer.wheel_slots(bindings, ctx.registry)
		helpers.assert_eq(slots.vertical[1].strokes, { { system = "BRIGHTNESS_UP" } })
		helpers.assert_eq(slots.vertical[-1].strokes, { { system = "BRIGHTNESS_DOWN" } })
		local rule = NavLayer.build_rule(bindings, ctx.registry)
		helpers.assert_eq(#rule.manipulators, 1)
		helpers.assert_eq(rule.manipulators[1].to, { { consumer_key_code = "display_brightness_increment" } })
		helpers.assert_eq(rule.manipulators[1].conditions,
			{ { type = "variable_if", name = "layer_active", value = 1 } })
	end)

	helpers.it("implements every macOS call handler the vocabulary declares", function()
		local declared = ctx.vocabulary.call_handlers.macos
		helpers.assert_true(#declared >= 1, "the vocabulary declares macOS call handlers")
		for _, handler in ipairs(declared) do
			helpers.assert_eq(type(NavLayer.CALL_HANDLERS[handler]), "function", "call:" .. handler)
		end
		local actual = normalise(NavLayer.build_rule({ MetaRight = { kind = "call",
			handler = "tap_escape_hold_option_shift", repeatable = true, action = "escape_or_option_shift" } },
			ctx.registry))
		helpers.assert_eq(actual.right_command, "to=left_shift[left_option] to_if_alone=escape")
	end)

	helpers.it("a layers.toml rejected as a whole logs an error, never a success (nav-layer-generated)", function()
		local dir = helpers.temp_dir() .. "/ergopti_nav_layer_rejected_" .. tostring(os.time()) .. "_"
			.. tostring(math.random(100000, 999999))
		local ok_mkdir = os.execute('mkdir "' .. dir .. '"')
		helpers.assert_true(ok_mkdir == true or ok_mkdir == 0, "sandbox directory must exist")
		local fh = assert(io.open(dir .. "/layers.toml", "wb"))
		fh:write('[_meta]\nschema_version = 99\n\n[layers.nav.all]\n"KeyS" = "arrow_up"\n')
		fh:close()
		local levels = {}
		local capture = {}
		for _, level in ipairs({ "trace", "debug", "done", "info", "start", "success", "warn", "error" }) do
			capture[level] = function() levels[#levels + 1] = level end
		end
		local saved_logger = package.loaded["infra.logger"]
		package.loaded["infra.logger"] = capture
		local ok, err = pcall(function()
			local Fresh = helpers.load_with_stubs("platform.remap.nav_layer")
			local layer = Fresh.load({ shared_root = helpers.shared(), config_dir = dir })
			helpers.assert_nil(next(layer.bindings), "a file rejected as a whole binds no key")
			-- The problem, then the error that closes the START: the load failed,
			-- so no SUCCESS may follow it.
			helpers.assert_eq(table.concat(levels, " "), "start warn error")
		end)
		package.loaded["infra.logger"] = saved_logger
		package.loaded["platform.remap.nav_layer"] = nil
		os.remove(dir .. "/layers.toml")
		os.execute('rmdir "' .. dir .. '"')
		if not ok then error(err, 0) end
	end)
end)





-- ========================================================
-- ========================================================
-- ======= 6/ Fresh install: the recommended import =======
-- ========================================================
-- ========================================================

-- A fresh install has no layers.toml, which binds no key: the recommended key
-- the wizard or « Restore recommended values » imported held an empty layer.
helpers.describe("the recommended layer comes with the key that enters it", function()
	--- Runs body(dir) in a private configuration folder, removed afterwards.
	local function with_folder(body)
		local dir = helpers.temp_dir() .. "/ergopti_nav_layer_import_" .. tostring(os.time()) .. "_"
			.. tostring(math.random(100000, 999999))
		local ok_mkdir = os.execute('mkdir "' .. dir .. '"')
		helpers.assert_true(ok_mkdir == true or ok_mkdir == 0, "sandbox directory must exist")
		local ok, err = pcall(body, dir)
		os.remove(dir .. "/layers.toml")
		os.execute('rmdir "' .. dir .. '"')
		if not ok then error(err, 0) end
	end

	--- The content of a file, nil when absent.
	local function content(path)
		local fh = io.open(path, "rb")
		if not fh then return nil end
		local text = fh:read("*a")
		fh:close()
		return text
	end

	helpers.it("(nav-layer-fresh-install-default) a folder without layers.toml gets the preset, which generates the layer", function()
		with_folder(function(dir)
			helpers.assert_nil(NavLayer.build_rule(NavLayer.load({ shared_root = helpers.shared(), config_dir = dir }).bindings,
				ctx.registry), "before the import the folder binds no key")
			local import = NavLayer.import_recommended({ shared_root = helpers.shared(), config_dir = dir })
			helpers.assert_not_nil(import, "the import succeeds")
			helpers.assert_eq(import.status, "imported")
			helpers.assert_eq(content(dir .. "/layers.toml"), recommended, "the preset's exact bytes")
			local layer = NavLayer.load({ shared_root = helpers.shared(), config_dir = dir })
			local rule = NavLayer.build_rule(layer.bindings, layer.registry)
			helpers.assert_true(rule ~= nil and #rule.manipulators >= MIN_ENTRIES,
				"the imported layer generates the navigation rule")
		end)
	end)

	helpers.it("(nav-layer-fresh-install-default) an existing layers.toml is never replaced", function()
		for label, own in pairs({ edited = '[_meta]\nschema_version = 1\n\n[layers.nav.all]\n"KeyJ" = "keystroke:ArrowDown"\n',
			empty = "" }) do
			with_folder(function(dir)
				local fh = assert(io.open(dir .. "/layers.toml", "wb"))
				fh:write(own)
				fh:close()
				local import = NavLayer.import_recommended({ shared_root = helpers.shared(), config_dir = dir })
				helpers.assert_eq(import.status, "kept", label)
				helpers.assert_eq(content(dir .. "/layers.toml"), own, label .. ": the user's file stays byte for byte")
				helpers.assert_true(NavLayer.undo_import(import), label)
				helpers.assert_eq(content(dir .. "/layers.toml"), own, label .. ": an undo never removes a kept file")
			end)
		end
	end)

	helpers.it("(nav-layer-fresh-install-default) an undo removes only the file the import created, as it created it", function()
		with_folder(function(dir)
			local import = NavLayer.import_recommended({ shared_root = helpers.shared(), config_dir = dir })
			helpers.assert_true(NavLayer.undo_import(import))
			helpers.assert_nil(content(dir .. "/layers.toml"), "the created file is removed")
			import = NavLayer.import_recommended({ shared_root = helpers.shared(), config_dir = dir })
			local fh = assert(io.open(dir .. "/layers.toml", "ab"))
			fh:write("# edited since\n")
			fh:close()
			helpers.assert_true(NavLayer.undo_import(import))
			helpers.assert_eq(content(dir .. "/layers.toml"), recommended .. "# edited since\n", "a later edit survives")
		end)
	end)

	helpers.it("(nav-layer-fresh-install-default) only a key whose preset hold is the layer brings it", function()
		local presets = require("platform.remap.defaults").tap_hold
		helpers.assert_eq(presets.left_command[2], NavLayer.HOLD_ACTION_ID, "the shipped preset's layer key")
		helpers.assert_true(NavLayer.recommendation_enters_layer({ "caps_lock", "left_command" }, presets))
		helpers.assert_eq(NavLayer.recommendation_enters_layer({ "caps_lock", "tab" }, presets), false)
	end)
end)

helpers.describe("navigation physical inputs and virtual outputs (iso-typing-convention)", function()
	helpers.it("keeps the physical ISO input domain but sends each target's canonical HID position", function()
		local bindings = bindings_of('[_meta]\nschema_version = 1\n[layers.nav.all]\n'
			.. '"IntlBackslash" = "keystroke:Backquote"\n"Backquote" = "keystroke:IntlBackslash"\n')
		local rule = NavLayer.build_rule(bindings, ctx.registry)
		local actual = normalise(rule)
		helpers.assert_eq(actual.grave_accent_and_tilde, "to=grave_accent_and_tilde",
			"the ISO extra source sends the target left of 1 through the ISO virtual keyboard")
		helpers.assert_eq(actual.non_us_backslash, "to=non_us_backslash",
			"the source left of 1 sends the ISO extra target through the ISO virtual keyboard")
	end)

	helpers.it("wheel Quartz strokes use the captured layout convention, without changing ordinary keys", function()
		local bindings = bindings_of('[_meta]\nschema_version = 1\n[layers.nav.all]\n'
			.. '"WheelUp" = "keystroke:IntlBackslash"\n"WheelDown" = "keystroke:Backquote"\n"WheelLeft" = "keystroke:KeyA"\n')
		for _, case in ipairs({ { "iso", 50, 10 }, { "ansi", 10, 50 } }) do
			local slots = NavLayer.wheel_slots(bindings, ctx.registry, case[1])
			helpers.assert_eq(slots.vertical[1].strokes[1].keycode, case[2], "extra-key output " .. case[1])
			helpers.assert_eq(slots.vertical[-1].strokes[1].keycode, case[3], "left-of-one output " .. case[1])
			helpers.assert_eq(slots.horizontal[-1].strokes[1].keycode, 0, "ordinary KeyA remains unchanged")
		end
	end)
end)


helpers.describe("navigation source close acknowledgement", function()
	local fixture_sequence = 0
	local layer_text = '[_meta]\nschema_version = 1\n[layers.nav.all]\n"KeyJ" = "keystroke:ArrowDown"\n'

	-- Intercept only a genuine stream's ACK after its real read and physical
	-- close. Cleanup restores IO and the original cache even when loading raises.
	local function receive_close_refusal(source, acknowledgement)
		local original_open = io.open
		local original_hs = rawget(_G, "hs")
		local original_cache = {}
		for name, value in pairs(package.loaded) do original_cache[name] = value end
		local records, levels = {}, {}
		local facts = { opens = 0, reads = 0, closes = 0, native_closes = 0, cleanup_closes = 0 }
		local directory, user_path, made_directory, created_file, quote
		local function close_record(record)
			if record.attempted then return record.closed end
			record.attempted = true
			local called, closed = pcall(record.close, record.handle)
			record.closed = called and closed == true
			if record.observed and record.closed then facts.native_closes = facts.native_closes + 1 end
			return record.closed
		end
		local called, outcome = pcall(function()
			quote = require("text_utils").shell_quote
			fixture_sequence = fixture_sequence + 1
			directory = helpers.temp_dir() .. "/ergopti_mac_nav_close_" .. tostring(os.time()) .. "_"
				.. tostring(math.random(100000, 999999)) .. "_" .. tostring(fixture_sequence)
			local made = os.execute("mkdir " .. quote(directory))
			assert(made == true or made == 0, "owned navigation directory must be created")
			made_directory = true
			user_path = directory .. "/layers.toml"
			local file = assert(original_open(user_path, "wb"))
			created_file = true
			local fixture = { handle = file, close = file.close }
			records[#records + 1] = fixture
			assert(file:write(layer_text), "owned navigation fixture must be written")
			assert(close_record(fixture), "fixture write close must be acknowledged")
			local capture = helpers.make_logger_stub()
			for _, level in ipairs({ "start", "success", "warn", "error" }) do
				capture[level] = function() levels[#levels + 1] = level end
			end
			package.loaded["infra.logger"] = capture
			package.loaded["platform.remap.nav_layer"] = nil
			local Fresh = require("platform.remap.nav_layer")
			local target = source == "user" and user_path or helpers.shared("data/keycodes/physical_keys.json")
			io.open = function(path, mode)
				if path ~= target or mode ~= "r" and mode ~= "rb" then return original_open(path, mode) end
				local handle, detail, code = original_open(path, mode)
				if not handle then return nil, detail, code end
				local record = { handle = handle, close = handle.close, observed = true }
				records[#records + 1] = record
				facts.opens = facts.opens + 1
				return {
					read = function(_, ...)
						facts.reads = facts.reads + 1
						local text, read_detail = handle:read(...)
						facts.read_string = type(text) == "string"
						return text, read_detail
					end,
					close = function()
						facts.closes = facts.closes + 1
						assert(not record.attempted, "navigation stream must be closed exactly once")
						if not close_record(record) then return nil, "real fixture close was not acknowledged" end
						if acknowledgement == "false" then return false, "controlled close ACK refusal" end
						assert(acknowledgement == "nil", "unknown controlled ACK")
						return nil, "controlled close ACK refusal"
					end,
				}
			end
			local loaded, result = pcall(Fresh.load, { shared_root = helpers.shared(), config_dir = directory })
			return { loaded = loaded, result = result }
		end)
		io.open = original_open
		for name in pairs(package.loaded) do
			if original_cache[name] == nil then package.loaded[name] = nil end
		end
		for name, value in pairs(original_cache) do package.loaded[name] = value end
		_G.hs = original_hs
		local cleanup_errors = {}
		for _, record in ipairs(records) do
			if not record.attempted then
				if record.observed then facts.cleanup_closes = facts.cleanup_closes + 1 end
				close_record(record)
			end
			if not record.closed then cleanup_errors[#cleanup_errors + 1] = "real stream close remains unacknowledged" end
		end
		if created_file then
			local removed_ok, removed, detail = pcall(os.remove, user_path)
			if not removed_ok or removed ~= true then
				cleanup_errors[#cleanup_errors + 1] = "fixture removal refused: " .. tostring(removed_ok and detail or removed)
			end
		end
		if made_directory then
			local removed_ok, removed = pcall(os.execute, "rmdir " .. quote(directory))
			if not removed_ok or removed ~= true and removed ~= 0 then
				cleanup_errors[#cleanup_errors + 1] = "fixture directory removal refused"
			end
		end
		if not called or #cleanup_errors > 0 then
			error((called and "" or tostring(outcome) .. "; ") .. table.concat(cleanup_errors, "; "), 0)
		end
		outcome.facts, outcome.levels = facts, levels
		return outcome
	end

	local function assert_real_stream_closed(outcome)
		helpers.assert_eq(outcome.facts.opens, 1)
		helpers.assert_eq(outcome.facts.reads, 1)
		helpers.assert_eq(outcome.facts.read_string, true, "the genuine source was actually read")
		helpers.assert_eq(outcome.facts.closes, 1)
		helpers.assert_eq(outcome.facts.native_closes, 1, "the original physical stream close succeeded once")
		helpers.assert_eq(outcome.facts.cleanup_closes, 0, "no second close or cleanup replacement supplies the ACK")
	end

	local function assert_user_refused(outcome)
		assert_real_stream_closed(outcome)
		helpers.assert_eq(outcome.loaded, true, "a user source failure retains the existing isolated-load contract")
		helpers.assert_nil(next(outcome.result.bindings), "unacknowledged bytes cannot bind a key")
		helpers.assert_nil(NavLayer.build_rule(outcome.result.bindings, outcome.result.registry))
		helpers.assert_nil(next(outcome.result.wheel.vertical))
		helpers.assert_nil(next(outcome.result.wheel.horizontal))
		helpers.assert_eq(table.concat(outcome.levels, " "), "start warn error", "the failed load cannot log SUCCESS")
	end

	local function assert_shipped_refused(outcome)
		assert_real_stream_closed(outcome)
		helpers.assert_eq(outcome.loaded, false, "a failed shipped source is fatal before loading starts")
		helpers.assert_true(type(outcome.result) == "string" and outcome.result:find("source close failed", 1, true) ~= nil)
		helpers.assert_eq(outcome.levels, {}, "no START or SUCCESS precedes valid shipped context")
	end

	helpers.it("(nav-source-close-ack) a false user close ACK isolates the real file without SUCCESS", function()
		assert_user_refused(receive_close_refusal("user", "false"))
	end)

	helpers.it("(nav-source-close-ack) a nil user close ACK isolates the real file without SUCCESS", function()
		assert_user_refused(receive_close_refusal("user", "nil"))
	end)

	helpers.it("(nav-source-close-ack) a false shipped close ACK refuses context before START", function()
		assert_shipped_refused(receive_close_refusal("shipped", "false"))
	end)

	helpers.it("(nav-source-close-ack) a nil shipped close ACK refuses context before START", function()
		assert_shipped_refused(receive_close_refusal("shipped", "nil"))
	end)
end)

helpers.describe("navigation configured input observations", function()
	local sequence = 0
	local text = '[_meta]\nschema_version = 1\n[layers.nav.all]\n"KeyJ" = "none"\n'
	local function with_source(callback)
		local lfs = require("lfs")
		sequence = sequence + 1
		local directory = helpers.temp_dir() .. "/mac-nav-configured-" .. tostring(os.time()) .. "-" .. tostring(sequence)
		assert(lfs.mkdir(directory))
		local path = directory .. "/layers.toml"
		local function write(value)
			local stream = assert(io.open(path, "wb")); assert(stream:write(value)); assert(stream:close())
		end
		write(text)
		local called, detail = xpcall(function()
			helpers.with_stub_scope({ "platform.remap.nav_layer", "infra.logger" }, function()
				package.loaded["infra.logger"] = helpers.make_logger_stub()
				package.loaded["platform.remap.nav_layer"] = nil
				local subject = require("platform.remap.nav_layer")
				callback(subject, { shared_root = helpers.shared(), config_dir = directory }, write, path)
			end)
		end, debug.traceback)
		assert(os.remove(path)); assert(lfs.rmdir(directory))
		if not called then error(detail, 0) end
	end

	helpers.it("nav-configured captures explicit None as the genuine physical input", function()
		with_source(function(subject, options)
			local layer, observation = subject.load(options)
			local capture = subject.capture_configured_inputs(layer, observation)
			helpers.assert_type(capture, "table")
			helpers.assert_eq(capture.codes, { 38 }, "KeyJ's actual registry input is reserved even for None")
			helpers.assert_eq(capture.current(), true)
			helpers.assert_nil(subject.capture_configured_inputs({ bindings = layer.bindings, registry = layer.registry }, observation))
		end)
	end)

	helpers.it("nav-configured never admits later source bytes as an original-load baseline", function()
		with_source(function(subject, options, write)
			local layer, observation = subject.load(options)
			write(text:gsub("KeyJ", "KeyG"))
			helpers.assert_nil(subject.capture_configured_inputs(layer, observation))
		end)
	end)

	helpers.it("nav-configured refuses map mutation before the first capture", function()
		with_source(function(subject, options)
			local layer, observation = subject.load(options)
			layer.bindings.KeyG, layer.bindings.KeyJ = layer.bindings.KeyJ, nil
			helpers.assert_nil(subject.capture_configured_inputs(layer, observation))
		end)
	end)

	helpers.it("nav-configured detached code edits cannot change a subsequent capture", function()
		with_source(function(subject, options)
			local layer, observation = subject.load(options)
			local capture = subject.capture_configured_inputs(layer, observation)
			helpers.assert_type(capture, "table")
			capture.codes[1] = 5
			local second = subject.capture_configured_inputs(layer, observation)
			helpers.assert_type(second, "table")
			helpers.assert_eq(second.codes, { 38 })
			helpers.assert_eq(second.current(), true)
		end)
	end)

	helpers.it("nav-configured currency refuses an observed user source replacement", function()
		with_source(function(subject, options, write)
			local layer, observation = subject.load(options)
			local capture = subject.capture_configured_inputs(layer, observation)
			helpers.assert_type(capture, "table")
			write(text .. "# independent successor\n")
			helpers.assert_eq(capture.current(), false)
		end)
	end)

	helpers.it("nav-configured source exports cannot supply replacement observations", function()
		with_source(function(subject, options)
			local layer, observation = subject.load(options)
			local writer = require("toml_codec.writer")
			local original, reads = writer.read_classified, 0
			writer.read_classified = function(...) reads = reads + 1; return original(...) end
			local called, capture = pcall(subject.capture_configured_inputs, layer, observation)
			writer.read_classified = original
			helpers.assert_eq(called, true)
			helpers.assert_nil(capture)
			helpers.assert_eq(reads, 0, "an unowned replacement must not create a new read baseline")
		end)
	end)

	helpers.it("nav-configured rejoins original source bytes after the load logger callback", function()
		with_source(function(subject, options, write)
			local logger = package.loaded["infra.logger"]
			logger.success = function() write(text .. "# logger successor\n") end
			local layer, observation = subject.load(options)
			helpers.assert_nil(subject.capture_configured_inputs(layer, observation))
		end)
	end)
	for _, override in ipairs({ false, true }) do
		helpers.it("nav-configured refuses actual compiled input mutation " .. tostring(override), function()
			with_source(function(subject, options)
				local layer, observation = subject.load(options)
				local entry = layer.registry.keys.KeyJ
				if override then entry.macos_iso = { hs = 38, karabiner = { key_code = "g" } }
				else entry.karabiner.key_code = "g" end
				local actual = subject.build_rule(layer.bindings, layer.registry)
				helpers.assert_eq(actual.manipulators[1].from.key_code, "g", "the real compiler consumes the changed input")
				helpers.assert_eq(entry.hs, 38, "HS input alone cannot authenticate the compiled map")
				helpers.assert_nil(subject.capture_configured_inputs(layer, observation))
			end)
		end)
	end

end)
