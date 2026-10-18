--- tests/hardware/run_hook_text_custody.lua

--- ==============================================================================
--- MODULE: Hook Text And Native Output Custody
--- DESCRIPTION:
--- Creates two real uinput source keyboards and the production output channel.
--- The real Hook, Reader, Writer, XKB capture and injector must report exactly
--- the text the output kernel device emits, including overlapping physical
--- presses and a held key spent by an injection. Only discovery is directed at
--- these test-owned virtual sources; production discovery excludes virtual input.
--- Run from the Linux driver root with LuaJIT, a live X11 keymap and /dev/uinput.
--- ==============================================================================

require("compat.utf8").install()

local Names = require("infra.device_names")
local Input = require("infra.input_event")
local Reader = require("adapters.evdev_reader")
local Finder = require("modules.hotstrings.device_finder")
local Layout = require("adapters.keyboard_layout")
local Monotonic = require("infra.monotonic")

local keyboards, paths, chars, rows = {}, {}, {}, {}
local original_name, original_find = Names.VIRTUAL_KEYBOARD, Finder.find_devices
local Injector, Hook

--- Finds one named test keyboard after the kernel publishes its event node.
--- @param name string Exact test-owned name.
--- @return string
local function await_node(name)
	local deadline = Monotonic.now_ms() + 5000
	repeat
		local file = assert(io.open("/proc/bus/input/devices", "r"))
		local devices = file:read("*a"); file:close()
		for block in devices:gmatch("I:.-\n\n") do
			if block:find('N: Name="' .. name .. '"', 1, true) then
				local event = (block:match("H: Handlers=([^\n]*)") or ""):match("(event%d+)")
				if event then return "/dev/input/" .. event end
			end
		end
		os.execute("sleep 0.01")
	until Monotonic.now_ms() >= deadline
	error("kernel did not publish " .. name)
end

--- Pumps the production hook, then observes the actual kernel output stream.
local function pump()
	Hook.pump()
	while true do
		local event = Reader.read_event("custody-output")
		if not event then break end
		if event.type == Input.EV_KEY then rows[#rows + 1] = event.code .. ":" .. event.value end
	end
end

--- Sends one real source transition and admits it through the production hook.
--- @param index integer Source keyboard.
--- @param code integer evdev keycode.
--- @param value integer evdev transition.
local function emit(index, code, value)
	assert(keyboards[index].emit(code, value), "source keyboard write failed")
	pump()
end

local ok, failure = pcall(function()
	assert(Reader.use_ffi_backend(), "native evdev backend unavailable")
	for index = 1, 2 do
		Names.VIRTUAL_KEYBOARD = "Ergopti Custody Test " .. index
		package.loaded["adapters.uinput_writer"] = nil
		local keyboard = require("adapters.uinput_writer")
		keyboards[index] = keyboard
		assert(keyboard.open(), "cannot create source keyboard")
		paths[index] = await_node(Names.VIRTUAL_KEYBOARD)
	end
	Names.VIRTUAL_KEYBOARD = original_name
	package.loaded["adapters.uinput_writer"] = nil
	Injector = require("modules.hotstrings.injector")
	assert(Injector.open_fast_channel(), "cannot create production output")
	assert(Reader.open(await_node(original_name), "custody-output"), "cannot observe output")
	assert(Layout.refresh(), "cannot load the live XKB keymap")
	-- The standard finder rejects these synthetic test devices; retain its real
	-- kernel capability checks and override only the selected test source list.
	Finder.find_devices = function() return paths, {} end
	Hook = require("adapters.keyboard_hook")
	Hook.start({ intercept = true, onEmitRaw = Injector.emit_key,
		onChar = function(char) chars[#chars + 1] = char end })
	assert(Hook.isRunning(), "production Hook refused native source capture")
	-- Starting capture replaces XKB state. Revalidate its inverse cohort, as the
	-- daemon's onCaptureReacquired publisher does before accepting injections.
	assert(Layout.publish_current_capture(), "cannot publish the started capture's inverse map")

	emit(1, 30, 1); emit(2, 30, 1); emit(1, 30, 0); emit(2, 30, 0)
	assert(table.concat(rows, ",") == "30:1,30:0", "overlap produced unexpected kernel output: " .. table.concat(rows, ","))
	assert(table.concat(chars) == "a", "overlap invented matcher text: " .. table.concat(chars))
	print("PASS: two native source keyboards produce one aggregate matcher character")

	chars, rows = {}, {}
	emit(1, 30, 1)
	local replacement = Injector.type_directly("x")
	assert(replacement.ok, "native replacement failed: " .. tostring(replacement.error)
		.. " (cleanup_ok=" .. tostring(replacement.cleanup_ok) .. ")")
	pump()
	emit(1, 30, 2); emit(1, 30, 0)
	assert(table.concat(rows, ",") == "30:1,30:0,45:1,45:0", "spent repeat changed kernel output: " .. table.concat(rows, ","))
	assert(table.concat(chars) == "a", "spent repeat invented matcher text: " .. table.concat(chars))
	print("PASS: native injection spends a held key without inventing autorepeat text")

	chars, rows = {}, {}
	local capture = require("adapters.xkb_capture")
	emit(1, 58, 1); emit(1, 30, 1)
	assert(capture.caps_locked() == true, "physical CapsLock did not enter the captured locked state")
	local locked_replacement = Injector.type_directly("x")
	assert(locked_replacement.ok, "locked native replacement failed: " .. tostring(locked_replacement.error))
	pump()
	emit(1, 30, 0); emit(1, 58, 0)
	emit(1, 58, 1); emit(1, 58, 0)
	assert(capture.caps_locked() == false, "spent physical CapsLock release never retired its captured down")
	assert(table.concat(rows, ",") == "58:1,30:1,30:0,58:0,58:1,58:0,45:1,45:0,58:1,58:0,58:1,58:0",
		"lock retirement changed native output: " .. table.concat(rows, ","))
	print("PASS: a spent physical CapsLock release retires XKB before the next toggle")

	chars, rows = {}, {}
	emit(1, 42, 1)
	local second_path = paths[2]
	paths[2] = nil
	for _ = 1, Hook.DEVICE_CHECK_TICKS do Hook.check_device() end
	assert(Hook.isRunning(), "removing the unrelated source stopped native capture")
	emit(1, 30, 1); emit(1, 30, 0)
	assert(table.concat(chars) == "A", "source removal forgot a retained native Shift: " .. table.concat(chars))
	paths[2] = second_path
	for _ = 1, Hook.DEVICE_CHECK_TICKS do Hook.check_device() end
	assert(Hook.isRunning(), "adding the unrelated source stopped native capture")
	emit(1, 30, 1); emit(1, 30, 0); emit(1, 42, 0)
	assert(table.concat(chars) == "AA", "source addition forgot a retained native Shift: " .. table.concat(chars))
	assert(table.concat(rows, ",") == "42:1,30:1,30:0,30:1,30:0,42:0",
		"source reconciliation changed retained native output: " .. table.concat(rows, ","))
	print("PASS: adding and removing another native source preserves the retained Shift without output replay")
end)

Finder.find_devices = original_find
Names.VIRTUAL_KEYBOARD = original_name
if Hook then pcall(Hook.stop) end
pcall(Reader.close, "custody-output")
if Injector then pcall(Injector.close_fast_channel) end
for _, keyboard in ipairs(keyboards) do pcall(keyboard.close) end
if not ok then io.stderr:write(tostring(failure) .. "\n"); os.exit(1) end
