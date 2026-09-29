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
	for _, name in ipairs({ "infra.hotstring_preferences", "infra.legacy_hotstring_storage" }) do
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
			local adapter = storage({ ["hotstrings.disabled_categories"] = "+autocorrection.caps" })
			helpers.assert_eq(Import.import({ path = path, storage = adapter }), false)
			helpers.assert_eq(read(path), source)
			helpers.assert_eq(adapter.values["hotstrings.disabled_categories"], "+autocorrection.caps")
		end)
	end)
end)
