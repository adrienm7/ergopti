--- tests/hardware/run_xkb_source_qualification.lua

--- ==============================================================================
--- MODULE: Actual X11 Keyboard Source Qualification
--- DESCRIPTION:
--- Qualifies native server group/map receipts on an owned private Xvfb server.
--- No hardware keyboard, compositor input, or native Wayland seat is simulated
--- and described as physically validated. Missing native prerequisites fail.
--- ==============================================================================

local ffi = require("ffi")
local Capture = require("adapters.xkb_capture")
local Probe = require("adapters.xkb_source_probe")
local DisplayServer = require("infra.display_server")

ffi.cdef([[
	struct _XDisplay;
	struct _XDisplay *XOpenDisplay(const char *);
	int XCloseDisplay(struct _XDisplay *);
	int XSync(struct _XDisplay *, int);
	int XkbLockGroup(struct _XDisplay *, unsigned int, unsigned int);
	int XkbLockModifiers(struct _XDisplay *, unsigned int, unsigned int, unsigned int);
	int setenv(const char *, const char *, int);
	int unsetenv(const char *);
	int usleep(unsigned int);
	int kill(int, int);
]])
local X11 = ffi.load(require("_generated.native_runtime").x11)
local _checks, _failures = 0, 0
local _server_pid, _control = nil, nil
local _second_server_pid, _second_control = nil, nil
-- Xlib retains extension callbacks until the owned display is closed.
local _xtest = nil
local _files = {}
local _saved_env = { DISPLAY = os.getenv("DISPLAY"), WAYLAND_DISPLAY = os.getenv("WAYLAND_DISPLAY"),
	XDG_SESSION_TYPE = os.getenv("XDG_SESSION_TYPE") }





-- =========================================
-- =========================================
-- ======= 1/ Owned native fixture =========
-- =========================================
-- =========================================

local function quote(text) return "'" .. text:gsub("'", "'\\''") .. "'" end
local function succeeded(status) return status == true or status == 0 end
local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end
local function check(condition, text)
	_checks = _checks + 1
	if not condition then _failures = _failures + 1 end
	print((condition and "  ok   " or "  FAIL ") .. text)
