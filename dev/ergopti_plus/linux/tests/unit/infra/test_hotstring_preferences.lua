--- tests/unit/infra/test_hotstring_preferences.lua

--- ==============================================================================
--- MODULE: Canonical Hotstring Scalar Preferences
--- DESCRIPTION:
--- The magic key, the preview toggles and the dynamic switches are canonical
--- config.toml leaves: absent means the manifest's neutral value, writes are
--- sparse and conditional, the typing path never rereads the disk, and a scope
--- owns the cache while it publishes.
--- ==============================================================================

local helpers = require("tests.helpers")
local Codec = require("toml_codec")
local Writer = require("toml_codec.writer")

local SOURCE = '[hotstrings]\npreview_star_enabled = true\nunknown = "kept"\n[other]\nvalue = 1\n'

--- Runs body against a fresh owner routed to a private file.
--- @param content string|nil Initial bytes; nil is an absent file.
--- @param body function body(Preferences, path)
local function with_preferences(content, body)
	local previous = package.loaded["infra.hotstring_preferences"]
	local path = string.format("%s/ergopti_hotstring_preferences_%d_%d.toml",
		(os.getenv("TMPDIR") or "/tmp"):gsub("/+$", ""), os.time(), math.random(100000, 999999))
	if content then
		local handle = assert(io.open(path, "w"))
		handle:write(content)
		handle:close()
	end
	local ok, err = pcall(function()
		local Preferences = helpers.load_module("infra.hotstring_preferences")
		assert(Preferences._set_file_for_test(path))
		body(Preferences, path)
	end)
	package.loaded["infra.hotstring_preferences"] = previous
	os.remove(path)
	os.remove(path .. ".tmp")
	if not ok then error(err, 0) end
end

local function read(path)
	local handle = io.open(path, "r")
	if not handle then return nil end
	local content = handle:read("*a")
	handle:close()
	return content
end

