--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_nav_wheel.lua

--- ==============================================================================
--- MODULE: The Navigation Layer's Wheel Through The Keyboard Hook
--- DESCRIPTION:
--- The recommended layer makes the wheel the volume while its key is held, as on
--- Windows and macOS. A bound notch must reach the desktop as the volume key and
--- never also scroll, so the hook takes the mouse for the hold only: every other
--- report of it (motion, a click, an unbound direction) goes on through the
--- virtual device, and the grab ends with the layer, after the last forwarded
--- button is released. A touchpad is never taken.
---
--- The real reader, hook, engine and layer compiler run over a controlled
--- syscall backend (no device, no kernel): this is the hardware-free harness of
--- the pointer-during-a-tap tests, with a mouse capability mask.
--- ==============================================================================

local helpers = require("tests.helpers")
local Engine = require("platform.remap.tap_hold_engine")
local InputEvent = require("infra.input_event")

-- Kernel ABI values (input-event-codes.h), spelled here rather than read from
-- the driver so a wrong driver constant cannot agree with itself.
local EV_KEY, EV_REL, EV_SYN = 1, 2, 0
local LEFT_ALT, KEY_K, VOLUME_UP, VOLUME_DOWN = 56, 37, 115, 114
local BTN_LEFT, REL_X, REL_WHEEL, REL_HWHEEL, REL_WHEEL_HI_RES = 0x110, 0, 8, 6, 11
local EVIOCGRAB = 0x40044590

local KEYS = { left_alt = { tap_action = "backspace", hold_layer = "nav", time_activation_seconds = 10 } }

--- EVIOCGBIT(0) bytes: SYN, KEY, MSC for a keyboard; SYN, KEY, REL for a mouse;
--- SYN, KEY, ABS for a touchpad.
local MASKS = { keyboard = string.char(19, 0, 18, 0), mouse = string.char(7, 0, 0, 0), touchpad = string.char(11, 0, 0, 0),
	mouse_with_switch = string.char(39, 0, 0, 0), mouse_with_led = string.char(7, 0, 2, 0),
	mouse_with_power = string.char(7, 0, 64, 0), mouse_with_msc = string.char(23, 0, 0, 0),
	mouse_with_gesture = string.char(23, 0, 0, 0), mouse_msc_unknown = string.char(23, 0, 0, 0) }

local function fake_node(label)
	local path = os.tmpname()
	local fh = assert(io.open(path, "w"))
	fh:write(label)
	fh:close()
	return path
end

--- A navigation layer with the wheel as the volume, as the recommended one has,
--- compiled by the production compiler against the shared key registry.
local function wheel_layer()
	local ctx = require("keymap.layers").load_context({
		shared_root = helpers.driver_root() .. "/../_shared", json_decode = require("json").decode,
		toml_decode = require("toml_codec").decode, read_file = require("keymap.layer_editor").read_shipped,
	})
	local function key(name) return { kind = "keystroke", chords = { { mods = {}, key = name } } } end
	return require("platform.remap.nav_layer").compile({
		WheelUp = key("AudioVolumeUp"), WheelDown = key("AudioVolumeDown"), KeyJ = key("ArrowLeft"),
	}, ctx.registry)
end

