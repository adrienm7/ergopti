--- tests/unit/ui/menu/shortcuts/test_tap_hold_edit_owner.lua

local helpers = require("tests.helpers")
local MODULES = { "platform.remap.tap_hold_manager", "platform.remap.tap_hold_writer", "ui.menu.menu_builder", "ui.action_picker.bridge" }
local INITIAL = '[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.caps_lock]\ntap_action = "enter"\ntime_activation_seconds = 0.2\n'
local function read(path)
	local f = io.open(path, "rb"); if not f then return nil end
	local text = f:read("*a"); assert(f:close()); return text
end
local function write(path, text)
	local f = assert(io.open(path, "wb")); assert(f:write(text)); assert(f:close())
end
-- Real files, Manager, Engine, Writer and menu; only UI and Hook registration
-- are typed ports. This fixture claims no physical injection or WebKit coverage.
local function with_editor(body, options)
	options = options or {}
	local saved = {}
	for _, name in ipairs(MODULES) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local path, defaults = os.tmpname(), os.tmpname(); os.remove(path)
	write(defaults, assert(read(require("infra.paths").shared("tap_hold/defaults.toml"))))
	if not options.absent then write(path, options.file_off and INITIAL:gsub("enabled = true", "enabled = false") or INITIAL) end
	local Prompt = require("ui.text_prompt")
	local ask, execute, open = Prompt.ask, os.execute, io.open
	local manager
	local ok, err = xpcall(function()
		manager = require(MODULES[1])
		assert(manager.init({ defaults_path = defaults, user_path = path,
			keyboard_hook = { set_remapper = function() return true end, key_text = function() return nil end,
				held_modifiers = function() return {} end, held_text_modifier_codes = function() return {} end,
				held_shortcut_modifier_codes = function() return {} end },
			execute_action = function() end, on_text_injected = function() end, action_names = function() return {} end }))
		if options.off then assert(manager.set_enabled(false)) end
		local writer = require(MODULES[2])
		local s = { manager = manager, writer = writer, path = path, defaults = defaults, notices = 0, paused = false }
		s.bind = function(reload)
			writer.init({ path = path, reload = reload or function() if s.reload_refused then return false end; return manager.reload() end, is_tap_action = manager.is_tap_action, canonical_hold = manager.canonical_hold })
		end
		s.bind()
		package.loaded[MODULES[4]] = { open = function(opts, confirm)
			if opts.presentation_id == "tap_hold_hold_action" then s.hold_opts, s.hold_confirm = opts, confirm; return true end
			assert(opts.presentation_id == "tap_hold_action"); s.confirm = confirm; return true
		end }
		os.execute = function(command)
			if command:find("zenity --error", 1, true) then s.notices = s.notices + 1; return 1 end
			return execute(command)
		end
		local I18n = require("infra.i18n"); I18n.init()
		s.context = { tap_holds = manager, is_paused = function() return s.paused end, on_menu_changed = function() end }
		local rows = require(MODULES[3]).build(s.context)
		local label
		for _, entry in ipairs(manager.key_catalog()) do if entry.id == "caps_lock" then label = I18n.get(entry.label_key) end end
		local caps
		local function locate(items)
			for _, row in ipairs(items) do
				if row.menu and row.title:sub(1, #label) == label then caps = row; return end
				if row.menu then locate(row.menu) end
			end
		end
		locate(rows); assert(caps, "actual CapsLock menu")
		local caption = I18n.get("tap_hold.picker.tap"); local prefix = caption:match("^(.-)%%s") or caption
		for _, row in ipairs(caps.menu) do if row.fn and row.title:sub(1, #prefix) == prefix then s.tap = row.fn end end
		local hold_caption = I18n.get("tap_hold.picker.hold"); local hold_prefix = hold_caption:match("^(.-)%%s") or hold_caption
		for _, row in ipairs(caps.menu) do if row.fn and row.title:sub(1, #hold_prefix) == hold_prefix then s.hold = row.fn end end
		assert(s.hold, "actual hold callback")
		local declaration = require("infra.manifest_menu").get_array("tap_hold_key_delay_tail")[2]
		assert(declaration.id == "tap_hold_key_delay", "the declared delay row")
		local delay_caption = I18n.get(declaration.i18n); local delay_prefix = delay_caption:match("^(.-)%%s") or delay_caption
		for _, row in ipairs(caps.menu) do
			if row.fn and row.title:sub(1, #delay_prefix) == delay_prefix then s.delay = row.fn end
		end
		assert(s.tap and s.delay, "actual tap and delay callbacks")
		s.pause = function(value) s.paused = value; assert(manager.set_paused(value)) end
		s.prompt = function(callback) Prompt.ask = function() callback(); return "450" end end
		s.stage = function(callback)
			io.open = function(filename, mode)
				local f, detail = open(filename, mode)
				if filename ~= path .. ".tmp" or not f then return f, detail end
				local proxy = {}
				proxy.write = function(_, text) local ack = f:write(text); return ack and proxy end
				proxy.close = function() local ack = f:close(); callback(); return ack end
				return proxy
			end
		end
		body(s)
	end, debug.traceback)
	Prompt.ask, os.execute, io.open = ask, execute, open
	if manager then manager._reset_for_test() end
	for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
	for _, filename in ipairs({ path, defaults, path .. ".tmp" }) do os.remove(filename) end
	if not ok then error(err, 0) end
end

helpers.describe("TapHold deferred configuration owner", function()
	for _, route in ipairs({ "tap", "delay" }) do
		for _, change in ipairs({ "pause", "pause ABA", "reload", "source", "defaults" }) do
			helpers.it("rejects retired " .. route .. " after " .. change, function()
				with_editor(function(s)
					local before
					local function retire()
						if change == "pause" then s.pause(true)
						elseif change == "pause ABA" then s.pause(true); s.pause(false)
						elseif change == "reload" then assert(s.writer.set_tap("caps_lock", "delete"))
						elseif change == "source" then write(s.path, INITIAL:gsub('"enter"', '"delete"'))
						else write(s.defaults, read(s.defaults) .. "\n# changed defaults\n") end
						before = read(s.path)
					end
					local accepted
					if route == "tap" then s.tap(); assert(s.confirm); retire(); accepted = s.confirm("backspace")
					else s.prompt(retire); accepted = s.delay() end
					helpers.assert_eq(accepted, false)
					helpers.assert_eq(read(s.path), before, "retired editors preserve current bytes")
					helpers.assert_eq(read(s.path .. ".tmp"), nil)
					helpers.assert_eq(s.notices, 1, "refusal is visible")
				end)
			end)
		end
		for _, change in ipairs({ "pause", "source", "defaults", "writer" }) do
			helpers.it("rejects " .. route .. " retired during staging by " .. change, function()
				with_editor(function(s)
					local before = read(s.path)
					s.stage(function()
						if change == "pause" then s.pause(true)
						elseif change == "source" then write(s.path, INITIAL:gsub('"enter"', '"delete"')); before = read(s.path)
						elseif change == "defaults" then write(s.defaults, read(s.defaults) .. "\n# changed during staging\n")
						else package.loaded[MODULES[2]] = {} end
					end)
					local accepted
					if route == "tap" then s.tap(); accepted = s.confirm("backspace")
					else s.prompt(function() end); accepted = s.delay() end
					helpers.assert_eq(accepted, false)
					helpers.assert_eq(read(s.path), before)
					helpers.assert_eq(read(s.path .. ".tmp"), nil)
				end)
			end)
		end
		helpers.it("commits current " .. route .. " to real source and engine", function()
			with_editor(function(s)
				local accepted
				if route == "tap" then s.tap(); accepted = s.confirm("backspace")
				else s.prompt(function() end); accepted = s.delay() end
				helpers.assert_eq(accepted, true); helpers.assert_eq(s.notices, 0)
				local fields = s.manager.keys().caps_lock
				helpers.assert_eq(route == "tap" and fields.tap_action or fields.time_activation_seconds, route == "tap" and "backspace" or 0.45)
			end)
		end)
	end
	for _, route in ipairs({ "tap", "delay" }) do
		helpers.it("rechecks " .. route .. " after a reentrant pause getter", function()
			with_editor(function(s)
				local armed = false
				s.context.is_paused = function()
					if armed then armed = false; s.pause(true); s.pause(false) end
					return false
				end
				local before = read(s.path)
				local accepted
				if route == "tap" then s.tap(); armed = true; accepted = s.confirm("backspace")
				else s.prompt(function() armed = true end); accepted = s.delay() end
				helpers.assert_eq(accepted, false); helpers.assert_eq(read(s.path), before)
			end)
		end)
	end
	helpers.it("admits a fresh picker after the previous scope was retired", function()
		with_editor(function(s)
			s.tap(); local retired = s.confirm; s.pause(true); s.pause(false)
			helpers.assert_eq(retired("backspace"), false)
			s.tap(); helpers.assert_true(s.confirm ~= retired)
			helpers.assert_eq(s.confirm("delete"), true)
			helpers.assert_eq(s.manager.keys().caps_lock.tap_action, "delete")
		end)
	end)
	for _, mode in ipairs({ "off", "file_off", "absent" }) do
		helpers.it("allows an original editor with " .. mode, function()
			with_editor(function(s)
				s.tap(); assert(s.confirm); helpers.assert_eq(s.confirm("backspace"), true)
				helpers.assert_eq(s.manager.keys().caps_lock.tap_action, "backspace")
			end, { [mode] = true })
		end)
	end
	for _, receipt in ipairs({ "false", "nil", "truthy", "throw" }) do
		helpers.it("requires strict guard ACK " .. receipt, function()
			with_editor(function(s)
				local before = read(s.path)
				local guard = function()
					if receipt == "throw" then error("controlled editor failure") end
					if receipt == "false" then return false elseif receipt == "truthy" then return {} end
				end
				helpers.assert_eq(s.writer.set_tap("caps_lock", "backspace", guard), false)
				helpers.assert_eq(s.writer.set_threshold("caps_lock", 0.45, guard), false)
				helpers.assert_eq(read(s.path), before)
			end)
		end)
	end
	-- The hold row opens the shared action picker (2026-10-22); its pick goes
	-- through the real set_hold, source and engine.
	helpers.it("commits a hold picked in the shared picker to real source and engine (tap-hold-hold-action-picker)", function()
		with_editor(function(s)
			helpers.assert_eq(s.hold(), true, "the hold row opens the picker")
			helpers.assert_eq(s.hold_opts.current, "none", "CapsLock holds nothing in this file")
			helpers.assert_eq(s.hold_confirm("ctrl+shift"), true); helpers.assert_eq(s.notices, 0)
			helpers.assert_eq(s.manager.keys().caps_lock.hold_modifier, "ctrl+shift")
			helpers.assert_true(read(s.path):find('hold_modifier = "ctrl+shift"', 1, true) ~= nil)
			helpers.assert_eq(s.hold_confirm("none"), true, "the none row clears the hold")
			helpers.assert_eq(s.manager.keys().caps_lock.hold_modifier, "")
		end)
	end)
	helpers.it("keeps the hold picker open on an unoffered or refused pick (tap-hold-hold-action-picker)", function()
		with_editor(function(s)
			s.hold(); local before = read(s.path)
			helpers.assert_eq(s.hold_confirm("backspace"), false, "a tap action is not a hold")
			helpers.assert_eq(read(s.path), before, "an unoffered pick writes nothing")
			helpers.assert_eq(s.notices, 0)
			s.reload_refused = true
			helpers.assert_eq(s.hold_confirm("shift"), false, "a refused reload is a refused pick")
			helpers.assert_eq(s.manager.keys().caps_lock.hold_modifier, nil, "the engine kept its hold")
			helpers.assert_eq(s.notices, 1, "refusal is visible")
		end)
	end)
	helpers.it("reports accepted rename honestly when reload refuses", function()
		with_editor(function(s)
			s.reload_refused = true; s.tap(); local before = read(s.path)
			helpers.assert_eq(s.confirm("backspace"), false)
			helpers.assert_true(read(s.path) ~= before, "accepted rename has no fictitious rollback")
			helpers.assert_eq(s.manager.keys().caps_lock.tap_action, "enter")
			helpers.assert_eq(s.notices, 1)
		end)
	end)
end)
