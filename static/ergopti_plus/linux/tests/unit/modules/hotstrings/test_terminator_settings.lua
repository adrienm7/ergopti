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
	for _, header in ipairs({ "[[hotstrings.terminators]]", '[["hotstrings"."terminators"]]' }) do
		helpers.it("removes the complete custom list and its state from " .. header, function()
			local stored = '[hotstrings]\nunknown = "kept"\n\n' .. header .. '\n'
				.. 'key = "custom_¤"\nchar = "¤"\nlabel = "¤"\nconsume = true\n'
				.. '# keep this comment\n[hotstrings.terminator_states]\n"custom_¤" = false\n'
				.. '\n[other]\nvalue = 42\n'
			with_settings(stored, function(Settings, path, sandbox, Terminators)
				helpers.assert_true(Settings.load())
				helpers.assert_true(Terminators.remove_custom_terminator("custom_¤"))
				helpers.assert_true(Settings.persist())
				local bytes = sandbox.read_bytes(path)
				local document = Codec.decode(bytes)
				helpers.assert_nil(document.hotstrings.terminators)
				helpers.assert_nil(document.hotstrings.terminator_states["custom_¤"])
				helpers.assert_eq(document.hotstrings.unknown, "kept")
				helpers.assert_eq(document.other.value, 42)
				helpers.assert_true(bytes:find("# keep this comment", 1, true) ~= nil)
				helpers.assert_true(Settings.load())
				helpers.assert_eq(has_custom(Terminators, "custom_¤"), false)
			end)
		end)
	end

	helpers.it("updates the whole list while preserving unowned records, nested fields and comments", function()
		local stored = '[hotstrings]\nunknown = "kept"\n\n[[hotstrings.terminators]]\n'
			.. 'key = "custom_¤"\nchar = "¤"\nlabel = "¤"\nconsume = true\nfuture = "kept"\n'
			.. '# keep this comment\n\n[[hotstrings.terminators]]\n'
			.. 'key = "obsolete"\nchar = "ab"\nlabel = "bad"\nconsume = "wrong"\n'
			.. '[hotstrings.terminators.metadata]\nnote = "kept"\n'
			.. '\n[[other.items]]\nvalue = 42\n'
		with_settings(stored, function(Settings, path, sandbox, Terminators)
			helpers.assert_true(Settings.load())
			helpers.assert_true(Terminators.add_custom_terminator("custom_µ", "µ", "µ", false))
			helpers.assert_true(Settings.persist(), "the shared writer owns replacement of the whole list")
			local bytes = sandbox.read_bytes(path)
			local document = Codec.decode(bytes)
			helpers.assert_eq(document.hotstrings.terminators, {
				{ key = "custom_¤", char = "¤", label = "¤", consume = true, future = "kept" },
				{ key = "obsolete", char = "ab", label = "bad", consume = "wrong", metadata = { note = "kept" } },
				{ key = "custom_µ", char = "µ", label = "µ", consume = false },
			})
			helpers.assert_eq(document.hotstrings.unknown, "kept")
			helpers.assert_eq(document.other.items, { { value = 42 } })
			helpers.assert_true(bytes:find("# keep this comment", 1, true) ~= nil)
			helpers.assert_true(Settings.persist())
			helpers.assert_eq(sandbox.read_bytes(path), bytes, "an unchanged list is byte-stable")
			helpers.assert_true(Terminators.remove_custom_terminator("custom_¤"))
			helpers.assert_true(Settings.persist())
			document = Codec.decode(sandbox.read_bytes(path))
			helpers.assert_eq(#document.hotstrings.terminators, 2)
			helpers.assert_eq(document.hotstrings.terminators[1].metadata.note, "kept")
			helpers.assert_eq(document.hotstrings.terminators[2].key, "custom_µ")
			helpers.assert_true(Settings.adopt_configuration({}))
			helpers.assert_true(Settings.load())
			helpers.assert_true(has_custom(Terminators, "custom_µ"), "the saved list survives restart")
			helpers.assert_eq(has_custom(Terminators, "custom_¤"), false)
		end)
	end)

	helpers.it("saves states and the list, but still refuses a malformed destination", function()
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
				helpers.assert_eq(#warnings, 0, "a supported table-array spelling needs no refusal warning")
				helpers.assert_true(Terminators.set_terminator_enabled("slash", true))
				helpers.assert_true(Settings.persist(), "a state change is saved around the list")
				helpers.assert_eq(Codec.decode(sandbox.read_bytes(path)).hotstrings.terminator_states.slash, true)
				helpers.assert_true(Terminators.add_custom_terminator("custom_µ", "µ", "µ", false))
				helpers.assert_true(Settings.persist(), "a whole-list change is saved over its tables")
				helpers.assert_eq(#Codec.decode(sandbox.read_bytes(path)).hotstrings.terminators, 2)
				helpers.assert_eq(#errors, 0)
				local before = sandbox.read_bytes(path) .. "\n[other]\nvalue = {\n"
				sandbox.write_bytes(path, before)
				helpers.assert_true(Terminators.add_custom_terminator("custom_§", "§", "§", false))
				helpers.assert_eq(Settings.persist(), false, "a malformed document is still refused")
				helpers.assert_eq(sandbox.read_bytes(path), before)
				helpers.assert_true(#errors > 0, "the refusal remains visible")
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


--- Builds the actual tray provider over its existing acknowledged settings owner.
--- @param Settings table Native persistent delimiter owner.
--- @param paused boolean Initial pause posture.
--- @param reordered boolean Whether the shared section is reversed.
--- @return table controls, table context, table observations
local function menu_controls(Settings, paused, reordered)
	local paths = require("infra.paths")
	local i18n = require("infra.i18n")
	local original = package.loaded["infra.manifest_menu"]
	local observations = { writes = 0, redraws = 0 }
	local renderer = assert(require("menu.renderer").new({
		platform = "linux",
		manifest_path = function() return paths.shared("modules/menu/menu_manifest.json") end,
		json_decode = function(raw)
			local value = assert(require("json").decode(raw))
			if reordered then
				local rows = value.word_expanders_menu
				rows[1], rows[3] = rows[3], rows[1]
			end
			return value
		end,
		i18n = i18n,
		logger = require("logger.shim"),
	}))
	package.loaded["infra.manifest_menu"] = setmetatable({
		build = function(section, ...)
			local rows = renderer.build(section, ...)
			if section == "word_expanders_menu" then observations.controls = rows end
			return rows
		end,
	}, { __index = renderer })
	local ctx = {
		paused = paused,
		config = {
			get_groups = function() return {} end,
			get_categories = function() return {} end,
			language_packs = function() return {} end,
			resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
			get_global_delay = function() return 0.75 end,
			has_global_delay_override = function() return false end,
		},
		on_persist_terminators = function()
			observations.writes = observations.writes + 1
			return Settings.persist()
		end,
		on_menu_changed = function() observations.redraws = observations.redraws + 1 end,
		on_toggle_pause = function() end,
		on_quit = function() end,
	}
	ctx.is_paused = function() return ctx.paused end
	local passed, rows = pcall(function() return helpers.load_module("ui.menu.menu_builder").build(ctx) end)
	package.loaded["infra.manifest_menu"] = original
	if not passed then error(rows, 0) end
	local function find(items)
		for _, row in ipairs(items or {}) do
			if row.title == i18n.get("menu.hotstrings.word_expanders") then return row.menu end
			local found = find(row.menu)
			if found then return found end
		end
	end
	for _, row in ipairs(rows) do
		if row.title == i18n.get("menu.hotstrings.title") then
			observations.hotstrings_disabled = row.disabled
			observations.hotstrings_submenu = row.menu
		end
	end
	return assert(find(rows) or observations.controls, "the actual word-expander menu must be built"), ctx, observations
end

--- Reads the independent fixed-command and delimiter-state expectations.
--- @return table corpus
local function controls_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/word_expander_controls.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

helpers.describe("word-expander native menu controls use shared declarations", function()
	local stored = SOURCE .. '\n[hotstrings.terminator_states]\nspace = false\nslash = true\n'
	local modes = { "enable_all", "disable_all", "restore" }

	helpers.it("replays all three native callbacks through actual durable writes and restart (shared-word-expander-controls)", function()
		local expected = controls_corpus()
		for position, mode in ipairs(modes) do
			with_settings(stored, function(Settings, path, sandbox, Terminators)
				helpers.assert_true(Settings.load())
				helpers.assert_true(Terminators.add_custom_terminator("custom_x", "x", "x", true))
				helpers.assert_true(Terminators.set_terminator_enabled("custom_x", false))
				helpers.assert_true(Settings.persist())
				local controls, _, observed = menu_controls(Settings, false, false)
				for index, row in ipairs(expected.rows) do
					helpers.assert_eq(controls[index].title, require("infra.i18n").get(row.i18n))
					helpers.assert_type(controls[index].fn, "function")
				end
				helpers.assert_eq(controls[4].title, "-")
				helpers.assert_eq(controls[position].fn(), true)
				helpers.assert_eq(observed.writes, 1)
				helpers.assert_eq(observed.redraws, 1)
				local values = expected.delimiter_states[mode]
				for key, enabled in pairs(values) do
					helpers.assert_eq(Terminators.is_terminator_enabled(key), enabled)
				end
				local document = Codec.decode(sandbox.read_bytes(path))
				helpers.assert_eq(document.hotstrings.unknown, "kept")
				helpers.assert_eq(document.other.value, 42)
				helpers.assert_eq(document.hotstrings.terminators[1].consume, true)
				helpers.assert_true(Settings.adopt_configuration({}))
				helpers.assert_true(Settings.load())
				for key, enabled in pairs(values) do
					helpers.assert_eq(Terminators.is_terminator_enabled(key), enabled, "native restart/" .. mode)
				end
			end)
		end
	end)

	helpers.it("follows shared command reordering and retains actual lease refusal (shared-word-expander-controls)", function()
		with_settings(stored, function(Settings, path, sandbox, Terminators)
			local expected = controls_corpus()
			helpers.assert_true(Settings.load())
			local controls, _, observed = menu_controls(Settings, false, true)
			local labels = {}
			for _, row in ipairs(expected.rows) do labels[row.id] = row.i18n end
			for position, id in ipairs(expected.reordered_ids) do
				helpers.assert_eq(controls[position].title, require("infra.i18n").get(labels[id]))
			end
			local owner = {}
			local preferences = require("infra.hotstring_preferences")
			helpers.assert_true(preferences.acquire(owner))
			local passed, failure = pcall(function()
				helpers.assert_eq(controls[1].fn(), false)
				helpers.assert_eq(Terminators.is_terminator_enabled("space"), false)
				helpers.assert_eq(Terminators.is_terminator_enabled("slash"), true)
				helpers.assert_eq(sandbox.read_bytes(path), stored)
				helpers.assert_eq(observed.writes, 1)
				helpers.assert_eq(observed.redraws, 0)
			end)
			helpers.assert_true(preferences.release(owner))
			if not passed then error(failure, 0) end
		end)
	end)

	helpers.it("retains the paused menu posture and refuses stale callbacks before mutation (shared-word-expander-controls)", function()
		with_settings(stored, function(Settings, path, sandbox, Terminators)
			helpers.assert_true(Settings.load())
			local controls, ctx, observed = menu_controls(Settings, false, false)
			ctx.paused = true
			local receipts = {}
			for position = 1, 3 do receipts[position] = controls[position].fn() end
			helpers.assert_eq(observed.writes, 0, "paused callbacks cannot reach the writer")
			helpers.assert_eq(observed.redraws, 0)
			helpers.assert_eq(Terminators.is_terminator_enabled("space"), false)
			helpers.assert_eq(Terminators.is_terminator_enabled("slash"), true)
			helpers.assert_eq(sandbox.read_bytes(path), stored)
			for position = 1, 3 do helpers.assert_eq(receipts[position], false) end
			local grey, _, grey_observed = menu_controls(Settings, true, false)
			helpers.assert_eq(grey_observed.hotstrings_disabled, true)
			helpers.assert_nil(grey_observed.hotstrings_submenu, "paused native roots strip every feature action")
			for position = 1, 3 do helpers.assert_eq(grey[position].disabled, true) end
			helpers.assert_eq(grey_observed.writes, 0)
		end)
	end)
end)
