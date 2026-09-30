--- tests/unit/infra/test_legacy_hotstring_storage.lua

--- ==============================================================================
--- MODULE: Legacy Hotstring Storage Import
--- DESCRIPTION:
--- An install updated from a build that kept hotstring choices in storage.json
--- keeps the categories, sections, magic key and repeat key it had: the import
--- writes their canonical config.toml leaves once, never over an explicit leaf,
--- and removes the legacy keys only after that write commits.
--- ==============================================================================

local helpers = require("tests.helpers")
local Codec = require("toml_codec")

local FAMILIES = { { id = "date_fr", section = "datefr" }, { separator = true } }

-- The legacy word-delimiter lists and the two separators their records used.
local STATE_KEY = "hotstrings.terminator_state"
local CUSTOM_KEY = "hotstrings.custom_terminators"
local RECORD = "\30"
local FIELD = "\31"

--- An in-memory storage adapter.
--- @param values table Initial keys.
--- @return table adapter
local function storage(values)
	local adapter = { values = values, refuse_delete = false }
	function adapter.has(key) return adapter.values[key] ~= nil end
	function adapter.get(key, default)
		local value = adapter.values[key]
		if value == nil then return default end
		return value
	end
	function adapter.delete(key)
		if adapter.refuse_delete then return false end
		adapter.values[key] = nil
		return true
	end
	return adapter
end

local function read(path)
	local handle = io.open(path, "r")
	if not handle then return nil end
	local content = handle:read("*a")
	handle:close()
	return content
end

--- Runs body with the import and the preference owner routed to a private file.
--- @param content string|nil Initial config.toml bytes; nil is an absent file.
--- @param body function body(Import, path, Preferences)
local function with_config(content, body)
	local previous = {}
	for _, name in ipairs({ "infra.hotstring_preferences", "modules.hotstrings.terminator_settings",
		"infra.legacy_hotstring_storage" }) do
		previous[name] = package.loaded[name]
		package.loaded[name] = nil
	end
	local path = string.format("%s/ergopti_legacy_hotstrings_%d_%d/config.toml",
		(os.getenv("TMPDIR") or "/tmp"):gsub("/+$", ""), os.time(), math.random(100000, 999999))
	local directory = path:match("^(.*)/[^/]+$")
	if content then
		assert(os.execute("mkdir -p '" .. directory .. "'"))
		local handle = assert(io.open(path, "w"))
		handle:write(content)
		handle:close()
	end
	local ok, err = pcall(function()
		local Preferences = require("infra.hotstring_preferences")
		assert(Preferences._set_file_for_test(path))
		body(require("infra.legacy_hotstring_storage"), path, Preferences)
	end)
	for name, value in pairs(previous) do package.loaded[name] = value end
	os.remove(path)
	os.remove(path .. ".tmp")
	os.remove(directory)
	if not ok then error(err, 0) end
end

local MAINTAINER = {
	["hotstrings.disabled_categories"] = "+autocorrection.caps,+rolls.hc,rolls,+french_autocorrection.accents,"
		.. "french_autocorrection.accents,+ext:demo:pack.main",
	["hotstrings.trigger_char"] = "§",
	["hotstrings.preview_ai_enabled"] = true,
	["hotstrings.dynamic.datefr"] = true,
	["hotstrings.terminators"] = "kept",
}

