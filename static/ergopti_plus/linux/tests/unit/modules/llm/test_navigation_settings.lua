--- tests/unit/modules/llm/test_navigation_settings.lua

--- ==============================================================================
--- MODULE: Linux LLM Validation Navigation
--- DESCRIPTION:
--- Proves durable modifier matching and lossless suppression of an accepted
--- digit through the real evdev dispatch path.
--- ==============================================================================

local helpers = require("tests.helpers")
local PreferencesFixture = require("tests.support.llm_preferences_fixture")

helpers.describe("LLM navigation settings", function()
	helpers.it("reads the manifest default and matches the exact held chord", function()
		local previous = package.loaded["infra.llm_preferences"]
		package.loaded["infra.llm_preferences"] = PreferencesFixture.new()
		local settings = helpers.load_module("modules.llm.navigation_settings")
		settings._reset()
		helpers.assert_eq(settings.get(), {}, "a bare digit accepts by default")
		helpers.assert_true(settings.matches({}))
		helpers.assert_eq(settings.matches({ alt = true }), false, "Alt+1 is not the default chord")
		helpers.assert_eq(settings.matches({ shift = true }), false, "Shift+1 is a character")
		helpers.assert_true(settings.set({ "alt" }))
		helpers.assert_true(settings.matches({ alt = true }), "the menu can require Alt")
		helpers.assert_eq(settings.matches({}), false, "and then a bare digit types")
		package.loaded["infra.llm_preferences"] = previous
	end)

	helpers.it("persists a canonical chord before publishing it", function()
		local previous = package.loaded["infra.llm_preferences"]
		local storage = PreferencesFixture.new()
		package.loaded["infra.llm_preferences"] = storage
		local settings = helpers.load_module("modules.llm.navigation_settings")
		settings._reset()
		helpers.assert_true(settings.set({ "shift", "ctrl" }))
		helpers.assert_eq(settings.get(), { "ctrl", "shift" })
		helpers.assert_eq(storage.get("llm.navigation.val_modifiers"), { "ctrl", "shift" })
		helpers.assert_eq(settings.set({ "alt", "alt" }), false)
		package.loaded["infra.llm_preferences"] = previous
	end)

	helpers.it("keeps a navigation chord of its own, bare by default (llm-tooltip-chords-consumed)", function()
		local previous = package.loaded["infra.llm_preferences"]
		local storage = PreferencesFixture.new()
		package.loaded["infra.llm_preferences"] = storage
		local settings = helpers.load_module("modules.llm.navigation_settings")
		settings._reset()
		helpers.assert_eq(settings.get_navigation(), {}, "bare Up and Down navigate by default")
		helpers.assert_true(settings.matches_navigation({}))
		helpers.assert_eq(settings.matches_navigation({ shift = true }), false, "Shift+Down is the application's")
		helpers.assert_true(settings.set_navigation({ "shift", "ctrl" }))
		helpers.assert_eq(settings.get_navigation(), { "ctrl", "shift" })
		helpers.assert_eq(storage.get("llm.navigation.nav_modifiers"), { "ctrl", "shift" })
		helpers.assert_eq(settings.get(), {}, "the validation chord is a separate setting")
		helpers.assert_true(settings.matches_navigation({ ctrl = true, shift = true }))
		helpers.assert_eq(settings.matches_navigation({ ctrl = true, shift = true, alt = true }), false)
		helpers.assert_eq(settings.set_navigation({ "win" }), false, "only the four chord modifiers exist")
		package.loaded["infra.llm_preferences"] = previous
	end)
end)

