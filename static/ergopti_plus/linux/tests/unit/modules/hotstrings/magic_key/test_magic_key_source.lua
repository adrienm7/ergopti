--- tests/unit/modules/hotstrings/magic_key/test_magic_key_source.lua

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
		magic_key = function() return state.magic or "★" end,
		can_type = function(text) return text == (state.magic or "★") and state.typable ~= false end,
		typing_plan = function() return state.plan end,
		input_source_receipt = function() return state.origin or { generation = 1, ready = true } end,
		direct_source_admitted = function(code) return state.blocked_code ~= code end,
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
			if delay_ms == 0 then
				if state.answer == "throw" then error("Controlled answer queue refusal") end
				if state.answer == "premature" then fn() end
				if state.answer == "refuse" then return false end
				if state.answer_pause then state.answer_pause() end
			end
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

	helpers.it("(magic-key-source) no capture while the driver is paused, as on macOS", function()
		with_source(nil, function(Source)
			local state = { active = false, replace = true, typed_ok = true }
			wire(Source, state)
			helpers.assert_eq(Source.can_capture(), false, "the menu greys the row")
			helpers.assert_eq(Source.capture({ on_chosen = function() end, on_refused = function() end }), false)
			state.active = true
			helpers.assert_true(Source.can_capture(), "resumed, it captures again")
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

helpers.describe("magic key source: physical editor evidence", function()
	local function with_native(state, body)
		local previous = package.loaded["adapters.xkb_capture"]
		package.loaded["adapters.xkb_capture"] = {
			source_generation = function() return state.generation end,
			direct_sources = function(codes)
				state.probed = codes
				return state.rows
			end,
		}
		local ok, err = pcall(body)
		package.loaded["adapters.xkb_capture"] = previous
		if not ok then error(err, 0) end
	end

	helpers.it("(magic-editor-source) follows live native groups and magic characters without changing personal preferences", function()
		with_source(nil, function(Source, Preferences)
			local state = { active = true, replace = true, typed_ok = true, magic = "ù" }
			wire(Source, state)
			local native = { generation = 10, rows = {
				{ code = 40, text = "ù", plain = true, direct = true, dead = false, mods = {} },
				{ code = 39, text = ";", plain = true, direct = true, dead = false, mods = {} },
			} }
			with_native(native, function()
				local first = Source.editor_source()
				helpers.assert_eq(first.status, "ready")
				helpers.assert_eq(#first.candidates, 2)
				helpers.assert_eq(first.candidates[1].code, "Quote")
				helpers.assert_eq(first.candidates[1].identity, "evdev:40")
				helpers.assert_true(first.candidates[1].direct)
				helpers.assert_eq(Source.editor_source().generation, first.generation, "unchanged native evidence has a stable epoch")
				local preference = Preferences.generation()
				state.magic = ";"
				local changed = Source.editor_source()
				helpers.assert_true(changed.generation > first.generation, "a live magic character retargets its conditional shortcut")
				helpers.assert_eq(Preferences.generation(), preference, "retargeting writes no preference or personal chord")
				helpers.assert_eq(Source.get(), "auto")
				native.generation = 11
				helpers.assert_true(Source.editor_source().generation > changed.generation, "group changes invalidate queued native deliveries")
				first.candidates[1].text = "corrupted"
				helpers.assert_eq(Source.editor_source().candidates[1].text, "ù", "receipts do not alias mutable native evidence")
			end)
		end)
	end)

	helpers.it("(magic-editor-source) qualifies a configured remap against the injector plan in the actual group", function()
		with_source("[hotstrings]\nmagic_key_source = \"KeyJ\"\n", function(Source)
			local state = { active = true, replace = true, typed_ok = true, magic = "ù", plan = { keycode = 40, mods = {} } }
			wire(Source, state)
			local native = { generation = 20, rows = {
				{ code = KEY_J, text = "j", plain = true, direct = true, dead = false, mods = {} },
				{ code = 40, text = "ù", plain = true, direct = true, dead = false, mods = {} },
			} }
			with_native(native, function()
				local first = Source.editor_source()
				helpers.assert_eq(#first.candidates, 1, "a proven chosen replacement owns its physical source despite another native magic glyph")
				helpers.assert_eq(first.candidates[1].text, "ù", "the plain configured key types the actual live magic character")
				helpers.assert_eq(first.candidates[1].native_text, "j", "ordinary personal Super+J retains its physical claim")
				helpers.assert_eq(first.candidates[1].native_code, KEY_J)
				state.replace = false
				helpers.assert_eq(#Source.editor_source().candidates, 2, "an ineffective source setting falls back to every native candidate")
				state.replace, state.active = true, false
				helpers.assert_eq(#Source.editor_source().candidates, 2, "a paused replacement owner cannot claim its configured source")
				state.active = true
				native.rows[2].text, native.generation = "'", 21
				local switched = Source.editor_source()
				helpers.assert_eq(switched.candidates[1].text, "j", "a stale injection plan cannot prove a remap in another group")
				helpers.assert_true(switched.generation > first.generation)
			end)
		end)
	end)

	helpers.it("(magic-editor-source) preserves duplicate, dead and higher-level evidence and refuses tap-hold ownership", function()
		with_source(nil, function(Source)
			local state = { active = true, replace = true, typed_ok = true, blocked_code = KEY_J }
			wire(Source, state)
			with_native({ generation = 30, rows = {
				{ code = KEY_J, text = "★", plain = true, direct = true, dead = false, mods = {} },
				{ code = KEY_C, text = "★", plain = true, direct = true, dead = false, mods = {} },
				{ code = 26, text = "^", plain = true, direct = false, dead = true, mods = {} },
				{ code = 40, text = "★", plain = false, direct = false, dead = false, mods = { "altgr" } },
			} }, function()
				local evidence = Source.editor_source()
				helpers.assert_eq(#evidence.candidates, 4, "the native owner must never reduce evidence through first-match inversion")
				helpers.assert_eq(evidence.candidates[1].direct, false, "an admitted native glyph does not bypass a tap-hold owner")
				helpers.assert_true(evidence.candidates[2].direct)
				helpers.assert_true(evidence.candidates[3].dead)
				helpers.assert_eq(evidence.candidates[4].direct, false)
				state.blocked_code = nil
				helpers.assert_true(Source.editor_source().generation > evidence.generation, "runtime tap admission changes cancel old deliveries")
				state.origin = { generation = 2, ready = false }
				local unqualified = Source.editor_source()
				helpers.assert_eq(unqualified.status, "unavailable", "pinned upstream/unknown origins cannot qualify a physical recommendation")
				helpers.assert_eq(unqualified.reason, "physical-origin-unqualified")
				helpers.assert_true(unqualified.generation > evidence.generation)
			end)
		end)
	end)

	helpers.it("(magic-editor-source) never invents a fallback physical C when native proof is unavailable", function()
		with_source(nil, function(Source)
			wire(Source, { active = true, replace = true, typed_ok = true })
			with_native({ generation = nil, rows = nil }, function()
				local evidence = Source.editor_source()
				helpers.assert_eq(evidence.status, "unavailable")
				helpers.assert_eq(evidence.candidates, {})
				helpers.assert_nil(Source.evdev_code(), "automatic source remains automatic on every layout")
			end)
		end)
	end)
end)


helpers.describe("magic replacement: the Ergopti extension control", function()
	local Choices = require("tests.support.hotstring_choices")
	local SOURCE = '[hotstrings]\ngroups = { magickey = true }\n'
		.. '[hotstrings.modules.magickey]\nreplace = false\n'
		.. '[future]\nchoice = "preserve exact bytes" # untouched\n'

	--- Exercises the canonical choice owner and actual rendered layout menu.
	--- @param source string Initial canonical document.
	--- @param body function body(Config, path, state, row).
	local function with_replace(source, body)
		local names = { "modules.hotstrings.loader", "modules.hotstrings.hotstrings_config", "ui.menu.menu_builder" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local state = { published = {}, notified = 0, redraw = 0, paused = false, reject = false }
		package.loaded[names[1]] = {
			read_file = function() return nil end,
			load_catalogue = function()
				return { committed = true, errors = 0, categories = {
					magickey = { id = "magickey", sections_order = { "replace" },
						sections = { replace = { count = 1, description = "Native replacement",
							extension = { id = "ergopti", name = "Ergopti+" } } }, count = 1 },
				}, mappings = { { trigger = "j", replacement = "★", group = "magickey", section = "replace" } } }
			end,
		}
		local ok, err = pcall(function()
			local Config = helpers.load_module(names[2])
			Choices.with_file(Config, source, function(path)
				local engine, attempts = require("hotstring_engine").new(), 0
				local load = engine.load_mappings
				engine.load_mappings = function(self, mappings)
					attempts = attempts + 1
					if state.reject and attempts == 2 then return false end
					local committed = load(self, mappings)
					if committed then state.published[#state.published + 1] = mappings end
					return committed
				end
				Config.init(engine, "virtual.toml", function() state.notified = state.notified + 1 end)
				local _, committed = Config.load_all()
				helpers.assert_eq(committed, true, "the fixture catalogue must initialize")
				local Builder = helpers.load_module(names[3])
				local I18n = require("infra.i18n")
				local function row()
					local items = Builder.build({ config = Config, on_quit = function() end,
						paused = state.paused, is_paused = function() return state.paused end,
						on_menu_changed = function() state.redraw = state.redraw + 1 end,
						magic_key_source = state.source })
					local extension_label = string.format(I18n.get("menu.extensions.hotstrings_of"), "Ergopti+")
					local extension, layout
					local function find(rows)
						for _, item in ipairs(rows or {}) do
							if item.title == extension_label then extension = item end
							if item.title == I18n.get("menu.layout.title") then layout = item end
							find(item.menu)
						end
					end
					find(items)
					for index, child in ipairs(extension and extension.menu or {}) do
						if child.title == "Native replacement (1)" then return child, index, layout end
					end
					return nil, nil, layout
				end
				body(Config, path, state, row)
			end)
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end

	helpers.it("(ergopti-magic-replace) renders the prerequisite and commits the current choice once", function()
		with_replace(SOURCE, function(Config, path, state, row)
			local first = row()
			helpers.assert_type(first, "table", "the extension-owned native feature must reach the tray")
			helpers.assert_eq(first.checked, false)
			helpers.assert_type(first.fn, "function")
			helpers.assert_eq(first.fn(), true)
			helpers.assert_eq(Config.is_section_checked("magickey", "replace"), true)
			helpers.assert_eq(#state.published[#state.published], 1)
			helpers.assert_eq(state.notified, 1)
			helpers.assert_eq(state.redraw, 0, "the menu must not duplicate its owner's redraw")
			helpers.assert_true(Choices.read(path):find('choice = "preserve exact bytes" # untouched', 1, true) ~= nil)
			helpers.assert_eq(row().checked, true)
			helpers.assert_eq(first.fn(), true, "a retained callback toggles the current value")
			helpers.assert_eq(Config.is_section_checked("magickey", "replace"), false)
			helpers.assert_eq(#state.published[#state.published], 0)
			helpers.assert_eq(state.notified, 2)
		end)
	end)

	for _, refusal in ipairs({ "false", "nil", "throw", "runtime" }) do
		helpers.it("(ergopti-magic-replace) preserves source and runtime after " .. refusal, function()
			with_replace(SOURCE, function(Config, path, state, row)
				local item = row()
				helpers.assert_type(item, "table")
				local Writer, Modal = require("toml_codec.writer"), require("ui.modal")
				local previous_write, previous_modal = Writer.batch_write, Modal.run
				local writes, notices = 0, 0
				Writer.batch_write = function(...)
					writes = writes + 1
					if refusal == "throw" then error("injected canonical write refusal") end
					if refusal == "nil" then return nil end
					if refusal == "false" then return false end
					return previous_write(...)
				end
				Modal.run = function() notices = notices + 1; return true end
				state.reject = refusal == "runtime"
				local called, result = pcall(item.fn)
				Writer.batch_write, Modal.run = previous_write, previous_modal
				helpers.assert_eq(called, true)
				helpers.assert_eq(result, false)
				helpers.assert_eq(writes, refusal == "runtime" and 0 or 1)
				helpers.assert_eq(notices, 1, "a refusal is visible")
				helpers.assert_eq(Choices.read(path), SOURCE, "every original byte survives")
				helpers.assert_eq(Config.is_section_checked("magickey", "replace"), false)
				helpers.assert_eq(#state.published[#state.published], 0, "the old catalogue is republished")
				helpers.assert_eq(state.notified, 0)
				helpers.assert_eq(state.redraw, 0)
				helpers.assert_eq(row().checked, false)
			end)
		end)
	end

	helpers.it("(ergopti-magic-replace) keeps a checked choice behind a closed group", function()
		local source = SOURCE:gsub("magickey = true", "magickey = false"):gsub("replace = false", "replace = true")
		with_replace(source, function(_, path, state, row)
			local item = row()
			helpers.assert_type(item, "table")
			helpers.assert_eq(item.checked, true)
			helpers.assert_eq(item.disabled, true)
			helpers.assert_eq(item.fn, nil)
			helpers.assert_eq(Choices.read(path), source)
			helpers.assert_eq(#state.published[#state.published], 0)
		end)
	end)

	helpers.it("(ergopti-magic-replace) leaves physical source capture in Layout while replacement moves to Ergopti", function()
		with_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source)
			wire(Source, { active = true, replace = true, typed_ok = true })
			with_replace(SOURCE, function(_, _, state, row)
				state.source = Source
				local item, _, layout = row()
				helpers.assert_type(item, "table", "replacement is in its extension")
				local I18n = require("infra.i18n")
				local physical
				for _, child in ipairs(layout.menu or {}) do
					helpers.assert_true(child.title ~= I18n.get("menu.layout.replace"), "the old duplicate is removed")
					if child.title == I18n.get("menu.layout.magic_key_source") .. " : j   (KeyJ)" then physical = child end
				end
				helpers.assert_type(physical, "table")
				helpers.assert_type(physical.menu[1].fn, "function", "the capture picker remains available")
			end)
			Source._reset_for_test()
		end)
	end)

	helpers.it("(ergopti-magic-replace) refuses an old callback after its group closes", function()
		with_replace(SOURCE, function(Config, path, state, row)
			local before = row()
			helpers.assert_type(before, "table")
			helpers.assert_eq(Config.toggle_group("magickey"), true)
			local closed_source, notified = Choices.read(path), state.notified
			helpers.assert_eq(before.fn(), false)
			helpers.assert_eq(Choices.read(path), closed_source)
			helpers.assert_eq(state.notified, notified)
			helpers.assert_eq(row().disabled, true)
		end)
	end)

	helpers.it("(ergopti-magic-replace) strips paused actions and refuses an old callback", function()
		with_replace(SOURCE, function(_, path, state, row)
			local before = row()
			helpers.assert_type(before, "table")
			state.paused = true
			local paused, _, layout = row()
			helpers.assert_eq(paused, nil, "the paused layout subtree is retired")
			helpers.assert_eq(layout.disabled, true)
			helpers.assert_eq(layout.menu, nil)
			helpers.assert_eq(before.fn(), false)
			helpers.assert_eq(Choices.read(path), SOURCE)
			helpers.assert_eq(state.notified, 0)
		end)
	end)
end)


helpers.describe("magic key source: per-press repeat ownership", function()
	local function observe(mode)
		local previous = package.loaded["adapters.xkb_capture"]
		local state = { active = true, replace = true, typed_ok = true, group = 0, native_epoch = 1 }
		local observed
		local ok, err = pcall(function()
			local Capture = helpers.load_module("adapters.xkb_capture")
			Capture._set_backend({
				create = function() return {} end, destroy = function() end,
				source_group = function() return state.group, state.native_epoch end,
			})
			assert(Capture.load("fixture keymap", "C"))
			with_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source)
				local calls = wire(Source, state)
				local press = { code = KEY_J, value = 1, physical = true, origin_generation = 1, mods = {} }
				if mode == "untrusted" then press.physical = false end
				if mode == "unknown epoch" then press.origin_generation = nil end
				if mode == "unknown group" then state.group = nil end
				local consumed, repeat_callback = Source.on_key(press)
				observed = { consumed = consumed, callback = repeat_callback, calls = calls }
				if type(repeat_callback) == "function" then
					local repeat_event = { code = KEY_J, value = 2, physical = true, origin_generation = 1, mods = {} }
					if mode == "paused" then state.active = false end
					if mode == "group" then state.group = 1 end
					if mode == "origin" then repeat_event.origin_generation = 2 end
					if mode == "modified" then repeat_event.mods.shift = true end
					if mode == "injection" then state.typed_ok = false end
					if mode == "source" then assert(Source.set("KeyQ")) end
					if mode == "replacement" then state.replace = false end
					if mode == "magic" then state.magic = "ù" end
					if mode == "untrusted repeat" then repeat_event.physical = false end
					if mode == "missing modifiers" then repeat_event.mods = nil end
					if mode == "admission" then state.blocked_code = KEY_J end
					observed.first_repeat = repeat_callback(repeat_event)
					observed.second_repeat = repeat_callback(repeat_event)
				end
				Source._reset_for_test()
			end)
			Capture._reset_backend()
		end)
		package.loaded["adapters.xkb_capture"] = previous
		if not ok then error(err, 0) end
		return observed
	end

	helpers.it("(magic-source-repeat) dispatches each acknowledged repeated magic character", function()
		local state = observe("accepted")
		helpers.assert_eq(state.consumed, true)
		helpers.assert_type(state.callback, "function")
		helpers.assert_eq(state.first_repeat, true)
		helpers.assert_eq(state.second_repeat, true)
		helpers.assert_eq(state.calls.typed, { "★", "★", "★" })
		helpers.assert_eq(#state.calls.dispatched, 3)
		helpers.assert_eq(state.calls.ended, 3)
	end)
	for _, mode in ipairs({ "paused", "group", "origin", "modified", "injection", "source", "replacement", "magic",
		"untrusted repeat", "missing modifiers", "admission" }) do
		helpers.it("(magic-source-repeat) refuses a " .. mode .. " change on the held source", function()
			local state = observe(mode)
			helpers.assert_eq(state.consumed, true)
			helpers.assert_type(state.callback, "function")
			helpers.assert_eq(state.first_repeat, false)
			helpers.assert_eq(state.second_repeat, false)
			helpers.assert_eq(#state.calls.dispatched, 1, "only acknowledged output reaches the character path")
			helpers.assert_eq(state.calls.ended, 1)
		end)
	end
	for _, mode in ipairs({ "untrusted", "unknown epoch", "unknown group" }) do
		helpers.it("(magic-source-repeat) leaves an " .. mode .. " press nonrepeatable", function()
			local state = observe(mode)
			helpers.assert_eq(state.consumed, true, "the existing first-press boolean contract remains intact")
			helpers.assert_nil(state.callback)
			helpers.assert_eq(#state.calls.dispatched, 1)
		end)
	end
end)

helpers.describe("magic key source: tap assignment admission", function()
	helpers.it("(magic-key-source) configured claims refuse choice and capture without changing any bytes", function()
		with_source('[hotstrings]\nmagic_key_source = "KeyJ"\n[shortcuts.tap_keys]\nnumber_row_left = "send_text" # owned choice\n[action_parameters]\nfuture = "preserved"\n', function(Source, Preferences, path)
			local Paths = require("infra.config_paths")
			local get_path, saved = Paths.config, package.loaded["modules.shortcuts.tap_keys"]
			local called, detail = pcall(function()
				Paths.config = function(name) if name == "config.toml" then return path end return get_path(name) end
				package.loaded["modules.shortcuts.tap_keys"] = nil
				local Tap = require("modules.shortcuts.tap_keys")
				helpers.assert_eq(Tap.get_action("number_row_left"), "send_text")
				local file = assert(io.open(path, "rb")); local before = file:read("*a"); file:close()
				local state = { active = false, replace = false, typed_ok = true }
				local calls = wire(Source, state)
				local ok, reason = Source.set("Backquote")
				helpers.assert_eq(ok, false, "transient pause and replacement gates never release stored ownership")
				helpers.assert_eq(reason, Shared.TAP_CONFLICT_REASON)
				helpers.assert_eq(Source.get(), "KeyJ")
				state.active = true; state.replace = true
				local refused = {}
				helpers.assert_true(Source.capture({ on_chosen = function(value) refused[#refused + 1] = value end,
					on_refused = function(value) refused[#refused + 1] = value end }))
				helpers.assert_true(Source.on_key({ code = 41, mods = {} }))
				calls.deferred[#calls.deferred].fn()
				helpers.assert_eq(refused, { Shared.TAP_CONFLICT_REASON })
				file = assert(io.open(path, "rb")); local after = file:read("*a"); file:close()
				helpers.assert_eq(after, before, "every source/tap/future/comment byte remains unchanged")
				helpers.assert_eq(Tap.get_action("number_row_left"), "send_text")
				helpers.assert_true(Source.set("auto"))
				helpers.assert_true(Tap.set_action("number_row_left", "none"))
				helpers.assert_true(Source.set("Backquote"), "none explicitly gives the key back")
			end)
			Paths.config = get_path
			package.loaded["modules.shortcuts.tap_keys"] = saved
			if not called then error(detail, 0) end
		end)
	end)

	helpers.it("(magic-key-source) old conflicting intent refuses initial injection until actual tap admission releases it", function()
		with_source('[hotstrings]\nmagic_key_source = "Backquote"\n', function(Source)
			local state = { active = true, replace = true, typed_ok = true, blocked_code = 41 }
			local calls = wire(Source, state)
			local consumed, repeat_owner = Source.on_key({ code = 41, mods = {}, value = 1, physical = true, origin_generation = 1 })
			helpers.assert_eq(consumed, false)
			helpers.assert_nil(repeat_owner)
			helpers.assert_eq(calls.typed, {})
			helpers.assert_eq(calls.dispatched, {})
			helpers.assert_eq(calls.ended, 0)
			state.blocked_code = nil
			helpers.assert_true(Source.on_key({ code = 41, mods = {} }))
			helpers.assert_eq(calls.typed, { "★" })
		end)
	end)
end)


--- Runs actual Capture and Layout owners through the caller's later callbacks.
--- The native protocol is controlled and supplies no physical delivery authority.
--- @param body function
local function caller_cohort(body)
	local saved_capture = package.loaded["adapters.xkb_capture"]
	local saved_layout = package.loaded["adapters.keyboard_layout"]
	local capture = helpers.load_module("adapters.xkb_capture")
	local state = { group = 0, native_epoch = 7, observed = true, origin = { generation = 1, ready = true } }
	local backend = {
		create = function() return { identity = "caller-source-map", groups = 2 } end,
		destroy = function() end,
		capture_group = function()
			if state.on_group then local fn = state.on_group; state.on_group = nil; fn() end
			return state.group
		end,
		source_group = function()
			if state.on_source then local fn = state.on_source; state.on_source = nil; fn() end
			local group, epoch = state.group, state.native_epoch
			return group, epoch, function() return state.observed and state.group == group and state.native_epoch == epoch end
		end,
		direct_sources = function(_, _, group)
			return { { code = 39, text = group == 0 and ";" or "ù", mods = {}, plain = true, direct = true, dead = false } }
		end,
		inverse = function()
			local rows = {}
			for code = 32, 126 do rows[string.char(code)] = { keycode = code, level = 1, mods = {} } end
			rows[";"] = { keycode = 39, level = 1, mods = {} }
			return rows
		end,
	}
	capture._set_backend(backend)
	local path = os.tmpname()
	local file = assert(io.open(path, "w")); file:write("caller-source-map"); file:close()
	local layout = helpers.load_module("adapters.keyboard_layout")
	local called, detail = pcall(function()
		helpers.assert_true(layout.refresh(path))
		with_source(nil, function(Source, Preferences)
			local deps = {
				is_active = function() return true end, replace_on = function() return true end,
				magic_key = function() return ";" end,
				can_type = function(text) return layout.resolve(text) ~= nil end,
				typing_plan = function(text)
					if state.on_plan then state.on_plan(Source, Preferences, layout, path) end
					return layout.resolve(text)
				end,
				input_source_receipt = function() return state.origin end,
				direct_source_admitted = function()
					if state.on_admit then state.on_admit(Source, Preferences) end
					return true
				end,
				type_text = function() error("read-only source must not emit") end,
				dispatch_char = function() error("read-only source must not dispatch") end,
				end_selection = function() end, can_capture = function() return true end,
				key_text = function() return ";" end, defer = function() return false end,
			}
			Source.init(deps)
			body(Source, Preferences, capture, layout, state, path, deps)
		end)
	end)
	capture._reset_backend(); os.remove(path)
	package.loaded["adapters.xkb_capture"] = saved_capture
	package.loaded["adapters.keyboard_layout"] = saved_layout
	if not called then error(detail, 0) end
end

helpers.describe("magic key source: caller cohort after layout and admission callbacks", function()
	helpers.it("retains an unchanged actual source without typing or publishing", function()
		caller_cohort(function(Source)
			local source = Source.editor_source()
			helpers.assert_eq(source.status, "ready")
			helpers.assert_eq(source.candidates[1].text, ";")
			helpers.assert_true(source.candidates[1].direct)
		end)
	end)
	for _, kind in ipairs({ "group", "session", "preference", "origin", "source export", "collaborator", "observed issuer", "final source callback" }) do
		helpers.it("refuses a " .. kind .. " retirement after direct enumeration", function()
			caller_cohort(function(Source, Preferences, capture, layout, state, path, deps)
				local getter, replacements = capture.source_generation, 0
				state.on_plan = function()
					if kind == "group" then
						state.on_group = function() state.group = 1; state.native_epoch = state.native_epoch + 1 end
					elseif kind == "session" then helpers.assert_true(layout.refresh(path))
					elseif kind == "preference" then helpers.assert_true(Source.set("KeyJ"))
					elseif kind == "source export" then
						capture.source_generation = function() replacements = replacements + 1; return 1 end
					elseif kind == "collaborator" then deps.direct_source_admitted = function() return true end
					elseif kind == "observed issuer" then state.observed = false
					elseif kind == "final source callback" then
						state.on_source = function() helpers.assert_true(Source.set("KeyJ")) end
					end
				end
				if kind == "origin" then state.on_admit = function() state.origin.ready = false; state.origin.generation = 2 end end
				local called, result = pcall(Source.editor_source)
				capture.source_generation = getter
				if not called then error(result, 0) end
				helpers.assert_eq(result.status, "unavailable")
				helpers.assert_eq(result.candidates, {})
				helpers.assert_eq(result.reason, "direct-source-changed")
				helpers.assert_eq(replacements, 0, "replacement cannot acquire the retained source's authority")
				if kind == "preference" or kind == "final source callback" then helpers.assert_eq(Source.get(), "KeyJ") end
			end)
		end)
	end
end)

helpers.describe("independent final-source-callback origin currency", function()
 helpers.it("refuses origin retirement after the earlier origin rejoin", function()
  caller_cohort(function(Source, Preferences, capture, layout, state)
   state.on_plan = function()
    state.on_source = function() state.origin.ready = false; state.origin.generation = 2 end
   end
   local result = Source.editor_source()
   helpers.assert_eq(state.origin.ready, false, "the final native callback withdrew origin")
   helpers.assert_eq(result.status, "unavailable", "origin must rejoin after the final source callback")
   helpers.assert_eq(result.candidates, {})
  end)
 end)
end)

helpers.describe("independent final-origin-callback capture currency", function()
 helpers.it("refuses same-map capture replacement during final origin rejoin", function()
  caller_cohort(function(Source, Preferences, capture, layout, state, path, deps)
   local reads, fired = 0, false
   deps.input_source_receipt = function()
    reads = reads + 1
    if reads == 2 then fired = true; helpers.assert_true(layout.refresh(path)) end
    return { generation = state.origin.generation, ready = state.origin.ready }
   end
   local result = Source.editor_source()
   helpers.assert_true(fired, "the final origin getter replaced the actual capture session")
   helpers.assert_eq(result.status, "unavailable", "same-map Capture retirement must survive the final origin callback")
   helpers.assert_eq(result.candidates, {})
  end)
 end)
end)

helpers.describe("editor source: retained Capture RAM owner", function()
	helpers.it("a native issuer closure cannot survive same-map Capture replacement", function()
		caller_cohort(function(_, _, capture, layout, _, path)
			local generation, _, current = capture.source_generation()
			helpers.assert_type(generation, "number")
			helpers.assert_type(current, "function")
			helpers.assert_true(current())
			helpers.assert_true(layout.refresh(path))
			helpers.assert_eq(current(), false, "issuer identity alone cannot keep a destroyed Capture session current")
		end)
	end)

	helpers.it("a source query cannot borrow the session its callback created", function()
		caller_cohort(function(_, _, capture, layout, state, path)
			state.on_source = function() helpers.assert_true(layout.refresh(path)) end
			local generation, reason, current = capture.source_generation()
			helpers.assert_nil(generation)
			helpers.assert_eq(reason, "native-source-owner-changed")
			helpers.assert_nil(current)
		end)
	end)

	helpers.it("does not manufacture an issuer for an unsealed controlled source tuple", function()
		caller_cohort(function(_, _, capture, _, state)
			local backend
			for index = 1, 100 do
				local name, value = debug.getupvalue(capture.source_generation, index)
				if name == "_backend" then backend = value; break end
				if not name then break end
			end
			-- The predecessor exports source_identity directly through its wrapper.
			if not backend then
				local _, identity = debug.getupvalue(capture.source_generation, 1)
				for index = 1, 100 do
					local name, value = debug.getupvalue(identity, index)
					if name == "_backend" then backend = value; break end
					if not name then break end
				end
			end
			helpers.assert_type(backend, "table")
			backend.source_group = function() return state.group, state.native_epoch end
			local generation, _, current = capture.source_generation()
			helpers.assert_type(generation, "number")
			helpers.assert_nil(current, "RAM owner wrapping cannot upgrade absent native issuer evidence")
		end)
	end)
end)


-- Native notice title policy does not own the physical source or its body.
local native_caption_file = assert(io.open(helpers.driver_root()
	.. "/../_shared/tests/corpus/native_presentations/original_captions.json", "rb"))
local native_caption_read, native_caption_bytes = pcall(function() return native_caption_file:read("*a") end)
local native_caption_closed, native_caption_close = pcall(function() return native_caption_file:close() end)
if not native_caption_read then error(native_caption_bytes, 0) end
assert(native_caption_closed and native_caption_close ~= nil and native_caption_close ~= false)
local native_caption_corpus = assert(Json.decode(native_caption_bytes))

local magic_notice_module_names = { "ui.menu.menu_builder", "infra.native_presentation", "adapters.application_notifier",
	"infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu" }

-- A caller catching an expected primary must also consume cleanup_failures.
-- Normal positive subjects fail on any cleanup refusal after all attempts finish.
local function with_magic_notice(body, cleanup_failures)
	cleanup_failures = cleanup_failures or {}
	local cache, saved = package.loaded, {}
	for _, name in ipairs(magic_notice_module_names) do saved[name] = rawget(cache, name) end
	local Locale, I18n, previous_locale, locale_captured, policy, lookup_owner, lookup_captured
	local function restore(operation, fn)
		local restored, failure = pcall(fn)
		if not restored then cleanup_failures[#cleanup_failures + 1] = { operation = operation, failure = failure } end
	end
	-- Protection starts before the first owned cache edit, including setup imports.
	local ok, failure = pcall(function()
		for _, name in ipairs(magic_notice_module_names) do rawset(cache, name, nil) end
		Locale, I18n = require("infra.locale"), require("infra.i18n")
		previous_locale = Locale.current_locale()
		locale_captured = true
		policy = require("window_titles")
		lookup_owner, lookup_captured = policy.native_presentation, true
		local notices = {}
		rawset(cache, "adapters.application_notifier", { send = function(message, options)
			notices[#notices + 1] = { message = message, title = options.title, level = options.level }
			return true
		end })
		with_source(nil, function(Source)
			local settled, primary = pcall(function()
				local calls = wire(Source, { active = true, replace = true, typed_ok = true })
				local Builder = require("ui.menu.menu_builder")
				local changed = 0
				local items = Builder.build({ on_quit = function() end, magic_key_source = Source,
					on_menu_changed = function() changed = changed + 1 end })
				local capture
				local function find(rows)
					for _, row in ipairs(rows or {}) do
						if row.title == I18n.get("menu.layout.magic_key_source.capture") then capture = row.fn end
						find(row.menu)
					end
				end
				find(items)
				helpers.assert_type(capture, "function", "actual physical capture command must exist")
				body({ source = Source, calls = calls, capture = capture, notices = notices,
					locale = Locale, i18n = I18n, changed = function() return changed end,
					policy = policy, native = require("infra.native_presentation") })
			end)
			-- The genuine reset returns nil; only a thrown failure is refusal here.
			restore("physical_source_reset", function() Source._reset_for_test() end)
			if not settled then error(primary, 0) end
		end)
	end)
	if lookup_captured then
		restore("native_policy_lookup", function()
			policy.native_presentation = lookup_owner
			assert(rawequal(policy.native_presentation, lookup_owner), "native policy lookup was not restored")
		end)
	end
	if locale_captured then
		restore("locale_selection", function()
			Locale.set_locale(previous_locale)
			assert(Locale.current_locale() == previous_locale, "fixture locale was not restored")
		end)
	end
	for _, name in ipairs(magic_notice_module_names) do
		restore("package.loaded:" .. name, function()
			rawset(cache, name, saved[name])
			assert(rawequal(rawget(cache, name), saved[name]), "fixture module cache was not restored")
		end)
	end
	if not ok then error(failure, 0) end
	if #cleanup_failures > 0 then error(cleanup_failures[1].failure, 0) end
end

helpers.describe("declared physical magic notice captions", function()
	for code, original in pairs(native_caption_corpus.locales) do
		helpers.it("(native-magic-caption) receives original notice title/body through actual capture in " .. code, function()
			with_magic_notice(function(f)
				f.locale.set_locale(code)
				f.capture()
				helpers.assert_eq(f.notices[1], { title = original.captions.magic_key_source_notice.original_bare_caption,
					message = f.i18n.get("dialog.magic_key_source.prompt"), level = "info" })
				helpers.assert_true(f.source.on_key({ code = 57, mods = {} }))
				run_due(f.calls)
				helpers.assert_eq(f.notices[2], { title = original.captions.magic_key_source_notice.original_bare_caption,
					message = f.i18n.get("dialog.magic_key_source.not_a_candidate"), level = "warning" })
				helpers.assert_eq(f.source.get(), "auto")
				helpers.assert_eq(f.changed(), 0)
				helpers.assert_eq(f.calls.typed, {})
			end)
		end)
	end
	helpers.it("(native-magic-caption) actual declaration withdrawal refuses delivery and exact repair preserves capture", function()
		with_magic_notice(function(f)
			local original, observed = f.policy.native_presentation, 0
			f.policy.native_presentation = function() observed = observed + 1; return {} end
			f.capture()
			helpers.assert_eq(f.notices, {})
			helpers.assert_eq(observed, 0)
			helpers.assert_true(f.source.on_key({ code = 1, mods = {} }))
			run_due(f.calls)
			f.policy.native_presentation = original
			f.capture()
			helpers.assert_eq(#f.notices, 1)
			helpers.assert_eq(f.notices[1].title, f.i18n.get("dialog.magic_key_source.title"))
			helpers.assert_eq(f.source.get(), "auto")
		end)
	end)
	helpers.it("(native-magic-caption) wrong kind, platform, borrowed receipt and locale drift refuse bare titles", function()
		with_magic_notice(function(f)
			helpers.assert_nil(f.native.prepare("magic_key_source_notice", "dialog"))
			helpers.assert_nil(f.native.prepare("profile_shortcut_dialog", "dialog"))
			helpers.assert_nil(f.native.title({}))
			f.locale.set_locale("fr")
			local receipt = f.native.prepare("magic_key_source_notice", "notification")
			helpers.assert_type(receipt, "table")
			f.locale.set_locale("es")
			helpers.assert_nil(f.native.title(receipt))
			f.locale.set_locale("fr")
			helpers.assert_eq(f.native.title(receipt), native_caption_corpus.locales.fr.captions.magic_key_source_notice.original_bare_caption)
		end)
	end)
end)

local function magic_notice_cache_snapshot()
	local saved = {}
	for _, name in ipairs(magic_notice_module_names) do saved[name] = rawget(package.loaded, name) end
	return saved
end

local function assert_magic_notice_cache_restored(saved)
	for _, name in ipairs(magic_notice_module_names) do
		helpers.assert_true(rawequal(rawget(package.loaded, name), saved[name]), "exact original module restored: " .. name)
	end
end

helpers.describe("physical magic notice fixture lifecycle", function()
	helpers.it("(native-magic-caption-lifecycle) setup import failure restores every owned cache entry", function()
		local saved, primary, secondary = magic_notice_cache_snapshot(), {}, {}
		local preload, original = package.preload, package.preload["infra.locale"]
		local ok, failure = pcall(function()
			rawset(preload, "infra.locale", function() error(primary, 0) end)
			with_magic_notice(function() error("setup failure must prevent scenario entry", 0) end, secondary)
		end)
		local restored, restore_failure = pcall(function() rawset(preload, "infra.locale", original) end)
		helpers.assert_true(restored, restore_failure)
		helpers.assert_true(rawequal(rawget(preload, "infra.locale"), original))
		helpers.assert_eq(ok, false)
		helpers.assert_true(rawequal(failure, primary), "setup primary object must survive independent cleanup")
		helpers.assert_eq(secondary, {})
		assert_magic_notice_cache_restored(saved)
	end)
	helpers.it("(native-magic-caption-lifecycle) scenario primary survives real policy locale and cache restoration", function()
		local saved, primary, secondary = magic_notice_cache_snapshot(), {}, {}
		local owner, lookup, locale, previous
		local ok, failure = pcall(function()
			with_magic_notice(function(f)
				owner, lookup, locale, previous = f.policy, f.policy.native_presentation, f.locale, f.locale.current_locale()
				f.policy.native_presentation = function() return {} end
				f.locale.set_locale(previous == "es" and "fr" or "es")
				error(primary, 0)
			end, secondary)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_true(rawequal(failure, primary))
		helpers.assert_eq(secondary, {})
		helpers.assert_true(rawequal(owner.native_presentation, lookup))
		helpers.assert_eq(locale.current_locale(), previous)
		assert_magic_notice_cache_restored(saved)
	end)
	helpers.it("(native-magic-caption-lifecycle) simultaneous reset failure remains separate while later restores complete", function()
		local saved, primary, cleanup_primary, secondary = magic_notice_cache_snapshot(), {}, {}, {}
		local source, reset, owner, lookup, locale, previous
		local ok, failure = pcall(function()
			with_magic_notice(function(f)
				source, reset = f.source, f.source._reset_for_test
				owner, lookup, locale, previous = f.policy, f.policy.native_presentation, f.locale, f.locale.current_locale()
				source._reset_for_test = function() reset(); error(cleanup_primary, 0) end
				f.policy.native_presentation = function() return {} end
				f.locale.set_locale(previous == "es" and "fr" or "es")
				error(primary, 0)
			end, secondary)
		end)
		-- Restore the control's own function replacement even if the scenario failed.
		local restored, restore_failure = pcall(function() source._reset_for_test = reset end)
		helpers.assert_true(restored, restore_failure)
		helpers.assert_true(rawequal(source._reset_for_test, reset))
		helpers.assert_eq(ok, false)
		helpers.assert_true(rawequal(failure, primary), "cleanup failure must not replace the scenario primary")
		helpers.assert_eq(#secondary, 1)
		helpers.assert_eq(secondary[1].operation, "physical_source_reset")
		helpers.assert_true(rawequal(secondary[1].failure, cleanup_primary))
		helpers.assert_true(rawequal(owner.native_presentation, lookup))
		helpers.assert_eq(locale.current_locale(), previous)
		assert_magic_notice_cache_restored(saved)
	end)
end)

helpers.describe("magic key source: capture answer queue admission", function()
	for _, mode in ipairs({ "refuse", "throw", "premature" }) do
		helpers.it("keeps the physical key native and the capture retryable after " .. mode, function()
			with_source(nil, function(Source, Preferences, path)
				local state = { active = true, replace = true, typed_ok = true, answer = mode }
				local calls = wire(Source, state)
				local chosen, refused = {}, {}
				local handlers = {
					on_chosen = function(value) chosen[#chosen + 1] = value end,
					on_refused = function(reason) refused[#refused + 1] = reason end,
				}
				helpers.assert_true(Source.capture(handlers))
				helpers.assert_eq(Source.on_key({ code = KEY_J, mods = {} }), false)
				run_due(calls)
				helpers.assert_eq(chosen, {})
				helpers.assert_eq(refused, {})
				helpers.assert_eq(Source.get(), "auto")
				local handle = io.open(path, "rb")
				if handle then handle:close() end
				helpers.assert_nil(handle, "refused scheduling creates no preference document")
				helpers.assert_eq(Source.capture(handlers), false, "the original timed capture remains owned")
				state.answer = nil
				helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
				helpers.assert_eq(chosen, {}, "persistence remains outside the key callback")
				run_due(calls)
				helpers.assert_eq(chosen, { "KeyJ" })
				helpers.assert_eq(Source.get(), "KeyJ")
				helpers.assert_eq(#calls.typed, 0)
				helpers.assert_eq(#calls.dispatched, 0)
				Source._reset_for_test()
			end)
		end)
	end
end)

--- Compiles the genuine daemon pause callback over explicit non-input ports.
--- The ScriptActions owner still executes its real toggle/notification path.
--- @param Source table Actual initialized magic-key owner.
--- @param state table Live activity observed by the recording input ports.
--- @return table controller Actual script-actions controller.
local function capture_pause_controller(Source, state)
	local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
	local source = file:read("*a"); assert(file:close())
	local marker = "on_pause_change = function(paused)"
	local first, last = source:find(marker, 1, true)
	assert(first and last, "The genuine daemon pause callback must exist")
	local finish = assert(source:find("\n\t\tend,\n\t})", last + 1, true))
	local body = source:sub(last + 1, finish - 1)
	local callback = assert(load("return function(paused)" .. body .. "\nend", "genuine-daemon-pause", "t", {
		MagicKeySource = Source,
		keylogger = require("modules.keylogger.keylogger"),
		TapHold = { set_paused = function() end },
		package = { loaded = {} },
	}))()
	return require("modules.shortcuts.script_actions").new({
		reset = function() end, reload = function() end, quit = function() end,
		on_pause_change = function(paused)
			state.active = not paused
			callback(paused)
		end,
	})
end

helpers.describe("magic key source: genuine pause notification retires captures", function()
	for _, stage in ipairs({ "waiting", "answered", "roundtrip" }) do
		helpers.it("discards a " .. stage .. " capture at the real daemon pause callback", function()
			with_source(nil, function(Source, Preferences, path)
				local state = { active = true, replace = true, typed_ok = true }
				local calls = wire(Source, state)
				local controller = capture_pause_controller(Source, state)
				local chosen = {}
				local handlers = { on_chosen = function(value) chosen[#chosen + 1] = value end, on_refused = function() end }
				helpers.assert_true(Source.capture(handlers))
				if stage ~= "waiting" then helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} })) end
				controller.toggle_pause()
				if stage == "roundtrip" then controller.toggle_pause() end
				if stage == "waiting" then helpers.assert_eq(Source.on_key({ code = KEY_J, mods = {} }), false) end
				run_due(calls)
				helpers.assert_eq(chosen, {})
				helpers.assert_eq(Source.get(), "auto")
				local file = io.open(path, "rb"); if file then file:close() end
				helpers.assert_nil(file, "retired capture cannot create preferences")
				if stage ~= "roundtrip" then controller.toggle_pause() end
				helpers.assert_true(Source.capture(handlers), "resume permits a fresh capture, not the old choice")
				helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
				run_due(calls)
				helpers.assert_eq(chosen, { "KeyJ" })
				Source._reset_for_test()
			end)
		end)
	end

	for _, stage in ipairs({ "before_press", "after_answer" }) do
		helpers.it("refuses capture input after grab loss " .. stage, function()
			with_source(nil, function(Source)
				local state = { active = true, replace = true, typed_ok = true }
				local calls = wire(Source, state)
				local chosen = {}
				local handlers = { on_chosen = function(value) chosen[#chosen + 1] = value end, on_refused = function() end }
				helpers.assert_true(Source.capture(handlers))
				if stage == "after_answer" then helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} })) end
				state.grab = false
				if stage == "before_press" then helpers.assert_eq(Source.on_key({ code = KEY_J, mods = {} }), false) end
				run_due(calls)
				helpers.assert_eq(chosen, {})
				helpers.assert_eq(Source.get(), "auto")
				state.grab = true
				helpers.assert_true(Source.capture(handlers))
				Source._reset_for_test()
			end)
		end)
	end

	helpers.it("leaves the physical key native if pause and resume occur inside deferred submission", function()
		with_source(nil, function(Source)
			local state = { active = true, replace = true, typed_ok = true }
			local calls = wire(Source, state)
			local controller = capture_pause_controller(Source, state)
			local chosen = {}
			local handlers = { on_chosen = function(value) chosen[#chosen + 1] = value end, on_refused = function() end }
			helpers.assert_true(Source.capture(handlers))
			state.answer_pause = function() controller.toggle_pause(); controller.toggle_pause() end
			helpers.assert_eq(Source.on_key({ code = KEY_J, mods = {} }), false)
			run_due(calls)
			helpers.assert_eq(chosen, {})
			helpers.assert_eq(Source.get(), "auto")
			helpers.assert_true(Source.capture(handlers))
			Source._reset_for_test()
		end)
	end)
end)


helpers.describe("magic key source: newer admitted capture requests fence queued predecessors", function()
	local function handlers(chosen)
		return { on_chosen = function(value) chosen[#chosen + 1] = value end,
			on_refused = function() error("This declared candidate should not be refused") end }
	end
	helpers.it("a fresh admitted B fences queued A while preserving B and its later answer", function()
		with_source(nil, function(Source, Preferences, path)
			local calls = wire(Source, { active = true, replace = true, typed_ok = true })
			local a, b = {}, {}
			helpers.assert_true(Source.capture(handlers(a)))
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
			helpers.assert_true(Source.capture(handlers(b)), "a fresh request can start after A answer admission")
			run_due(calls)
			helpers.assert_eq(a, {}, "the superseded A callback must not notify")
			helpers.assert_eq(b, {})
			helpers.assert_eq(Source.get(), "auto", "the superseded A callback must not persist")
			local file = io.open(path, "rb"); if file then file:close() end
			helpers.assert_nil(file, "A cannot create a preference document after B admission")
			helpers.assert_eq(Source.capture(handlers({})), false, "B remains the exact pending capture")
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
			run_due(calls)
			helpers.assert_eq(a, {})
			helpers.assert_eq(b, { "KeyJ" })
			Source._reset_for_test()
		end)
	end)
	helpers.it("a refused B timeout grants no generation authority over acknowledged A", function()
		with_source(nil, function(Source)
			local state = { active = true, replace = true, typed_ok = true, fail_arm = false }
			local actual_init = Source.init
			Source.init = function(dependencies)
				local actual_defer = dependencies.defer
				dependencies.defer = function(callback, delay)
					if delay > 0 and state.fail_arm then return false end
					return actual_defer(callback, delay)
				end
				return actual_init(dependencies)
			end
			local calls = wire(Source, state); Source.init = actual_init
			local a, b = {}, {}
			helpers.assert_true(Source.capture(handlers(a)))
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
			state.fail_arm = true
			helpers.assert_eq(Source.capture(handlers(b)), false)
			run_due(calls)
			helpers.assert_eq(a, { "KeyJ" }, "unadmitted B cannot invalidate the accepted prior answer")
			helpers.assert_eq(b, {})
			Source._reset_for_test()
		end)
	end)
	helpers.it("stale A submission cannot cancel B created by a reentrant answer callback", function()
		with_source(nil, function(Source)
			local state = { active = true, replace = true, typed_ok = true }
			local calls = wire(Source, state)
			local a, b = {}, {}
			helpers.assert_true(Source.capture(handlers(a)))
			state.answer_pause = function()
				state.answer_pause = nil
				Source.cancel_capture()
				helpers.assert_true(Source.capture(handlers(b)), "reentrant B must actually be admitted")
			end
			helpers.assert_eq(Source.on_key({ code = KEY_J, mods = {} }), false)
			helpers.assert_eq(Source.capture(handlers({})), false, "the stale mismatch path must preserve B")
			run_due(calls)
			helpers.assert_eq(a, {})
			helpers.assert_eq(Source.get(), "auto")
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
			run_due(calls)
			helpers.assert_eq(a, {})
			helpers.assert_eq(b, { "KeyJ" })
			Source._reset_for_test()
		end)
	end)
end)


helpers.describe("magic key source: native timeout throw is a refused capture admission", function()
	local function timed_throw_source(Source, state)
		local init = Source.init
		Source.init = function(dependencies)
			local actual_defer = dependencies.defer
			dependencies.defer = function(callback, delay)
				if delay > 0 and state.throw_arm then
					if state.reentrant then state.reentrant() end
					error("Controlled native timeout submission refusal")
				end
				return actual_defer(callback, delay)
			end
			return init(dependencies)
		end
		local calls = wire(Source, state); Source.init = init
		return calls
	end
	local function answer(chosen)
		return { on_chosen = function(value) chosen[#chosen + 1] = value end,
			on_refused = function() error("Timed admission failure must not publish a choice") end }
	end
	helpers.it("returns false instead of propagating an initial native timeout exception", function()
		with_source(nil, function(Source)
			local state = { active = true, replace = true, typed_ok = true, throw_arm = true }
			timed_throw_source(Source, state)
			local called, started = pcall(Source.capture, answer({}))
			helpers.assert_true(called, "native timer refusal must remain a typed false result")
			helpers.assert_eq(started, false, "a thrown timeout was not admitted")
			Source._reset_for_test()
		end)
	end)
	helpers.it("does not leak the capture slot after a throwing initial timeout", function()
		with_source(nil, function(Source)
			local state = { active = true, replace = true, typed_ok = true, throw_arm = true }
			local calls = timed_throw_source(Source, state)
			local failed, fresh = {}, {}
			pcall(Source.capture, answer(failed))
			state.throw_arm = false
			helpers.assert_true(Source.capture(answer(fresh)), "the failed candidate must release only its own slot")
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
			run_due(calls)
			helpers.assert_eq(failed, {})
			helpers.assert_eq(fresh, { "KeyJ" })
			Source._reset_for_test()
		end)
	end)
	helpers.it("preserves queued A generation when B timeout submission throws", function()
		with_source(nil, function(Source)
			local state = { active = true, replace = true, typed_ok = true, throw_arm = false }
			local calls = timed_throw_source(Source, state)
			local a, b = {}, {}
			helpers.assert_true(Source.capture(answer(a)))
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
			state.throw_arm = true
			local called, started = pcall(Source.capture, answer(b))
			run_due(calls)
			helpers.assert_eq(a, { "KeyJ" }, "B acquired no generation authority over the prior acknowledged A")
			helpers.assert_eq(b, {})
			helpers.assert_true(called)
			helpers.assert_eq(started, false)
			state.throw_arm = false
			helpers.assert_true(Source.capture(answer({})), "failed B must leave no hidden capture debt")
			Source._reset_for_test()
		end)
	end)
	helpers.it("failed A timeout cannot cancel reentrant admitted B", function()
		with_source(nil, function(Source)
			local state = { active = true, replace = true, typed_ok = true, throw_arm = true }
			local calls = timed_throw_source(Source, state)
			local a, b = {}, {}
			state.reentrant = function()
				state.reentrant, state.throw_arm = nil, false
				Source.cancel_capture()
				helpers.assert_true(Source.capture(answer(b)))
			end
			local called, started = pcall(Source.capture, answer(a))
			helpers.assert_true(called)
			helpers.assert_eq(started, false)
			helpers.assert_eq(Source.capture(answer({})), false, "reentrant B remains the exact admitted owner")
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
			run_due(calls)
			helpers.assert_eq(a, {})
			helpers.assert_eq(b, { "KeyJ" })
			Source._reset_for_test()
		end)
	end)
end)

--- Keeps the real cached preference owner and exact source route in one fixture.
local function with_collision_source(content, body)
	local saved = package.loaded["infra.config_paths"]
	local routed
	package.loaded["infra.config_paths"] = { config = function() return routed end }
	local ok, why = pcall(function()
		with_source(content, function(Source, Preferences, path)
			routed = path
			body(Source, Preferences, path)
		end)
	end)
	package.loaded["infra.config_paths"] = saved
	if not ok then error(why, 0) end
end

helpers.describe("configured Magic Key collision receipt", function()
	helpers.it("(magic-collision) observes the real plain replacement consumer without typing during capture", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source)
			local calls = wire(Source, { active = true, replace = true, typed_ok = true })
			local frame = assert(Source.capture_collision_inventory())
			helpers.assert_eq(frame.claims, { { kind = "chord", binding = "magic_key_source__replacement", code = 36, mods = {} } })
			helpers.assert_true(frame.current()); helpers.assert_true(frame.sealed())
			helpers.assert_eq(calls.typed, {}); helpers.assert_eq(calls.dispatched, {})
			helpers.assert_true(Source.on_key({ code = 36, mods = {} }))
			helpers.assert_eq(calls.typed, { "★" }); helpers.assert_eq(calls.dispatched, { { char = "★", code = 36 } })
		end)
	end)
	for _, case in ipairs({
		{ name = "absent automatic source", content = nil, state = { active = true, replace = true } },
		{ name = "explicit automatic source", content = '[hotstrings]\nmagic_key_source = "auto"\n', state = { active = true, replace = true } },
		{ name = "paused owner", state = { active = false, replace = true } },
		{ name = "replacement switched off", state = { active = true, replace = false } },
		{ name = "untypable replacement", state = { active = true, replace = true, typable = false } },
		{ name = "prior native owner refusal", state = { active = true, replace = true, blocked_code = 36 } },
	}) do
		helpers.it("(magic-collision) has no replacement reservation for " .. case.name, function()
			local content = case.content
			if not case.name:find("automatic", 1, true) then content = '[hotstrings]\nmagic_key_source = "KeyJ"\n' end
			with_collision_source(content, function(Source)
				local calls = wire(Source, case.state)
				local frame = assert(Source.capture_collision_inventory())
				helpers.assert_eq(frame.claims, {}); helpers.assert_true(frame.current())
				helpers.assert_eq(Source.on_key({ code = 36, mods = {} }), false)
				helpers.assert_eq(calls.typed, {}); helpers.assert_eq(calls.dispatched, {})
			end)
		end)
	end
	helpers.it("(magic-collision) refuses waiting and accepted queued choices until real settlement", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source)
			local calls, chosen = wire(Source, { active = true, replace = true, typed_ok = true }), {}
			helpers.assert_true(Source.capture({ on_chosen = function(value) chosen[#chosen + 1] = value end, on_refused = function() error("candidate is admitted") end }))
			helpers.assert_nil(Source.capture_collision_inventory())
			helpers.assert_true(Source.on_key({ code = 46, mods = {} }))
			helpers.assert_eq(chosen, {}, "the accepted key has not yet published its preference")
			helpers.assert_nil(Source.capture_collision_inventory(), "_capture is now nil but the genuine queued setter remains pending")
			run_due(calls)
			helpers.assert_eq(chosen, { "KeyC" })
			local frame = assert(Source.capture_collision_inventory())
			helpers.assert_eq(frame.claims[1].code, 46); helpers.assert_true(frame.current())
			helpers.assert_eq(calls.typed, {}); helpers.assert_eq(calls.dispatched, {})
		end)
	end)
	helpers.it("(magic-collision) cancellation withdraws a queued choice without retiring a successor", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source)
			local calls, chosen = wire(Source, { active = true, replace = true, typed_ok = true }), {}
			helpers.assert_true(Source.capture({ on_chosen = function(value) chosen[#chosen + 1] = value end, on_refused = function() error("cancelled request must not notify") end }))
			helpers.assert_true(Source.on_key({ code = 46, mods = {} }))
			Source.cancel_capture()
			local successor = assert(Source.capture_collision_inventory())
			run_due(calls)
			helpers.assert_eq(chosen, {}); helpers.assert_eq(Source.get(), "KeyJ")
			helpers.assert_true(successor.current()); helpers.assert_eq(successor.claims[1].code, 36)
		end)
	end)
	helpers.it("(magic-collision) real preference acquisition and inverse revoke the original frame", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source, Preferences)
			wire(Source, { active = true, replace = true, typed_ok = true })
			local frame, snapshot, token = assert(Source.capture_collision_inventory()), assert(Preferences.snapshot()), {}
			helpers.assert_true(Preferences.acquire(token)); helpers.assert_eq(frame.current(), false)
			helpers.assert_nil(Source.capture_collision_inventory())
			helpers.assert_true(Preferences.adopt(token, snapshot.document))
			helpers.assert_true(Preferences.restore(token, snapshot)); helpers.assert_true(Preferences.release(token))
			helpers.assert_eq(frame.current(), false, "restoring equal values cannot restore the old preference generation")
			helpers.assert_true(assert(Source.capture_collision_inventory()).current())
		end)
	end)
	helpers.it("(magic-collision) refuses changed source bytes before the preference cache refresh", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source, Preferences, path)
			wire(Source, { active = true, replace = true, typed_ok = true })
			local frame, generation = assert(Source.capture_collision_inventory()), Preferences.generation()
			local file = assert(io.open(path, "wb")); file:write('[hotstrings]\nmagic_key_source = "KeyC"\n'); file:close()
			helpers.assert_eq(Preferences.generation(), generation)
			helpers.assert_eq(frame.current(), false); helpers.assert_nil(Source.capture_collision_inventory())
			helpers.assert_true(Preferences.refresh())
			local fresh = assert(Source.capture_collision_inventory())
			helpers.assert_eq(fresh.claims[1].code, 46); helpers.assert_true(fresh.current())
		end)
	end)
	helpers.it("(magic-collision) late initialization revokes the known inactive constructor frame", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source)
			local frame = assert(Source.capture_collision_inventory())
			helpers.assert_eq(frame.claims, {}); helpers.assert_true(frame.current())
			wire(Source, { active = true, replace = true, typed_ok = true })
			helpers.assert_eq(frame.current(), false)
			helpers.assert_eq(assert(Source.capture_collision_inventory()).claims[1].code, 36)
		end)
	end)
end)

helpers.describe("accepted Magic choice observation ends on every callback exit", function()
	helpers.it("(magic-pending-finally) chosen handler error propagates after real publication without retaining observation debt", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source)
			local calls = wire(Source, { active = true, replace = true, typed_ok = true })
			local primary, chosen = {}, {}
			helpers.assert_true(Source.capture({
				on_chosen = function(value) chosen[#chosen + 1] = value; error(primary, 0) end,
				on_refused = function() error("the real setter must accept KeyC") end,
			}))
			helpers.assert_true(Source.on_key({ code = 46, mods = {} }))
			helpers.assert_nil(Source.capture_collision_inventory())
			local ok, failure = pcall(run_due, calls)
			helpers.assert_eq(ok, false); helpers.assert_true(rawequal(failure, primary))
			helpers.assert_eq(chosen, { "KeyC" }); helpers.assert_eq(Source.get(), "KeyC")
			local frame = assert(Source.capture_collision_inventory())
			helpers.assert_eq(frame.claims[1].code, 46); helpers.assert_true(frame.current())
			helpers.assert_eq(calls.typed, {}); helpers.assert_eq(calls.dispatched, {})
		end)
	end)
	helpers.it("(magic-pending-finally) refused handler error propagates after real setter refusal without retaining observation debt", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source, _, path)
			local calls = wire(Source, { active = true, replace = true, typable = false })
			local primary, refused = {}, {}
			local file = assert(io.open(path, "rb")); local before = file:read("*a"); file:close()
			helpers.assert_true(Source.capture({
				on_chosen = function() error("the real untypable setter must refuse") end,
				on_refused = function(reason) refused[#refused + 1] = reason; error(primary, 0) end,
			}))
			helpers.assert_true(Source.on_key({ code = 46, mods = {} }))
			local ok, failure = pcall(run_due, calls)
			helpers.assert_eq(ok, false); helpers.assert_true(rawequal(failure, primary))
			helpers.assert_eq(refused, { "dialog.magic_key_source.untypable" }); helpers.assert_eq(Source.get(), "KeyJ")
			file = assert(io.open(path, "rb")); local after = file:read("*a"); file:close()
			helpers.assert_eq(after, before)
			local frame = assert(Source.capture_collision_inventory())
			helpers.assert_eq(frame.claims, {}); helpers.assert_true(frame.current())
			helpers.assert_eq(calls.typed, {}); helpers.assert_eq(calls.dispatched, {})
		end)
	end)
	helpers.it("(magic-pending-finally) deferred readiness error propagates without a setter or retained observation debt", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source, _, path)
			local primary, throwing, notified = {}, false, 0
			local state = setmetatable({ active = true, replace = true, typed_ok = true }, {
				__index = function(_, name) if name == "grab" and throwing then error(primary, 0) end end,
			})
			local calls = wire(Source, state)
			local file = assert(io.open(path, "rb")); local before = file:read("*a"); file:close()
			helpers.assert_true(Source.capture({ on_chosen = function() notified = notified + 1 end,
				on_refused = function() notified = notified + 1 end }))
			helpers.assert_true(Source.on_key({ code = 46, mods = {} }))
			throwing = true
			local ok, failure = pcall(run_due, calls)
			throwing = false
			helpers.assert_eq(ok, false); helpers.assert_true(rawequal(failure, primary))
			helpers.assert_eq(notified, 0); helpers.assert_eq(Source.get(), "KeyJ")
			file = assert(io.open(path, "rb")); local after = file:read("*a"); file:close()
			helpers.assert_eq(after, before)
			local frame = assert(Source.capture_collision_inventory())
			helpers.assert_eq(frame.claims[1].code, 36); helpers.assert_true(frame.current())
		end)
	end)
	helpers.it("(magic-pending-finally) throwing predecessor cannot clear an accepted reentrant successor choice", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source)
			local calls = wire(Source, { active = true, replace = true, typed_ok = true })
			local primary, successor = {}, {}
			helpers.assert_true(Source.capture({ on_chosen = function()
				helpers.assert_true(Source.capture({ on_chosen = function(value) successor[#successor + 1] = value end,
					on_refused = function() error("successor must accept its genuine key") end }))
				helpers.assert_true(Source.on_key({ code = 36, mods = {} }))
				error(primary, 0)
			end, on_refused = function() error("predecessor must accept its genuine key") end }))
			helpers.assert_true(Source.on_key({ code = 46, mods = {} }))
			local ok, failure = pcall(run_due, calls)
			helpers.assert_eq(ok, false); helpers.assert_true(rawequal(failure, primary))
			helpers.assert_eq(Source.get(), "KeyC"); helpers.assert_eq(successor, {})
			helpers.assert_nil(Source.capture_collision_inventory(), "the successor still owns a real deferred setter")
			run_due(calls)
			helpers.assert_eq(successor, { "KeyJ" }); helpers.assert_eq(Source.get(), "KeyJ")
			local frame = assert(Source.capture_collision_inventory())
			helpers.assert_eq(frame.claims[1].code, 36); helpers.assert_true(frame.current())
			helpers.assert_eq(calls.typed, {}); helpers.assert_eq(calls.dispatched, {})
		end)
	end)
end)
