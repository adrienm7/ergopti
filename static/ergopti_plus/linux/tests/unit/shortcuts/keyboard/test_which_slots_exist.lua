--- tests/unit/shortcuts/keyboard/test_which_slots_exist.lua

--- ==============================================================================
--- MODULE: The User\'s Own Modifier Chords
--- DESCRIPTION:
--- Configurable keyboard shortcuts on Linux: which chord matches which slot,
--- what survives a restart, and what the metrics record.
---
--- WHAT WAS MISSING:
--- `keyboard_slots` is a manifest row restricted to Windows and macOS, and the
--- reason written beside it was accurate: this driver had no chord capture and
--- nowhere to store an assignment. The hook reported every modified keystroke as
--- the bare string "shortcut" — enough to tell the engine the caret had moved,
--- and not enough to say WHICH shortcut. So there was nothing to match, and
--- `keystats.record_shortcut` had no caller for the same reason: every action
--- that types no text was absent from the metrics.
---
--- THE MATCHING RULE THAT MATTERS:
--- A slot requires its modifiers EXACTLY, not at least. Ctrl+Shift+P is not
--- Ctrl+P with something extra held — matching a subset would make the first
--- binding a user creates swallow every longer chord that starts the same way,
--- and the symptom would be a shortcut that works until they add another one.
---
--- AltGr is excluded from the comparison on purpose. It selects a layout level
--- rather than forming a chord: on a French layout the user holds it to type
--- "@", and a shortcut that fired on that would be unusable.
--- ==============================================================================

package.loaded["tests.support.modules.shortcuts.keyboard.keyboard_shortcuts_fixture"] = nil
local Fixture = require("tests.support.modules.shortcuts.keyboard.keyboard_shortcuts_fixture")
local helpers, Sandbox, Codec, load_over_config, drop_config, chord =
	Fixture.helpers, Fixture.Sandbox, Fixture.Codec, Fixture.load_over_config, Fixture.drop_config, Fixture.chord




-- =================================================================
-- =================================================================
-- ======= 1/ The slot space =======================================
-- =================================================================
-- =================================================================

--- Runs `body` with every translation answering `<key>`, so a label that
--- hard-codes a language shows up as text without the marker.
--- @param body function
--- @return any The body's result.
local function with_marked_translations(body)
	local saved = package.loaded["core.i18n.engine.i18n"]
	package.loaded["core.i18n.engine.i18n"] = { get = function(key) return "<" .. key .. ">" end }
	local ok, result = pcall(body)
	package.loaded["core.i18n.engine.i18n"] = saved
	if not ok then error(result, 0) end
	return result
end

