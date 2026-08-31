--- tests/unit/modules/shortcuts/test_keyboard_shortcuts.lua

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
--- `keylogger.record_shortcut` had no caller for the same reason: every action
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

local helpers = require("tests.helpers")

local Fakes = helpers.load_module("tests.fakes")

local _displaced = { storage = nil, chatgpt = nil, module = nil, held = false }

--- Loads the module over a fake storage.
--- @param initial table|nil Pre-existing stored values.
--- @param writes_fail boolean|nil Whether mutations fail.
--- @param chatgpt table|nil ChatGPT shortcut seam.
--- @return table shortcuts, table storage
local function load_over_storage(initial, writes_fail, chatgpt)
	if not _displaced.held then
		_displaced.storage = package.loaded["adapters.storage"]
		_displaced.chatgpt = package.loaded["modules.shortcuts.chatgpt"]
		_displaced.module = package.loaded["modules.shortcuts.keyboard_shortcuts"]
		_displaced.held = true
	end
	local storage = Fakes.storage({ initial = initial, writes_fail = writes_fail })
	package.loaded["adapters.storage"] = storage
	package.loaded["modules.shortcuts.chatgpt"] = chatgpt or { open = function() return true end }
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
	local shortcuts = require("modules.shortcuts.keyboard_shortcuts")
	shortcuts._reset()
	return shortcuts, storage
end

--- Puts back exactly what was there.
local function drop_storage()
	package.loaded["adapters.storage"] = _displaced.storage
	package.loaded["modules.shortcuts.chatgpt"] = _displaced.chatgpt
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = _displaced.module
end

--- What the hook reports for one chord.
--- @param key string
--- @param mods table
--- @return table
local function chord(key, mods)
	return { key = key, mods = mods }
end




-- =================================================================
-- =================================================================
-- ======= 1/ The slot space =======================================
-- =================================================================
-- =================================================================