helpers.describe("legacy hotstring storage import", function()
	helpers.it("keeps an updated install's categories, sections and scalar settings", function()
		with_config('[hotstrings]\nunknown = "kept"\n\n[other]\nvalue = 1\n', function(Import, path, Preferences)
			local adapter = storage((function()
				local copy = {}
				for key, value in pairs(MAINTAINER) do copy[key] = value end
				return copy
			end)())
			helpers.assert_true(Import.import({ path = path, storage = adapter, families = FAMILIES }))
			local document = Codec.decode(read(path))
			local hotstrings = document.hotstrings
			helpers.assert_eq(hotstrings.groups.autocorrection, true, "an open gate with a chosen section")
			helpers.assert_nil(hotstrings.groups.rolls, "a closed gate stays neutral")
			helpers.assert_eq(hotstrings.modules.rolls.hc, true, "a section choice survives its closed gate")
			helpers.assert_eq(hotstrings.modules.autocorrection.caps, true)
			helpers.assert_nil(hotstrings.modules.french_autocorrection, "an explicit opt-out wins")
			helpers.assert_eq(hotstrings.groups["ext:demo:pack"], true, "an extension identity is kept")
			helpers.assert_eq(hotstrings.modules["ext:demo:pack"].main, true)
			helpers.assert_eq(hotstrings.trigger_char, "§")
			helpers.assert_eq(hotstrings.preview_ai_enabled, true)
			helpers.assert_eq(hotstrings.dynamic.date_fr.enabled, true)
			helpers.assert_eq(hotstrings.repeat_key_enabled, true, "the legacy repeat default was on")
			helpers.assert_eq(hotstrings.unknown, "kept")
			helpers.assert_eq(document.other.value, 1)
			helpers.assert_eq(Preferences.get("hotstrings.trigger_char"), "§", "the owner reads the import")
			helpers.assert_eq(adapter.values["hotstrings.terminators"], "kept", "unrelated storage survives")
			for key in pairs(MAINTAINER) do
				if key ~= "hotstrings.terminators" then helpers.assert_nil(adapter.values[key], key) end
			end
		end)
	end)

	helpers.it("never overwrites a leaf config.toml already sets", function()
		local source = '[hotstrings]\ntrigger_char = "#"\nrepeat_key_enabled = false\ngroups = { autocorrection = false }\n'
		with_config(source, function(Import, path)
			local adapter = storage({ ["hotstrings.disabled_categories"] = "+autocorrection.caps",
				["hotstrings.trigger_char"] = "§" })
			helpers.assert_true(Import.import({ path = path, storage = adapter }))
			local hotstrings = Codec.decode(read(path)).hotstrings
			helpers.assert_eq(hotstrings.trigger_char, "#")
			helpers.assert_eq(hotstrings.repeat_key_enabled, false)
			helpers.assert_eq(hotstrings.groups.autocorrection, false)
			helpers.assert_eq(hotstrings.modules.autocorrection.caps, true)
			helpers.assert_eq(next(adapter.values), nil, "a settled import removes its keys")
		end)
	end)

	helpers.it("leaves a fresh install neutral and unwritten", function()
		with_config(nil, function(Import, path)
			local adapter = storage({ ["hotstrings.terminators"] = "kept" })
			helpers.assert_true(Import.import({ path = path, storage = adapter, families = FAMILIES }))
			helpers.assert_nil(read(path))
			helpers.assert_eq(adapter.values["hotstrings.terminators"], "kept")
		end)
	end)

	helpers.it("keeps the legacy keys for the next start when config.toml refuses the write", function()
		local source = "[hotstrings\nbroken"
		with_config(source, function(Import, path)
			local adapter = storage({ ["hotstrings.disabled_categories"] = "+autocorrection.caps",
				[STATE_KEY] = "space" .. FIELD .. "0" })
			helpers.assert_eq(Import.import({ path = path, storage = adapter }), false)
			helpers.assert_eq(read(path), source)
			helpers.assert_eq(adapter.values["hotstrings.disabled_categories"], "+autocorrection.caps")
			helpers.assert_eq(adapter.values[STATE_KEY], "space" .. FIELD .. "0")
		end)
	end)
end)

