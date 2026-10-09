--- tests/unit/modules/keymap/test_magic_key_source.lua

--- ==============================================================================
--- MODULE: Physical Magic Key (macOS)
--- DESCRIPTION:
--- `hotstrings.magic_key_source` names the physical key that types the magic
--- key, on every driver. macOS used a fixed key: whatever its input source put
--- the magic key on, with no way to choose another. These cases replay the
--- shared decisions with macOS keycodes, then drive the real keymap keyDown
--- callback: a plain press of the chosen key must leave the tap carrying the
--- magic key, and every other press must stay untouched.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Shared = require("keymap.magic_key_source")

local PATH = "hotstrings.magic_key_source"
local KEYCODE_J = 38
local KEYCODE_C = 8

local RESET_MODULES = {
	"modules.keylogger.physical_accounting_mode",
	"adapters.event_provenance", "adapters.synthetic_input",
	"infra.logger", "infra.text_utils",
	"modules.hotstrings.hotstrings_config", "modules.keylogger",
	"modules.keymap", "modules.keymap.init", "modules.keymap.expander",
	"modules.keymap.llm_bridge", "modules.keymap.registry",
	"modules.keymap.state", "modules.keymap.terminator_replay",
	"modules.keymap.utils", "modules.keymap.magic_key_source",
	"modules.llm", "modules.llm.prediction_engine", "ui.tooltip",
}

local function registry()
	local handle = assert(io.open(helpers.shared("data/keycodes/physical_keys.json"), "rb"))
	local decoded = Json.decode(handle:read("*a"))
	handle:close()
	return decoded
end

local Manifest = require("infra.manifest_reader")
require("test.magic_key_source_contract")(helpers, Shared, {
	entry = Manifest.find_entry_by_path(PATH),
	registry = registry(),
	field = "hs",
})

