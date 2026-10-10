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


--- Reads the independent custom-command identity used by each native provider.
--- @return table expected Canonical command expectation.
local function custom_command_expected()
	local path = require("infra.paths").shared("tests/corpus/menus/word_expander_custom_controls.json")
	local file = assert(io.open(path, "rb"))
	local text = file:read("*a")
	file:close()
	local corpus = assert(require("json").decode(text))
	assert(#corpus.rows == 1, "every independent custom command must be observed")
	return corpus.rows[1]
end

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

--- Independent stored-list vectors distinguish the admitted record from its
--- unusable neighbors, including an otherwise valid duplicate of the same key.
local DUPLICATE_RECORDS = {
	{
		name = "valid before invalid",
		owned = 1,
		rejected = 2,
		records = {
			{ key = "custom_¤", char = "¤", label = "first", consume = true, metadata = { note = "admitted" } },
			{ key = "custom_¤", char = "ab", label = "invalid", consume = false, metadata = { note = "unusable" } },
		},
	},
	{
		name = "invalid before valid",
		owned = 2,
		rejected = 1,
		records = {
			{ key = "custom_¤", char = "ab", label = "invalid", consume = false, metadata = { note = "unusable" } },
			{ key = "custom_¤", char = "¤", label = "first", consume = true, metadata = { note = "admitted" } },
		},
	},
	{
		name = "two valid definitions",
		owned = 1,
		rejected = 2,
		records = {
			{ key = "custom_¤", char = "¤", label = "first", consume = true, metadata = { note = "admitted" } },
			{ key = "custom_¤", char = "§", label = "duplicate", consume = false, metadata = { note = "unusable" } },
		},
	},
	{
		name = "identical definitions with distinct metadata",
		owned = 1,
		rejected = 2,
		records = {
			{ key = "custom_¤", char = "¤", label = "first", consume = true, metadata = { note = "admitted" } },
			{ key = "custom_¤", char = "¤", label = "first", consume = true, metadata = { note = "unusable" } },
		},
	},
}

helpers.describe("word-delimiter settings: duplicate-record ownership", function()
	for _, vector in ipairs(DUPLICATE_RECORDS) do
		local source = Codec.encode({ hotstrings = {
			unknown = "kept",
			terminators = vector.records,
			terminator_states = { ["custom_¤"] = false, retired = true },
		}, other = { items = { { value = 42 } } } }) .. "\n# keep the duplicate-record comment\n"

		helpers.it("adds and removes only the admitted record: " .. vector.name, function()
			with_settings(source, function(Settings, path, sandbox, Terminators)
				helpers.assert_true(Settings.load())
				helpers.assert_eq(Settings.snapshot().custom, {
					{ key = "custom_¤", char = "¤", label = "first", consume = true },
				}, "an unusable neighbor never becomes the runtime owner")
				local reports = require("config_outdated").collect_reports(function()
					Settings.mark_config_reads(Codec.decode(source), function() end)
				end)
				helpers.assert_true(reports["hotstrings.terminators." .. vector.rejected] ~= nil)
				helpers.assert_nil(reports["hotstrings.terminators." .. vector.owned])
				helpers.assert_true(Terminators.add_custom_terminator("custom_±", "±", "added", false))
				helpers.assert_true(Settings.persist())
				local added = Codec.decode(sandbox.read_bytes(path))
				helpers.assert_eq(added.hotstrings.terminators, {
					vector.records[1], vector.records[2],
					{ key = "custom_±", char = "±", label = "added", consume = false },
				}, "Add retains both physical records, their order and unknown nested metadata")
				helpers.assert_eq(added.hotstrings.terminator_states["custom_¤"], false)
				helpers.assert_eq(added.hotstrings.terminator_states.retired, true)
				helpers.assert_true(Terminators.remove_custom_terminator("custom_¤"))
				helpers.assert_true(Settings.persist())
				local bytes = sandbox.read_bytes(path)
				local removed = Codec.decode(bytes)
				helpers.assert_eq(removed.hotstrings.terminators, {
					vector.records[vector.rejected],
					{ key = "custom_±", char = "±", label = "added", consume = false },
				}, "Delete cannot claim the unusable same-key record left for explicit cleanup")
				helpers.assert_nil(removed.hotstrings.terminator_states["custom_¤"])
				helpers.assert_eq(removed.hotstrings.terminator_states.retired, true)
				helpers.assert_eq(removed.hotstrings.unknown, "kept")
				helpers.assert_eq(removed.other.items, { { value = 42 } })
				helpers.assert_true(bytes:find("# keep the duplicate-record comment", 1, true) ~= nil)
				helpers.assert_true(Settings.persist())
				helpers.assert_eq(sandbox.read_bytes(path), bytes, "no pending change rewrites preserved records")
			end)
		end)

		helpers.it("removes only its admitted occurrence after writer retry: " .. vector.name, function()
			with_settings(source, function(Settings, path, sandbox, Terminators)
				local Writer = require("toml_codec.writer")
				local original, writes = Writer.batch_write, 0
				local called, failure = pcall(function()
					helpers.assert_true(Settings.load())
					helpers.assert_true(Terminators.remove_custom_terminator("custom_¤"))
					Writer.batch_write = function(target, rows, files, expected)
						writes = writes + 1
						sandbox.write_bytes(target, source .. "# deletion source changed\n")
						return original(target, rows, files, expected)
					end
					helpers.assert_eq(Settings.persist(), false)
					helpers.assert_eq(writes, 1, "the actual source fence rejected the proposed Delete")
					helpers.assert_eq(sandbox.read_bytes(path), source .. "# deletion source changed\n")
					Writer.batch_write = original
					helpers.assert_true(Settings.persist(), "refusal never acknowledges the pending removal")
					local bytes = sandbox.read_bytes(path)
					local document = Codec.decode(bytes)
					helpers.assert_eq(document.hotstrings.terminators, { vector.records[vector.rejected] },
						"only the admitted stored occurrence is removed, even when its fields match a duplicate")
					helpers.assert_nil(document.hotstrings.terminator_states["custom_¤"])
					helpers.assert_eq(document.hotstrings.terminator_states.retired, true)
					helpers.assert_eq(document.hotstrings.unknown, "kept")
					helpers.assert_eq(document.other.items, { { value = 42 } })
					helpers.assert_true(bytes:find("# deletion source changed", 1, true) ~= nil)
					helpers.assert_true(Settings.persist())
					helpers.assert_eq(sandbox.read_bytes(path), bytes)
				end)
				Writer.batch_write = original
				if not called then error(failure, 0) end
			end)
		end)

		helpers.it("retains the pending Add across lease and real writer refusal: " .. vector.name, function()
			with_settings(source, function(Settings, path, sandbox, Terminators)
				local Preferences = require("infra.hotstring_preferences")
				local Writer = require("toml_codec.writer")
				local original, owner, observations = Writer.batch_write, {}, {}
				local called, failure = pcall(function()
					helpers.assert_true(Settings.load())
					helpers.assert_true(Terminators.add_custom_terminator("custom_±", "±", "added", false))
					helpers.assert_true(Preferences.acquire(owner))
					Writer.batch_write = function(target, rows, files, expected)
						observations[#observations + 1] = { target = target, rows = rows, expected = expected }
						sandbox.write_bytes(target, source .. "# external edit\n")
						return original(target, rows, files, expected)
					end
					helpers.assert_eq(Settings.persist(), false, "the real preference lease prevents publication")
					helpers.assert_eq(#observations, 0, "a held owner cannot even enter the writer")
					helpers.assert_eq(sandbox.read_bytes(path), source)
					helpers.assert_true(Preferences.release(owner))
					helpers.assert_eq(Settings.persist(), false, "the actual writer rejects its changed source")
					helpers.assert_eq(#observations, 1)
					helpers.assert_eq(observations[1].target, path)
					helpers.assert_eq(observations[1].expected.content, source)
					helpers.assert_eq(sandbox.read_bytes(path), source .. "# external edit\n")
					helpers.assert_true(has_custom(Terminators, "custom_±"), "the refused delta remains pending")
					Writer.batch_write = original
					helpers.assert_true(Settings.persist(), "retry uses the freshly read real source")
					local bytes = sandbox.read_bytes(path)
					helpers.assert_eq(Codec.decode(bytes).hotstrings.terminators, {
						vector.records[1], vector.records[2],
						{ key = "custom_±", char = "±", label = "added", consume = false },
					})
					helpers.assert_true(bytes:find("# external edit", 1, true) ~= nil)
					helpers.assert_true(Settings.load())
					helpers.assert_eq(#Settings.snapshot().custom, 2, "restart admits only the first usable duplicate")
				end)
				Writer.batch_write = original
				if Preferences.is_acquired() then assert(Preferences.release(owner)) end
				if not called then error(failure, 0) end
			end)
		end)
	end
end)

helpers.describe("word-delimiter settings: pending records must survive the real reader", function()
	local source = '[hotstrings]\nunknown = "kept"\n'
		.. 'terminators = [{ key = "custom_¤", char = "¤", label = "first", consume = true }, '
		.. '{ key = "custom_¤", char = "§", label = "duplicate", consume = false, metadata = { note = "unowned" } }]\n'
		.. '# keep the surviving record comment\n[hotstrings.terminator_states]\n"custom_¤" = false\nretired = true\n'
		.. '[other]\nvalue = 42\n'
	local cleaned = '[hotstrings]\nunknown = "kept"\n'
		.. '# keep the surviving record comment\n[hotstrings.terminator_states]\nretired = true\n'
		.. '[other]\nvalue = 42\n# explicit external cleanup\n'
	for _, vector in ipairs({
		{ name = "same key with different fields", key = "custom_¤", char = "±" },
		{ name = "different key with the same character", key = "custom_±", char = "§" },
	}) do
		helpers.it("refuses a hidden Add after Delete without reload: " .. vector.name, function()
			with_settings(source, function(Settings, path, sandbox, Terminators)
				local Writer = require("toml_codec.writer")
				local original, observations, change_source = Writer.batch_write, {}, false
				local wanted = { key = vector.key, char = vector.char, label = "replacement", consume = true }
				local called, failure = pcall(function()
					helpers.assert_true(Settings.load())
					helpers.assert_true(Terminators.remove_custom_terminator("custom_¤"))
					helpers.assert_true(Settings.persist())
					local deleted = sandbox.read_bytes(path)
					local document = Codec.decode(deleted)
					helpers.assert_eq(document.hotstrings.terminators, {
						{ key = "custom_¤", char = "§", label = "duplicate", consume = false,
							metadata = { note = "unowned" } },
					}, "Delete retains the unowned occurrence for explicit cleanup")
					helpers.assert_nil(document.hotstrings.terminator_states["custom_¤"])
					helpers.assert_true(deleted:find("# keep the surviving record comment", 1, true) ~= nil)
					local before = Settings.snapshot()
					Writer.batch_write = function(target, rows, files, expected)
						observations[#observations + 1] = { target = target, expected = expected.content }
						if change_source then
							sandbox.write_bytes(target, cleaned .. "# source changed before publication\n")
						end
						return original(target, rows, files, expected)
					end
					helpers.assert_true(Terminators.add_custom_terminator(wanted.key, wanted.char, wanted.label, wanted.consume))
					for _ = 1, 2 do
						helpers.assert_eq(Settings.persist(), false, "a hidden pending record cannot be acknowledged")
						helpers.assert_eq(#observations, 0, "semantic refusal precedes any writer entry")
						helpers.assert_eq(sandbox.read_bytes(path), deleted, "no hidden Add changes preserved bytes")
						helpers.assert_eq(Settings.snapshot().custom, { wanted }, "refusal leaves the exact delta pending")
					end
					helpers.assert_true(Settings.restore_configuration(before), "the acknowledged runtime rollback remains usable")
					helpers.assert_eq(Settings.snapshot(), before)
					helpers.assert_true(Settings.persist())
					helpers.assert_eq(#observations, 0)
					helpers.assert_eq(sandbox.read_bytes(path), deleted)
					helpers.assert_true(Terminators.add_custom_terminator(wanted.key, wanted.char, wanted.label, wanted.consume))
					helpers.assert_eq(Settings.persist(), false)
					helpers.assert_eq(#observations, 0)
					-- Explicit external cleanup removes the ambiguity; the owner still
					-- requires the real writer's fresh source acknowledgement.
					sandbox.write_bytes(path, cleaned)
					change_source = true
					helpers.assert_eq(Settings.persist(), false, "an admissible retry still obeys the actual source fence")
					helpers.assert_eq(observations, { { target = path, expected = cleaned } })
					helpers.assert_eq(sandbox.read_bytes(path), cleaned .. "# source changed before publication\n")
					helpers.assert_eq(Settings.snapshot().custom, { wanted })
					change_source = false
					helpers.assert_true(Settings.persist(), "the unacknowledged Add retries against the fresh cleaned source")
					helpers.assert_eq(observations, {
						{ target = path, expected = cleaned },
						{ target = path, expected = cleaned .. "# source changed before publication\n" },
					})
					local bytes = sandbox.read_bytes(path)
					local added = Codec.decode(bytes)
					helpers.assert_eq(added.hotstrings.terminators, { wanted })
					helpers.assert_eq(added.hotstrings.unknown, "kept")
					helpers.assert_eq(added.hotstrings.terminator_states.retired, true)
					helpers.assert_eq(added.other.value, 42)
					helpers.assert_true(bytes:find("# keep the surviving record comment", 1, true) ~= nil)
					helpers.assert_true(bytes:find("# explicit external cleanup", 1, true) ~= nil)
					helpers.assert_true(bytes:find("# source changed before publication", 1, true) ~= nil)
					helpers.assert_true(Settings.persist())
					helpers.assert_eq(#observations, 2, "successful retry acknowledges only the real durable candidate")
					helpers.assert_eq(sandbox.read_bytes(path), bytes)
					helpers.assert_true(Settings.load())
					helpers.assert_eq(Settings.snapshot().custom, { wanted }, "the exact new record survives a real reload")
				end)
				Writer.batch_write = original
				if not called then error(failure, 0) end
			end)
		end)
	end

	helpers.it("refuses a changed record hidden by an externally added character owner", function()
		local initial = '[hotstrings]\nterminators = [{ key = "custom_¤", char = "¤", label = "first", consume = true }]\n'
		local edited = '[hotstrings]\nterminators = [{ key = "custom_§", char = "§", label = "foreign", consume = false, '
			.. 'metadata = { note = "unowned" } }, { key = "custom_¤", char = "¤", label = "first", consume = true }]\n'
			.. '# preserve the external character owner\n'
		with_settings(initial, function(Settings, path, sandbox, Terminators)
			local Writer = require("toml_codec.writer")
			local original, writes = Writer.batch_write, 0
			local called, failure = pcall(function()
				helpers.assert_true(Settings.load())
				sandbox.write_bytes(path, edited)
				helpers.assert_true(Terminators.add_custom_terminator("custom_¤", "§", "replacement", true))
				Writer.batch_write = function(...)
					writes = writes + 1
					return original(...)
				end
				for _ = 1, 2 do
					helpers.assert_eq(Settings.persist(), false, "a changed record also needs real reader admission")
					helpers.assert_eq(writes, 0)
					helpers.assert_eq(sandbox.read_bytes(path), edited)
				end
				helpers.assert_eq(Settings.snapshot().custom, {
					{ key = "custom_¤", char = "§", label = "replacement", consume = true },
				})
				sandbox.write_bytes(path, initial)
				helpers.assert_true(Settings.persist(), "explicit cleanup permits the pending changed record")
				helpers.assert_eq(writes, 1)
				helpers.assert_true(Settings.load())
				helpers.assert_eq(Settings.snapshot().custom, {
					{ key = "custom_¤", char = "§", label = "replacement", consume = true },
				})
			end)
			Writer.batch_write = original
			if not called then error(failure, 0) end
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
			if reordered == "config_shared_label" then
				if type(value.hotstrings_delays_menu) == "table" then value.hotstrings_delays_menu[1].i18n = "button.ok" end
			elseif reordered == "custom_delete_label" then
				value.word_expander_custom_menu[1].i18n = "button.delete"
			elseif reordered then
				local rows = value.word_expanders_menu
				rows[1], rows[3] = rows[3], rows[1]
			end
			return value
		end,
		i18n = i18n,
		logger = require("logger.shim"),
	}))
	-- Forward the actual renderer's own methods through a plain observer facade.
	-- Native source admission deliberately does not acquire inherited methods.
	local facade = {}; for key, value in pairs(renderer) do facade[key] = value end
	facade.build = function(section, ...)
		local rows = renderer.build(section, ...)
		if section == "word_expanders_menu" then observations.controls = rows end
		return rows
	end
	package.loaded["infra.manifest_menu"] = facade
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
			if row.title == i18n.get("menu.hotstrings.delays_colors") then observations.delay_controls = row.menu end
			if row.title == i18n.get("menu.hotstrings.word_expanders") then observations.controls_found = row.menu end
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
	find(rows)
	return assert(observations.controls_found or observations.controls, "the actual word-expander menu must be built"), ctx, observations
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


--- Finds a command in the actual rendered native control list.
--- @param rows table Native menu items.
--- @param key string Independent translation identity.
--- @return table|nil row
local function custom_delete_row(rows, key)
	local text = require("infra.i18n").get(key)
	for _, row in ipairs(rows or {}) do
		if type(row.title) == "string" and row.title:gsub("^%s+", "") == text then return row end
	end
end

helpers.describe("custom delimiter deletion consumes the shared command declaration", function()
	helpers.it("the actual provider follows a changed declared label without changing its target", function()
		with_settings(SOURCE, function(Settings, path, sandbox, Terminators)
			helpers.assert_true(Settings.load())
			helpers.assert_true(Terminators.add_custom_terminator("custom_probe", "☃", "Independent snowman", true))
			helpers.assert_true(Settings.persist())
			local rows = menu_controls(Settings, false, "custom_delete_label")
			local row = assert(custom_delete_row(rows, "button.delete"), "the canonical declaration supplies the command label")
			helpers.assert_eq(row.fn(), true)
			helpers.assert_eq(has_custom(Terminators, "custom_probe"), false)
			helpers.assert_eq(Codec.decode(sandbox.read_bytes(path)).other.value, 42)
		end)
	end)

	for _, verdict in ipairs({ "ack", "false", "nil", "throw", "truthy" }) do
		helpers.it("the actual Delete callback acknowledges and compensates writer " .. verdict, function()
			with_settings(SOURCE, function(Settings, path, sandbox, Terminators)
				helpers.assert_true(Settings.load())
				helpers.assert_true(Terminators.add_custom_terminator("custom_probe", "☃", "Independent snowman", true))
				helpers.assert_true(Terminators.set_terminator_enabled("custom_probe", false))
				helpers.assert_true(Settings.persist())
				local initial = sandbox.read_bytes(path)
				local rows, _, observed = menu_controls(Settings, false, false)
				local row = assert(custom_delete_row(rows, custom_command_expected().i18n))
				local Writer = require("toml_codec.writer")
				local native_writer = Writer.batch_write
				Writer.batch_write = function(...)
					if verdict == "throw" then error("owned custom-delete writer refused") end
					if verdict == "nil" then return nil end
					if verdict == "truthy" then return 2 end
					if verdict == "false" then return false end
					return native_writer(...)
				end
				local called, committed = pcall(row.fn)
				Writer.batch_write = native_writer
				-- Observations follow both the production catch and native publisher.
				helpers.assert_eq(called, true)
				helpers.assert_eq(committed, verdict == "ack")
				helpers.assert_eq(observed.writes, 1)
				helpers.assert_eq(observed.redraws, verdict == "ack" and 1 or 0)
				helpers.assert_eq(has_custom(Terminators, "custom_probe"), verdict ~= "ack")
				if verdict ~= "ack" then
					helpers.assert_eq(sandbox.read_bytes(path), initial)
					helpers.assert_eq(Terminators.is_terminator_enabled("custom_probe"), false)
				end
				helpers.assert_eq(Codec.decode(sandbox.read_bytes(path)).hotstrings.unknown, "kept")
			end)
		end)
	end

	helpers.it("a held declared Delete cannot act after pause while the custom toggle remains present", function()
		with_settings(SOURCE, function(Settings, _, _, Terminators)
			helpers.assert_true(Settings.load())
			helpers.assert_true(Terminators.add_custom_terminator("custom_probe", "☃", "Independent snowman", false))
			helpers.assert_true(Settings.persist())
			local rows, ctx, observed = menu_controls(Settings, false, false)
			local row = assert(custom_delete_row(rows, custom_command_expected().i18n))
			local toggle
			for _, item in ipairs(rows) do
				if type(item.title) == "string" and item.title:find("Independent snowman", 1, true) then toggle = item end
			end
			helpers.assert_type(toggle, "table")
			helpers.assert_type(toggle.fn, "function", "the existing independent custom activation owner remains reachable")
			ctx.paused = true
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(observed.writes, 0)
			helpers.assert_eq(observed.redraws, 0)
			helpers.assert_eq(has_custom(Terminators, "custom_probe"), true)
		end)
	end)
end)


helpers.describe("custom delimiter Delete translations use the shared declaration", function()
	helpers.it("the actual provider renders the canonical Delete label in every supported locale", function()
		local locales = { "ar", "cs", "da", "de", "en", "es", "fr", "hi", "he", "it", "ja", "ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }
		local i18n = require("infra.i18n")
		local previous_get = i18n.get
		local observed = {}
		local passed, failure = pcall(function()
			for _, locale in ipairs(locales) do
				local path = require("infra.paths").shared("data/locales/" .. locale .. ".json")
				local file = assert(io.open(path, "rb"))
				local raw = file:read("*a")
				file:close()
				local translations = assert(require("json").decode(raw))
				i18n.get = function(key) return translations[key] or previous_get(key) end
				with_settings(SOURCE, function(Settings, _, _, Terminators)
					assert(Settings.load())
					assert(Terminators.add_custom_terminator("custom_probe", "☃", "Independent snowman", false))
					local rows, _, effects = menu_controls(Settings, false)
					local found = custom_delete_row(rows, custom_command_expected().i18n)
					observed[#observed + 1] = { locale = locale, expected = translations[custom_command_expected().i18n],
						label = found and found.title, action = found and type(found.fn), writes = effects.writes }
				end)
			end
		end)
		i18n.get = previous_get
		if not passed then error(failure, 0) end
		helpers.assert_eq(#observed, 21)
		for _, record in ipairs(observed) do
			helpers.assert_type(record.expected, "string", record.locale)
			helpers.assert_eq(record.label, record.expected, record.locale)
			helpers.assert_eq(record.action, "function", record.locale)
			helpers.assert_eq(record.writes, 0, record.locale)
		end
		helpers.assert_eq(i18n.get, previous_get, "the existing translation owner is restored exactly")
	end)
end)


--- Reads independent Add identity and custom-record expectations.
--- @return table corpus
local function add_command_expected()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/word_expander_add_controls.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

--- Uses the actual native menu and acknowledged TOML owner; only the native
--- prompt answers and writer refusal are controlled, then restored exactly.
--- @param mode string Native response/publication scenario.
--- @return table observed Captured effects, independent of callback catches.
local function observe_add_command(mode)
	local corpus = add_command_expected()
	local result
	with_settings(SOURCE, function(Settings, path, sandbox, Terminators)
		assert(Settings.load())
		local prior_prompt = package.loaded["ui.text_prompt"]
		local prior_execute = os.execute
		local Writer = require("toml_codec.writer")
		local prior_writer = Writer.batch_write
		local context, effects
		local observed = { prompts = 0, questions = 0, errors = 0, writes = 0 }
		package.loaded["ui.text_prompt"] = { ask = function()
			observed.prompts = observed.prompts + 1
			if mode == "pause_after_prompt" then context.paused = true end
			if mode == "input_cancel" then return nil end
			if mode == "input_empty" then return "" end
			return corpus.target.char
		end }
		os.execute = function(command)
			if command == "command -v zenity >/dev/null 2>&1" then
				return mode == "consume_unavailable" and 1 or 0
			end
			if command:find("zenity --question", 1, true) == 1 then
				observed.questions = observed.questions + 1
				if mode == "pause_after_consume" then context.paused = true end
				return mode == "consume_no" and 1 or 0
			end
			if command:find("zenity --error", 1, true) == 1 then
				observed.errors = observed.errors + 1
				return 0
			end
			return prior_execute(command)
		end
		Writer.batch_write = function(...)
			observed.writes = observed.writes + 1
			if mode == "write_false" then return false end
			if mode == "write_nil" then return nil end
			if mode == "write_throw" then error("injected Add writer refusal", 0) end
			if mode == "write_truthy" then return 2 end
			return prior_writer(...)
		end
		local passed, failure = pcall(function()
			local rows
			rows, context, effects = menu_controls(Settings, false)
			local row = assert(custom_delete_row(rows, corpus.i18n), "the actual Add provider must be accessible")
			if mode == "late_pause" then context.paused = true end
			observed.result = row.fn()
			observed.source = sandbox.read_bytes(path)
			observed.present = has_custom(Terminators, corpus.target.linux_key)
			observed.redraws = effects.redraws
			observed.records = require("toml_codec").decode(observed.source)
		end)
		package.loaded["ui.text_prompt"] = prior_prompt
		os.execute = prior_execute
		Writer.batch_write = prior_writer
		observed.prompt_restored = package.loaded["ui.text_prompt"] == prior_prompt
		observed.execute_restored = os.execute == prior_execute
		observed.writer_restored = Writer.batch_write == prior_writer
		if not passed then error(failure, 0) end
		result = observed
	end)
	return result
end

helpers.describe("custom delimiter Add uses shared declaration and native acknowledgement", function()
	for _, mode in ipairs({ "ack", "consume_no", "write_false", "write_nil", "write_throw", "write_truthy" }) do
		helpers.it("keeps exact owner publication semantics after " .. mode, function()
			local observed = observe_add_command(mode)
			local acknowledged = mode == "ack" or mode == "consume_no"
			helpers.assert_eq(observed.result, acknowledged)
			helpers.assert_eq(observed.present, acknowledged)
			helpers.assert_eq(observed.writes, 1)
			helpers.assert_eq(observed.redraws, acknowledged and 1 or 0)
			helpers.assert_eq(observed.records.hotstrings.unknown, "kept")
			helpers.assert_eq(observed.records.other.value, 42)
			if not acknowledged then helpers.assert_eq(observed.source, SOURCE) end
			helpers.assert_eq(observed.prompt_restored, true)
			helpers.assert_eq(observed.execute_restored, true)
			helpers.assert_eq(observed.writer_restored, true)
		end)
	end
	for _, mode in ipairs({ "late_pause", "pause_after_prompt", "pause_after_consume", "input_cancel", "input_empty", "consume_unavailable" }) do
		helpers.it("refuses held native Add without publication after " .. mode, function()
			local observed = observe_add_command(mode)
			helpers.assert_eq(observed.present, false)
			helpers.assert_eq(observed.result, false)
			helpers.assert_eq(observed.source, SOURCE)
			helpers.assert_eq(observed.writes, 0)
			helpers.assert_eq(observed.redraws, 0)
			if mode == "late_pause" then helpers.assert_eq(observed.prompts, 0) end
			if mode == "pause_after_prompt" then helpers.assert_eq(observed.questions, 0) end
			helpers.assert_eq(observed.prompt_restored, true)
			helpers.assert_eq(observed.execute_restored, true)
			helpers.assert_eq(observed.writer_restored, true)
		end)
	end
end)


--- Reads the independent command and existing native window identity.
--- @return table corpus Historical command expectation.
local function delay_settings_command_expected()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/delays_settings_command.json"), "rb"))
	local bytes = file:read("*a")
	file:close()
	return assert(require("json").decode(bytes))
end

helpers.describe("declared delay configuration command: actual Linux provider", function()
	helpers.it("uses the shared command label and preserves existing quick-delay rows", function()
		with_settings(SOURCE, function(Settings)
			local _, _, observations = menu_controls(Settings, false, "config_shared_label")
			local rows = assert(observations.delay_controls)
			local expected = delay_settings_command_expected()
			helpers.assert_eq(rows[expected.position].title, require("infra.i18n").get("button.ok"))
			helpers.assert_eq(rows[2].title, "-")
			helpers.assert_eq(#rows, 5, "the three existing variable-delay rows stay after the command")
		end)
	end)

	helpers.it("dispatches the existing window identity without a preference write", function()
		with_settings(SOURCE, function(Settings, path, sandbox)
			local _, ctx, observations = menu_controls(Settings, false, false)
			local native = { opens = 0 }
			ctx.webview = { show = function(name) native.opens = native.opens + 1; native.name = name end }
			assert(observations.delay_controls)[1].fn()
			helpers.assert_eq(native.opens, 1)
			helpers.assert_eq(native.name, delay_settings_command_expected().window)
			helpers.assert_eq(observations.writes, 0)
			helpers.assert_eq(sandbox.read_bytes(path), SOURCE)
		end)
	end)

	helpers.it("refuses a missing window owner without saving or redrawing", function()
		with_settings(SOURCE, function(Settings)
			local _, _, observations = menu_controls(Settings, false, false)
			assert(observations.delay_controls)[1].fn()
			helpers.assert_eq(observations.writes, 0)
			helpers.assert_eq(observations.redraws, 0)
		end)
	end)
end)
