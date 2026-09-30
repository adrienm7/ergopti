--- tests/unit/modules/hotstrings/test_terminator_settings.lua

--- ==============================================================================
--- MODULE: Word-Delimiter Settings (Linux)
--- DESCRIPTION:
--- The delimiter choices and the user's own delimiters are config.toml leaves:
--- written sparsely by the menu, read back into the shared catalogue at start,
--- adopted and restored exactly by the hotstrings scope, and outdated entries
--- are warned about and offered for cleanup. They used to live in storage.json,
--- where no configuration scope could reach them.
--- ==============================================================================

local helpers = require("tests.helpers")
local Codec = require("toml_codec")

local SOURCE = '[hotstrings]\nunknown = "kept"\n\n[other]\nvalue = 42\n'

--- Runs body with the owner routed to a private config.toml, then puts the
--- shared catalogue and every module cache back.
--- @param source string|nil Initial config.toml bytes; nil is an absent file.
--- @param body function body(Settings, path, sandbox, Terminators)
local function with_settings(source, body)
	local Sandbox = require("test.config_unused_keys_contract").sandbox
	local Terminators = require("keymap.terminators")
	local loaded = {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local baseline = nil
	local ok, err = pcall(function()
		Sandbox.with_config(source, function(path)
			local paths = {}
			for key, value in pairs(require("infra.config_paths")) do paths[key] = value end
			paths.config = function() return path end
			package.loaded["infra.config_paths"] = paths
			for _, name in ipairs({ "infra.hotstring_preferences", "modules.hotstrings.terminator_settings" }) do
				package.loaded[name] = nil
			end
			local Settings = require("modules.hotstrings.terminator_settings")
			baseline = Settings.snapshot()
			local passed, failure = pcall(body, Settings, path, Sandbox, Terminators)
			assert(Settings.restore_configuration(baseline), "the shared catalogue must be put back")
			if not passed then error(failure, 0) end
		end)
	end)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	if not ok then error(err, 0) end
end

--- The default state the catalogue ships for one built-in delimiter.
--- @param Terminators table Shared catalogue.
--- @param key string Delimiter identity.
--- @return boolean
local function shipped(Terminators, key)
	for _, def in ipairs(Terminators.get_terminator_defs()) do
		if def.key == key then return def.default_enabled ~= false end
	end
	error("no built-in delimiter " .. key)
end

--- Whether the catalogue holds a custom delimiter.
--- @param Terminators table Shared catalogue.
--- @param key string Delimiter identity.
--- @return boolean
local function has_custom(Terminators, key)
	for _, def in ipairs(Terminators.get_terminator_defs()) do
		if def.key == key and def.custom then return true end
	end
	return false
end

helpers.describe("word-delimiter settings: config.toml leaves", function()
	helpers.it("keeps a menu change across a restart, sparsely and beside unknown entries", function()
		with_settings(SOURCE, function(Settings, path, sandbox, Terminators)
			helpers.assert_true(Settings.load())
			helpers.assert_eq(shipped(Terminators, "space"), true)
			helpers.assert_eq(shipped(Terminators, "slash"), false)
			helpers.assert_true(Terminators.set_terminators_enabled({ space = false, slash = true }))
			helpers.assert_true(Terminators.add_custom_terminator("custom_§", "§", "§", true))
			helpers.assert_true(Terminators.set_terminator_enabled("custom_§", false))
			helpers.assert_true(Settings.persist())
			local document = Codec.decode(sandbox.read_bytes(path))
			local states = document.hotstrings.terminator_states
			helpers.assert_eq(states.space, false)
			helpers.assert_eq(states.slash, true)
			helpers.assert_eq(states["custom_§"], false)
			helpers.assert_nil(states.comma, "a delimiter on its default leaves no key")
			helpers.assert_eq(document.hotstrings.terminators,
				{ { key = "custom_§", char = "§", label = "§", consume = true } })
			helpers.assert_eq(document.hotstrings.unknown, "kept")
			helpers.assert_eq(document.other.value, 42)

			-- A restart: the catalogue starts from its defaults and reads the file.
			helpers.assert_true(Settings.adopt_configuration({}))
			helpers.assert_eq(Terminators.is_terminator_enabled("space"), true)
			helpers.assert_eq(has_custom(Terminators, "custom_§"), false)
			helpers.assert_true(Settings.load())
			helpers.assert_eq(Terminators.is_terminator_enabled("space"), false)
			helpers.assert_eq(Terminators.is_terminator_enabled("slash"), true)
			helpers.assert_eq(has_custom(Terminators, "custom_§"), true)
			helpers.assert_eq(Terminators.is_terminator_enabled("custom_§"), false)
			helpers.assert_eq(Terminators.terminator_is_consumed("§"), false, "a disabled delimiter ends nothing")
		end)
	end)

	helpers.it("removes the keys of a delimiter back on its default and of a removed custom one", function()
		local stored = '[hotstrings]\nunknown = "kept"\n'
			.. 'terminators = [{ key = "custom_§", char = "§", label = "§", consume = false }]\n'
			.. '\n[hotstrings.terminator_states]\nspace = false\n"custom_§" = false\n'
		with_settings(stored, function(Settings, path, sandbox, Terminators)
			helpers.assert_true(Settings.load())
			helpers.assert_eq(has_custom(Terminators, "custom_§"), true)
			helpers.assert_eq(Terminators.is_terminator_enabled("custom_§"), false)
			helpers.assert_true(Terminators.set_terminator_enabled("space", true))
			helpers.assert_true(Terminators.remove_custom_terminator("custom_§"))
			helpers.assert_true(Settings.persist())
			local document = Codec.decode(sandbox.read_bytes(path))
			local states = document.hotstrings.terminator_states or {}
			helpers.assert_nil(states.space)
			helpers.assert_nil(states["custom_§"], "a removed delimiter's state goes with it")
			helpers.assert_nil(document.hotstrings.terminators)
			helpers.assert_eq(document.hotstrings.unknown, "kept")
		end)
	end)

	helpers.it("writes nothing when the file already holds the catalogue's settings", function()
		with_settings(nil, function(Settings, path, sandbox)
			helpers.assert_true(Settings.load())
			helpers.assert_true(Settings.persist())
			helpers.assert_nil(sandbox.read_bytes(path), "the defaults create no configuration")
		end)
	end)

	helpers.it("waits while a hotstrings scope holds the preferences", function()
		with_settings(SOURCE, function(Settings, path, sandbox, Terminators)
			helpers.assert_true(Settings.load())
			local Preferences = require("infra.hotstring_preferences")
			local owner = {}
			helpers.assert_true(Preferences.acquire(owner))
			helpers.assert_true(Terminators.set_terminator_enabled("space", false))
			helpers.assert_eq(Settings.persist(), false)
			helpers.assert_eq(sandbox.read_bytes(path), SOURCE)
			helpers.assert_true(Preferences.release(owner))
			helpers.assert_true(Settings.persist())
		end)
	end)

	helpers.it("refuses to publish over a file an external editor changed", function()
		with_settings(SOURCE, function(Settings, path, sandbox, Terminators)
			local Writer = require("toml_codec.writer")
			local original = Writer.batch_write
			Writer.batch_write = function(target, rows, files, expected)
				sandbox.write_bytes(target, SOURCE .. "external = 1\n")
				return original(target, rows, files, expected)
			end
			helpers.assert_true(Settings.load())
			local passed, err = pcall(function()
				helpers.assert_true(Terminators.set_terminator_enabled("space", false))
				helpers.assert_eq(Settings.persist(), false)
				helpers.assert_eq(sandbox.read_bytes(path), SOURCE .. "external = 1\n", "the external edit wins")
			end)
			Writer.batch_write = original
			if not passed then error(err, 0) end
		end)
	end)

	helpers.it("refuses a save before the first read, when it cannot know what changed", function()
		with_settings(SOURCE, function(Settings, path, sandbox, Terminators)
			helpers.assert_true(Terminators.set_terminator_enabled("space", false))
			helpers.assert_eq(Settings.persist(), false)
			helpers.assert_eq(sandbox.read_bytes(path), SOURCE)
		end)
	end)

	-- A save rewrote every delimiter leaf from memory: an unusable record or
	-- state the owner had warned about vanished on an unrelated change, and a
	-- hand edit made since the start was reverted.
	helpers.it("writes only what the menu changed, keeping outdated entries and hand edits", function()
		local stored = '[hotstrings]\nunknown = "kept"\n'
			.. 'terminators = [{ key = "custom_¤", char = "¤", label = "¤", consume = true }, '
			.. '{ key = "custom_comma", char = ",", label = ",", consume = false }]\n'
			.. '\n[hotstrings.terminator_states]\nspace = "no"\nretired = true\n"custom_¤" = false\n'
		with_settings(stored, function(Settings, path, sandbox, Terminators)
			helpers.assert_true(Settings.load())
			-- A hand edit after the start: comma switched off, the label renamed.
			local edited = sandbox.read_bytes(path):gsub('label = "¤"', 'label = "hand"')
				:gsub("retired = true\n", "retired = true\ncomma = false\n")
			sandbox.write_bytes(path, edited)
			helpers.assert_true(Terminators.set_terminator_enabled("slash", true))
			helpers.assert_true(Settings.persist())
			local document = Codec.decode(sandbox.read_bytes(path))
			local states = document.hotstrings.terminator_states
			helpers.assert_eq(states.slash, true, "the menu's change is written")
			helpers.assert_eq(states.comma, false, "a hand edit survives an unrelated change")
			helpers.assert_eq(states.space, "no", "an outdated state stays for the cleanup")
			helpers.assert_eq(states.retired, true)
			helpers.assert_eq(states["custom_¤"], false)
			helpers.assert_eq(document.hotstrings.terminators, {
				{ key = "custom_¤", char = "¤", label = "hand", consume = true },
				{ key = "custom_comma", char = ",", label = ",", consume = false },
			}, "the list is not rewritten for a state change")

			helpers.assert_true(Terminators.add_custom_terminator("custom_µ", "µ", "µ", false))
			helpers.assert_true(Settings.persist())
			helpers.assert_eq(Codec.decode(sandbox.read_bytes(path)).hotstrings.terminators, {
				{ key = "custom_¤", char = "¤", label = "hand", consume = true },
				{ key = "custom_comma", char = ",", label = ",", consume = false },
				{ key = "custom_µ", char = "µ", label = "µ", consume = false },
			}, "an added delimiter joins the records as written")

			helpers.assert_true(Terminators.remove_custom_terminator("custom_¤"))
			helpers.assert_true(Settings.persist())
			document = Codec.decode(sandbox.read_bytes(path))
			helpers.assert_eq(document.hotstrings.terminators, {
				{ key = "custom_comma", char = ",", label = ",", consume = false },
				{ key = "custom_µ", char = "µ", label = "µ", consume = false },
			}, "a removed delimiter leaves, an unusable record stays")
			helpers.assert_nil(document.hotstrings.terminator_states["custom_¤"])
			helpers.assert_eq(document.hotstrings.terminator_states.comma, false)
		end)
	end)
end)

helpers.describe("word-delimiter settings: a [[hotstrings.terminators]] list", function()
	-- Readable, but the shared writer cannot update array-of-tables elements:
	-- every delimiter save refused over it with a writer error that named
	-- neither the form nor the fix.
	helpers.it("is read, names its inline form, and lets the states be saved around it", function()
		local stored = '[hotstrings]\nunknown = "kept"\n\n[[hotstrings.terminators]]\n'
			.. 'key = "custom_¤"\nchar = "¤"\nlabel = "¤"\nconsume = true\n'
		with_settings(stored, function(Settings, path, sandbox, Terminators)
			local Logger = require("logger.shim")
			local warn, fail, warnings, errors = Logger.warn, Logger.error, {}, {}
			Logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
			Logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
			local passed, failure = pcall(function()
				helpers.assert_true(Settings.load())
				helpers.assert_true(has_custom(Terminators, "custom_¤"), "the list is read")
				local named = false
				for _, line in ipairs(warnings) do
					if line:find(path, 1, true) and line:find("terminators = [{", 1, true) then named = true end
				end
				helpers.assert_true(named, "the load names the file and the inline form")
				helpers.assert_true(Terminators.set_terminator_enabled("slash", true))
				helpers.assert_true(Settings.persist(), "a state change is saved around the list")
				helpers.assert_eq(Codec.decode(sandbox.read_bytes(path)).hotstrings.terminator_states.slash, true)
				local before = sandbox.read_bytes(path)
				helpers.assert_true(Terminators.add_custom_terminator("custom_µ", "µ", "µ", false))
				helpers.assert_eq(Settings.persist(), false, "a list change cannot be saved over its tables")
				helpers.assert_eq(sandbox.read_bytes(path), before)
				helpers.assert_true(#errors > 0 and errors[#errors]:find("terminators = [{", 1, true) ~= nil,
					"the refusal names the inline form")
			end)
			Logger.warn, Logger.error = warn, fail
			if not passed then error(failure, 0) end
		end)
	end)
end)

helpers.describe("word-delimiter settings: scope adoption and outdated entries", function()
	helpers.it("adopts a candidate and restores the exact runtime snapshot", function()
		with_settings(SOURCE, function(Settings, _, _, Terminators)
			helpers.assert_true(Terminators.add_custom_terminator("custom_µ", "µ", "µ", false))
			helpers.assert_true(Terminators.set_terminator_enabled("comma", false))
			local before = Settings.snapshot()
			helpers.assert_true(Settings.adopt_configuration({ hotstrings = {
				terminator_states = { slash = true },
				terminators = { { key = "custom_¤", char = "¤", label = "¤", consume = true } },
			} }))
			helpers.assert_eq(has_custom(Terminators, "custom_µ"), false)
			helpers.assert_eq(has_custom(Terminators, "custom_¤"), true)
			helpers.assert_eq(Terminators.is_terminator_enabled("comma"), shipped(Terminators, "comma"))
			helpers.assert_eq(Terminators.is_terminator_enabled("slash"), true)
			helpers.assert_true(Settings.restore_configuration(before))
			helpers.assert_eq(Settings.snapshot(), before)
		end)
	end)

	helpers.it("warns about each unusable entry, reads the rest and offers only the rest", function()
		with_settings(SOURCE, function(Settings, _, _, Terminators)
			local document = { hotstrings = {
				terminator_states = { slash = true, retired = true, space = "no", ["custom_µ"] = false },
				terminators = {
					{ key = "custom_µ", char = "µ", label = "µ", consume = false },
					{ key = "custom_comma", char = ",", label = ",", consume = false },
					{ key = "space", char = "¤", label = "¤", consume = false },
				},
			} }
			require("config_outdated").reset_for_tests()
			local marked = {}
			local outdated = require("config_outdated").collect_reports(function()
				Settings.mark_config_reads(document, function(...) marked[table.concat({ ... }, ".")] = true end)
			end)
			helpers.assert_true(marked["hotstrings.terminator_states.slash"])
			helpers.assert_true(marked["hotstrings.terminator_states.custom_µ"])
			helpers.assert_true(marked["hotstrings.terminators"], "a list with a usable delimiter is kept whole")
			helpers.assert_nil(marked["hotstrings.terminator_states.retired"])
			helpers.assert_nil(marked["hotstrings.terminator_states.space"])
			helpers.assert_true(outdated["hotstrings.terminator_states.retired"])
			helpers.assert_true(outdated["hotstrings.terminator_states.space"])
			helpers.assert_nil(outdated["hotstrings.terminators"], "the usable delimiters are not offered")
			helpers.assert_true(outdated["hotstrings.terminators.2"], "each unusable record is named")
			helpers.assert_true(outdated["hotstrings.terminators.3"])
			helpers.assert_true(Settings.adopt_configuration(document))
			helpers.assert_eq(Terminators.is_terminator_enabled("slash"), true)
			helpers.assert_eq(Terminators.is_terminator_enabled("space"), shipped(Terminators, "space"))
			helpers.assert_eq(has_custom(Terminators, "custom_µ"), true)
			helpers.assert_eq(Terminators.is_terminator_enabled("custom_µ"), false)
			helpers.assert_eq(has_custom(Terminators, "custom_comma"), false, "a built-in character stays built-in")
		end)
	end)

	helpers.it("keeps its leaves through the actual unused-key cleanup", function()
		local stored = SOURCE .. '\n[hotstrings.terminator_states]\nslash = true\nretired = true\n'
		with_settings(stored, function(_, path)
			package.loaded["ui.menu.unused_keys_cleanup"] = nil
			local scan = require("ui.menu.unused_keys_cleanup").find(path)
			helpers.assert_eq(scan.status, "ok")
			local offered = {}
			for _, key in ipairs(scan.keys) do offered[table.concat(key.path, ".")] = true end
			helpers.assert_nil(offered["hotstrings.terminator_states.slash"], "a read delimiter is kept")
			helpers.assert_true(offered["hotstrings.terminator_states.retired"], "an unknown one is offered")
		end)
	end)

	helpers.it("keeps a list holding one unusable delimiter out of the cleanup", function()
		local stored = '[hotstrings]\nterminators = [{ key = "custom_¤", char = "¤", label = "¤", consume = true }, '
			.. '{ key = "custom_comma", char = ",", label = ",", consume = false }]\n'
		with_settings(stored, function(_, path)
			package.loaded["ui.menu.unused_keys_cleanup"] = nil
			local scan = require("ui.menu.unused_keys_cleanup").find(path)
			helpers.assert_eq(scan.status, "ok")
			for _, key in ipairs(scan.keys) do
				helpers.assert_true(table.concat(key.path, ".") ~= "hotstrings.terminators",
					"the cleanup would delete the usable delimiter with the unusable one")
			end
		end)
	end)
end)
