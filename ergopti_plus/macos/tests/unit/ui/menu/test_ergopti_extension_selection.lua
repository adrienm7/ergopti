--- tests/unit/ui/menu/test_ergopti_extension_selection.lua

--- ==============================================================================
--- MODULE: Shipped Ergopti Native Feature Menu (macOS)
--- DESCRIPTION:
--- Joins real shipped discovery, TOML registration, the menu callback, canonical
--- persistence and the actual keyDown callback; only native OS APIs are stubbed.
--- ==============================================================================

local helpers = require("tests.helpers")
local CaptionFixture = require("tests.support.hotstrings_parent_caption_fixture")
require("test.ergopti_extension_selection_contract").run(helpers, require("infra.manifest_reader").features())

--- Provides the real files beneath a shipped scanner root.
--- @return table Scanner filesystem collaborators.
local function scanner_io()
	local lfs = require("lfs")
	local function list(path, mode)
		local out = {}
		for name in lfs.dir(path) do
			local full = path .. "/" .. name
			if name ~= "." and name ~= ".." and lfs.attributes(full, "mode") == mode then out[#out + 1] = full end
		end
		table.sort(out)
		return out
	end
	return {
		list_dirs = function(path) return list(path, "directory") end,
		list_files = function(path) return list(path, "file") end,
		read_file = function(path)
			local file = io.open(path, "r")
			if not file then return nil end
			local content = file:read("*a"); file:close(); return content
		end,
	}
end

--- A physical J press delivered to the production keyDown event tap.
--- @return table
local function physical_j()
	local event = { text = "j" }
	function event:getProperty() return 0 end
	function event:getKeyCode() return 38 end
	function event:getFlags() return {} end
	function event:getCharacters() return self.text end
	function event:setUnicodeString(text) self.text, self.remapped = text, true end
	return event
end

helpers.describe("Shipped Ergopti menu and physical replacement", function()
	helpers.it("(ergopti-extension-selection) persists the actual replacement gate, reloads it and rolls back refusals", function()
		helpers.with_stub_scope({ "modules.keymap", "modules.keymap.init", "modules.keymap.state",
			"modules.keymap.utils", "modules.keymap.expander", "modules.keymap.llm_bridge",
			"infra.extension_packs", "infra.preferences", "infra.i18n", "adapters.storage", "adapters.file_system" }, function()
			package.loaded["modules.keymap.utils"] = setmetatable({
				is_ignored_window = function() return false, 0 end,
				is_secure_field = function() return false end,
				start_ignored_win_tracking = function() return 1 end,
			}, { __index = function() return function() return true end end })
			local native = require("tests.stubs.hs").eventtap
			local eventtap, taps = {}, {}
			for key, value in pairs(native) do eventtap[key] = value end
			eventtap.new = function(types, callback)
				local tap = { callback = callback, enabled = false }
				function tap:start() self.enabled = true; return self end
				function tap:stop() self.enabled = false; return self end
				function tap:isEnabled() return self.enabled end
				taps[#taps + 1] = tap
				return tap
			end
			local Keymap = helpers.load_with_stubs("modules.keymap", { eventtap = eventtap })
			package.loaded["infra.i18n"] = setmetatable({ build_language_menu_items = function() return {} end },
				{ __index = require("infra.i18n") })
			local FixtureFiles = require("tests.support.file_system_write_stub")
			package.loaded["adapters.file_system"] = setmetatable({
				read = function(path) return FixtureFiles.read_with_status(path) end,
			}, { __index = FixtureFiles })
			package.loaded["modules.hotstrings.hotstrings_config"] = {
				get_user_override = function() return nil end,
				resolve = function() return { delay = 0.5, has_override = false } end,
			}
			local Packs = require("infra.extension_packs")
			Packs._reset()
			local found = Packs.discover({ { pack = helpers.driver_root() .. "../../layouts/registry/ergopti" } }, scanner_io())
			helpers.assert_eq(#found, 1, "the shipped pack needs no installed-layout record")
			local common = helpers.shared("modules/hotstrings/magickey.toml")
			local path, sources = Packs.route("magickey", common)
			helpers.assert_true(Keymap.load_toml("magickey", path, sources))
			local suffix_path = Packs.route("french_distancesreduction", nil)
			helpers.assert_true(Keymap.load_toml("french_distancesreduction", suffix_path))
			helpers.assert_true(Keymap.set_magic_key_source("KeyJ"))
			CaptionFixture.install(require("infra.i18n"))
			package.loaded["ui.menu.builder"] = nil
			local Registry = require("modules.keymap.registry")
			local Hotstrings = require("ui.menu.menu_hotstrings")
			local Preferences = require("infra.preferences")
			local neutral = Preferences.project_hotstring_preferences({}, Registry.list_groups(), Keymap.get_sections)
			helpers.assert_eq(neutral.section_states.magickey.replace, false, "fresh canonical absence keeps native replacement opt-in")
			local prefs_file = os.tmpname()
			os.remove(prefs_file)
			local refuse, saves = false, 0
			local ctx = { hotfiles = { "magickey", "french_distancesreduction" }, extension_packs = found, keymap = Keymap,
				state = { hotstrings = { magickey = true, french_distancesreduction = true }, keymap = false,
					sections_order_overrides = {}, delays = {} }, paused = false,
				config = { log_level = 2 }, base_dir = helpers.driver_root(),
				get_group_name = function(name) return name end,
				build_language_menu_items = function() return {} end,
				applyTriggerChar = function(text) return text end,
				updateMenu = function() end,
			}
			ctx.save_prefs = function()
				saves = saves + 1
				if refuse then return false end
				return Preferences.save(prefs_file, ctx.state, ctx.hotfiles, { keymap = Keymap })
			end
			local function row()
				local by_extension = Hotstrings.bound_sections(ctx)
				for _, candidate in ipairs(Hotstrings.build_bound_section_rows(ctx, by_extension.ergopti)) do
					if candidate.label:find("(0)", 1, true) then return candidate end
				end
			end
			local ok, err = pcall(function()
				local initial = row()
				helpers.assert_type(initial, "table", "the metadata-only feature draws an actual extension row")
				local tree = require("ui.menu.builder").generate(ctx, { hotstrings = Hotstrings },
					setmetatable({}, { __index = function() return function() end end }))
				local extension_title = string.format(require("infra.i18n").get("menu.extensions.hotstrings_of"), "Ergopti+")
				local function find(rows, title)
					for _, candidate in ipairs(rows or {}) do
						if candidate.title == title then return candidate end
						local nested = find(candidate.menu, title)
						if nested then return nested end
					end
				end
				local extension
				local function find_extension(rows)
					for _, candidate in ipairs(rows or {}) do
						if type(candidate.title) == "string" and candidate.title:sub(1, #extension_title) == extension_title then
							extension = candidate
						end
						find_extension(candidate.menu)
					end
				end
				find_extension(tree)
				helpers.assert_type(extension, "table", "the actual native renderer shows the shipped extension")
				helpers.assert_type(find(extension.menu, initial.label), "table", "the localized replacement is inside Ergopti")
				local suffix = Keymap.get_sections("french_distancesreduction")[1]
				local locale = require("infra.i18n").get_locale()
				local suffix_title = suffix.description[locale] or suffix.description.en
				helpers.assert_type(find(extension.menu, suffix_title .. " (24)"), "table",
					"all suffixes are visible in the extension's actual category subtree")
				helpers.assert_true(type(initial.action) == "function")
				helpers.assert_true(initial.action())
				helpers.assert_eq(Registry.is_section_enabled("magickey", "replace"), true)
				local saved = Preferences.load(prefs_file)
				helpers.assert_eq(saved.section_states.magickey.replace, true, "the empty native feature is persisted")
				local event = physical_j(); taps[1].callback(event)
				helpers.assert_eq(event.text, Keymap.get_trigger_char(), "the real row opens the physical remap gate")
				helpers.assert_eq(event.remapped, true)
				refuse = true
				helpers.assert_eq(initial.action(), false)
				helpers.assert_eq(Registry.is_section_enabled("magickey", "replace"), true, "save refusal rolls back native and cache")
				local before = saves; ctx.paused = true
				helpers.assert_eq(initial.action(), false)
				helpers.assert_eq(saves, before, "a retained paused callback cannot write")
				ctx.paused, refuse = false, false
				helpers.assert_true(Registry.disable_section("magickey", "replace"))
				helpers.assert_true(Registry.apply_hotstring_preferences(saved))
				helpers.assert_eq(Registry.is_section_enabled("magickey", "replace"), true, "canonical boot projection restores replacement")
				helpers.assert_true(initial.action())
				local disabled = physical_j(); taps[1].callback(disabled)
				helpers.assert_nil(disabled.remapped, "the same extension callback closes actual physical remapping")
				helpers.assert_true(Registry.enable_section("magickey", "text_expansion_symbols"))
				local bound = Hotstrings.bound_sections(ctx)
				helpers.assert_true(Hotstrings.build_extension_bulk_actions(ctx, {}, bound.ergopti)[1].action())
				helpers.assert_eq(Registry.is_section_enabled("magickey", "replace"), true)
				helpers.assert_true(Hotstrings.build_extension_bulk_actions(ctx, {}, bound.ergopti)[1].action())
				helpers.assert_eq(Registry.is_section_enabled("magickey", "replace"), false)
				helpers.assert_eq(Registry.is_section_enabled("magickey", "repeat_corrections"), false)
				helpers.assert_eq(Registry.is_section_enabled("magickey", "text_expansion_symbols"), true,
					"extension bulk disable preserves the unrelated common symbol choice")
				helpers.assert_eq(Registry.is_group_enabled("magickey"), true)
				local before = saves
				helpers.assert_true(Registry.disable_group("magickey"))
				helpers.assert_eq(initial.action(), false, "a retained callback loses admission when its category closes")
				helpers.assert_eq(saves, before)
			end)
			os.remove(prefs_file)
			Packs._reset()
			if not ok then error(err, 0) end
		end)
	end)
end)