--- Loads the real keymap with a recording keyDown eventtap.
--- @return table keymap
--- @return table tap The keyDown tap, whose callback is the production one.
local function load_keymap()
	package.loaded["adapters.keyboard_geometry"] = nil
	for _, name in ipairs(RESET_MODULES) do package.loaded[name] = nil end
	for name in pairs(package.loaded) do
		if type(name) == "string" and (name:match("^modules%.keymap") or name:match("^modules%.llm")) then
			package.loaded[name] = nil
		end
	end
	package.loaded["modules.keymap.utils"] = setmetatable({
		is_ignored_window = function() return false, 0 end,
		is_secure_field = function() return false end,
	}, { __index = function() return function() return true end end })

	local base = require("tests.stubs.hs").eventtap
	local taps = {}
	local eventtap = {}
	for key, value in pairs(base) do eventtap[key] = value end
	eventtap.new = function(types, callback)
		local tap = { types = types, callback = callback, enabled = false }
		function tap:start() self.enabled = true return self end
		function tap:stop() self.enabled = false return self end
		function tap:isEnabled() return self.enabled end
		taps[#taps + 1] = tap
		return tap
	end
	local keymap = helpers.load_with_stubs("modules.keymap", { eventtap = eventtap })
	require("tests.support.keyboard_geometry").initialize(require("adapters.keyboard_geometry"))
	return keymap, taps[1]
end

--- A physical keyDown that records the text the tap gives it.
--- @param key_code number
--- @param flags table
--- @return table event
local function key_down(key_code, flags, keyboard_type)
	local event = { text = "x", set = nil }
	event.getProperty = function(_, property)
		if property == hs.eventtap.event.properties.keyboardEventKeyboardType then return keyboard_type end
		return 0
	end
	event.getKeyCode = function() return key_code end
	event.getFlags = function() return flags end
	event.getCharacters = function() return event.text end
	event.setUnicodeString = function(self, text)
		self.set = text
		self.text = text
	end
	return event
end

helpers.describe("magic key source: the macOS owner", function()
	helpers.it("(magic-key-source) resolves the chosen key to its keycode, automatic to none", function()
		helpers.with_fresh_modules({ "modules.keymap.magic_key_source" }, function()
			local Source = require("modules.keymap.magic_key_source")
			helpers.assert_eq(Source.get(), Manifest.default_for(PATH), "the manifest default is in effect first")
			helpers.assert_nil(Source.keycode())
			helpers.assert_eq(Source.set("KeyJ"), "KeyJ")
			helpers.assert_eq(Source.keycode(), KEYCODE_J)
			helpers.assert_eq(Source.set("SC03B"), "auto", "an outdated value is the automatic key")
			helpers.assert_nil(Source.keycode(), "and remaps nothing")
			Source.set("KeyJ")
			local on = function() return true end
			helpers.assert_true(Source.remaps(KEYCODE_J, {}, on))
			helpers.assert_eq(Source.remaps(KEYCODE_J, { shift = true }, on), false, "Shift keeps J")
			helpers.assert_eq(Source.remaps(KEYCODE_J, { cmd = true }, on), false, "⌘J stays a shortcut")
			helpers.assert_eq(Source.remaps(KEYCODE_C, {}, on), false, "the former fixed key is free")
			helpers.assert_eq(Source.remaps(KEYCODE_J, {}, function() return false end), false,
				"nothing is remapped while the replace section is off")
			Source.set("auto")
		end)
	end)
end)

-- The key left of 1 reaches the tap as 50 behind Karabiner's ANSI virtual
-- keyboard and on an ANSI board, as 10 on a bare ISO board; the key left of Z
-- the other way round. Read in the ISO form alone, Backquote remapped the key
-- left of Z in the driver's own Karabiner setup.
helpers.describe("magic key source: the two keys ISO boards swap", function()
	helpers.it("(magic-key-source) Backquote and IntlBackslash keep distinct physical positions", function()
		helpers.with_fresh_modules({ "modules.keymap.magic_key_source", "adapters.keyboard_geometry" }, function()
			require("tests.support.keyboard_geometry").initialize(require("adapters.keyboard_geometry"))
			local Source = require("modules.keymap.magic_key_source")
			local on = function() return true end
			for _, code in ipairs({ "Backquote", "IntlBackslash" }) do
				Source.set(code)
				local ansi, iso = code == "Backquote" and 50 or 10, code == "Backquote" and 10 or 50
				helpers.assert_true(Source.remaps(ansi, {}, on, 40), code .. " on ANSI")
				helpers.assert_true(Source.remaps(iso, {}, on, 41), code .. " on ISO")
				helpers.assert_eq(Source.remaps(iso, {}, on, 40), false, "the ANSI neighbor remains free")
				helpers.assert_eq(Source.remaps(ansi, {}, on, 41), false, "the ISO neighbor remains free")
				helpers.assert_eq(Source.remaps(38, {}, on), false, "and no other key")
			end
			Source.set("Backquote")
			helpers.assert_eq(Source.keycode(), 50, "the key left of 1 as the driver's Karabiner setup sends it")
			Source.set("KeyJ")
			helpers.assert_true(Source.owns(KEYCODE_J))
			helpers.assert_eq(Source.owns(50), false, "a key no board swaps has one keycode")
			helpers.assert_eq(Source.owns(10), false)
			Source.set("auto")
			helpers.assert_eq(Source.owns(50), false, "the automatic key owns no keycode")
		end)
	end)
end)

helpers.describe("magic key source: boot cost", function()
	helpers.it("(magic-key-source) the automatic key is applied without reading the key registry", function()
		helpers.with_fresh_modules({ "modules.keymap.magic_key_source", "adapters.file_system" }, function()
			local real = require("adapters.file_system")
			local reads = 0
			package.loaded["adapters.file_system"] = setmetatable({
				read = function(path)
					reads = reads + 1
					return real.read(path)
				end,
			}, { __index = real })
			local Source = require("modules.keymap.magic_key_source")
			helpers.assert_eq(Source.set(nil), "auto")
			helpers.assert_eq(Source.set("auto"), "auto")
			helpers.assert_eq(reads, 0, "every boot applies the automatic key: no 37 KB JSON decode for it")
			helpers.assert_eq(Source.set("KeyJ"), "KeyJ")
			helpers.assert_eq(reads, 1, "a chosen key reads the registry once")
			Source.set("auto")
		end)
	end)
end)

helpers.describe("magic key source: the keymap keyDown tap", function()
	helpers.it("(magic-key-source) a plain press of the chosen key carries the magic key", function()
		local keymap, tap = load_keymap()
		helpers.assert_type(tap and tap.callback, "function", "the keyDown tap must be captured")
		local Registry = require("modules.keymap.registry")
		local replace = true
		Registry.is_group_enabled = function(name) return name == "magickey" end
		Registry.is_section_enabled = function(group, section)
			return group == "magickey" and section == "replace" and replace
		end
		local magic = keymap.get_trigger_char()

		helpers.assert_true(keymap.set_magic_key_source("KeyJ"))
		helpers.assert_eq(keymap.get_magic_key_source(), "KeyJ")
		local plain = key_down(KEYCODE_J, {})
		tap.callback(plain)
		helpers.assert_eq(plain.set, magic, "the chosen key types the magic key")

		local shifted = key_down(KEYCODE_J, { shift = true })
		tap.callback(shifted)
		helpers.assert_nil(shifted.set, "Shift keeps the key's own capital")
		local other = key_down(KEYCODE_C, {})
		tap.callback(other)
		helpers.assert_nil(other.set, "any other key keeps its character")

		replace = false
		local off = key_down(KEYCODE_J, {})
		tap.callback(off)
		helpers.assert_nil(off.set, "the replace section gates the remap")

		replace = true
		helpers.assert_true(keymap.set_magic_key_source("Backquote"))
		for _, row in ipairs({ { 50, 40, true }, { 10, 41, true }, { 10, 40, false }, { 50, 41, false } }) do
			local event = key_down(row[1], {}, row[2])
			tap.callback(event)
			helpers.assert_eq(event.set == magic, row[3], "keymap reads the originating keyboard type")
		end
		helpers.assert_true(keymap.set_magic_key_source("auto"))
		local automatic = key_down(KEYCODE_J, {})
		tap.callback(automatic)
		helpers.assert_nil(automatic.set, "the automatic key leaves the input source alone")
	end)
end)

helpers.describe("magic key source: config.toml", function()
	helpers.it("(magic-key-source) a stored key reaches the menu state, an outdated one is offered", function()
		helpers.with_fresh_modules({ "logger.shim", "config_outdated", "infra.preferences" }, function()
			local warnings = {}
			local shim = helpers.make_logger_stub()
			shim.warn = function(_, message, ...) warnings[#warnings + 1] = string.format(message, ...) end
			package.loaded["logger.shim"] = shim
			helpers.load_with_stubs("config_outdated")
			local Preferences = helpers.load_with_stubs("infra.preferences")
			local TomlCodec = require("toml_codec")

			local chosen = "[hotstrings]\nmagic_key_source = \"Semicolon\"\n"
			helpers.assert_eq(Preferences.flatten_document(TomlCodec.decode(chosen)).magic_key_source, "Semicolon")

			local stale = "[hotstrings]\nmagic_key_source = \"SC03B\"\n"
			helpers.assert_nil(Preferences.flatten_document(TomlCodec.decode(stale)).magic_key_source,
				"an outdated key reads as absent, never as another key")
			helpers.assert_eq(#warnings, 1, table.concat(warnings, " | "))
			helpers.assert_true(warnings[1]:find("'hotstrings.magic_key_source'", 1, true) ~= nil, warnings[1])
			local scan = require("config_unused_keys").find_in_source(stale, Preferences.mark_config_reads)
			helpers.assert_eq(#scan.keys, 1, "the cleanup offers the outdated key")
			helpers.assert_eq(scan.keys[1].section .. "." .. scan.keys[1].key, PATH)
		end)
	end)
end)

helpers.describe("magic key source: acknowledged tap dispatcher", function()
 helpers.it("(magic-key-source) an acknowledged tap claims the same position on mixed keyboards", function()
  -- The earlier real keymap owns an always-on KC drain. Retire that exact
  -- producer before constructing another CoreState and its bridge owner.
  local prior_bridge = package.loaded["modules.keylogger.kc_bridge"]
  if prior_bridge then helpers.assert_true(prior_bridge.stop()) end
  package.loaded["modules.keylogger.kc_bridge"] = nil
  local keymap, keymap_tap = load_keymap()
  local Registry = require("modules.keymap.registry")
  Registry.is_group_enabled = function(name) return name == "magickey" end
  Registry.is_section_enabled = function(group, section) return group == "magickey" and section == "replace" end
  assert(keymap.set_magic_key_source("Backquote"))
  local fixture = require("tests.support.system_actions_fixture")
  fixture.with_fixture(function()
   local sys, spy = fixture.make_sys_screenshot_spies()
   local Tap = require("modules.shortcuts.tap_keys")
   local f = assert(io.open(helpers.shared("modules/actions/modifier_chords.json"), "rb"))
   local actions = require("actions.assignable").build(require("_generated.action_catalogue"), Json.decode(f:read("*a")), "macos"); f:close()
   assert(Tap.apply_configuration({shortcuts={tap_keys={number_row_left="send_text"}}}, function(id) return actions[id] == true end))
   local ran, admitted = 0, true
   sys.bind_tap_keys(function() return admitted end, function(code, keyboard_type)
    local action = Tap.decide(code, keyboard_type)
    if action then return function() ran = ran + 1; return true end end
   end)
   local results = {}
   for _, row in ipairs({{50,40}, {10,41}, {10,40}, {50,41}}) do
    local code = row[1]
    local event = key_down(code, {}, row[2])
    local keymap_consumed = keymap_tap.callback(event)
    local tap_consumed = spy.captured_cb(event)
    if tap_consumed then fixture.run_screenshot_deferred(spy) end
    results[#results+1] = {code=code, unicode=event.set, keymap=keymap_consumed, tap=tap_consumed, ran=ran}
   end
   helpers.assert_eq(results[1].tap, true)
   helpers.assert_eq(results[2].tap, true)
   helpers.assert_eq(results[3].tap, false, "ANSI extra key remains native")
   helpers.assert_eq(results[4].tap, false, "ISO extra key remains native")
   helpers.assert_eq(ran, 2)
   helpers.assert_nil(results[1].unicode, "a native accepted tap should not mutate the keymap's text context first")
   helpers.assert_nil(results[2].unicode, "ISO delivery uses the same captured type in the claim projection")
   helpers.assert_nil(results[3].unicode, "the ANSI neighbor is never remapped")
   helpers.assert_nil(results[4].unicode, "the ISO neighbor is never remapped")
  end)
 end)
end)