helpers.describe("keyboard shortcuts: which slots exist", function()

	helpers.it("offers a slot per key from the shared catalogue", function()
		local shortcuts = load_over_storage()
		local slots = shortcuts.available_slots("ctrl_")
		drop_storage()
		helpers.assert_true(#slots > 20,
			"the key space is the shared catalogue's forty keys, which the gesture "
				.. "actions and the Windows driver already use — a private list here "
				.. "would be a fourth answer to which keys exist")
	end)

	helpers.it("labels a chord in words the user can read", function()
		local shortcuts = load_over_storage()
		local label = shortcuts.get_slot_label("ctrl_shift_p")
		drop_storage()
		helpers.assert_true(label:find("Ctrl", 1, true) ~= nil, "the label must name the modifier")
		helpers.assert_true(label:find("Maj", 1, true) ~= nil,
			"and both of them: a label that shows only the first modifier describes "
				.. "a different chord from the one that fires")
	end)

	helpers.it("resolves the longer prefix first", function()
		local shortcuts = load_over_storage()
		local label = shortcuts.get_slot_label("ctrl_shift_a")
		drop_storage()
		helpers.assert_true(label:find("Maj", 1, true) ~= nil,
			"'ctrl_shift_a' also starts with 'ctrl_', so a shorter prefix reached "
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

	helpers.it("stores a binding the user makes", function()
		local shortcuts, storage = load_over_storage()
		local ok = shortcuts.set_action("ctrl_shift_p", "select_word")
		local stored = storage.get("shortcuts.keyboard.ctrl_shift_p")
		drop_storage()
		helpers.assert_true(ok)
		helpers.assert_eq(stored, "select_word",
			"an assignment that is not persisted is a menu that forgets what the "
				.. "user told it at every restart")
	end)

	helpers.it("reads a binding back", function()
		local shortcuts = load_over_storage({ ["shortcuts.keyboard.ctrl_j"] = "select_line" })
		local action = shortcuts.get_action("ctrl_j")
		drop_storage()
		helpers.assert_eq(action, "select_line")
	end)

	helpers.it("clears the entry when the binding is removed", function()
		local shortcuts, storage = load_over_storage({ ["shortcuts.keyboard.ctrl_j"] = "select_line" })
		shortcuts.set_action("ctrl_j", "none")
		local has = storage.has("shortcuts.keyboard.ctrl_j")
		drop_storage()
		helpers.assert_true(not has,
			"an unbound slot must leave nothing behind, or the next start binds a "
				.. "chord the user has already removed")
	end)

	helpers.it("keeps the active binding when persistence fails", function()
		local shortcuts, storage = load_over_storage({
			["shortcuts.keyboard.ctrl_j"] = "select_line",
		}, true)
		local rebound = shortcuts.set_action("ctrl_j", "select_word")
		local removed = shortcuts.set_action("ctrl_j", "none")
		local active = shortcuts.get_action("ctrl_j")
		local stored = storage.get("shortcuts.keyboard.ctrl_j")
		drop_storage()
		helpers.assert_eq(rebound, false, "a failed write must not report a new binding")
		helpers.assert_eq(removed, false, "a failed delete must not report an unbound slot")
		helpers.assert_eq(active, "select_line", "the live chord must keep its durable action")
		helpers.assert_eq(stored, "select_line", "the durable action must remain untouched")
	end)

	helpers.it("refuses a slot with no known modifier prefix", function()
		local shortcuts, storage = load_over_storage()
		local ok = shortcuts.set_action("hyper_z", "select_word")
		local written = #storage.keys()
		drop_storage()
		helpers.assert_true(not ok,
			"a slot whose prefix resolves to no chord can never fire, so storing it "
				.. "gives the user a binding that silently does nothing")
		helpers.assert_eq(written, 0)
	end)

	helpers.it("lists only the slots of the group asked for", function()
		local shortcuts = load_over_storage({
			["shortcuts.keyboard.ctrl_j"] = "select_line",
			["shortcuts.keyboard.alt_j"] = "select_word",
		})
		local ctrl = shortcuts.assigned_slots("ctrl_")
		drop_storage()
		helpers.assert_eq(#ctrl, 1,
			"'ctrl_' must not match 'alt_j', and it must not match 'ctrl_shift_j' "
				.. "either — each group renders its own rows")
		helpers.assert_eq(ctrl[1], "ctrl_j")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ Which chord fires ====================================
-- =================================================================
-- =================================================================

helpers.describe("keyboard shortcuts: matching a chord", function()

	helpers.it("fires the binding for the exact chord", function()
		local shortcuts = load_over_storage({ ["shortcuts.keyboard.ctrl_j"] = "select_line" })
		local fired, slot = shortcuts.dispatch(chord("j", { ctrl = true }))
		drop_storage()
		helpers.assert_true(fired, "the whole feature")
		helpers.assert_eq(slot, "ctrl_j")
	end)

	helpers.it("does not fire when an extra modifier is held", function()
		local shortcuts = load_over_storage({ ["shortcuts.keyboard.ctrl_j"] = "select_line" })
		local fired = shortcuts.dispatch(chord("j", { ctrl = true, shift = true }))
		drop_storage()
		helpers.assert_true(not fired,
			"Ctrl+Shift+J is not Ctrl+J with something extra held. Matching a subset "
				.. "would make the first binding a user creates swallow every longer "
				.. "chord that starts the same way, and it would work until they "
				.. "added the second one.")
	end)

	helpers.it("does not fire when a required modifier is missing", function()
		local shortcuts = load_over_storage({ ["shortcuts.keyboard.ctrl_shift_j"] = "select_line" })
		local fired = shortcuts.dispatch(chord("j", { ctrl = true }))
		drop_storage()
		helpers.assert_true(not fired)
	end)

	helpers.it("ignores AltGr, which selects a layout level rather than a chord", function()
		local shortcuts = load_over_storage({ ["shortcuts.keyboard.ctrl_j"] = "select_line" })
		local fired = shortcuts.dispatch(chord("j", { ctrl = true, altgr = true }))
		drop_storage()
		helpers.assert_true(fired,
			"on a French layout AltGr is how the user types '@'; a shortcut layer "
				.. "that treated it as part of the chord would be unusable there")
	end)

	helpers.it("does nothing for an unbound chord", function()
		local shortcuts = load_over_storage()
		local fired = shortcuts.dispatch(chord("j", { ctrl = true }))
		drop_storage()
		helpers.assert_true(not fired,
			"nothing is bound by default, because a desktop environment already "
				.. "owns most modifier chords and a binding the user did not ask for "
				.. "fires alongside the one they expected")
	end)

	helpers.it("opens the canonical ChatGPT URL for the default Ctrl+G chord", function()
		local calls = 0
		local shortcuts = load_over_storage(nil, nil, {
			open = function() calls = calls + 1 ; return true end,
		})
		local fired, slot = shortcuts.dispatch(chord("g", { ctrl = true }))
		drop_storage()
		helpers.assert_true(fired)
		helpers.assert_eq(slot, "ctrl_g")
		helpers.assert_eq(calls, 1,
			"Linux captured Ctrl+G but left shortcuts.chatgpt_url unused; the default "
				.. "binding must consume the persisted canonical preference")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 4/ What the metrics record ==============================
-- =================================================================
-- =================================================================

helpers.describe("keyboard shortcuts: the chord's identity", function()

	helpers.it("names a chord the same way whatever order it arrives in", function()
		local shortcuts = load_over_storage()
		local a = shortcuts.chord_name(chord("p", { ctrl = true, shift = true }))
		local b = shortcuts.chord_name(chord("p", { shift = true, ctrl = true }))
		drop_storage()
		helpers.assert_eq(a, b,
			"the modifier table has no order, so a name built by iterating it would "
				.. "give Ctrl+Maj+P and Maj+Ctrl+P different identities — two rows in "
				.. "the dashboard for one keystroke")
		helpers.assert_true(a:find("Ctrl", 1, true) ~= nil and a:find("p", 1, true) ~= nil)
	end)

	helpers.it("answers nothing for a bare key", function()
		local shortcuts = load_over_storage()
		local name = shortcuts.chord_name(chord("p", {}))
		drop_storage()
		helpers.assert_true(name == nil,
			"a key with no modifier is ordinary typing, already counted as a "
				.. "keystroke; recording it again as a shortcut would double it")
	end)

end)