end
local function file(suffix)
	local path = os.tmpname()
	os.remove(path)
	path = path .. suffix
	_files[#_files + 1] = path
	return path
end
local function cleanup()
	if _second_control ~= nil then X11.XCloseDisplay(_second_control) _second_control = nil end
	if _second_server_pid then ffi.C.kill(_second_server_pid, 15) _second_server_pid = nil end
	Capture.clear()
	Probe.close()
	if _control ~= nil then X11.XCloseDisplay(_control) _control = nil end
	if _server_pid then
		-- This is the exact PID created by our fixture, never a global X server.
		ffi.C.kill(_server_pid, 15)
		_server_pid = nil
	end
	for _, path in ipairs(_files) do os.remove(path) end
	for _, name in ipairs({ "DISPLAY", "WAYLAND_DISPLAY", "XDG_SESSION_TYPE" }) do
		if _saved_env[name] then ffi.C.setenv(name, _saved_env[name], 1) else ffi.C.unsetenv(name) end
	end
	DisplayServer.refresh()
end
local function start()
	for _, command in ipairs({ "Xvfb", "xkbcomp", "setxkbmap" }) do
		assert(succeeded(os.execute("command -v " .. command .. " >/dev/null 2>&1")), command .. " is required")
	end
	local display_file, pid_file, log_file = file(".display"), file(".pid"), file(".log")
	assert(succeeded(os.execute("Xvfb -displayfd 3 -screen 0 1024x768x24 -nolisten tcp -noreset -fp built-ins 3>"
		.. quote(display_file) .. " >" .. quote(log_file) .. " 2>&1 & echo $! >" .. quote(pid_file))))
	_server_pid = assert(tonumber((read(pid_file) or ""):match("^(%d+)")), "the owned Xvfb PID is required")
	local number
	for _ = 1, 250 do
		number = (read(display_file) or ""):match("^(%d+)\n")
		if number then break end
		ffi.C.usleep(20000)
	end
	assert(number, "Xvfb did not acknowledge readiness: " .. tostring(read(log_file)))
	local display = ":" .. number
	ffi.C.setenv("DISPLAY", display, 1)
	ffi.C.unsetenv("WAYLAND_DISPLAY")
	ffi.C.setenv("XDG_SESSION_TYPE", "x11", 1)
	DisplayServer.refresh()
	_control = X11.XOpenDisplay(display)
	assert(_control ~= nil, "the private server must accept a native Xlib connection")
	return display
end
local function layout(display, names)
	assert(succeeded(os.execute("setxkbmap -display " .. quote(display) .. " -layout " .. quote(names)
		.. " -option '' -option grp:win_space_toggle")), "the private native server keymap must install")
	X11.XSync(_control, 0)
end
local function server_map(display)
	local pipe = assert(io.popen("xkbcomp -xkb " .. quote(display) .. " - 2>/dev/null", "r"))
	local text = pipe:read("*a")
	pipe:close()
	assert(text:find("xkb_keymap", 1, true), "the actual native server map must dump")
	return text
end
local function plain(rows, code)
	for _, row in ipairs(rows or {}) do if row.code == code and row.plain then return row end end
end
local function group(index)
	assert(X11.XkbLockGroup(_control, 0x100, index) ~= 0, "the actual server group must acknowledge its change")
	X11.XSync(_control, 0)
end





-- =========================================
-- =========================================
-- ======= 2/ Actual server acknowledgments
-- =========================================
-- =========================================

--- Reads the actual full server map through the same native parser as capture.
local function native_identity(text)
 local lib = ffi.load(require("_generated.native_runtime").xkbcommon)
 local context = lib.xkb_context_new(0); assert(context ~= nil)
 local keymap = lib.xkb_keymap_new_from_string(context, text, 1, 0); assert(keymap ~= nil)
 local pointer = lib.xkb_keymap_get_as_string(keymap, 1); assert(pointer ~= nil)
 local identity = ffi.string(pointer)
 ffi.C.free(pointer); lib.xkb_keymap_unref(keymap); lib.xkb_context_unref(context)
 return identity
end

--- Independent actual XKB input state changes; production never clears latches.
local function input_state_qualification(identity, groups)
 local requests={{code=36,mods={}}}
 ffi.cdef([[int XkbLatchModifiers(struct _XDisplay *, unsigned int, unsigned int, unsigned int);
  int XTestFakeKeyEvent(struct _XDisplay *, unsigned int, int, unsigned long);]])
 _xtest = ffi.load('libXtst.so.6')
 local state=assert(Probe.read_input_state(identity,groups))
 check(state.mods==0 and state.base_mods==0 and state.latched_mods==0 and state.locked_mods==0 and state.observed_current()==true,'actual initial native input masks acknowledged')
 local initial_generation, initial_locked=state.generation,state.locked_generation
 state.latched_mods=99
 check(state.observed_current()==true,'detached receipt mutation cannot alter private observation seal')
 assert(X11.XkbLatchModifiers(_control,0x100,1,1)~=0);X11.XSync(_control,0)
 local latch=assert(Probe.read_input_state(identity,groups))
 local unsupported,latch_reason=Capture.chord_sources(requests)
 check(unsupported==nil and latch_reason=='physical-input-modifiers-unsupported','actual native sticky Shift refuses physical chord admission with a closed reason')
 check(latch.mods==1 and latch.base_mods==0 and latch.latched_mods==1 and latch.locked_mods==0 and latch.input_generation>state.input_generation and state.observed_current()==false,'actual sticky Shift observed independently of held and Caps state')
 check(latch.generation==initial_generation and latch.locked_generation==initial_locked,'latches preserve original source and locked-only epochs')
 assert(X11.XkbLatchModifiers(_control,0x100,1,0)~=0);X11.XSync(_control,0)
 assert(X11.XkbLatchModifiers(_control,0x100,1,1)~=0);X11.XSync(_control,0)
 local returned=assert(Probe.read_input_state(identity,groups))
 check(returned.latched_mods==1 and returned.input_generation>latch.input_generation and latch.observed_current()==false,'native latch away-and-back revokes equal-final-mask receipt')
 assert(X11.XkbLatchModifiers(_control,0x100,1,0)~=0);X11.XSync(_control,0)
 assert(Probe.read_locked(identity,groups))
 check(returned.observed_current()==false,'existing native locked read also records latch observations without changing its public contract')
 local released=assert(Probe.read_input_state(identity,groups))
 assert(_xtest.XTestFakeKeyEvent(_control,50,1,0)~=0);X11.XSync(_control,0)
 local held=assert(Probe.read_input_state(identity,groups))
 local unsupported_held,held_reason=Capture.chord_sources(requests)
 check(unsupported_held==nil and held_reason=='physical-input-modifiers-unsupported','actual native depressed Shift cannot be guessed into physical source admission')
 check(held.base_mods==1 and held.latched_mods==0 and held.mods==1 and held.locked_mods==0 and released.observed_current()==false,'real native depressed Shift is distinct from a latch')
 assert(_xtest.XTestFakeKeyEvent(_control,50,0,0)~=0);X11.XSync(_control,0)
 assert(_xtest.XTestFakeKeyEvent(_control,50,1,0)~=0);X11.XSync(_control,0)
 local held_again=assert(Probe.read_input_state(identity,groups))
 check(held_again.base_mods==1 and held_again.input_generation>held.input_generation and held.observed_current()==false,'native held Shift away-and-back revokes input seal despite equal final depressed mask')
 assert(_xtest.XTestFakeKeyEvent(_control,50,0,0)~=0);X11.XSync(_control,0)
 local neutral=assert(Probe.read_input_state(identity,groups))
 local recovered=assert(Capture.chord_sources(requests))
 check(Capture.chord_source_current(recovered)==true and Capture.chord_source_view(recovered)~=nil,'fresh physical source admission recovers only after actual native neutral state acknowledgement')
 check(neutral.mods==0 and neutral.base_mods==0 and neutral.latched_mods==0 and neutral.locked_mods==0 and held_again.observed_current()==false,'native input restoration is acknowledged without clearing a latch in production')
 local original_read=Probe.read_input_state
 local injected=false
 Probe.read_input_state=function(...)
  local receipt,why=original_read(...)
  if receipt and not injected then
   injected=true;assert(X11.XkbLatchModifiers(_control,0x100,1,1)~=0);X11.XSync(_control,0)
  end
  return receipt,why
 end
 local changed,changed_reason=Capture.chord_sources(requests)
 Probe.read_input_state=original_read
 assert(X11.XkbLatchModifiers(_control,0x100,1,0)~=0);X11.XSync(_control,0)
 check(injected and changed==nil and changed_reason=='physical-source-changed','actual native latch inserted during read callback cannot escape final physical source currency')
 Probe.close()
 check(neutral.observed_current()==false,'native connection retirement revokes input-state seal')
 local reopened=assert(Probe.read_input_state(identity,groups))
 check(reopened.input_generation>neutral.input_generation and reopened.observed_current()==true,'new native connection establishes a new input-state observation epoch')
end

--- Two independently owned displays with identical complete map/RMLVO.
--- These eight controls retain the independent connection-lifetime oracle.
local function connection_lifetime_qualification(first_display, keymap)
 assert(Capture.load(keymap, "C.UTF-8"))
 local codes={2,3,4,5,6,7,8,9,10,11}
 local levels=assert(Capture.number_row_levels(codes))
 local view=assert(Capture.number_row_view(levels,codes))
 local namespace=assert(Probe.capture_number_row_namespace("de",view.keymap,view.groups))
 check(Probe.number_row_namespace_view(namespace)~=nil,"first native namespace is owned")
 local first_pid,first_control=_server_pid,_control
 -- A failed second acquisition must never duplicate the borrowed first owner.
 _server_pid,_control=nil,nil
 local started,second_display=pcall(start)
 _second_server_pid,_second_control=_server_pid,_control
 _server_pid,_control=first_pid,first_control
 assert(started,second_display)
 assert(second_display~=first_display,"owned displays must differ")
 layout(second_display,"de")
 -- No stale saved Display may be dereferenced after this M.read reconnect.
 check(Probe.number_row_namespace_view(namespace)==nil,"saved native display refuses an identical-map reconnect before property read")
 check(Probe.read(view.keymap,view.groups)~=nil,"second identical native source is independently acknowledged")
 local other=assert(Probe.capture_number_row_namespace("de",view.keymap,view.groups))
 check(Probe.number_row_namespace_view(other)~=nil,"second native namespace is owned")
 ffi.C.setenv("DISPLAY",first_display,1)
 check(Probe.number_row_namespace_view(other)==nil,"second saved display refuses a native reconnect back")
 check(Probe.number_row_namespace_view(namespace)==nil,"returning to equal bytes cannot revive the first native issuer")
 local fresh=assert(Probe.capture_number_row_namespace("de",view.keymap,view.groups))
 check(Probe.number_row_namespace_view(fresh)~=nil,"fresh native issuer works after acknowledged reconnect")
 Probe.close()
 check(Probe.number_row_namespace_view(fresh)==nil,"native close revokes the fresh namespace issuer")
end

print("=== native X11 source qualification on an owned Xvfb server ===")
local ok, err = xpcall(function()
	local display = start()
	layout(display, "us,fr")
	group(1)
	check(Capture.load(server_map(display), "C.UTF-8"), "the driver loads the actual server map after French is selected")
	local first, reason = Capture.source_generation()
	check(first ~= nil, "an externally selected initial group is acknowledged (" .. tostring(reason) .. ")")
	local initial = Capture.direct_sources({ 30, 40 })
	check(plain(initial, 30) and plain(initial, 30).text == "q", "the initial desktop French group is independent of reconstructed group0")
	check(plain(initial, 40) and plain(initial, 40).text == "ù", "French ù qualifies on the actual server's bare physical key")
	check(Capture.peek_text(30) == "q", "native group acknowledgement also seeds the capture owner")

	group(0)
	group(1)
	local returned = Capture.source_generation()
	check(first and returned and returned > first, "actual away-and-back group events fence an old receipt even when the final group matches")
	X11.XkbLockModifiers(_control, 0x100, 2, 2)
	X11.XSync(_control, 0)
	check(Capture.source_generation() == returned, "modifier/lock changes do not masquerade as physical source changes")
	local locked = plain(Capture.direct_sources({ 40 }), 40)
	check(locked and locked.text == "ù", "locked modifiers cannot alter plain source qualification")
	X11.XkbLockModifiers(_control, 0x100, 2, 0)
	X11.XSync(_control, 0)
	input_state_qualification(native_identity(server_map(display)), 2)

	group(0)
	local pending, why = Capture.source_generation()
	check(pending == nil and why == "native-group-resynchronized", "an external group change fences the resynchronization boundary")
	local switched = Capture.source_generation()
	check(switched and returned and switched > returned, "the next event uses an acknowledged new group epoch")
	local us = plain(Capture.direct_sources({ 30 }), 30)
	check(us and us.text == "a", "the new actual desktop US group is proved without guessing")

	layout(display, "de")
	local stale, mismatch = Capture.source_generation()
	check(stale == nil and mismatch == "native-keymap-unacknowledged", "a changed actual server keymap invalidates the loaded capture map before delivery")
	check(Capture.direct_sources({ 30 }) == nil, "an unacknowledged map cannot silently reuse old physical candidates")
	local german_map = server_map(display)
	check(Capture.load(german_map, "C.UTF-8"), "a fresh native map can be acknowledged through the same owner")
	local german = Capture.direct_sources({ 39 })
	check(plain(german, 39) and plain(german, 39).text == "ö", "the recommendation source works on a standard non-Ergopti layout")
	-- Exercise order independence even when the installed codec happens to agree.
	local alias_z, alias_y = "alias <LatZ> = <AD06>;", "alias <LatY> = <AB01>;"
	local reordered, moved = german_map:gsub("alias <Lat[YZ]> = <A[BD]0[16]>;", function(line)
		assert(line == alias_z or line == alias_y, "the complete alias relation must remain unchanged")
		return line == alias_z and alias_y or alias_z
	end)
	check(moved == 2 and Capture.load(reordered, "C.UTF-8"), "the complete alias relations may be declared in either order")
	local reordered_generation, reordered_rows = Capture.source_generation(), Capture.direct_sources({ 39 })
	check(reordered_generation and plain(reordered_rows, 39) and plain(reordered_rows, 39).text == "ö", "alias declaration order cannot refuse a matching native source")
	-- Input spacing is canonicalized by the real parser, independently of order.
	local spaced, spaced_aliases = reordered:gsub("alias <Lat[YZ]> = <A[BD]0[16]>;", function(line)
		return (line:gsub(" = ", "\t =\t "))
	end)
	check(spaced_aliases == 2 and Capture.load(spaced, "C.UTF-8"), "native parsing accepts horizontally spaced complete alias relations")
	local spaced_generation, spaced_rows = Capture.source_generation(), Capture.direct_sources({ 39 })
	check(spaced_generation and plain(spaced_rows, 39) and plain(spaced_rows, 39).text == "ö", "native alias spacing and order preserve the exact matching source")
	-- Aliases change physical identity even when this probed character is unchanged.
	local altered, replacements = german_map:gsub("alias <LatZ> = <AD06>;", "alias <LatZ> = <AD07>;")
	check(replacements == 1, "the real German map supplies exactly one alias target adversary")
	check(Capture.load(altered, "C.UTF-8"), "the alias-altered map remains locally parseable")
	local detached = Capture._capture_direct_sources_for_test({ 39 })
	check(plain(detached, 39) and plain(detached, 39).text == "ö", "the detached altered map preserves the probed symbol")
	local alias_generation, alias_reason = Capture.source_generation()
	check(alias_generation == nil and alias_reason == "native-keymap-unacknowledged", "a changed alias target cannot acquire a desktop receipt")
	local alias_rows, alias_rows_reason = Capture.direct_sources({ 39 })
	check(alias_rows == nil and alias_rows_reason == "native-keymap-unacknowledged", "matching symbols cannot hide a different alias target")
	check(Capture.load(german_map, "C.UTF-8"), "the original server map restores the acknowledged capture owner")
	local restored_generation, restored_rows = Capture.source_generation(), Capture.direct_sources({ 39 })
	check(restored_generation and plain(restored_rows, 39) and plain(restored_rows, 39).text == "ö", "source delivery recovers only after the complete server map matches")

	local dead_results = dofile("tests/hardware/run_xkb_dead_symbols.lua")
	check(dead_results.passed == 8 and dead_results.failed == 0, "all eight independent actual native chord/dead symbol cases pass")
	check(Capture.load(german_map, "C.UTF-8"), "the real server capture owner is restored after independent detached library cases")

	connection_lifetime_qualification(display, german_map)

	DisplayServer._set_for_test(DisplayServer.WAYLAND)
	local unsupported, wayland = Capture.source_generation()
	check(unsupported == nil and wayland == "native-wayland-seat-unqualified", "a matching XWayland map alone never qualifies a native Wayland seat")
	check(Capture.direct_sources({ 39 }) == nil, "the genuine native-seat limit stays inactive rather than assuming group0")
	DisplayServer.refresh()
end, debug.traceback)
if not ok then _failures = _failures + 1 io.stderr:write(tostring(err) .. "\n") end
cleanup()
print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
