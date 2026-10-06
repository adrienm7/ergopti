--- tests/unit/modules/shortcuts/test_keyboard_canonical.lua

--- Canonical sources drive actual native acquisition and exact cleanup ownership.
local helpers = require("tests.helpers")
local Codec = require("toml_codec")
local function with_subject(source, body)
	local names = { "adapters.storage", "adapters.file_system", "adapters.hotkey_registrar", "infra.preferences",
		"infra.paths", "infra.config_paths", "modules.gestures.actions", "modules.shortcuts.keyboard_shortcuts" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local control = { content = source, writes = 0, handles = {}, fired = {} }
	local subject
	local ok, err = pcall(function()
		helpers.load_with_stubs("infra.preferences")
		package.loaded["adapters.storage"] = setmetatable({}, { __index = function()
			return function() error("canonical owner must not read legacy storage") end
		end })
		package.loaded["infra.paths"] = { shared = function(rel) return helpers.shared(rel) end }
		package.loaded["infra.config_paths"] = { get = function() return "keyboard-config" end }
		package.loaded["adapters.file_system"] = {
			read = function(path)
				local f = assert(io.open(path, "rb")); local raw = f:read("*a"); f:close(); return raw
			end,
			read_with_status = function() return control.content, control.unreadable and "error" or (control.content and "ok" or "absent") end,
			write = function() error("exact source required") end,
			write_if_unchanged = function(_, candidate, expected)
				if control.before_write then control.before_write() end
				if control.refuse or expected.content ~= control.content then return false end
				control.content, control.writes = candidate, control.writes + 1; return true
			end,
		}
		package.loaded["adapters.hotkey_registrar"] = {
			bind = function(chord, callback)
				if control.refuse_bind then return nil end
				local handle = { chord = chord, callback = callback, enabled = true }
				control.handles[#control.handles + 1] = handle
				if control.before_bind then control.before_bind() end
				return handle
			end,
			setEnabled = function(handle, enabled) handle.enabled = enabled; return true end,
			unbind = function(handle) handle.enabled = false; return true end,
		}
		package.loaded["modules.gestures.actions"] = {
			is_assignable = function(id) return id == "none" or id == "send_text" or id == "screen_capture" end,
			execute_single = function(action) control.fired[#control.fired + 1] = action; return true end,
		}
		package.loaded["infra.preferences"], package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil, nil
		local preferences = require("infra.preferences"); preferences.load("keyboard-config")
		subject = require("modules.shortcuts.keyboard_shortcuts")
		body(subject, preferences, control)
	end)
	if subject then pcall(subject.stop) end
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("canonical keyboard shortcut ownership", function()
	helpers.it("reads desired assignments behind a stopped master without acquiring native input", function()
		with_subject('[shortcuts.keyboard]\ncmd_a = "send_text"\n', function(subject, _, control)
			helpers.assert_eq(subject.get_action("cmd_a"), "send_text")
			helpers.assert_eq(subject.get_assignments().cmd_a, "send_text")
			helpers.assert_eq(subject.assigned_slots("cmd_")[1].id, "cmd_a")
			helpers.assert_eq(#control.handles, 0)
			helpers.assert_eq(control.writes, 0)
		end)
	end)
	helpers.it("acquires only exact catalogue slots and cleanup preserves all consumed leaves", function()
		with_subject('[shortcuts.keyboard]\ncmd_a = "send_text"\ncmd_not_a_key = "screen_capture"\nforeign_a = "send_text"\n', function(subject, _, control)
			helpers.assert_eq(subject.start(), true)
			helpers.assert_eq(#control.handles, 1)
			helpers.assert_eq(subject.get_action("cmd_a"), "send_text")
			helpers.assert_eq(subject.get_action("cmd_not_a_key"), "none")
			local marks = {}
			subject.mark_config_reads(Codec.decode(control.content), function(...) marks[table.concat({ ... }, ".")] = true end)
			helpers.assert_eq(marks, { ["shortcuts.keyboard.cmd_a"] = true })
			helpers.assert_eq(subject.get_owned_config_paths(), {
				"shortcuts.keyboard.cmd_a", "shortcuts.keyboard.magic_editor",
			})
			local scan = require("config_unused_keys").find_in_source(control.content,
				require("ui.menu.unused_keys_cleanup").collect)
			helpers.assert_eq(#scan.keys, 2)
			for _, key in ipairs(scan.keys) do helpers.assert_true(key.key ~= "cmd_a") end
			helpers.assert_eq(subject.set_action("cmd_not_a_key", "send_text"), false)
			helpers.assert_eq(control.writes, 0)
		end)
	end)
	helpers.it("writes explicit choices without replacing a chord and advances the ordinary baseline", function()
		with_subject('[shortcuts]\nkeyboard = { cmd_a = "send_text", foreign = 7 }\n', function(subject, preferences, control)
			helpers.assert_eq(subject.start(), true)
			local exact = control.handles[1]
			helpers.assert_eq(subject.set_action("cmd_a", "screen_capture"), true)
			exact.callback()
			helpers.assert_eq(control.fired[1], "screen_capture")
			helpers.assert_eq(#control.handles, 1)
			helpers.assert_eq(preferences.save("keyboard-config", { shortcuts = false }, {}, {}), true)
			helpers.assert_eq(subject.set_action("cmd_a", "none"), true)
			local decoded = Codec.decode(control.content)
			helpers.assert_eq(decoded.shortcuts.keyboard.cmd_a, "none")
			local assignments, claims = subject.get_configuration_intent()
			helpers.assert_eq(assignments.cmd_a, "none")
			helpers.assert_eq(claims.cmd_a, true)
			helpers.assert_eq(decoded.shortcuts.keyboard.foreign, 7)
			helpers.assert_eq(exact.enabled, false)
		end)
	end)
	helpers.it("refuses publication before changing dispatch and compensates disabled native ownership", function()
		with_subject('[shortcuts.keyboard]\ncmd_a = "send_text"\n', function(subject, _, control)
			helpers.assert_eq(subject.start(), true)
			local before, exact = control.content, control.handles[1]
			control.refuse = true
			helpers.assert_eq(subject.set_action("cmd_a", "none"), false)
			helpers.assert_eq(control.content, before)
			helpers.assert_eq(exact.enabled, true)
			helpers.assert_eq(subject.get_action("cmd_a"), "send_text")
		end)
	end)
	helpers.it("absent configuration clears cached intent and invalid sources never acquire native handles", function()
		with_subject('[shortcuts.keyboard]\ncmd_a = "send_text"\n', function(subject, _, control)
			helpers.assert_eq(subject.start(), true)
			helpers.assert_eq(subject.stop(), true)
			control.content = nil
			helpers.assert_eq(subject.start(), true)
			helpers.assert_eq(subject.get_action("cmd_a"), "none")
			helpers.assert_eq(#control.handles, 1)
			helpers.assert_eq(subject.stop(), true)
			control.content = "[broken"
			helpers.assert_eq(subject.start(), false)
			helpers.assert_eq(#control.handles, 1)
		end)
	end)
	helpers.it("rejects nested edits and external source replacement without losing native ownership", function()
		with_subject('[shortcuts.keyboard]\ncmd_a = "send_text"\n', function(subject, preferences, control)
			helpers.assert_eq(subject.start(), true)
			control.before_bind = function()
				helpers.assert_eq(subject.set_action("cmd_b", "screen_capture"), false)
			end
			control.before_write = function()
				helpers.assert_eq(subject.set_action("cmd_b", "screen_capture"), false)
			end
			helpers.assert_eq(subject.set_action("cmd_b", "send_text"), true)
			helpers.assert_eq(subject.get_action("cmd_b"), "send_text")
			helpers.assert_eq(#control.handles, 2)
			control.before_write, control.before_bind = nil, nil
			local source = preferences.source_snapshot("keyboard-config")
			control.content = control.content .. "foreign = 8\n"
			helpers.assert_eq(subject.set_action("cmd_a", "none"), false)
			helpers.assert_eq(subject.get_action("cmd_a"), "send_text")
			helpers.assert_eq(control.handles[1].enabled, true)
			helpers.assert_eq(preferences.source_snapshot("keyboard-config").content, source.content)
		end)
	end)
end)

helpers.describe("keyboard scope candidate admission", function()
	helpers.it("acquires candidate chords without reloading the unpublished disk source", function()
		with_subject('[shortcuts.keyboard]\ncmd_a = "send_text"\n', function(subject, _, control)
			helpers.assert_eq(subject.start(), true)
			helpers.assert_eq(subject.pause(), true)
			local source = control.content
			helpers.assert_eq(subject.resume_after_pause({ shortcuts = { keyboard = { cmd_b = "screen_capture" } } }), true)
			helpers.assert_eq(subject.get_action("cmd_a"), "none")
			helpers.assert_eq(subject.get_action("cmd_b"), "screen_capture")
			helpers.assert_eq(#control.handles, 2)
			control.handles[2].callback()
			helpers.assert_eq(control.fired, { "screen_capture" })
			helpers.assert_eq(control.content, source)
			helpers.assert_eq(control.writes, 0)
			helpers.assert_eq(subject.is_started(), true)
		end)
	end)

	helpers.it("stages OFF intent without acquiring input and rejects changes while native handles remain", function()
		with_subject('[shortcuts.keyboard]\ncmd_a = "send_text"\n', function(subject, _, control)
			helpers.assert_eq(subject.apply_configuration({ shortcuts = { keyboard = { cmd_b = "screen_capture" } } }), true)
			helpers.assert_eq(subject.get_action("cmd_b"), "screen_capture")
			helpers.assert_eq(subject.is_started(), false)
			helpers.assert_eq(#control.handles, 0)
			helpers.assert_eq(subject.start(), true)
			helpers.assert_eq(subject.apply_configuration({}), false)
			helpers.assert_eq(subject.get_action("cmd_a"), "send_text")
			helpers.assert_eq(subject.start({}), false)
		end)
	end)

	helpers.it("refuses an invalid candidate without publishing a partial assignment map", function()
		with_subject('[shortcuts.keyboard]\ncmd_a = "send_text"\n', function(subject, _, control)
			helpers.assert_eq(subject.get_action("cmd_a"), "send_text")
			helpers.assert_eq(subject.apply_configuration({ shortcuts = { keyboard = { cmd_b = "unknown_action" } } }), false)
			helpers.assert_eq(subject.get_action("cmd_a"), "send_text")
			helpers.assert_eq(subject.get_action("cmd_b"), "none")
			helpers.assert_eq(#control.handles, 0)
			helpers.assert_eq(subject.pause(), true)
			helpers.assert_eq(subject.resume_after_pause({ shortcuts = { keyboard = false } }), false)
			helpers.assert_eq(subject.is_started(), false)
			helpers.assert_eq(control.writes, 0)
		end)
	end)

	helpers.it("compensates a refused candidate acquisition by reapplying the captured source", function()
		with_subject('[shortcuts.keyboard]\ncmd_a = "send_text"\n', function(subject, _, control)
			helpers.assert_eq(subject.start(), true)
			local snapshot = Codec.decode(control.content)
			helpers.assert_eq(subject.pause(), true)
			control.refuse_bind = true
			helpers.assert_eq(subject.resume_after_pause({ shortcuts = { keyboard = { cmd_b = "screen_capture" } } }), false)
			helpers.assert_eq(subject.is_started(), false)
			control.refuse_bind = false
			helpers.assert_eq(subject.pause(), true)
			helpers.assert_eq(subject.resume_after_pause(snapshot), true)
			helpers.assert_eq(subject.get_action("cmd_a"), "send_text")
			helpers.assert_eq(subject.get_action("cmd_b"), "none")
			helpers.assert_eq(control.writes, 0)
		end)
	end)
end)

require("test.keyboard_native_publication_contract").register(helpers, "macos")
