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
--- @param body function body(Source, Preferences, path)
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
		body(require("modules.hotstrings.magic_key_source"), Preferences, path)
	end)
	package.loaded["infra.hotstring_preferences"] = saved.preferences
	package.loaded["modules.hotstrings.magic_key_source"] = saved.source
	os.remove(path)
	os.remove(path .. ".tmp")
	if not ok then error(err, 0) end
end

--- Wires the owner to recording collaborators.
--- @param Source table
--- @param state table { active, replace, typed_ok, grab, typable } switches the test flips.
--- @param end_selection function|nil The selection window's end; counted when nil.
--- @return table calls { typed = {}, dispatched = {}, deferred = {}, ended = 0 }
local function wire(Source, state, end_selection)
	local calls = { typed = {}, dispatched = {}, deferred = {}, ended = 0 }
	Source.init({
		end_selection = end_selection or function() calls.ended = calls.ended + 1 end,
		is_active = function() return state.active end,
		replace_on = function() return state.replace end,
		magic_key = function() return "★" end,
		can_type = function(text) return text == "★" and state.typable ~= false end,
		type_text = function(text)
			calls.typed[#calls.typed + 1] = text
			return state.typed_ok
		end,
		dispatch_char = function(char, code)
			calls.dispatched[#calls.dispatched + 1] = { char = char, code = code }
		end,
		can_capture = function() return state.grab ~= false end,
		key_text = function(code) return code == KEY_J and "j" or nil end,
		defer = function(fn, delay_ms)
			calls.deferred[#calls.deferred + 1] = { fn = fn, delay_ms = delay_ms }
			return true
		end,
	})
	return calls
end

--- Runs the deferred work queued with no delay, as the next loop tick would.
local function run_due(calls)
	for _, entry in ipairs(calls.deferred) do
		if entry.delay_ms == 0 and not entry.ran then
			entry.ran = true
			entry.fn()
		end
	end
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
			helpers.assert_eq(calls.ended, 1, "only the typed magic key ended the selection window")
			local ok = pcall(wire, Source, state)
			helpers.assert_eq(ok, false, "a second initialization is refused")
			Source._reset_for_test()
		end)
	end)

	helpers.it("(magic-key-source) a keystroke reads no preference; a new document is followed at once", function()
		with_source("[hotstrings]\nmagic_key_source = \"KeyJ\"\n", function(Source, Preferences, path)
			wire(Source, { active = true, replace = true, typed_ok = true })
			local real_get, reads = Preferences.get, 0
			Preferences.get = function(leaf)
				reads = reads + 1
				return real_get(leaf)
			end
			local ok, err = pcall(function()
				for _ = 1, 50 do Source.on_key({ code = KEY_C, mods = {} }) end
				helpers.assert_true(reads <= 1,
					"the evdev code is derived once per document, not on each of 50 key-downs: " .. reads)
				helpers.assert_eq(Source.evdev_code(), KEY_J)
				helpers.assert_true(Source.set("Semicolon"))
				helpers.assert_eq(Source.evdev_code(), 39, "a choice is followed on the next press")
				local handle = assert(io.open(path, "w"))
				handle:write("[hotstrings]\nmagic_key_source = \"KeyQ\"\n")
				handle:close()
				helpers.assert_eq(Source.evdev_code(), 39, "an unread edit changes nothing yet")
				helpers.assert_true(Preferences.refresh())
				helpers.assert_eq(Source.evdev_code(), 16, "a refreshed document is followed")
			end)
			Preferences.get = real_get
			Source._reset_for_test()
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("(magic-key-source) the magic key typed over a selection ends wrap-on-type's window", function()
		with_source("[hotstrings]\nmagic_key_source = \"KeyJ\"\n", function(Source)
			local primary, wrapped = "", {}
			local wrap = helpers.load_module("modules.shortcuts.wrap_on_type").new({
				is_active = function() return true end,
				get_pair = function(char) return char == "(" and { left = "(", right = ")" } or nil end,
				read_primary = function() return true, primary end,
				type_text = function(text)
					wrapped[#wrapped + 1] = text
					return true
				end,
			})
			wire(Source, { active = true, replace = true, typed_ok = true }, wrap.end_selection_window)
			-- A drag selects "foo", then the magic key replaces it.
			wrap.on_pointer_down()
			primary = "foo"
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
			helpers.assert_eq(wrap.selection_window_open(), false, "the typed ★ ended the selection")
			helpers.assert_eq(wrap.on_key({ code = 10, char = "(", mods = {} }), false, "the symbol types")
			helpers.assert_eq(wrapped, {}, "the text ★ replaced is not typed back from PRIMARY")
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

helpers.describe("magic key source: choosing a key", function()
	helpers.it("(magic-key-source) stores a candidate sparsely and refuses any other value", function()
		with_source(nil, function(Source, Preferences)
			local _, refusal = pcall(Source.set, "Semicolon")
			helpers.assert_true(tostring(refusal):find("needs M.init first", 1, true) ~= nil,
				"a choice needs the daemon's collaborators: " .. tostring(refusal))
			wire(Source, { active = true, replace = true, typed_ok = true })
			helpers.assert_true(Source.set("Semicolon"))
			helpers.assert_eq(Source.get(), "Semicolon")
			helpers.assert_eq(Source.evdev_code(), 39)
			local ok, reason = Source.set("Space")
			helpers.assert_eq(ok, false, "the space bar is never the magic key")
			helpers.assert_eq(reason, "dialog.magic_key_source.not_a_candidate")
			helpers.assert_eq(Source.get(), "Semicolon", "a refusal changes nothing")
			helpers.assert_true(Source.set("auto"))
			helpers.assert_eq(Preferences.is_explicit(PATH), false, "the automatic key is written as absence")
			Source._reset_for_test()
		end)
	end)

	helpers.it("(magic-key-source) a magic key the layout cannot type with key presses leaves every key its own", function()
		with_source("[hotstrings]\nmagic_key_source = \"KeyJ\"\n", function(Source)
			local state = { active = true, replace = true, typed_ok = true, typable = false }
			local calls = wire(Source, state)
			helpers.assert_eq(Source.on_key({ code = KEY_J, mods = {} }), false, "the key types its own character")
			helpers.assert_eq(#calls.typed, 0, "nothing is injected: no paste on every press")
			local ok, reason = Source.set("Semicolon")
			helpers.assert_eq(ok, false, "a key that would do nothing is refused aloud")
			helpers.assert_eq(reason, "dialog.magic_key_source.untypable")
			helpers.assert_eq(Source.get(), "KeyJ")
			helpers.assert_true(Source.set("auto"), "the automatic key is always allowed")
			state.typable = true
			helpers.assert_true(Source.set("KeyJ"))
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
			helpers.assert_eq(calls.typed, { "★" })
			Source._reset_for_test()
		end)
	end)

	helpers.it("(magic-key-source) a capture takes the next grabbed key, whatever it types", function()
		with_source(nil, function(Source)
			local calls = wire(Source, { active = true, replace = true, typed_ok = true })
			local chosen, refused = {}, {}
			local handlers = {
				on_chosen = function(value) chosen[#chosen + 1] = value end,
				on_refused = function(reason) refused[#refused + 1] = reason end,
			}
			helpers.assert_true(Source.capture(handlers))
			helpers.assert_eq(Source.capture(handlers), false, "one capture at a time")
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = { shift = true } }),
				"the answering key reaches no application, modifiers or not")
			helpers.assert_eq(#chosen, 0, "nothing is written on the keystroke path")
			run_due(calls)
			helpers.assert_eq(chosen, { "KeyJ" })
			helpers.assert_eq(Source.get(), "KeyJ")
			helpers.assert_eq(Source.on_key({ code = KEY_C, mods = { shift = true } }), false,
				"the capture ended with its answer")

			helpers.assert_true(Source.capture(handlers))
			helpers.assert_true(Source.on_key({ code = 57, mods = {} }), "the space bar is captured too")
			run_due(calls)
			helpers.assert_eq(refused, { "dialog.magic_key_source.not_a_candidate" }, "and refused aloud")
			helpers.assert_eq(Source.get(), "KeyJ")

			helpers.assert_true(Source.capture(handlers))
			helpers.assert_true(Source.on_key({ code = 1, mods = {} }))
			run_due(calls)
			helpers.assert_eq(#chosen + #refused, 2, "Escape ends the capture with nothing changed")

			helpers.assert_true(Source.capture(handlers))
			local timeout = calls.deferred[#calls.deferred]
			helpers.assert_true(timeout.delay_ms > 0, "the capture carries the shared timeout")
			timeout.fn()
			helpers.assert_eq(Source.on_key({ code = KEY_C, mods = {} }), false, "a timed-out capture takes nothing")
			Source._reset_for_test()
		end)
	end)

	helpers.it("(magic-key-source) no capture without the grab", function()
		with_source(nil, function(Source)
			wire(Source, { active = true, replace = true, typed_ok = true, grab = false })
			helpers.assert_eq(Source.can_capture(), false)
			helpers.assert_eq(Source.capture({ on_chosen = function() end, on_refused = function() end }), false)
			Source._reset_for_test()
		end)
	end)
end)

helpers.describe("magic key source: the keyboard-layout menu", function()
	helpers.it("(magic-key-source) the tray lists the key in effect under the keyboard layout", function()
		with_source("[hotstrings]\nmagic_key_source = \"KeyJ\"\n", function(Source)
			wire(Source, { active = true, replace = true, typed_ok = true })
			local I18n = require("infra.i18n")
			local builder = helpers.load_module("ui.menu.menu_builder")
			local ok, items = pcall(builder.build, { on_quit = function() end, magic_key_source = Source })
			Source._reset_for_test()
			if not ok then error(items, 0) end
			local layout
			for _, item in ipairs(items) do
				if item.title == I18n.get("menu.layout.title") then layout = item.menu end
			end
			helpers.assert_type(layout, "table", "the tray has a keyboard-layout submenu")
			local prefix = I18n.get("menu.layout.magic_key_source") .. " : "
			local row
			for _, item in ipairs(layout) do
				if type(item.title) == "string" and item.title:sub(1, #prefix) == prefix then row = item end
			end
			helpers.assert_type(row, "table", "the keyboard-layout menu names the physical magic key")
			helpers.assert_eq(row.title, prefix .. "j   (KeyJ)")
			helpers.assert_eq(row.menu[1].title, I18n.get("menu.layout.magic_key_source.capture"))
			helpers.assert_type(row.menu[1].fn, "function", "a grabbing daemon captures a key")
		end)
	end)
end)
