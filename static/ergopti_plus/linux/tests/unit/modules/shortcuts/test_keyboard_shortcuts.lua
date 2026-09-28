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
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Codec = require("toml_codec")

local Fakes = helpers.load_module("tests.fakes")

local _displaced = { storage = nil, chatgpt = nil, module = nil, paths = nil, held = false }
local _files = {}

--- Loads the module over a real canonical config and separate legacy storage.
--- @param initial table|nil Pre-existing stored values.
--- @param writes_fail boolean|nil Whether mutations fail.
--- @param chatgpt table|nil ChatGPT shortcut seam.
--- @return table shortcuts, table storage
local function load_over_config(initial, writes_fail, chatgpt)
	if not _displaced.held then
		_displaced.storage = package.loaded["adapters.storage"]
		_displaced.chatgpt = package.loaded["modules.shortcuts.chatgpt"]
		_displaced.module = package.loaded["modules.shortcuts.keyboard_shortcuts"]
		_displaced.paths = package.loaded["infra.config_paths"]
		_displaced.held = true
	end
	local storage = Fakes.storage({ initial = initial, writes_fail = writes_fail })
	package.loaded["adapters.storage"] = storage
	local path = os.tmpname()
	_files[#_files + 1] = path
	local lines = { "[shortcuts.keyboard]" }
	for key, value in pairs(initial or {}) do
		lines[#lines + 1] = key:match("([^.]+)$") .. " = " .. string.format("%q", value)
	end
	Sandbox.write_bytes(path, table.concat(lines, "\n") .. "\n")
	package.loaded["infra.config_paths"] = { config = function() return path end }
	if writes_fail then require("toml_codec.writer").refuse_writes(path, "injected persistence refusal") end
	package.loaded["modules.shortcuts.chatgpt"] = chatgpt or { open = function() return true end }
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
	local shortcuts = require("modules.shortcuts.keyboard_shortcuts")
	shortcuts._reset()
	local function values()
		local decoded = Codec.decode(Sandbox.read_bytes(path) or "")
		return decoded.shortcuts and decoded.shortcuts.keyboard or {}
	end
	return shortcuts, {
		path = path,
		get = function(key) return values()[key:match("([^.]+)$")] end,
		has = function(key) return values()[key:match("([^.]+)$")] ~= nil end,
		keys = function()
			local keys = {}
			for key in pairs(values()) do keys[#keys + 1] = "shortcuts.keyboard." .. key end
			return keys
		end,
	}
end

--- Puts back exactly what was there.
local function drop_config()
	package.loaded["adapters.storage"] = _displaced.storage
	package.loaded["modules.shortcuts.chatgpt"] = _displaced.chatgpt
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = _displaced.module
	package.loaded["infra.config_paths"] = _displaced.paths
	_displaced.held = false
	for _, path in ipairs(_files) do os.remove(path) os.remove(path .. ".tmp") end
	_files = {}
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
		local shortcuts = load_over_config()
		local slots = shortcuts.available_slots("ctrl_")
		drop_config()
		helpers.assert_true(#slots > 20,
			"the key space is the shared catalogue's forty keys, which the gesture "
				.. "actions and the Windows driver already use — a private list here "
				.. "would be a fourth answer to which keys exist")
	end)

	helpers.it("labels a chord in words the user can read", function()
		local shortcuts = load_over_config()
		local label = shortcuts.get_slot_label("ctrl_shift_p")
		drop_config()
		helpers.assert_true(label:find("Ctrl", 1, true) ~= nil, "the label must name the modifier")
		helpers.assert_true(label:find("Maj", 1, true) ~= nil,
			"and both of them: a label that shows only the first modifier describes "
				.. "a different chord from the one that fires")
	end)

	helpers.it("resolves the longer prefix first", function()
		local shortcuts = load_over_config()
		local label = shortcuts.get_slot_label("ctrl_shift_a")
		drop_config()
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
	helpers.it("keyboard-config-owner: ignores legacy storage and clears persisted overrides on restart", function()
		local shortcuts, config = load_over_config({ ["shortcuts.keyboard.ctrl_j"] = "select_line" })
		local ok, err = pcall(function()
			helpers.assert_eq(shortcuts.get_action("ctrl_j"), "select_line")
			Sandbox.write_bytes(config.path, "[shortcuts.keyboard]\nctrl_k = \"enter\"\n")
			shortcuts._reset()
			helpers.assert_eq(shortcuts.get_action("ctrl_j"), "none", "legacy storage cannot resurrect a cleared chord")
			helpers.assert_eq(shortcuts.get_action("ctrl_k"), "enter", "restart consumes canonical config")
		end)
		drop_config()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("keyboard-config-owner: validates full slot identity and preserves unknown neighbors", function()
		local shortcuts, config = load_over_config({ ["shortcuts.keyboard.ctrl_not_a_key"] = "select_line" })
		local ok, err = pcall(function()
			helpers.assert_eq(shortcuts.get_action("ctrl_not_a_key"), "none")
			helpers.assert_eq(shortcuts.set_action("ctrl_not_a_key", "enter"), false)
			Sandbox.write_bytes(config.path, Sandbox.read_bytes(config.path) .. "ctrl_j = \"select_line\"\n[other]\nvalue = 42\n")
			local decoded = Codec.decode(Sandbox.read_bytes(config.path))
			local marked = {}
			shortcuts.mark_config_reads(decoded, function(...) marked[#marked + 1] = table.concat({ ... }, ".") end)
			helpers.assert_eq(table.concat(marked), "shortcuts.keyboard.ctrl_j")
			helpers.assert_true(shortcuts.set_action("ctrl_j", "enter"))
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
			Sandbox.write_bytes(config.path, "[shortcuts.keyboard]\nctrl_j = \"select_line\"\n")
			helpers.assert_eq(shortcuts.get_action("ctrl_j"), "select_line", "a repaired source is read without resetting the owner")
			Sandbox.write_bytes(config.path, "[shortcuts.keyboard\n")
			helpers.assert_eq(shortcuts.set_action("ctrl_j", "enter"), false)
			helpers.assert_eq(shortcuts.get_action("ctrl_j"), "select_line")
		end)
		drop_config()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("stores a binding the user makes", function()
		local shortcuts, storage = load_over_config()
		local ok = shortcuts.set_action("ctrl_shift_p", "select_line")
		local stored = storage.get("shortcuts.keyboard.ctrl_shift_p")
		drop_config()
		helpers.assert_true(ok)
		helpers.assert_eq(stored, "select_line",
			"an assignment that is not persisted is a menu that forgets what the "
				.. "user told it at every restart")
	end)

	helpers.it("reads a binding back", function()
		local shortcuts = load_over_config({ ["shortcuts.keyboard.ctrl_j"] = "select_line" })
		local action = shortcuts.get_action("ctrl_j")
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
		local saved_logger = package.loaded["logger.shim"]
		package.loaded["logger.shim"] = logger
		local ok, err = pcall(function()
			local shortcuts = load_over_config({
				["shortcuts.keyboard.ctrl_j"] = "select_line",
				["shortcuts.keyboard.ctrl_k"] = "no_such_action",
			})
			helpers.assert_eq(shortcuts.get_action("ctrl_j"), "select_line", "a catalogue id still loads")
			helpers.assert_eq(shortcuts.get_action("ctrl_k"), "none",
				"an id the catalogue does not offer must not be bound")
			helpers.assert_eq(#shortcuts.assigned_slots("ctrl_"), 1, "only the valid slot is bound")
		end)
		package.loaded["logger.shim"] = saved_logger
		drop_config()
		if not ok then error(err, 0) end
		local named = false
		for _, message in ipairs(warnings) do
			named = named or message:find("no_such_action", 1, true) ~= nil
		end
		helpers.assert_true(named, "the ignored id must be named in a warning")
	end)

	helpers.it("clears the entry when the binding is removed", function()
		local shortcuts, storage = load_over_config({ ["shortcuts.keyboard.ctrl_j"] = "select_line" })
		shortcuts.set_action("ctrl_j", "none")
		local has = storage.has("shortcuts.keyboard.ctrl_j")
		drop_config()
		helpers.assert_true(not has,
			"an unbound slot must leave nothing behind, or the next start binds a "
				.. "chord the user has already removed")
	end)

	helpers.it("keeps the active binding when persistence fails", function()
		local shortcuts, storage = load_over_config({
			["shortcuts.keyboard.ctrl_j"] = "select_line",
		}, true)
		local rebound = shortcuts.set_action("ctrl_j", "enter")
		local removed = shortcuts.set_action("ctrl_j", "none")
		local active = shortcuts.get_action("ctrl_j")
		local stored = storage.get("shortcuts.keyboard.ctrl_j")
		drop_config()
		helpers.assert_eq(rebound, false, "a failed write must not report a new binding")
		helpers.assert_eq(removed, false, "a failed delete must not report an unbound slot")
		helpers.assert_eq(active, "select_line", "the live chord must keep its durable action")
		helpers.assert_eq(stored, "select_line", "the durable action must remain untouched")
	end)

	helpers.it("refuses an action the catalogue does not offer", function()
		local shortcuts, storage = load_over_config()
		local ok = shortcuts.set_action("ctrl_shift_p", "no_such_action")
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
			["shortcuts.keyboard.ctrl_j"] = "select_line",
			["shortcuts.keyboard.alt_j"] = "enter",
		})
		local ctrl = shortcuts.assigned_slots("ctrl_")
		drop_config()
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
		local shortcuts = load_over_config({ ["shortcuts.keyboard.ctrl_j"] = "select_line" })
		local fired, slot = shortcuts.dispatch(chord("j", { ctrl = true }))
		drop_config()
		helpers.assert_true(fired, "the whole feature")
		helpers.assert_eq(slot, "ctrl_j")
	end)

	helpers.it("does not fire when an extra modifier is held", function()
		local shortcuts = load_over_config({ ["shortcuts.keyboard.ctrl_j"] = "select_line" })
		local fired = shortcuts.dispatch(chord("j", { ctrl = true, shift = true }))
		drop_config()
		helpers.assert_true(not fired,
			"Ctrl+Shift+J is not Ctrl+J with something extra held. Matching a subset "
				.. "would make the first binding a user creates swallow every longer "
				.. "chord that starts the same way, and it would work until they "
				.. "added the second one.")
	end)

	helpers.it("does not fire when a required modifier is missing", function()
		local shortcuts = load_over_config({ ["shortcuts.keyboard.ctrl_shift_j"] = "select_line" })
		local fired = shortcuts.dispatch(chord("j", { ctrl = true }))
		drop_config()
		helpers.assert_true(not fired)
	end)

	helpers.it("ignores AltGr, which selects a layout level rather than a chord", function()
		local shortcuts = load_over_config({ ["shortcuts.keyboard.ctrl_j"] = "select_line" })
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

	helpers.it("opens the canonical ChatGPT URL for the default Ctrl+G chord", function()
		local calls = 0
		local shortcuts = load_over_config(nil, nil, {
			open = function() calls = calls + 1 ; return true end,
		})
		local fired, slot = shortcuts.dispatch(chord("g", { ctrl = true }))
		drop_config()
		helpers.assert_true(fired)
		helpers.assert_eq(slot, "ctrl_g")
		helpers.assert_eq(calls, 1,
			"Linux captured Ctrl+G but left shortcuts.chatgpt_url unused; the default "
				.. "binding must consume the persisted canonical preference")
	end)

end)




helpers.describe("keyboard shortcuts: the manifest's shipped bindings", function()

	helpers.it("leaves Super+Space native on a fresh install", function()
		local shortcuts = load_over_config()
		local action = shortcuts.get_action("super_space")
		local super_slots = shortcuts.assigned_slots("super_")
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
		local shortcuts = load_over_config({ ["shortcuts.keyboard.super_space"] = "llm_generate_prediction" })
		local action = shortcuts.get_action("super_space")
		local super_slots = shortcuts.assigned_slots("super_")
		local fired, slot = shortcuts.dispatch(chord("space", { meta = true }))
		drop_config()
		helpers.assert_eq(action, "llm_generate_prediction",
			"an explicit saved action remains effective")
		helpers.assert_eq(#super_slots, 1)
		helpers.assert_eq(fired, true)
		helpers.assert_eq(slot, "super_space")
	end)

	helpers.it("offers a Super group in the menu", function()
		local shortcuts = load_over_config()
		local found = false
		for _, group in ipairs(shortcuts.SLOT_GROUPS) do
			if group.prefix == "super_" then found = true end
		end
		local slots = shortcuts.available_slots("super_")
		drop_config()
		helpers.assert_true(found, "a default Super binding needs a group the user can see and change")
		helpers.assert_true(#slots > 20)
	end)

	helpers.it("keeps a shipped binding the user cleared cleared after a restart", function()
		local shortcuts, storage = load_over_config({ ["shortcuts.keyboard.super_space"] = "llm_generate_prediction" })
		helpers.assert_true(shortcuts.set_action("super_space", "none"))
		local stored = storage.get("shortcuts.keyboard.super_space")
		shortcuts._reset()
		local action = shortcuts.get_action("super_space")
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
			local shortcuts, config = load_over_config({ ["shortcuts.keyboard.ctrl_j"] = "select_line" })
			local gestures = require("modules.gestures.manager")
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
					helpers.assert_true(shortcuts.set_action("ctrl_j", "enter"))
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
				helpers.assert_eq(shortcuts.set_action("ctrl_j", "enter"), false)
				helpers.assert_eq(Sandbox.read_bytes(config.path), before)
				helpers.assert_eq(shortcuts.get_action("ctrl_j"), "select_line")
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
