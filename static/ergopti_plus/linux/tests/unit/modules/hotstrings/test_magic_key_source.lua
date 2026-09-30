--- tests/unit/modules/hotstrings/test_magic_key_source.lua

--- ==============================================================================
--- MODULE: Physical Magic Key (Linux)
--- DESCRIPTION:
--- `hotstrings.magic_key_source` names the physical key that types the magic
--- key, on every driver. Linux used a fixed key: whatever its XKB layout put
--- the magic key on, with no way to choose another. These cases replay the
--- shared decisions with evdev codes, read the canonical config.toml leaf, and
--- drive the consumption decision the keyboard hook asks for every grabbed
--- key-down: the chosen key is consumed, the magic key typed in its place and
--- handed to the character path; every other press stays the application's.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Shared = require("keymap.magic_key_source")

local PATH = "hotstrings.magic_key_source"
local KEY_J = 36
local KEY_C = 46

local function registry()
	local handle = assert(io.open(helpers.driver_root() .. "/../_shared/data/keycodes/physical_keys.json", "rb"))
	local decoded = Json.decode(handle:read("*a"))
	handle:close()
	return decoded
end

require("test.magic_key_source_contract")(helpers, Shared, {
	entry = require("infra.manifest_reader").find_entry_by_path(PATH),
	registry = registry(),
	field = "evdev",
})

--- Runs body against fresh owners whose config.toml is a private file.
--- @param content string|nil Initial config.toml; nil is an absent file.
--- @param body function body(Source, Preferences)
local function with_source(content, body)
	local saved = {
		preferences = package.loaded["infra.hotstring_preferences"],
		source = package.loaded["modules.hotstrings.magic_key_source"],
	}
	local path = string.format("%s/ergopti_magic_key_source_%d_%d.toml",
		(os.getenv("TMPDIR") or "/tmp"):gsub("/+$", ""), os.time(), math.random(100000, 999999))
	if content then
		local handle = assert(io.open(path, "w"))
		handle:write(content)
		handle:close()
	end
	local ok, err = pcall(function()
		package.loaded["modules.hotstrings.magic_key_source"] = nil
		local Preferences = helpers.load_module("infra.hotstring_preferences")
		assert(Preferences._set_file_for_test(path))
		body(require("modules.hotstrings.magic_key_source"), Preferences)
	end)
	package.loaded["infra.hotstring_preferences"] = saved.preferences
	package.loaded["modules.hotstrings.magic_key_source"] = saved.source
	os.remove(path)
	os.remove(path .. ".tmp")
	if not ok then error(err, 0) end
end

--- Wires the owner to recording collaborators.
--- @param Source table
--- @param state table { active, replace, typed_ok } switches the test flips.
--- @return table calls { typed = {}, dispatched = {} }
local function wire(Source, state)
	local calls = { typed = {}, dispatched = {} }
	Source.init({
		is_active = function() return state.active end,
		replace_on = function() return state.replace end,
		magic_key = function() return "★" end,
		type_text = function(text)
			calls.typed[#calls.typed + 1] = text
			return state.typed_ok
		end,
		dispatch_char = function(char, code)
			calls.dispatched[#calls.dispatched + 1] = { char = char, code = code }
		end,
	})
	return calls
end

helpers.describe("magic key source: the config.toml leaf", function()
	helpers.it("(magic-key-source) reads the chosen key and its evdev code, automatic when absent", function()
		with_source(nil, function(Source)
			helpers.assert_eq(Source.get(), "auto")
			helpers.assert_nil(Source.evdev_code(), "the XKB layout keeps its own magic key")
		end)
		with_source("[hotstrings]\nmagic_key_source = \"KeyJ\"\n", function(Source)
			helpers.assert_eq(Source.get(), "KeyJ")
			helpers.assert_eq(Source.evdev_code(), KEY_J)
		end)
	end)

	helpers.it("(magic-key-source) an outdated value reads as automatic and is offered for cleanup", function()
		with_source("[hotstrings]\nmagic_key_source = \"SC03B\"\n", function(Source, Preferences)
			helpers.assert_eq(Source.get(), "auto")
			helpers.assert_nil(Source.evdev_code())
			local marked = {}
			Preferences.mark_config_reads({ hotstrings = { magic_key_source = "SC03B" } },
				function(...) marked[#marked + 1] = table.concat({ ... }, ".") end)
			helpers.assert_eq(#marked, 0, "an outdated leaf is left unmarked for the cleanup")
			Preferences.mark_config_reads({ hotstrings = { magic_key_source = "KeyJ" } },
				function(...) marked[#marked + 1] = table.concat({ ... }, ".") end)
			helpers.assert_eq(marked, { PATH })
		end)
	end)
end)

helpers.describe("magic key source: the keyboard hook decision", function()
	helpers.it("(magic-key-source) consumes a plain press of the chosen key and types the magic key", function()
		with_source("[hotstrings]\nmagic_key_source = \"KeyJ\"\n", function(Source)
			local state = { active = true, replace = true, typed_ok = true }
			local calls = wire(Source, state)
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {}, char = "j" }))
			helpers.assert_eq(calls.typed, { "★" }, "the magic key is typed in the key's place")
			helpers.assert_eq(calls.dispatched, { { char = "★", code = KEY_J } },
				"then read as typed, so a ★ trigger can fire")

			for _, case in ipairs({
				{ detail = { code = KEY_J, mods = { shift = true } }, why = "Shift keeps the capital" },
				{ detail = { code = KEY_J, mods = { altgr = true } }, why = "AltGr keeps its level" },
				{ detail = { code = KEY_J, mods = { ctrl = true } }, why = "a chord stays a chord" },
				{ detail = { code = KEY_C, mods = {} }, why = "the former fixed key is free" },
			}) do
				helpers.assert_eq(Source.on_key(case.detail), false, case.why)
			end
			state.replace = false
			helpers.assert_eq(Source.on_key({ code = KEY_J, mods = {} }), false, "the replace section gates it")
			state.replace, state.active = true, false
			helpers.assert_eq(Source.on_key({ code = KEY_J, mods = {} }), false, "a paused driver types the key")
			state.active, state.typed_ok = true, false
			helpers.assert_eq(Source.on_key({ code = KEY_J, mods = {} }), false,
				"an injection that did not happen lets the key through, typed once")
			helpers.assert_eq(#calls.dispatched, 1, "nothing reaches the buffer that the application lacks")
			local ok = pcall(wire, Source, state)
			helpers.assert_eq(ok, false, "a second initialization is refused")
			Source._reset_for_test()
		end)
	end)

	helpers.it("(magic-key-source) the automatic key consumes nothing", function()
		with_source(nil, function(Source)
			local calls = wire(Source, { active = true, replace = true, typed_ok = true })
			helpers.assert_eq(Source.on_key({ code = KEY_C, mods = {} }), false)
			helpers.assert_eq(Source.on_key({ code = KEY_J, mods = {} }), false)
			helpers.assert_eq(#calls.typed, 0)
			Source._reset_for_test()
		end)
	end)
end)