--- Runs a keyboard and a pointer through the hook with the layer engine installed.
--- @param pointer_kind string "mouse" or "touchpad"
--- @param keyboard_events table { {code, value, at_us} }
--- @param pointer_events table { {type, code, value, at_us} }
--- @return table emitted { "key:code:value" | "rel:axis:value" }, table grabs { [path] = {on, off} }
local function drive(pointer_kind, keyboard_events, pointer_events, on_relative, observer, fatal_pointer, fail_ungrab, on_click, omit_click, snapshot, fatal_keyboard, quit_on_recovery, after_recovery)
	local keyboard, pointer, second = fake_node("keyboard"), fake_node(pointer_kind), fake_node("mouse")
	local queues = { [keyboard] = {}, [pointer] = {}, [second] = {} }
	for _, ev in ipairs(keyboard_events) do
		queues[keyboard][#queues[keyboard] + 1] = InputEvent.encode(EV_KEY, ev[1], ev[2], nil, ev[3])
	end
	for _, ev in ipairs(pointer_events) do
		local target = ev[5] == "second" and second or pointer
		queues[target][#queues[target] + 1] = InputEvent.encode(ev[1], ev[2], ev[3], nil, ev[4])
	end
	local grabs = { [keyboard] = { on = 0, off = 0 }, [pointer] = { on = 0, off = 0 }, [second] = { on = 0, off = 0 } }
	local doubled, saved = { "modules.hotstrings.device_finder", "adapters.xkb_capture" }, {}
	for _, name in ipairs(doubled) do saved[name] = package.loaded[name] end
	package.loaded["modules.hotstrings.device_finder"] = {
		find_devices = function() return { keyboard }, { pointer } end,
		is_key_device = function() return true, nil end,
		is_interceptable_key_device = function() return true, nil end,
		is_interceptable_event_mask = require("tests.support.evdev_capabilities_fixture").policy,
	}
	package.loaded["adapters.xkb_capture"] = {
		is_ready = function() return true end,
		reset_state = function() return true end,
		process = function() return nil, nil, nil end,
		modifier_role = function(code) return require("infra.evdev_codes").MODIFIER_OF[code], nil end,
	}
	local pressed = { [pointer] = type(snapshot) == "table" and snapshot or {} }
	local reader = helpers.load_module("adapters.evdev_reader")
	reader._set_backend({
		read_event_bits = function(fd, request)
			if request % 256 == 0x24 then
				if pointer_kind == "mouse_msc_unknown" then return nil end
				return string.char(pointer_kind == "mouse_with_gesture" and 0x14 or 0x10, 0, 0, 0)
			end
			return fd == pointer and MASKS[pointer_kind] or fd == second and MASKS.mouse or MASKS.keyboard
		end,
		open = function(path) return path end,
		ioctl = function(fd, request, value)
			if request == EVIOCGRAB and grabs[fd] then
				if value == 1 then grabs[fd].on = grabs[fd].on + 1 else grabs[fd].off = grabs[fd].off + 1 end
				if fd == pointer and value == 0 and fail_ungrab then return false end
			end
			return true
		end,
		read = function(fd)
			local event = table.remove(queues[fd] or {}, 1)
			if event == nil and fd == pointer and fatal_pointer then return nil, "fatal", "controlled removal" end
			if event == nil and fd == keyboard and (fatal_keyboard == true or type(fatal_keyboard) == "table" and fatal_keyboard.enabled) then return nil, "fatal", "controlled keyboard removal" end
			return event
		end,
		read_bits = function(fd, _, count)
			if fd == pointer and type(snapshot) == "function" then pressed[fd] = snapshot(queues, pointer) end
			if pressed[fd] == false then return nil, "snapshot unavailable" end
			local bytes = {}
			for index = 1, count do bytes[index] = 0 end
			for code in pairs(pressed[fd] or {}) do
				local index = math.floor(code / 8) + 1
				if index <= count then bytes[index] = bytes[index] + 2 ^ (code % 8) end
			end
			for index = 1, count do bytes[index] = string.char(bytes[index]) end
			return table.concat(bytes)
		end,
		poll = function() return false end,
		close = function() end,
	})
	local kh = helpers.load_module("adapters.keyboard_hook")
	local emitted, before_stop, running, pointer_open, ungrabs_before_stop = {}, {}, false, false, 0
	local ok, err = pcall(function()
		kh.set_remapper(Engine.new({ keys = KEYS, tap_min_ms = 0, lone_tap_max_ms = 0, one_shot_timeout_ms = 2000,
			nav_layer = wheel_layer() }), function() end)
		local start_options
		start_options = {
			intercept = true,
			onEmitRaw = function(code, value) emitted[#emitted + 1] = "key:" .. code .. ":" .. value; return true end,
			onEmitRelative = function(axis, value)
				emitted[#emitted + 1] = "rel:" .. axis .. ":" .. value
				if on_relative and on_relative(kh, keyboard, pointer, second, grabs, emitted) == false then return false end
				return true
			end,
			onClick = not omit_click and function(code) if on_click then on_click(kh, code) end end or nil,
			onPointerEvent = observer and function(kind, code, value, slot)
				return observer(kind, code, value, slot, kh, start_options, grabs)
			end or nil,
		}
		kh.start(start_options)
		kh.pump()
		if after_recovery then after_recovery(kh) end
		if quit_on_recovery then
			assert(kh.isRecovering(), "expected last keyboard loss")
			local shutdown = require("infra.shutdown_coordinator").new({ pre_wait = {}, keyboard_hook = kh,
				event_loop = { stop = function() end } })
			shutdown.request("controlled quit")
		end
		running = kh.isRunning()
		pointer_open = reader.is_open("pointer:" .. pointer)
		ungrabs_before_stop = grabs[pointer].off
		for index, row in ipairs(emitted) do before_stop[index] = row end
	end)
	kh.set_remapper(nil)
	kh.stop()
	reader._reset_backend()
	-- By name: an absent original must become absent again, which pairs() would skip.
	for _, name in ipairs(doubled) do package.loaded[name] = saved[name] end
	os.remove(keyboard)
	os.remove(pointer)
	os.remove(second)
	assert(ok, err)
	return emitted, grabs[pointer], before_stop, running, "pointer:" .. pointer, pointer_open, ungrabs_before_stop
end

local function has(list, item)
	for _, value in ipairs(list) do if value == item then return true end end
	return false
end

local function count(list, item)
	local found = 0
	for _, value in ipairs(list) do if value == item then found = found + 1 end end
	return found
end

-- The layer key goes down at 1 ms and up at 9 ms; the pointer reports fall between.
local HOLD = { { LEFT_ALT, 1, 1000 }, { LEFT_ALT, 0, 9000 } }

helpers.describe("keyboard hook: the navigation layer's wheel (layer-wheel-linux)", function()
	helpers.it("ignores stale pointer reports until the sync boundary (pointer-dropped-stale)", function()
		local clicks, reports = 0, {}
		local _, _, _, running = drive("mouse", {}, {
			{ EV_SYN, 3, 0, 1000 }, { EV_KEY, BTN_LEFT, 1, 2000 },
			{ EV_SYN, 0, 0, 3000 }, { EV_KEY, BTN_LEFT, 1, 4000 },
		}, nil, function(kind) reports[#reports + 1] = kind end, nil, nil,
			function() clicks = clicks + 1 end)
		helpers.assert_true(running)
		helpers.assert_eq(clicks, 1, "only the press after SYN_REPORT is trustworthy")
		helpers.assert_eq(reports, { "dropped", "frame", "press", "reset" })
	end)

	helpers.it("waits for the pointer sync boundary before grabbing the wheel (pointer-dropped-stale)", function()
		local during_frame
		local _, grabs, _, running, source = drive("mouse", { { LEFT_ALT, 1, 2000 } }, {
			{ EV_SYN, 3, 0, 1000 }, { EV_KEY, BTN_LEFT, 1, 3000 }, { EV_SYN, 0, 0, 4000 },
		}, nil, function(kind, _, _, slot, _, _, all_grabs)
			if kind == "frame" then during_frame = all_grabs[slot:sub(#"pointer:" + 1)].on end
		end)
		helpers.assert_true(running)
		helpers.assert_eq(during_frame, 0, "stale events cannot cross a grab boundary")
		helpers.assert_eq(grabs.on, 1, "the synchronized pointer can be grabbed afterward")
	end)
	helpers.it("preserves a successor started during emergency pointer cleanup (emergency-pointer-successor)", function()
		local restarted = false
		local _, _, _, running, _, pointer_open = drive("mouse", {}, { { EV_KEY, BTN_LEFT, 1, 3000 } }, nil,
			function(kind, _, _, _, hook, options)
				if kind == "reset" and not restarted then
					hook.stop(); hook.start(options); restarted = hook.isRunning()
				end
			end, nil, nil, function(hook) hook.emergency_stop("controlled failure") end)
		helpers.assert_true(restarted and running)
		helpers.assert_true(pointer_open, "the old emergency cleanup cannot close the successor pointer")
	end)
	helpers.it("preserves a successor started from pointer retirement during stop (stop-pointer-successor)", function()
		local restarted = false
		local _, _, _, running, _, pointer_open = drive("mouse", {}, { { EV_KEY, BTN_LEFT, 1, 3000 } }, nil,
			function(kind, _, _, _, hook, options)
				if kind == "reset" and not restarted then
					hook.stop(); hook.start(options); restarted = hook.isRunning()
				end
			end, nil, nil, function(hook) hook.stop() end)
		helpers.assert_true(restarted)
		helpers.assert_true(running, "the old stop must not stop its successor")
		helpers.assert_true(pointer_open, "the old stop must not close the successor pointer")
	end)
	helpers.it("does not seize composite pointers reporting MSC_GESTURE (mouse-msc-gesture)", function()
		local _, grabs, _, running = drive("mouse_with_gesture", HOLD, { { 4, 2, 1, 3000 } })
		helpers.assert_true(running)
		helpers.assert_eq(grabs.on, 0, "a gesture report cannot be replaced by scan metadata")
	end)

	helpers.it("does not seize a pointer when MSC capabilities cannot be read (mouse-msc-gesture)", function()
		local _, grabs, _, running = drive("mouse_msc_unknown", HOLD, {})
		helpers.assert_true(running)
		helpers.assert_eq(grabs.on, 0)
	end)
	helpers.it("still takes a normal mouse with scan metadata (mouse-unsupported-events)", function()
		local _, grabs = drive("mouse_with_msc", HOLD, {})
		helpers.assert_eq(grabs.on, 1)
	end)
	for _, kind in ipairs({ "mouse_with_led", "mouse_with_power" }) do
		helpers.it("does not seize an unforwardable composite event on " .. kind .. " (mouse-unsupported-events)", function()
			local _, grabs, _, running = drive(kind, HOLD, {})
			helpers.assert_true(running)
			helpers.assert_eq(grabs.on, 0, "unsupported event types must stay with the desktop")
		end)
	end
	helpers.it("does not grab a pointer while a previously delivered button is held (pointer-held-before-grab)", function()
		local _, grabs, _, running = drive("mouse", { { LEFT_ALT, 1, 2000 } }, {
			{ EV_KEY, BTN_LEFT, 1, 1000 },
		}, nil, nil, nil, nil, nil, nil, { [BTN_LEFT] = true })
		helpers.assert_true(running)
		helpers.assert_eq(grabs.on, 0, "the physical device must deliver the matching release")
	end)

	helpers.it("takes the wheel after the pre-existing physical button is released (pointer-held-before-grab)", function()
		local queried = false
		local emitted, grabs, _, running = drive("mouse", { { LEFT_ALT, 1, 2000 } }, {
			{ EV_KEY, BTN_LEFT, 1, 1000 },
		}, nil, nil, nil, nil, nil, nil, function(queues, pointer)
			if not queried then
				queried = true
				queues[pointer][#queues[pointer] + 1] = InputEvent.encode(EV_KEY, BTN_LEFT, 0, nil, 3000)
				return { [BTN_LEFT] = true }
			end
			return {}
		end)
		helpers.assert_true(running and queried)
		helpers.assert_eq(grabs.on, 1, "acquisition is retried after the physical release")
		helpers.assert_true(not has(emitted, "key:" .. BTN_LEFT .. ":0"), "the physical release is not moved to the virtual device")
	end)

	helpers.it("does not take a pointer whose pressed state cannot be read (pointer-held-before-grab)", function()
		local _, grabs, _, running = drive("mouse", { { LEFT_ALT, 1, 2000 } }, {},
			nil, nil, nil, nil, nil, nil, function() return false end)
		helpers.assert_true(running)
		helpers.assert_eq(grabs.on, 0)
	end)

	helpers.it("releases a pointer if a button appears during acquisition (pointer-held-before-grab)", function()
		local calls = 0
		local _, grabs, _, running = drive("mouse", { { LEFT_ALT, 1, 2000 } }, {},
			nil, nil, nil, nil, nil, nil, function()
				calls = calls + 1
				return calls == 1 and {} or { [BTN_LEFT] = true }
			end)
		helpers.assert_true(running)
		helpers.assert_eq(grabs.on, 1)
		helpers.assert_eq(grabs.off, 1)
	end)
	helpers.it("leaves composite pointer switches with the desktop (mouse-switch-no-grab)", function()
		local _, grabs, _, running = drive("mouse_with_switch", HOLD, {
			{ 5, 0, 1, 3000 }, -- EV_SW / SW_LID
		})
		helpers.assert_true(running)
		helpers.assert_eq(grabs.on, 0, "an output without EV_SW cannot take the whole device")
	end)
	helpers.it("treats a composite pointer's high keycode as a key, not a click (mouse-high-key)", function()
		local clicks = 0
		local emitted = drive("mouse", HOLD, {
			{ EV_KEY, 0x160, 1, 3000 }, { EV_KEY, 0x160, 0, 4000 }, -- KEY_OK
		}, nil, nil, nil, nil, function() clicks = clicks + 1 end)
		helpers.assert_eq(clicks, 0, "KEY_OK must not reset click-dependent state")
		helpers.assert_true(has(emitted, "key:352:1") and has(emitted, "key:352:0"))
		helpers.assert_true(not has(emitted, "key:14:1"), "the key cancels the layer key's tap")
	end)
	helpers.it("preserves a mouse's keyboard-class keys while its wheel is grabbed (mouse-extra-key)", function()
		local emitted, grabs, _, running = drive("mouse", HOLD, {
			{ EV_KEY, KEY_K, 1, 3000 }, { EV_KEY, KEY_K, 2, 3500 }, { EV_KEY, KEY_K, 0, 10000 },
		})
		helpers.assert_true(running)
		helpers.assert_true(grabs.on > 0)
		helpers.assert_true(has(emitted, "key:" .. KEY_K .. ":1"))
		helpers.assert_true(has(emitted, "key:" .. KEY_K .. ":2"))
		helpers.assert_true(has(emitted, "key:" .. KEY_K .. ":0"))
		helpers.assert_true(not has(emitted, "key:14:1"), "an extra key cancels the held layer key's tap")
	end)
	helpers.it("observes pointer events when no click callback is registered (pointer-observer-only)", function()
		local reports = {}
		local _, _, _, running, source, opened = drive("mouse", {}, {
			{ EV_REL, REL_X, 3, 3000 }, { EV_KEY, BTN_LEFT, 1, 4000 },
		}, nil, function(kind, code, value, slot)
			reports[#reports + 1] = { kind, code, value, slot }
		end, nil, nil, nil, true)
		helpers.assert_true(running)
		helpers.assert_true(opened, "the registered pointer observer requires a live pointer source")
		helpers.assert_eq(reports, { { "motion", REL_X, 3, source }, { "press", BTN_LEFT, 1, source },
			{ "reset", nil, nil, source } })
	end)

	helpers.it("remaps the wheel without optional pointer observers (wheel-no-observers)", function()
		local emitted, grabs, _, running, _, opened = drive("mouse", HOLD, {
			{ EV_REL, REL_WHEEL, 1, 3000 },
		}, nil, nil, nil, nil, nil, true)
		helpers.assert_true(running)
		helpers.assert_true(opened, "a wheel remapper needs a pointer source")
		helpers.assert_true(grabs.on > 0)
		helpers.assert_true(has(emitted, "key:" .. VOLUME_UP .. ":1"))
		helpers.assert_true(has(emitted, "key:" .. VOLUME_UP .. ":0"))
	end)
	helpers.it("identifies the pointer on each motion and frame report", function()
		local reports = {}
		local _, _, _, _, source = drive("mouse", {}, {
			{ EV_REL, REL_X, 3, 3000 }, { EV_SYN, 0, 0, 3000 },
		}, nil, function(kind, code, value, slot)
			reports[#reports + 1] = { kind, code, value, slot }
		end)
		helpers.assert_eq(reports, { { "motion", REL_X, 3, source }, { "frame", 0, 0, source },
			{ "reset", nil, nil, source } })
	end)

	helpers.it("reports pointer queue loss to its observer", function()
		local reports = {}
		local _, _, _, _, source = drive("mouse", {}, { { EV_SYN, 3, 0, 3000 }, { EV_SYN, 0, 0, 4000 } }, nil,
			function(kind, code, value, slot) reports[#reports + 1] = { kind, code, value, slot } end)
		helpers.assert_eq(reports, { { "dropped", 3, 0, source }, { "frame", 0, 0, source },
			{ "reset", nil, nil, source } })
	end)

	helpers.it("does not recursively notify a failing pointer reset observer", function()
		local resets = 0
		drive("mouse", {}, {}, nil, function(kind)
			if kind == "reset" then
				resets = resets + 1
				if resets <= 5 then error("controlled reset failure") end
			end
		end)
		helpers.assert_eq(resets, 1, "cleanup cannot repeatedly reenter its reset observer")
	end)

	helpers.it("returns a held mouse button when the last keyboard disappears", function()
		local _, grabs, before_stop, running, _, _, ungrabs = drive("mouse", {
			{ LEFT_ALT, 1, 1000 }, { KEY_K, 1, 5000 },
		}, { { EV_KEY, BTN_LEFT, 1, 3000 }, { EV_SYN, 0, 0, 3000 } },
			nil, nil, nil, nil, nil, nil, nil, true)
		helpers.assert_eq(running, false)
		helpers.assert_eq(grabs.on, 1)
		helpers.assert_eq(ungrabs, 1, "the mouse must be usable before keyboard reacquisition")
		helpers.assert_true(has(before_stop, "key:" .. BTN_LEFT .. ":1"))
		helpers.assert_true(has(before_stop, "key:" .. BTN_LEFT .. ":0"), "virtual button is retired before ungrab")
	end)

	helpers.it("emergency-stops when pointer ungrab raises during keyboard recovery", function()
		local original, reader, stopped = nil, nil, false
		local ok, err = pcall(function()
			drive("mouse", { { LEFT_ALT, 1, 1000 }, { KEY_K, 1, 5000 } },
				{ { EV_REL, REL_X, 1, 3000 } }, nil, function(kind)
					if kind == "motion" then
						reader = require("adapters.evdev_reader"); original = reader.ungrab
						reader.ungrab = function() error("controlled ungrab exception") end
					end
				end, nil, nil, nil, nil, nil, true, false,
				function(hook) stopped = not hook.isRunning() and not hook.isRecovering() end)
		end)
		if original then reader.ungrab = original end
		if not ok then error(err, 0) end
		helpers.assert_true(stopped, "the grabbed source is retired without waiting for the outer pump guard")
	end)

	helpers.it("does not stop a successor started by a failed recovery ungrab", function()
		local original, reader, restarted = nil, nil, false
		local ok, err = pcall(function()
			local _, _, _, running = drive("mouse", { { LEFT_ALT, 1, 1000 }, { KEY_K, 1, 5000 } },
				{ { EV_REL, REL_X, 1, 3000 } }, nil, function(kind, _, _, _, hook, options)
					if kind == "motion" and not original then
						reader = require("adapters.evdev_reader"); original = reader.ungrab
						reader.ungrab = function(slot)
							reader.ungrab = original
							hook.stop(); hook.start(options); restarted = hook.isRunning()
							return false
						end
					end
				end, nil, nil, nil, nil, nil, true)
			helpers.assert_true(restarted and running, "old ungrab refusal cannot stop the successor")
		end)
		if original then reader.ungrab = original end
		if not ok then error(err, 0) end
	end)

	helpers.it("emergency-stops when a pointer cannot be returned on keyboard loss", function()
		local stopped = false
		drive("mouse", { { LEFT_ALT, 1, 1000 } }, {}, nil, nil, nil, true, nil, nil, nil,
			true, false, function(hook) stopped = not hook.isRunning() and not hook.isRecovering() end)
		helpers.assert_true(stopped, "an unacknowledged pointer grab cannot enter silent recovery")
	end)

	helpers.it("reacquires a keyboard after returning the seized pointer", function()
		local failure, recovered = { enabled = true }, false
		local _, grabs, _, running = drive("mouse", { { LEFT_ALT, 1, 1000 } }, {},
			nil, nil, nil, nil, nil, nil, nil, failure, false, function(hook)
				helpers.assert_true(hook.isRecovering())
				failure.enabled = false
				for _ = 1, hook.DEVICE_CHECK_TICKS do hook.check_device() end
				recovered = hook.isRunning() and not hook.isRecovering()
			end)
		helpers.assert_true(recovered and running)
		helpers.assert_eq(grabs.on, 1)
	end)

	helpers.it("releases grabbed pointer on quit while the last keyboard is recovering", function()
		local _, grabs, _, _, _, _, ungrabs = drive("mouse", { { LEFT_ALT, 1, 1000 } }, {},
			nil, nil, nil, nil, nil, nil, nil, true, true)
		helpers.assert_eq(grabs.on, 1, "the layer acquired the mouse")
		helpers.assert_eq(ungrabs, 1, "shutdown must not leave the mouse seized while input is recovering")
	end)

	helpers.it("reports one reset when a grabbed pointer reader fails", function()
		local resets = 0
		drive("mouse", HOLD, { { EV_KEY, BTN_LEFT, 1, 3000 } }, nil, function(kind)
			if kind == "reset" then resets = resets + 1 end
		end, true)
		helpers.assert_eq(resets, 1, "fatal read and emergency cleanup refer to the same closed source")
	end)

	helpers.it("does not read a successor pointer from the retired pump", function()
		local restarted = false
		local _, _, _, running, _, pointer_open = drive("mouse", HOLD, { { EV_REL, REL_X, 1, 3000 } }, nil,
			function(kind, _, _, _, hook, options)
				if kind == "reset" and not restarted then
					restarted = true
					hook.stop()
					hook.start(options)
				end
			end, true)
		helpers.assert_true(restarted and running)
		helpers.assert_true(pointer_open, "the old pump cannot consume the successor's reader lifetime")
	end)

	helpers.it("retires a grabbed mouse when its motion observer raises", function()
		local emitted, _, _, running = drive("mouse", HOLD, {
			{ EV_KEY, BTN_LEFT, 1, 2500 }, { EV_REL, REL_X, 1, 3000 }, { EV_REL, REL_X, 2, 4000 },
		}, nil, function(kind) if kind == "motion" then error("controlled observer failure") end end)
		helpers.assert_eq(running, false)
		helpers.assert_true(has(emitted, "key:" .. BTN_LEFT .. ":0"), "cleanup releases the virtual button")
		helpers.assert_true(not has(emitted, "rel:" .. REL_X .. ":2"), "later motion is not consumed")
	end)
	for _, failure in ipairs({ "refusal", "exception" }) do
		helpers.it("stops a grabbed mouse after relative output " .. failure, function()
			local emitted, _, _, running = drive("mouse", HOLD, {
				{ EV_KEY, BTN_LEFT, 1, 2500 }, { EV_REL, REL_X, 1, 3000 }, { EV_REL, REL_X, 2, 4000 },
			}, function()
				if failure == "exception" then error("controlled output failure") end
				return false
			end)
			helpers.assert_eq(running, false, "a grabbed mouse cannot keep running without output")
			helpers.assert_true(has(emitted, "key:" .. BTN_LEFT .. ":0"), "the virtual button is retired")
			helpers.assert_true(not has(emitted, "rel:" .. REL_X .. ":2"))
		end)
	end
	helpers.it("does not report a mouse motion after relative output fails", function()
		local reports = {}
		drive("mouse", HOLD, { { EV_REL, REL_X, 1, 3000 } }, function() return false end,
			function(kind) reports[#reports + 1] = kind end)
		helpers.assert_eq(reports, { "reset" }, "only the source reset is published after output failure")
	end)
	helpers.it("does not publish a pointer press after its click callback stops capture", function()
		local reports = {}
		local emitted = drive("mouse", HOLD, { { EV_KEY, BTN_LEFT, 1, 3000 } }, nil,
			function(kind) reports[#reports + 1] = kind end, false, false, function(hook) hook.stop() end)
		helpers.assert_eq(reports, { "reset" }, "only the source reset is published after capture stops")
		helpers.assert_true(not has(emitted, "key:" .. BTN_LEFT .. ":1"))
	end)
	helpers.it("compiles a wheel direction under its own code, never a key's", function()
		local layer = wheel_layer()
		local up = layer[InputEvent.wheel_layer_code("vertical", 1)]
		local down = layer[InputEvent.wheel_layer_code("vertical", -1)]
		helpers.assert_eq(up and up.chords and up.chords[1].keys[1], VOLUME_UP, "WheelUp is volume up")
		helpers.assert_eq(down and down.chords and down.chords[1].keys[1], VOLUME_DOWN, "WheelDown is volume down")
		helpers.assert_true(InputEvent.wheel_layer_code("vertical", 1) > 0x2ff, "above every evdev key code")
	end)

	helpers.it("turns each bound notch into the volume key and never scrolls", function()
		local emitted, grabs = drive("mouse", HOLD, {
			{ EV_REL, REL_WHEEL_HI_RES, 240, 3000 }, { EV_REL, REL_WHEEL, 2, 3000 }, { EV_SYN, 0, 0, 3000 },
			{ EV_REL, REL_WHEEL, -1, 4000 }, { EV_SYN, 0, 0, 4000 },
		})
		helpers.assert_eq(count(emitted, "key:" .. VOLUME_UP .. ":1"), 2, "two notches up, two volume-up presses")
		helpers.assert_eq(count(emitted, "key:" .. VOLUME_UP .. ":0"), 2)
		helpers.assert_eq(count(emitted, "key:" .. VOLUME_DOWN .. ":1"), 1, "one notch down")
		for _, item in ipairs(emitted) do
			helpers.assert_true(not item:find("^rel:" .. REL_WHEEL .. ":") and not item:find("^rel:" .. REL_WHEEL_HI_RES .. ":"),
				"a bound notch does not also scroll: " .. item)
		end
		helpers.assert_eq(grabs.on, 1, "the mouse is taken for the hold")
		helpers.assert_eq(grabs.off, 1, "and given back when the layer ends")
		helpers.assert_true(not has(emitted, "key:" .. LEFT_ALT .. ":1"), "the layer key itself types nothing")
	end)

	helpers.it("forwards the mouse's motion, clicks and unbound directions during the hold", function()
		local emitted = drive("mouse", HOLD, {
			{ EV_REL, REL_X, 5, 3000 }, { EV_SYN, 0, 0, 3000 },
			{ EV_KEY, BTN_LEFT, 1, 3500 }, { EV_SYN, 0, 0, 3500 },
			{ EV_KEY, BTN_LEFT, 0, 4000 }, { EV_SYN, 0, 0, 4000 },
			{ EV_REL, REL_HWHEEL, 1, 4500 }, { EV_SYN, 0, 0, 4500 },
		})
		helpers.assert_true(has(emitted, "rel:" .. REL_X .. ":5"), "motion goes on: " .. table.concat(emitted, " "))
		helpers.assert_true(has(emitted, "key:" .. BTN_LEFT .. ":1") and has(emitted, "key:" .. BTN_LEFT .. ":0"),
			"the click goes on")
		helpers.assert_true(has(emitted, "rel:" .. REL_HWHEEL .. ":1"), "a direction the layer leaves alone scrolls")
	end)

	helpers.it("keeps the mouse until a button pressed under the layer is released", function()
		local emitted, grabs = drive("mouse", HOLD, {
			{ EV_KEY, BTN_LEFT, 1, 3000 }, { EV_SYN, 0, 0, 3000 },
			{ EV_KEY, BTN_LEFT, 0, 9500 }, { EV_SYN, 0, 0, 9500 },
		})
		helpers.assert_true(has(emitted, "key:" .. BTN_LEFT .. ":0"),
			"the release after the layer ended still reaches the virtual device that has the button down")
		helpers.assert_eq(grabs.off, 1, "the mouse is given back once, after its button")
	end)

	helpers.it("releases a forwarded mouse button when a grabbed pointer loses its queue", function()
		local emitted = drive("mouse", HOLD, {
			{ EV_KEY, BTN_LEFT, 1, 3000 }, { EV_SYN, 0, 0, 3000 },
			{ EV_SYN, 3, 0, 4000 }, { EV_REL, REL_X, 9, 4500 },
			{ EV_SYN, 0, 0, 5000 },
		})
		helpers.assert_true(has(emitted, "key:" .. BTN_LEFT .. ":1"))
		helpers.assert_true(has(emitted, "key:" .. BTN_LEFT .. ":0"), "the virtual button must be released")
		helpers.assert_true(not has(emitted, "rel:" .. REL_X .. ":9"), "the lost frame cannot be forwarded")
	end)

	helpers.it("releases a forwarded mouse button when the hook stops during a hold", function()
		local emitted = drive("mouse", HOLD, {
			{ EV_KEY, BTN_LEFT, 1, 3000 }, { EV_SYN, 0, 0, 3000 },
		})
		helpers.assert_true(has(emitted, "key:" .. BTN_LEFT .. ":1"))
		helpers.assert_true(has(emitted, "key:" .. BTN_LEFT .. ":0"), "stop must release the virtual button")
	end)

	helpers.it("releases a grabbed mouse button when its reader fails", function()
		local _, _, emitted = drive("mouse", HOLD, {
			{ EV_KEY, BTN_LEFT, 1, 3000 },
		}, nil, nil, true)
		helpers.assert_true(has(emitted, "key:" .. BTN_LEFT .. ":1"))
		helpers.assert_true(has(emitted, "key:" .. BTN_LEFT .. ":0"), "reader failure must release the virtual button immediately")
	end)

	helpers.it("stops capture if a grabbed mouse cannot be released", function()
		local _, _, _, running = drive("mouse", HOLD, {
			{ EV_REL, REL_X, 1, 3000 },
		}, nil, nil, false, true)
		helpers.assert_eq(running, false, "an unacknowledged ungrab cannot leave a running silent mouse")
	end)

	helpers.it("releases a grabbed mouse and its button before entering a modal", function()
		local entered, released, button_up = false, false, false
		drive("mouse", HOLD, {
			{ EV_KEY, BTN_LEFT, 1, 3000 }, { EV_REL, REL_X, 1, 3500 },
		}, function(hook, _, pointer, _, grabs, emitted)
			if entered then return end
			hook.while_released(function()
				entered = true
				released = grabs[pointer].off > 0
				button_up = has(emitted, "key:" .. BTN_LEFT .. ":0")
			end)
		end)
		helpers.assert_true(entered)
		helpers.assert_true(released, "the dialog must receive the physical mouse")
		helpers.assert_true(button_up, "the virtual button must not remain held")
	end)

	helpers.it("refuses a modal if the grabbed mouse cannot be released", function()
		local entered, attempted = false, false
		drive("mouse", HOLD, { { EV_REL, REL_X, 1, 3500 } }, function(hook)
			if attempted then return end
			attempted = true
			hook.while_released(function() entered = true end)
		end, nil, false, true)
		helpers.assert_true(attempted)
		helpers.assert_eq(entered, false, "a dialog cannot use a mouse still held by the daemon")
	end)

	helpers.it("releases a grabbed mouse button when that pointer disappears", function()
		local changed = false
		local emitted = drive("mouse", HOLD, {
			{ EV_KEY, BTN_LEFT, 1, 3000 }, { EV_REL, REL_X, 1, 3500 },
		}, function(hook, keyboard)
			if changed then return end
			changed = true
			package.loaded["modules.hotstrings.device_finder"].find_devices = function() return { keyboard }, {} end
			for _ = 1, hook.DEVICE_CHECK_TICKS do hook.check_device() end
		end)
		helpers.assert_true(changed)
		helpers.assert_true(has(emitted, "key:" .. BTN_LEFT .. ":0"), "the departed mouse cannot leave a virtual button down")
	end)

	helpers.it("keeps a grabbed mouse forwarding its button after another mouse arrives", function()
		local changed, running = false, false
		local _, grabs, emitted = drive("mouse", HOLD, {
			{ EV_KEY, BTN_LEFT, 1, 3000 }, { EV_REL, REL_X, 1, 3500 },
			{ EV_KEY, BTN_LEFT, 0, 4000 },
		}, function(hook, keyboard, pointer, second)
			if changed then return end
			changed = true
			package.loaded["modules.hotstrings.device_finder"].find_devices = function() return { keyboard }, { pointer, second } end
			for _ = 1, hook.DEVICE_CHECK_TICKS do hook.check_device() end
			running = hook.isRunning()
		end)
		helpers.assert_true(changed)
		helpers.assert_true(running, "the retained mouse remains captured")
		helpers.assert_eq(grabs.on, 1, "a retained grab cannot be acquired a second time")
		helpers.assert_true(has(emitted, "key:" .. BTN_LEFT .. ":0"), "the retained mouse must still forward its release")
	end)

	helpers.it("keeps both mouse grabs until the last shared button release", function()
		local changed = false
		local _, grabs, emitted = drive("mouse", HOLD, {
			{ EV_REL, REL_X, 1, 2000 },
			{ EV_KEY, BTN_LEFT, 1, 3000 }, { EV_KEY, BTN_LEFT, 1, 4000, "second" },
			{ EV_KEY, BTN_LEFT, 0, 9500 }, { EV_KEY, BTN_LEFT, 0, 10000, "second" },
		}, function(hook, keyboard, pointer, second)
			if changed then return end
			changed = true
			package.loaded["modules.hotstrings.device_finder"].find_devices = function() return { keyboard }, { pointer, second } end
			for _ = 1, hook.DEVICE_CHECK_TICKS do hook.check_device() end
		end)
		helpers.assert_eq(count(emitted, "key:" .. BTN_LEFT .. ":1"), 1)
		helpers.assert_eq(count(emitted, "key:" .. BTN_LEFT .. ":0"), 1, "the last owner releases the shared virtual button")
		helpers.assert_eq(grabs.off, 1)
	end)

	helpers.it("leaves the wheel and the mouse alone outside the layer and under an unbound key", function()
		local emitted, grabs = drive("mouse", { { KEY_K, 1, 1000 }, { KEY_K, 0, 9000 } }, {
			{ EV_REL, REL_WHEEL, 1, 3000 }, { EV_SYN, 0, 0, 3000 },
		})
		helpers.assert_eq(grabs.on, 0, "no layer, no grab")
		helpers.assert_true(not has(emitted, "key:" .. VOLUME_UP .. ":1"), "the wheel scrolls as usual")
		helpers.assert_true(not has(emitted, "rel:" .. REL_WHEEL .. ":1"), "and is not forwarded: the desktop saw it")
	end)

	helpers.it("never takes a touchpad", function()
		local emitted, grabs = drive("touchpad", HOLD, { { EV_REL, REL_WHEEL, 1, 3000 }, { EV_SYN, 0, 0, 3000 } })
		helpers.assert_eq(grabs.on, 0, "a touchpad scrolls with its fingers and is not taken")
		helpers.assert_true(not has(emitted, "key:" .. VOLUME_UP .. ":1"))
	end)
end)