helpers.describe("keyboard hook validation consumption", function()
	helpers.it("suppresses the accepted digit down, repeat, and release only in intercept mode", function()
		local hook = helpers.load_module("adapters.keyboard_hook")
		local emitted = {}
		local chars = {}
		local consumed = 0
		hook._test_drive({
			{ type = 1, code = 2, value = 1 },
			{ type = 1, code = 2, value = 2 },
			{ type = 1, code = 2, value = 0 },
			{ type = 1, code = 3, value = 1 },
		}, {
			onConsume = function(detail)
				if detail.key == "1" or detail.char == "1" then consumed = consumed + 1; return true end
				return false
			end,
			onChar = function(char) chars[#chars + 1] = char end,
			onEmitRaw = function(code, value)
				emitted[#emitted + 1] = string.format("%d:%d", code, value)
				return true
			end,
		}, true)
		helpers.assert_eq(consumed, 1, "autorepeat must remain owned by the accepted down event")
		helpers.assert_eq(emitted, { "3:1" })
		helpers.assert_eq(chars, { "2" })
	end)
end)


helpers.describe("tray (linux): shared prediction modifier rows", function()
	local Sandbox = require("test.config_unused_keys_contract").sandbox
	local Json = require("json")
	local SOURCE = '# private independent neighbor\n[llm.navigation]\nfuture = "retain" # unknown\n[other]\nvalue = 42\n'
	local function with_native_navigation(variant, body)
		Sandbox.with_config(SOURCE, function(path)
			local names = { "infra.config_paths", "infra.llm_preferences", "modules.llm.navigation_settings", "infra.manifest_menu", "ui.menu.menu_builder", "adapters.storage", "ui.error_dialog.bridge", "ui.menu.start_at_login", "infra.i18n" }
			local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
			local previous_execute, previous_rename = os.execute, os.rename
			local notices, changed = 0, 0
			local ok, failure = xpcall(function()
				package.loaded["infra.config_paths"] = { config = function() return path end,
					config_home = function() return assert(path:match("^(.*)/[^/]+$")) end }
				package.loaded["ui.menu.start_at_login"] = { enabled = function() return false end }
				local i18n = require("infra.i18n")
				if type(variant) == "table" and type(variant.translate) == "function" then
					local localized = {}; for key, value in pairs(i18n) do localized[key] = value end
					localized.get = variant.translate
					package.loaded["infra.i18n"], i18n = localized, localized
				end
				local native_menu = assert(require("menu.renderer").new({
					platform = "linux", manifest_path = function() return helpers.driver_root() .. "/../_shared/modules/menu/menu_manifest.json" end,
					json_decode = function(raw)
						local root = assert(Json.decode(raw))
						if variant == "reverse" then root.llm_navigation_rows[1], root.llm_navigation_rows[2] = root.llm_navigation_rows[2], root.llm_navigation_rows[1]; root.llm_navigation_rows[1].i18n = "button.cancel" end
						if variant == "absent" then root.llm_navigation_rows = {} end
						if variant == "invalid" then root.llm_navigation_rows[1].i18n = 2 end
						return root
					end,
					i18n = i18n, logger = require("logger.shim"),
				}))
				package.loaded["infra.manifest_menu"] = native_menu
				os.execute = function(command)
					if command:find("zenity --error", 1, true) then notices = notices + 1; return true end
					if command:find("start_at_login.sh", 1, true) then return false end
					return previous_execute(command)
				end
				local settings = require("modules.llm.navigation_settings")
				local context = { llm = { is_enabled = function() return true end }, on_quit = function() end,
					on_menu_changed = function() changed = changed + 1 end }
				local function build()
					local items = require("ui.menu.menu_builder").build(context)
					for _, item in ipairs(items) do
						if item.title == i18n.get("menu.llm.title") then
							for _, child in ipairs(item.menu or {}) do if child.title == i18n.get("menu.llm.nav_menu_title") then return child.menu end end
						end
					end
					error("the actual tray navigation subtree is absent")
				end
				body({ path = path, build = build, settings = settings, i18n = i18n,
					changed = function() return changed end, notices = function() return notices end,
					fault = function(mode)
						os.rename = function(source, destination)
							if destination == path then
								if mode == "throw" then error("controlled native publication refusal") end
								if mode == "nil" then return nil, "refused" end
								return mode == "number" and 2 or false
							end
							return previous_rename(source, destination)
						end
					end,
					clear_fault = function() os.rename = previous_rename end,
				})
			end, debug.traceback)
			os.execute, os.rename = previous_execute, previous_rename
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
			if not ok then error(failure, 0) end
		end)
	end
	helpers.it("(llm-nav-shared) consumes reordered native submenu labels and shared absence", function()
		with_native_navigation("reverse", function(fixture)
			local rows = fixture.build()
			helpers.assert_eq(#rows, 2)
			helpers.assert_eq(rows[1].title, fixture.i18n.get("button.cancel"))
			helpers.assert_true(rows[2].title:find(fixture.i18n.get("menu.llm.nav_label"), 1, true) == 1)
			helpers.assert_eq(#rows[1].menu, #fixture.settings.options(), "the real validation choices remain intact")
			helpers.assert_eq(#rows[2].menu, #fixture.settings.options(), "the real navigation choices remain intact")
		end)
		with_native_navigation("absent", function(fixture) helpers.assert_eq(#fixture.build(), 0) end)
		with_native_navigation("invalid", function(fixture) helpers.assert_eq(#fixture.build(), 1) end)
	end)
	helpers.it("(llm-nav-shared) renders all twenty-one real locale captions through the actual tray", function()
		local root = helpers.driver_root() .. "/../_shared/data/"
		local input = assert(io.open(root .. "locale_order.json", "r"))
		local locales = assert(Json.decode(input:read("*a"))).order; input:close()
		helpers.assert_eq(#locales, 21)
		local manifest_file = assert(io.open(helpers.driver_root() .. "/../_shared/modules/menu/menu_manifest.json", "r"))
		local definitions = assert(Json.decode(manifest_file:read("*a"))).llm_navigation_rows; manifest_file:close()
		local corpus_file = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/menus/llm_navigation_rows.json", "r"))
		local expected = assert(Json.decode(corpus_file:read("*a"))).rows; corpus_file:close()
		helpers.assert_eq(#definitions, 2, "both actual declared modifier providers must be present")
		helpers.assert_eq(#expected, 2, "the independent navigation corpus must be nonempty and complete")
		for index, definition in ipairs(definitions) do
			helpers.assert_eq({ definition.id, definition.type, definition.i18n },
				{ expected[index].id, expected[index].type, expected[index].i18n })
		end
		for _, locale in ipairs(locales) do
			local file = assert(io.open(root .. "locales/" .. locale .. ".json", "r"))
			local catalogue = assert(Json.decode(file:read("*a"))); file:close()
			local matched_paths = {}
			local function translated(key)
				local direct = catalogue[key]
				local value = catalogue
				local matched = 0
				for segment in key:gmatch("[^.]+") do
					matched = matched + 1
					value = type(value) == "table" and value[segment] or nil
				end
				matched_paths[#matched_paths + 1] = matched
				if direct ~= nil then return direct end
				return value or key
			end
			with_native_navigation({ translate = translated }, function(fixture)
				local before = Sandbox.read_bytes(fixture.path)
				local rows = fixture.build()
				helpers.assert_eq(#rows, 2)
				helpers.assert_eq(rows[1].title, translated("menu.llm.nav_label") .. " — " .. translated("menu.llm.arrows_only"))
				helpers.assert_eq(rows[2].title, string.format(translated("menu.llm.val_label"), translated("menu.settings.no_modifier")))
				helpers.assert_eq(rows[1].menu[1].title, translated("menu.llm.arrows_only"))
				helpers.assert_eq(rows[2].menu[1].title, translated("menu.settings.no_modifier"))
				helpers.assert_eq(type(rows[1].menu[2].fn), "function")
				helpers.assert_eq(Sandbox.read_bytes(fixture.path), before)
				helpers.assert_eq(fixture.changed(), 0)
			end)
			helpers.assert_true(#matched_paths > 0, "real locale lookups must execute")
			for _, matched in ipairs(matched_paths) do
				helpers.assert_true(matched > 0, "every actual locale lookup matches a nonempty key path")
			end
		end
	end)
	for _, mode in ipairs({ "false", "nil", "number", "throw" }) do
		for _, direction in ipairs({ "navigation", "validation" }) do
			helpers.it("(llm-nav-ack) retains native file and chord after " .. direction .. " " .. mode, function()
				with_native_navigation(nil, function(fixture)
					local rows = fixture.build()
					local target = direction == "navigation" and rows[1] or rows[2]
					local before = Sandbox.read_bytes(fixture.path)
					local callback = target.menu[2].fn -- the existing Alt choice
					fixture.fault(mode)
					local called, result = pcall(callback)
					fixture.clear_fault()
					helpers.assert_eq({ called, result }, { true, false }, "the callback exposes actual publication refusal")
					helpers.assert_eq(Sandbox.read_bytes(fixture.path), before)
					helpers.assert_eq(fixture.settings.get(), {})
					helpers.assert_eq(fixture.settings.get_navigation(), {})
					helpers.assert_eq(fixture.changed(), 0)
					helpers.assert_eq(fixture.notices(), 1)
					helpers.assert_eq(callback(), true, "the same captured callback retries through the real native writer")
					helpers.assert_eq(fixture.changed(), 1)
					local document = require("toml_codec").decode(Sandbox.read_bytes(fixture.path))
					helpers.assert_eq(document.llm.navigation[direction == "navigation" and "nav_modifiers" or "val_modifiers"], { "alt" })
					helpers.assert_eq(document.llm.navigation.future, "retain")
					helpers.assert_eq(document.other.value, 42)
				end)
			end)
		end
	end
	helpers.it("(llm-nav-ack) refuses a nonboolean setter without repaint or durable publication", function()
		with_native_navigation(nil, function(fixture)
			local before = Sandbox.read_bytes(fixture.path)
			local original = fixture.settings.set_navigation
			fixture.settings.set_navigation = function() return 2 end
			local rows = fixture.build()
			local called, result = pcall(rows[1].menu[2].fn)
			fixture.settings.set_navigation = original
			helpers.assert_eq({ called, result }, { true, false })
			helpers.assert_eq(fixture.changed(), 0)
			helpers.assert_eq(fixture.notices(), 1)
			helpers.assert_eq(Sandbox.read_bytes(fixture.path), before)
		end)
	end)
end)