helpers.describe("hotstring preferences: canonical leaves", function()
	helpers.it("answers every owned leaf with its neutral default for an empty configuration", function()
		with_preferences(nil, function(Preferences, path)
			helpers.assert_eq(Preferences.get("hotstrings.preview_star_enabled"), false)
			helpers.assert_eq(Preferences.get("hotstrings.dynamic.enabled"), false)
			helpers.assert_eq(Preferences.get("hotstrings.dynamic.date.enabled"), false)
			helpers.assert_eq(Preferences.get("hotstrings.trigger_char"),
				require("infra.manifest_reader").default_for("hotstrings.trigger_char"))
			helpers.assert_eq(Preferences.is_explicit("hotstrings.trigger_char"), false)
			helpers.assert_nil(read(path), "reading never writes")
		end)
	end)

	helpers.it("persists a choice sparsely, keeps neighbours and reads it after a restart", function()
		with_preferences(SOURCE, function(Preferences, path)
			helpers.assert_true(Preferences.set("hotstrings.trigger_char", "§"))
			helpers.assert_true(Preferences.set("hotstrings.dynamic.date_fr.enabled", true))
			local decoded = Codec.decode(read(path))
			helpers.assert_eq(decoded.hotstrings.trigger_char, "§")
			helpers.assert_eq(decoded.hotstrings.dynamic.date_fr.enabled, true)
			helpers.assert_eq(decoded.hotstrings.unknown, "kept")
			helpers.assert_eq(decoded.other.value, 1)
			package.loaded["infra.hotstring_preferences"] = nil
			local restarted = require("infra.hotstring_preferences")
			assert(restarted._set_file_for_test(path))
			helpers.assert_eq(restarted.get("hotstrings.trigger_char"), "§")
			helpers.assert_eq(restarted.get("hotstrings.dynamic.date_fr.enabled"), true)
		end)
	end)

	helpers.it("removes a leaf set back to its neutral value", function()
		with_preferences(SOURCE, function(Preferences, path)
			helpers.assert_eq(Preferences.get("hotstrings.preview_star_enabled"), true)
			helpers.assert_true(Preferences.set("hotstrings.preview_star_enabled", false))
			local decoded = Codec.decode(read(path))
			helpers.assert_nil(decoded.hotstrings.preview_star_enabled, "neutral absence, not a stored false")
			helpers.assert_eq(Preferences.is_explicit("hotstrings.preview_star_enabled"), false)
		end)
	end)

	helpers.it("keeps a malformed configuration neutral and refuses to write over it", function()
		local malformed = '[hotstrings\npreview_star_enabled = true\n'
		with_preferences(malformed, function(Preferences, path)
			helpers.assert_eq(Preferences.refresh(), false)
			helpers.assert_eq(Preferences.get("hotstrings.preview_star_enabled"), false,
				"an unreadable choice is never guessed on")
			helpers.assert_eq(Preferences.set("hotstrings.preview_star_enabled", true), false)
			helpers.assert_eq(read(path), malformed)
		end)
	end)

	--- Runs body with the owner's logger recording ERROR and WARNING lines.
	--- @param content string Initial bytes.
	--- @param body function body(Preferences, path, errors, warnings)
	local function with_recorded_log(content, body)
		local saved = package.loaded["logger.shim"]
		local errors, warnings = {}, {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		package.loaded["logger.shim"] = logger
		require("config_outdated").reset_for_tests()
		local ok, err = pcall(with_preferences, content, function(Preferences, path)
			body(Preferences, path, errors, warnings)
		end)
		package.loaded["logger.shim"] = saved
		if not ok then error(err, 0) end
	end

	helpers.it("reads an old-shape leaf as neutral and keeps every other leaf (config-outdated-preferences)", function()
		-- One wrong-typed leaf made the whole document unreadable: two ERRORs at
		-- boot, the user's magic key replaced by the default, and a cleanup that
		-- reported the file as unreadable.
		local source = '[hotstrings]\ntrigger_char = "§"\npreview_star_enabled = "on"\n'
		with_recorded_log(source, function(Preferences, path, errors, warnings)
			helpers.assert_eq(Preferences.get("hotstrings.trigger_char"), "§")
			helpers.assert_eq(Preferences.get("hotstrings.preview_star_enabled"), false)
			helpers.assert_eq(errors, {})
			helpers.assert_eq(#warnings, 1, table.concat(warnings, " | "))
			helpers.assert_true(warnings[1]:find("'hotstrings.preview_star_enabled'", 1, true) ~= nil, warnings[1])
			local scan = require("config_unused_keys").find_in_source(source, Preferences.mark_config_reads)
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq({ scan.keys[1].section, scan.keys[1].key }, { "hotstrings", "preview_star_enabled" })
			helpers.assert_true(Preferences.set("hotstrings.preview_star_enabled", true),
				"a new choice replaces the old shape")
			helpers.assert_eq(read(path):match('preview_star_enabled = (%a+)'), "true")
		end)
	end)

	helpers.it("reads the leaves under an old scalar parent as neutral (config-outdated-preferences)", function()
		local source = '[hotstrings]\ntrigger_char = "§"\ndynamic = true\n'
		with_recorded_log(source, function(Preferences, _, errors)
			helpers.assert_eq(Preferences.get("hotstrings.dynamic.date.enabled"), false)
			helpers.assert_eq(Preferences.get("hotstrings.trigger_char"), "§")
			helpers.assert_eq(errors, {})
			local scan = require("config_unused_keys").find_in_source(source, Preferences.mark_config_reads)
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq({ scan.keys[1].section, scan.keys[1].key }, { "hotstrings", "dynamic" })
		end)
	end)

	helpers.it("refuses a write raced by an external editor and keeps its cache", function()
		with_preferences(SOURCE, function(Preferences, path)
			helpers.assert_eq(Preferences.get("hotstrings.preview_star_enabled"), true)
			local original = Writer.batch_write
			local external = SOURCE .. "external = 9\n"
			Writer.batch_write = function(...)
				local handle = assert(io.open(path, "w"))
				handle:write(external)
				handle:close()
				return original(...)
			end
			local ok, committed = pcall(Preferences.set, "hotstrings.preview_star_enabled", false)
			Writer.batch_write = original
			helpers.assert_true(ok, tostring(committed))
			helpers.assert_eq(committed, false)
			helpers.assert_eq(read(path), external, "the external edit wins")
			helpers.assert_eq(Preferences.get("hotstrings.preview_star_enabled"), true, "the cache is unchanged")
		end)
	end)

	helpers.it("answers the typing path from its cache", function()
		with_preferences(SOURCE, function(Preferences)
			helpers.assert_eq(Preferences.get("hotstrings.dynamic.date.enabled"), false)
			local original, reads = Writer.read_classified, 0
			Writer.read_classified = function(...) reads = reads + 1; return original(...) end
			local ok, err = pcall(function()
				for _ = 1, 100 do Preferences.get("hotstrings.dynamic.date.enabled") end
			end)
			Writer.read_classified = original
			if not ok then error(err, 0) end
			helpers.assert_eq(reads, 0)
		end)
	end)

	helpers.it("refuses paths it does not own and values of the wrong type", function()
		with_preferences(nil, function(Preferences, path)
			helpers.assert_throws(function() Preferences.get("hotstrings.groups.rolls") end,
				"a catalogue choice has its own owner")
			helpers.assert_throws(function() Preferences.get("hotstrings.repeat_key_enabled") end,
				"the repeat key has its own owner")
			helpers.assert_eq(Preferences.set("hotstrings.preview_star_enabled", "true"), false)
			helpers.assert_nil(read(path))
		end)
	end)

	helpers.it("marks exactly the owned leaves a configuration sets", function()
		with_preferences(nil, function(Preferences)
			local marked = {}
			Preferences.mark_config_reads(Codec.decode(SOURCE .. "[hotstrings.dynamic.date]\nenabled = true\n"),
				function(...) marked[#marked + 1] = table.concat({ ... }, ".") end)
			table.sort(marked)
			helpers.assert_eq(marked, { "hotstrings.dynamic.date.enabled", "hotstrings.preview_star_enabled" })
		end)
	end)

	helpers.it("lets only the acquiring scope adopt and restore a candidate", function()
		with_preferences(SOURCE, function(Preferences)
			local owner, stranger = {}, {}
			local snapshot = Preferences.snapshot()
			helpers.assert_eq(Preferences.adopt(owner, {}), false, "adoption requires ownership")
			helpers.assert_true(Preferences.acquire(owner))
			helpers.assert_eq(Preferences.acquire(stranger), false)
			helpers.assert_eq(Preferences.set("hotstrings.preview_star_enabled", false), false,
				"an ordinary write waits for the scope")
			helpers.assert_eq(Preferences.adopt(owner, { hotstrings = { preview_star_enabled = 1 } }), false,
				"a malformed candidate is refused")
			helpers.assert_true(Preferences.adopt(owner, {}))
			helpers.assert_eq(Preferences.get("hotstrings.preview_star_enabled"), false, "the candidate is effective")
			helpers.assert_eq(Preferences.restore(stranger, snapshot), false)
			helpers.assert_true(Preferences.restore(owner, snapshot))
			helpers.assert_eq(Preferences.get("hotstrings.preview_star_enabled"), true, "the snapshot is effective")
			helpers.assert_eq(Preferences.release(stranger), false)
			helpers.assert_true(Preferences.release(owner))
			helpers.assert_true(Preferences.set("hotstrings.preview_star_enabled", false))
		end)
	end)
end)