helpers.describe("keyboard shortcuts: which slots exist", function()

	helpers.it("names the modifiers and the special keys of a label through the key name table", function()
		local shortcuts = load_over_config()
		local space = with_marked_translations(function() return shortcuts.get_slot_label("primary_space") end)
		local enter = with_marked_translations(function() return shortcuts.get_slot_label("alt_enter") end)
		drop_config()
		helpers.assert_eq(space, "<key_name.ctrl> + <key_name.space>",
			"a French literal here would show Espace to every language")
		helpers.assert_eq(enter, "<key_name.alt> + <key_name.enter>")
	end)

	helpers.it("offers a slot per key from the shared catalogue", function()
		local shortcuts = load_over_config()
		local slots = shortcuts.available_slots("primary_")
		drop_config()
		helpers.assert_true(#slots > 20,
			"the key space is the shared catalogue's forty keys, which the gesture "
				.. "actions and the Windows driver already use — a private list here "
				.. "would be a fourth answer to which keys exist")
	end)

	helpers.it("labels a chord in words the user can read", function()
		local shortcuts = load_over_config()
		local label = with_marked_translations(function() return shortcuts.get_slot_label("primary_shift_p") end)
		drop_config()
		helpers.assert_true(label:find("<key_name.ctrl>", 1, true) ~= nil, "the label must name the modifier")
		helpers.assert_true(label:find("<key_name.shift>", 1, true) ~= nil,
			"and both of them: a label that shows only the first modifier describes "
				.. "a different chord from the one that fires")
	end)

	helpers.it("resolves the longer prefix first", function()
		local shortcuts = load_over_config()
		local label = with_marked_translations(function() return shortcuts.get_slot_label("primary_shift_a") end)
		drop_config()
		helpers.assert_true(label:find("<key_name.shift>", 1, true) ~= nil,
			"'primary_shift_a' also starts with 'ctrl_', so a shorter prefix reached "
				.. "first resolves the wrong chord — which is why the prefix list is "
				.. "ordered and walked with ipairs")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ Assignments survive a restart ========================
-- =================================================================
-- =================================================================

helpers.describe("keyboard shortcuts: what is stored", function()
	helpers.it("keyboard-config-owner: refuses an edit when a sibling binding changes externally", function()
		local shortcuts, config = load_over_config({ ["shortcuts.keyboard.primary_j"] = "select_line" })
		local ok, err = pcall(function()
			helpers.assert_eq(shortcuts.get_action("primary_j"), "select_line")
			local external = '[shortcuts.keyboard]\nprimary_j = "enter"\n'
			Sandbox.write_bytes(config.path, external)
			helpers.assert_eq(shortcuts.set_action("primary_k", "select_line"), false)
			helpers.assert_eq(Sandbox.read_bytes(config.path), external)
			helpers.assert_eq(shortcuts.get_action("primary_j"), "select_line")
		end)
		drop_config()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("keyboard-config-owner: refuses a sibling change racing the file write", function()
		local shortcuts, config = load_over_config({ ["shortcuts.keyboard.primary_j"] = "select_line" })
		local Writer = require("core.text.engine.toml_codec.writer")
		local original = Writer.batch_write
		local external = '[shortcuts.keyboard]\nprimary_j = "enter"\n'
		local ok, err = pcall(function()
			helpers.assert_eq(shortcuts.get_action("primary_j"), "select_line")
			Writer.batch_write = function(...) Sandbox.write_bytes(config.path, external); return original(...) end
			helpers.assert_eq(shortcuts.set_action("primary_k", "select_line"), false)
			helpers.assert_eq(Sandbox.read_bytes(config.path), external)
			helpers.assert_eq(shortcuts.get_action("primary_j"), "select_line")
		end)
		Writer.batch_write = original
		drop_config()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("keyboard-config-owner: ignores legacy storage and clears persisted overrides on restart", function()
		local shortcuts, config = load_over_config({ ["shortcuts.keyboard.primary_j"] = "select_line" })
		local ok, err = pcall(function()
			helpers.assert_eq(shortcuts.get_action("primary_j"), "select_line")
			Sandbox.write_bytes(config.path, "[shortcuts.keyboard]\nprimary_k = \"enter\"\n")
			shortcuts._reset()
			helpers.assert_eq(shortcuts.get_action("primary_j"), "none", "legacy storage cannot resurrect a cleared chord")
			helpers.assert_eq(shortcuts.get_action("primary_k"), "enter", "restart consumes canonical config")
		end)
		drop_config()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("keyboard-config-owner: validates full slot identity and preserves unknown neighbors", function()
		local shortcuts, config = load_over_config({ ["shortcuts.keyboard.ctrl_not_a_key"] = "select_line" })
		local ok, err = pcall(function()
			helpers.assert_eq(shortcuts.get_action("ctrl_not_a_key"), "none")
			helpers.assert_eq(shortcuts.set_action("ctrl_not_a_key", "enter"), false)
			Sandbox.write_bytes(config.path, Sandbox.read_bytes(config.path) .. "primary_j = \"select_line\"\n[other]\nvalue = 42\n")
			shortcuts._reset() -- the file is the source before this fixture checks sparse editing
			local decoded = Codec.decode(Sandbox.read_bytes(config.path))
			local marked = {}
			shortcuts.mark_config_reads(decoded, function(...) marked[#marked + 1] = table.concat({ ... }, ".") end)
			helpers.assert_eq(table.concat(marked), "shortcuts.keyboard.primary_j")
			helpers.assert_true(shortcuts.set_action("primary_j", "enter"))
			local saved = Codec.decode(Sandbox.read_bytes(config.path))
			helpers.assert_eq(saved.shortcuts.keyboard.ctrl_not_a_key, "select_line", "the owner does not erase unknown keys")
			helpers.assert_eq(saved.other.value, 42)
		end)
		drop_config()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("keyboard-config-owner: malformed input never becomes a cached successful load", function()
		local shortcuts, config = load_over_config()
		local ok, err = pcall(function()
			Sandbox.write_bytes(config.path, "[shortcuts.keyboard\n")
			local loaded, failure = pcall(shortcuts.get_assignments)
			helpers.assert_eq(loaded, false)
			helpers.assert_true(tostring(failure):find("malformed configuration", 1, true) ~= nil)
			Sandbox.write_bytes(config.path, "[shortcuts.keyboard]\nprimary_j = \"select_line\"\n")
			helpers.assert_eq(shortcuts.get_action("primary_j"), "select_line", "a repaired source is read without resetting the owner")
			Sandbox.write_bytes(config.path, "[shortcuts.keyboard\n")
			helpers.assert_eq(shortcuts.set_action("primary_j", "enter"), false)
			helpers.assert_eq(shortcuts.get_action("primary_j"), "select_line")
		end)
		drop_config()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("stores a binding the user makes", function()
		local shortcuts, storage = load_over_config()
		local ok = shortcuts.set_action("primary_shift_p", "select_line")
		local stored = storage.get("shortcuts.keyboard.primary_shift_p")
		drop_config()
		helpers.assert_true(ok)
		helpers.assert_eq(stored, "select_line",
			"an assignment that is not persisted is a menu that forgets what the "
				.. "user told it at every restart")
	end)

	helpers.it("reads a binding back", function()
		local shortcuts = load_over_config({ ["shortcuts.keyboard.primary_j"] = "select_line" })
		local action = shortcuts.get_action("primary_j")
		drop_config()
		helpers.assert_eq(action, "select_line")
	end)

	helpers.it("ignores a stored action the catalogue does not offer, loudly", function()
		-- set_action refuses such an id, so it can only come from a hand edit or
		-- an id this driver retired. Windows drops it at load with a warning;
		-- this loader bound it, so the chord fired a no-op on every press.
		local warnings = {}
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		-- The outdated-entry rule warns once per process; start from a fresh one.
		require("settings.engine.migration.outdated").reset_for_tests()
		local saved_logger = package.loaded["core.logger.engine.shim"]
		package.loaded["core.logger.engine.shim"] = logger
		local ok, err = pcall(function()
			local shortcuts = load_over_config({
				["shortcuts.keyboard.primary_j"] = "select_line",
				["shortcuts.keyboard.primary_k"] = "no_such_action",
			})
			helpers.assert_eq(shortcuts.get_action("primary_j"), "select_line", "a catalogue id still loads")
			helpers.assert_eq(shortcuts.get_action("primary_k"), "none",
				"an id the catalogue does not offer must not be bound")
			helpers.assert_eq(#shortcuts.assigned_slots("primary_"), 1, "only the valid slot is bound")
		end)
		package.loaded["core.logger.engine.shim"] = saved_logger
		drop_config()
		if not ok then error(err, 0) end
		local named = false
		for _, message in ipairs(warnings) do
			named = named or message:find("no_such_action", 1, true) ~= nil
		end
		helpers.assert_true(named, "the ignored id must be named in a warning")
	end)

	helpers.it("preserves an explicitly native chord after its action is removed", function()
		local shortcuts, storage = load_over_config({ ["shortcuts.keyboard.primary_j"] = "select_line" })
		local ok, err = pcall(function()
			helpers.assert_true(shortcuts.set_action("primary_j", "none"))
			helpers.assert_eq(storage.get("shortcuts.keyboard.primary_j"), "none", "explicit native behavior keeps its durable ownership")
			shortcuts._reset()
			helpers.assert_eq(shortcuts.get_action("primary_j"), "none", "restart never rebinds the removed action")
			helpers.assert_eq(shortcuts.dispatch(chord("j", { ctrl = true })), false, "the explicitly native chord dispatches no action")
		end)
		drop_config()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("keeps the active binding when persistence fails", function()
		local shortcuts, storage = load_over_config({
			["shortcuts.keyboard.primary_j"] = "select_line",
		}, true)
		local rebound = shortcuts.set_action("primary_j", "enter")
		local removed = shortcuts.set_action("primary_j", "none")
		local active = shortcuts.get_action("primary_j")
		local stored = storage.get("shortcuts.keyboard.primary_j")
		drop_config()
		helpers.assert_eq(rebound, false, "a failed write must not report a new binding")
		helpers.assert_eq(removed, false, "a failed explicit None write must not report an unbound slot")
		helpers.assert_eq(active, "select_line", "the live chord must keep its durable action")
		helpers.assert_eq(stored, "select_line", "the durable action must remain untouched")
	end)

	helpers.it("refuses an action the catalogue does not offer", function()
		local shortcuts, storage = load_over_config()
		local ok = shortcuts.set_action("primary_shift_p", "no_such_action")
		local written = #storage.keys()
		drop_config()
		helpers.assert_eq(ok, false,
			"an id no Linux executor runs would be stored, fire on the chord and do "
				.. "nothing — refused here as the gesture slots and Windows refuse it")
		helpers.assert_eq(written, 0)
	end)

	helpers.it("refuses a slot with no known modifier prefix", function()
		local shortcuts, storage = load_over_config()
		local ok = shortcuts.set_action("hyper_z", "select_line")
		local written = #storage.keys()
		drop_config()
		helpers.assert_true(not ok,
			"a slot whose prefix resolves to no chord can never fire, so storing it "
				.. "gives the user a binding that silently does nothing")
		helpers.assert_eq(written, 0)
	end)

	helpers.it("lists only the slots of the group asked for", function()
		local shortcuts = load_over_config({
			["shortcuts.keyboard.primary_j"] = "select_line",
			["shortcuts.keyboard.alt_j"] = "enter",
		})
		local ctrl = shortcuts.assigned_slots("primary_")
		drop_config()
		helpers.assert_eq(#ctrl, 1,
			"'ctrl_' must not match 'alt_j', and it must not match 'primary_shift_j' "
				.. "either — each group renders its own rows")
		helpers.assert_eq(ctrl[1], "primary_j")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ Which chord fires ====================================
-- =================================================================
-- =================================================================

helpers.describe("keyboard shortcuts: matching a chord", function()

	helpers.it("fires the binding for the exact chord", function()
		local shortcuts = load_over_config({ ["shortcuts.keyboard.primary_j"] = "select_line" })
		local fired, slot = shortcuts.dispatch(chord("j", { ctrl = true }))
		drop_config()
		helpers.assert_true(fired, "the whole feature")
		helpers.assert_eq(slot, "primary_j")
	end)

	helpers.it("does not fire when an extra modifier is held", function()
		local shortcuts = load_over_config({ ["shortcuts.keyboard.primary_j"] = "select_line" })
		local fired = shortcuts.dispatch(chord("j", { ctrl = true, shift = true }))
		drop_config()
		helpers.assert_true(not fired,
			"Ctrl+Shift+J is not Ctrl+J with something extra held. Matching a subset "
				.. "would make the first binding a user creates swallow every longer "
				.. "chord that starts the same way, and it would work until they "
				.. "added the second one.")
	end)

	helpers.it("does not fire when a required modifier is missing", function()
		local shortcuts = load_over_config({ ["shortcuts.keyboard.primary_shift_j"] = "select_line" })
		local fired = shortcuts.dispatch(chord("j", { ctrl = true }))
		drop_config()
		helpers.assert_true(not fired)
	end)

	helpers.it("ignores AltGr, which selects a layout level rather than a chord", function()
		local shortcuts = load_over_config({ ["shortcuts.keyboard.primary_j"] = "select_line" })
		local fired = shortcuts.dispatch(chord("j", { ctrl = true, altgr = true }))
		drop_config()
		helpers.assert_true(fired,
			"on a French layout AltGr is how the user types '@'; a shortcut layer "
				.. "that treated it as part of the chord would be unusable there")
	end)

	helpers.it("does nothing for an unbound chord", function()
		local shortcuts = load_over_config()
		local fired = shortcuts.dispatch(chord("j", { ctrl = true }))
		drop_config()
		helpers.assert_true(not fired,
			"a general slot starts unbound, because a desktop environment already "
				.. "owns most modifier chords and a binding the user did not ask for "
				.. "fires alongside the one they expected")
	end)

	helpers.it("leaves Ctrl+G native without an explicit assignment", function()
		local calls = 0
		local shortcuts = load_over_config(nil, nil, {
			open = function() calls = calls + 1; return true end,
		})
		local fired, slot = shortcuts.dispatch(chord("g", { ctrl = true }))
		drop_config()
		helpers.assert_eq(fired, false)
		helpers.assert_eq(slot, nil)
		helpers.assert_eq(calls, 0)
	end)

end)




helpers.describe("keyboard shortcuts: the manifest's shipped bindings", function()

	helpers.it("leaves Super+Space native on a fresh install", function()
		local shortcuts = load_over_config()
		local action = shortcuts.get_action("meta_space")
		local super_slots = shortcuts.assigned_slots("meta_")
		local queued = 0
		local consumed = shortcuts.consume(chord("space", { meta = true }), {
			defer = function() queued = queued + 1 return true end,
		})
		drop_config()
		helpers.assert_eq(action, "none", "the neutral manifest default keeps native input")
		helpers.assert_eq(consumed, false, "a neutral default must never consume the native Super+Space chord")
		helpers.assert_eq(queued, 0, "no inert action may be queued behind the native key")
		helpers.assert_eq(#super_slots, 0)
	end)

	helpers.it("binds Super+Space to an explicitly configured prediction action", function()
		local previous_engine = package.loaded["ai.engine.prediction.engine"]
		package.loaded["ai.engine.prediction.engine"] = { is_enabled = function() return true end }
		local ok, detail = xpcall(function()
			local shortcuts = load_over_config({ ["shortcuts.keyboard.meta_space"] = "llm_generate_prediction" })
			local action = shortcuts.get_action("meta_space")
			local super_slots = shortcuts.assigned_slots("meta_")
			local fired, slot = shortcuts.dispatch(chord("space", { meta = true }))
			helpers.assert_eq(action, "llm_generate_prediction",
				"an explicit saved action remains effective")
			helpers.assert_eq(#super_slots, 1)
			helpers.assert_eq(fired, true)
			helpers.assert_eq(slot, "meta_space")
		end, debug.traceback)
		drop_config()
		package.loaded["ai.engine.prediction.engine"] = previous_engine
		if not ok then error(detail, 0) end
	end)

	helpers.it("offers a Super group in the menu", function()
		local shortcuts = load_over_config()
		local found = false
		for _, group in ipairs(shortcuts.SLOT_GROUPS) do
			if group.prefix == "meta_" then found = true end
		end
		local slots = shortcuts.available_slots("meta_")
		drop_config()
		helpers.assert_true(found, "a default Super binding needs a group the user can see and change")
		helpers.assert_true(#slots > 20)
	end)

	helpers.it("keeps a shipped binding the user cleared cleared after a restart", function()
		local shortcuts, storage = load_over_config({ ["shortcuts.keyboard.meta_space"] = "llm_generate_prediction" })
		helpers.assert_true(shortcuts.set_action("meta_space", "none"))
		local stored = storage.get("shortcuts.keyboard.meta_space")
		shortcuts._reset()
		local action = shortcuts.get_action("meta_space")
		drop_config()
		helpers.assert_eq(stored, "none",
			"deleting the entry would bring the default back at the next start")
		helpers.assert_eq(action, "none")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 4/ What the metrics record ==============================
-- =================================================================
-- =================================================================

helpers.describe("keyboard shortcuts: the chord's identity", function()

	helpers.it("names a chord the same way whatever order it arrives in", function()
		local shortcuts = load_over_config()
		local a = shortcuts.chord_name(chord("p", { ctrl = true, shift = true }))
		local b = shortcuts.chord_name(chord("p", { shift = true, ctrl = true }))
		drop_config()
		helpers.assert_eq(a, b,
			"the modifier table has no order, so a name built by iterating it would "
				.. "give Ctrl+Maj+P and Maj+Ctrl+P different identities — two rows in "
				.. "the dashboard for one keystroke")
		helpers.assert_true(a:find("Ctrl", 1, true) ~= nil and a:find("p", 1, true) ~= nil)
	end)

	helpers.it("answers nothing for a bare key", function()
		local shortcuts = load_over_config()
		local name = shortcuts.chord_name(chord("p", {}))
		drop_config()
		helpers.assert_true(name == nil,
			"a key with no modifier is ordinary typing, already counted as a "
				.. "keystroke; recording it again as a shortcut would double it")
	end)

end)




helpers.describe("Keyboard configuration admission", function()
	for _, scenario in ipairs({ "ordinary rebind", "owned dispatch", "released generation", "new generation" }) do
		helpers.it("keeps " .. scenario .. " bounded by the actual dispatcher", function()
			local shortcuts, config = load_over_config({ ["shortcuts.keyboard.primary_j"] = "select_line" })
			local gestures = require("gestures.engine.manager")
			local execute = gestures.execute_action
			local queue, fired = {}, {}
			gestures.execute_action = function(action) fired[#fired + 1] = action end
			local ok, err = pcall(function()
				local detail = chord("j", { ctrl = true })
				local options = { defer = function(callback) queue[#queue + 1] = callback; return true end }
				helpers.assert_true(shortcuts.consume(detail, options))
				queue[1]()
				helpers.assert_eq(table.concat(fired), "select_line", "ordinary positive control must execute")
				fired = {}
				helpers.assert_true(shortcuts.consume(detail, options))
				if scenario == "ordinary rebind" then
					helpers.assert_true(shortcuts.set_action("primary_j", "enter"))
					queue[2]()
					helpers.assert_eq(#fired, 0, "an already queued old assignment must not fire")
					helpers.assert_true(shortcuts.consume(detail, options))
					queue[3]()
					helpers.assert_eq(table.concat(fired), "enter")
					return
				end
				local token = {}
				local before = Sandbox.read_bytes(config.path)
				helpers.assert_true(shortcuts.acquire_configuration(token))
				helpers.assert_eq(shortcuts.acquire_configuration({}), false)
				helpers.assert_eq(shortcuts.acquire_configuration(token), false)
				helpers.assert_eq(shortcuts.release_configuration({}), false)
				helpers.assert_eq(shortcuts.set_action("primary_j", "enter"), false)
				helpers.assert_eq(Sandbox.read_bytes(config.path), before)
				helpers.assert_eq(shortcuts.get_action("primary_j"), "select_line")
				helpers.assert_eq(shortcuts.consume(detail, options), false)
				helpers.assert_eq(shortcuts.dispatch(detail), false)
				helpers.assert_eq(#queue, 2)
				if scenario == "owned dispatch" then queue[2]() end
				helpers.assert_eq(#fired, 0)
				helpers.assert_true(shortcuts.release_configuration(token))
				helpers.assert_eq(shortcuts.release_configuration(token), false)
				queue[2]()
				helpers.assert_eq(#fired, 0, "release must not revive canceled actions")
				if scenario == "new generation" then
					helpers.assert_true(shortcuts.consume(detail, options))
					queue[3]()
					helpers.assert_eq(table.concat(fired), "select_line")
				end
			end)
			gestures.execute_action = execute
			drop_config()
			if not ok then error(err, 0) end
		end)
	end
end)




helpers.describe("keyboard shortcuts: ordinary physical magic editor slot", function()
	local function with_editor(initial, body, writes_fail)
		local saved_source = package.loaded["hotstrings.engine.magic_key_source"]
		local saved_magic = package.loaded["hotstrings.engine.magic_key"]
		local saved_builder = package.loaded["menu.ui.builder.builder"]
		local gestures = require("gestures.engine.manager")
		local saved_execute = gestures.execute_action
		local state = { trigger = "★", generation = 1, master = true, paused = false, inhibited = false,
			rows = { { code = "KeyJ", native_code = 36, identity = "evdev:36", text = "★", native_text = "j", direct = true, dead = false } },
			queue = {}, fired = {} }
		package.loaded["hotstrings.engine.magic_key_source"] = {
			editor_source = function() return { generation = state.generation, status = "ready", candidates = state.rows } end,
			known_codes = function() return { KeyJ = true, KeyC = true, Quote = true, Semicolon = true } end,
		}
		package.loaded["hotstrings.engine.magic_key"] = { get = function() return state.trigger end, is_customised = function() return false end }
		gestures.execute_action = function(action, binding) state.fired[#state.fired + 1] = { action, binding } return true end
		local ok, err = pcall(function()
			local shortcuts, config = load_over_config(initial, writes_fail)
			state.options = {
				defer = function(callback) state.queue[#state.queue + 1] = callback return true end,
				admission = function() return { master = state.master, paused = state.paused, inhibited = state.inhibited } end,
			}
			state.detail = { key = "j", code = 36, physical = true, mods = { meta = true } }
			body(shortcuts, config, state)
		end)
		gestures.execute_action = saved_execute
		package.loaded["hotstrings.engine.magic_key_source"] = saved_source
		package.loaded["hotstrings.engine.magic_key"] = saved_magic
		package.loaded["menu.ui.builder.builder"] = saved_builder
		drop_config()
		if not ok then error(err, 0) end
	end

	helpers.it("(magic-editor-broker) routes the manifest default through the ordinary executor and stable editable slot", function()
		with_editor(nil, function(shortcuts, config, state)
			helpers.assert_eq(shortcuts.get_action("magic_editor"), "open_hotstrings_editor")
			helpers.assert_eq(shortcuts.available_slots("contextual"), { "magic_editor" })
			helpers.assert_eq(shortcuts.assigned_slots("contextual"), { "magic_editor" })
			helpers.assert_eq(shortcuts.get_slot_label("magic_editor"), "Super + ★")
			helpers.assert_true(shortcuts.consume(state.detail, state.options))
			helpers.assert_eq(#state.fired, 0, "native capture queues ordinary actions outside the hook")
			state.queue[1]()
			helpers.assert_eq(state.fired, { { "open_hotstrings_editor", "keyboard__magic_editor" } })
			helpers.assert_eq(#config.keys(), 0, "a conditional default never seeds personal assignments")
			helpers.assert_true(shortcuts.set_action("magic_editor", "none"))
			helpers.assert_eq(config.get("shortcuts.keyboard.magic_editor"), "none", "clearing a default remains explicit across restart")
			shortcuts._reset()
			helpers.assert_eq(shortcuts.get_action("magic_editor"), "none")
			helpers.assert_eq(shortcuts.consume(state.detail, state.options), false)
			helpers.assert_eq(shortcuts.assigned_slots("contextual"), { "magic_editor" }, "a cleared conditional slot remains editable")
			helpers.assert_true(shortcuts.set_action("magic_editor", "enter"))
			helpers.assert_true(shortcuts.consume(state.detail, state.options))
			state.queue[2]()
			helpers.assert_eq(state.fired[2], { "enter", "keyboard__magic_editor" }, "reassignment uses the same ordinary action catalogue")
		end)
	end)


	helpers.it("(magic-editor-broker) exposes the ordinary contextual action and durable clearing in the tray", function()
		with_editor(nil, function(shortcuts, config, state)
			local changed = 0
			local builder = helpers.load_module("menu.ui.builder.builder")
			local i18n = require("core.i18n.engine.i18n")
			local function contextual(items)
				for _, row in ipairs(items or {}) do
					if row.title == i18n.get("menu.shortcuts.group_contextual") then return row end
					local found = contextual(row.menu)
					if found then return found end
				end
			end
			-- The menu reads the Shortcuts category on: an off category greys every
			-- row of its submenu (category-off rule), so the slot names no reason.
			local function build()
				return builder.build({ shortcuts = setmetatable({ is_enabled = function() return true end },
					{ __index = require("shortcuts.engine.manager") }), on_quit = function() end,
					on_menu_changed = function() changed = changed + 1 end })
			end
			local group = contextual(build())
			helpers.assert_type(group, "table", "the stable logical slot must be visible through the ordinary menu provider")
			helpers.assert_eq(#group.menu, 1)
			helpers.assert_eq(group.menu[1].title, "Super + ★ → " .. require("gestures.engine.manager").get_action_label("open_hotstrings_editor"))
			helpers.assert_type(group.menu[1].menu[1].fn, "function", "the ordinary action picker offers reassignment")
			helpers.assert_eq(group.menu[1].menu[2].title, i18n.get("dialog.action_picker.disabled"))
			group.menu[1].menu[2].fn()
			helpers.assert_eq(config.get("shortcuts.keyboard.magic_editor"), "none")
			helpers.assert_eq(changed, 1, "a committed removal rebuilds the menu")
			helpers.assert_eq(shortcuts.consume(state.detail, state.options), false)
			local cleared = contextual(build())
			helpers.assert_eq(#cleared.menu, 1, "clearing retains the editable stable slot")
			helpers.assert_type(cleared.menu[1].menu[1].fn, "function")
		end)
	end)

	helpers.it("(magic-editor-broker) follows ★ to ù and semicolon by physical proof on arbitrary layouts", function()
		with_editor(nil, function(shortcuts, config, state)
			local scenarios = {
				{ text = "★", code = "KeyJ", native = 36 },
				{ text = "ù", code = "Quote", native = 40 },
				{ text = ";", code = "Semicolon", native = 39 },
			}
			for index, scenario in ipairs(scenarios) do
				state.trigger, state.generation = scenario.text, index
				state.rows = { { code = scenario.code, native_code = scenario.native, identity = "evdev:" .. scenario.native,
					text = scenario.text, native_text = scenario.text, direct = true, dead = false } }
				local detail = { key = "deliberately unrelated", code = scenario.native, physical = true, mods = { meta = true } }
				helpers.assert_true(shortcuts.consume(detail, state.options), "matching is physical and does not guess from a symbolic key")
				state.queue[index]()
				helpers.assert_eq(shortcuts.get_slot_label("magic_editor"), "Super + " .. scenario.text)
			end
			helpers.assert_eq(#state.fired, 3)
			helpers.assert_eq(#config.keys(), 0, "following the effective source does not overwrite personal settings")
		end)
	end)

	helpers.it("(magic-editor-broker) leaves modified, remapped, dead, ambiguous and unproved input native", function()
		with_editor(nil, function(shortcuts, _, state)
			for _, modifier in ipairs({ "ctrl", "shift", "alt", "altgr" }) do
				local detail = { key = "j", code = 36, physical = true, mods = { meta = true, [modifier] = true } }
				helpers.assert_eq(shortcuts.consume(detail, state.options), false, "the source must not require " .. modifier)
			end
			state.detail.physical = false
			helpers.assert_eq(shortcuts.consume(state.detail, state.options), false, "tap-hold output is not the original physical source")
			state.detail.physical = true
			state.detail.code = 46
			helpers.assert_eq(shortcuts.consume(state.detail, state.options), false, "there is no historical physical-C fallback")
			state.detail.code = 36
			state.rows[1].direct = false
			helpers.assert_eq(shortcuts.consume(state.detail, state.options), false)
			state.rows[1].direct, state.rows[1].dead = true, true
			helpers.assert_eq(shortcuts.consume(state.detail, state.options), false)
			state.rows[1].dead = false
			state.rows[2] = { code = "KeyC", native_code = 46, identity = "evdev:46", text = "★", native_text = "★", direct = true, dead = false }
			helpers.assert_eq(shortcuts.consume(state.detail, state.options), false, "two actual bare sources require an explicit source choice")
			state.rows = {}
			helpers.assert_eq(shortcuts.consume(state.detail, state.options), false)
			helpers.assert_eq(#state.queue, 0)
		end)
	end)

	helpers.it("(magic-editor-broker) preserves newly selected physical None across restart", function()
		with_editor(nil, function(shortcuts, config, state)
			helpers.assert_true(shortcuts.set_action("meta_j", "none"))
			helpers.assert_eq(config.get("shortcuts.keyboard.meta_j"), "none")
			shortcuts._reset()
			helpers.assert_eq(shortcuts.magic_editor_decision(state.options.admission()).reason, "explicit_assignment")
			helpers.assert_eq(shortcuts.consume(state.detail, state.options), false)
			helpers.assert_eq(#state.queue, 0, "personal native intent never silently invokes the recommendation")
		end)
	end)

	for _, action in ipairs({ "select_line", "none" }) do
		helpers.it("(magic-editor-broker) preserves explicit personal physical claims including " .. action, function()
			with_editor({ ["shortcuts.keyboard.meta_j"] = action }, function(shortcuts, config, state)
				helpers.assert_eq(shortcuts.magic_editor_decision(state.options.admission()).reason, "explicit_assignment")
				local consumed = shortcuts.consume(state.detail, state.options)
				helpers.assert_eq(consumed, action ~= "none")
				if consumed then
					state.queue[1]()
					helpers.assert_eq(state.fired, { { action, "keyboard__meta_j" } })
				else helpers.assert_eq(#state.queue, 0) end
				helpers.assert_eq(config.get("shortcuts.keyboard.meta_j"), action)
				local token = {}
				helpers.assert_true(shortcuts.acquire_configuration(token))
				local snapshot = shortcuts.configuration_snapshot(token)
				helpers.assert_eq(snapshot.explicit_assignments.meta_j, action)
				helpers.assert_true(shortcuts.apply_configuration(token, shortcuts.configuration_candidate({}, true)))
				helpers.assert_true(shortcuts.apply_configuration(token, snapshot))
				helpers.assert_true(shortcuts.release_configuration(token))
				helpers.assert_eq(shortcuts.magic_editor_decision(state.options.admission()).reason, "explicit_assignment",
					"compensation restores provenance, including a personal none absent from live assignments")
			end)
		end)
	end

	for _, gate in ipairs({ "master", "paused", "inhibited", "source", "rebind", "owner" }) do
		helpers.it("(magic-editor-broker) cancels queued delivery when live " .. gate .. " changes", function()
			with_editor(nil, function(shortcuts, _, state)
				helpers.assert_true(shortcuts.consume(state.detail, state.options))
				if gate == "master" then state.master = false
				elseif gate == "paused" then state.paused = true
				elseif gate == "inhibited" then state.inhibited = true
				elseif gate == "source" then state.generation = 2
				elseif gate == "rebind" then helpers.assert_true(shortcuts.set_action("magic_editor", "enter"))
				else
					local token = {}
					helpers.assert_true(shortcuts.acquire_configuration(token))
					helpers.assert_true(shortcuts.release_configuration(token))
				end
				state.queue[1]()
				helpers.assert_eq(state.fired, {}, "already captured actions must not escape a changed native receipt or gate")
				if gate == "master" or gate == "paused" or gate == "inhibited" then
					helpers.assert_eq(shortcuts.consume(state.detail, state.options), false, "the same live gate also closes new capture")
				end
			end)
		end)
	end

	helpers.it("(magic-editor-broker) retains the acknowledged action and provenance after persistence refusal", function()
		with_editor({ ["shortcuts.keyboard.magic_editor"] = "enter" }, function(shortcuts, config, state)
			helpers.assert_eq(shortcuts.set_action("magic_editor", "none"), false)
			helpers.assert_eq(shortcuts.set_action("magic_editor", "select_line"), false)
			helpers.assert_eq(config.get("shortcuts.keyboard.magic_editor"), "enter")
			helpers.assert_eq(shortcuts.get_action("magic_editor"), "enter")
			helpers.assert_true(shortcuts.consume(state.detail, state.options))
			state.queue[1]()
			helpers.assert_eq(state.fired, { { "enter", "keyboard__magic_editor" } })
		end, true)
	end)
end)




require("tests.lua.layouts.keyboard_native_publication_contract").register(helpers, "linux")


for _, case in ipairs({
	{ name = "script chords", module = "shortcuts.engine.script_chords", path = "shortcuts/data/actions/script_chords.json",
		invoke = function(owner) return owner.catalogue() end },
	{ name = "tap keys", module = "shortcuts.engine.tap_keys", path = "shortcuts/data/actions/tap_keys.json",
		invoke = function(owner) return owner.keys() end },
	{ name = "modifier chords", module = "shortcuts.engine.keyboard_shortcuts", path = "shortcuts/data/actions/modifier_chords.json",
		invoke = function(owner) return owner.available_slots("ctrl_") end, empty = true },
	{ name = "physical keys", module = "shortcuts.engine.keyboard_shortcuts", path = "layouts/data/keycodes/physical_keys.json",
		invoke = function(owner) return owner.physical_slot_descriptor("physical_ctrl_KeyA") end },
	{ name = "hotstring keys", module = "hotstrings.engine.output_tokens", path = "shortcuts/data/actions/send_keys.json",
		invoke = function(owner) return owner.parse("{Enter}") end },
}) do
	helpers.it("shortcut catalogue refuses FIFO: " .. case.name, function()
		local uv, Paths = require("luv"), require("core.fs.engine.paths")
		local original_shared, original_module = Paths.shared, package.loaded[case.module]
		local source = assert(original_shared(case.path))
		local dir = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti-shortcut-config-XXXXXX"))
		local path = dir .. "/catalogue.json"
		local made = os.execute("mkfifo '" .. path .. "'")
		assert(made == 0 or made == true)
		package.loaded[case.module] = nil
		local owner = require(case.module)
		Paths.shared = function(relative)
			if relative == case.path then return path end
			return original_shared(relative)
		end
		local exited, process = false, nil
		process = assert(uv.spawn("sh", { args = { "-c", 'sleep 1; cat "$2" > "$1"', "fixture", path, source } }, function()
			exited = true; process:close()
		end))
		local ok, value = pcall(case.invoke, owner)
		Paths.shared, package.loaded[case.module] = original_shared, original_module
		os.remove(path); os.remove(dir)
		while not exited do uv.run("once") end
		if case.empty then helpers.assert_true(ok); helpers.assert_eq(value, {}, "special catalogue supplies no slots")
		else helpers.assert_eq(ok, false, "special catalogue must be refused") end
	end)
end

helpers.describe('keyboard shortcut after a pause cycle', function()
  for _, action in ipairs({'select_line', 'script_reload'}) do
    helpers.it('respects pause generation for '..action, function()
      local shortcuts = load_over_config({['shortcuts.keyboard.primary_j']=action})
      local gestures = require('gestures.engine.manager')
      local original = gestures.execute_action
      local queue, fired = {}, {}
      gestures.execute_action = function(value) fired[#fired+1]=value end
      local script = require('shortcuts.engine.script_actions').new({reset=function() end,reload=function() end,quit=function() end})
      local opts = { defer=function(fn) queue[#queue+1]=fn; return true end,
        pause_epoch=script.pause_epoch,
        admission=function() return {master=true,paused=script.is_paused(),inhibited=false} end }
      local ok, err = pcall(function()
        assert(shortcuts.consume(chord('j',{ctrl=true}), opts))
        assert(script.toggle_pause()); assert(script.toggle_pause())
        queue[1]()
        -- SCD-1: a pause cycle retires a claimed slot, a script action included.
        helpers.assert_eq(fired, {})
        assert(shortcuts.consume(chord('j',{ctrl=true}),opts)); queue[2]()
        helpers.assert_eq(fired, {action})
      end)
      gestures.execute_action = original
      drop_config()
      if not ok then error(err,0) end
    end)
  end
end)