helpers.describe("legacy hotstring storage import: word delimiters", function()
	helpers.it("carries the delimiters over as sparse config.toml leaves the owner reads", function()
		with_config('[hotstrings]\nunknown = "kept"\n', function(Import, path)
			local adapter = storage({
				[STATE_KEY] = table.concat({ "space" .. FIELD .. "0", "comma" .. FIELD .. "1", "slash" .. FIELD .. "1",
					"custom_§" .. FIELD .. "0", "retired" .. FIELD .. "1" }, RECORD),
				[CUSTOM_KEY] = table.concat({ "custom_§" .. FIELD .. "§" .. FIELD .. "§" .. FIELD .. "1",
					"custom_comma" .. FIELD .. "," .. FIELD .. "," .. FIELD .. "0" }, RECORD),
			})
			helpers.assert_true(Import.import({ path = path, storage = adapter }))
			local hotstrings = Codec.decode(read(path)).hotstrings
			helpers.assert_eq(hotstrings.terminators, { { key = "custom_§", char = "§", label = "§", consume = true } },
				"a custom delimiter that takes a built-in character is not imported")
			helpers.assert_eq(hotstrings.terminator_states.space, false)
			helpers.assert_eq(hotstrings.terminator_states.slash, true)
			helpers.assert_eq(hotstrings.terminator_states["custom_§"], false)
			helpers.assert_nil(hotstrings.terminator_states.comma, "a delimiter on its default stays sparse")
			helpers.assert_nil(hotstrings.terminator_states.retired, "an unknown delimiter is not imported")
			helpers.assert_nil(hotstrings.repeat_key_enabled, "the delimiters say nothing about the repeat key")
			helpers.assert_eq(hotstrings.unknown, "kept")
			helpers.assert_nil(adapter.values[STATE_KEY], "a settled import removes its keys")
			helpers.assert_nil(adapter.values[CUSTOM_KEY])

			-- The owner reads exactly what was imported.
			local Settings = require("modules.hotstrings.terminator_settings")
			local Terminators = require("keymap.terminators")
			local before = Settings.snapshot()
			local paths = require("infra.config_paths")
			local config = paths.config
			paths.config = function() return path end
			local called, loaded = pcall(Settings.load)
			local space, custom = Terminators.is_terminator_enabled("space"), Terminators.is_terminator_enabled("custom_§")
			paths.config = config
			helpers.assert_true(Settings.restore_configuration(before))
			helpers.assert_true(called and loaded)
			helpers.assert_eq(space, false)
			helpers.assert_eq(custom, false)
		end)
	end)

	-- A delimiter the user once added for a character a later catalogue ships
	-- itself cannot be imported as their own; its on/off state still belongs to
	-- that character, so the shipped delimiter takes it unless the store
	-- recorded a state for the shipped one too.
	helpers.it("carries a custom delimiter's state to the shipped one that now owns its character", function()
		with_config('[hotstrings]\nunknown = "kept"\n', function(Import, path)
			local adapter = storage({
				[STATE_KEY] = table.concat({ "custom_comma" .. FIELD .. "0", "custom_period" .. FIELD .. "0",
					"period" .. FIELD .. "1" }, RECORD),
				[CUSTOM_KEY] = table.concat({ "custom_comma" .. FIELD .. "," .. FIELD .. "," .. FIELD .. "0",
					"custom_period" .. FIELD .. "." .. FIELD .. "." .. FIELD .. "0" }, RECORD),
			})
			helpers.assert_true(Import.import({ path = path, storage = adapter }))
			local hotstrings = Codec.decode(read(path)).hotstrings
			local states = hotstrings.terminator_states or {}
			helpers.assert_eq(states.comma, false, "the custom delimiter's off state reaches its character")
			helpers.assert_nil(states.period, "a state the store recorded for the shipped one wins")
			helpers.assert_nil(hotstrings.terminators)
			helpers.assert_eq(next(adapter.values), nil)
		end)
	end)

	-- A config.toml list of another shape is outdated: it used to count as
	-- defined, so the legacy delimiters were skipped, then deleted unimported.
	helpers.it("imports the legacy delimiters over a config.toml list of another shape", function()
		with_config('[hotstrings]\nterminators = "broken"\n', function(Import, path)
			local adapter = storage({
				[STATE_KEY] = "custom_§" .. FIELD .. "0",
				[CUSTOM_KEY] = "custom_§" .. FIELD .. "§" .. FIELD .. "§" .. FIELD .. "1",
			})
			helpers.assert_true(Import.import({ path = path, storage = adapter }))
			local hotstrings = Codec.decode(read(path)).hotstrings
			helpers.assert_eq(hotstrings.terminators, { { key = "custom_§", char = "§", label = "§", consume = true } })
			helpers.assert_eq(hotstrings.terminator_states["custom_§"], false)
			helpers.assert_eq(next(adapter.values), nil, "removed only once imported")
		end)
	end)

	helpers.it("keeps the delimiter list config.toml already defines, with its states", function()
		local source = '[hotstrings]\nterminators = [{ key = "custom_x", char = "¤", label = "¤", consume = false }]\n'
		with_config(source, function(Import, path)
			local adapter = storage({
				[STATE_KEY] = "space" .. FIELD .. "0" .. RECORD .. "custom_§" .. FIELD .. "0",
				[CUSTOM_KEY] = "custom_§" .. FIELD .. "§" .. FIELD .. "§" .. FIELD .. "1",
			})
			helpers.assert_true(Import.import({ path = path, storage = adapter }))
			local hotstrings = Codec.decode(read(path)).hotstrings
			helpers.assert_eq(hotstrings.terminators, { { key = "custom_x", char = "¤", label = "¤", consume = false } })
			helpers.assert_eq(hotstrings.terminator_states.space, false)
			helpers.assert_nil(hotstrings.terminator_states["custom_§"], "a legacy custom state follows its list")
			helpers.assert_eq(next(adapter.values), nil)
		end)
	end)
end)
