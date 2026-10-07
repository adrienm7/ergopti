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
				Config.init({ load_mappings = function(_, mappings)
					state.published[#state.published + 1] = mappings
					return not (state.reject and #state.published == 2)
				end }, "virtual.toml", function() state.notified = state.notified + 1 end)
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
