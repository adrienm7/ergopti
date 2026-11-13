--- layouts/adapters/input_source_group_worker.lua
--- The owned, deadline-bounded X11 group activation child. This file needs
--- only LuaJIT's built-in ffi, so its literal script path is sufficient even
--- when the application directory contains Lua template delimiters.
local ffi = require("ffi")

local M = {}

-- Declared only when the child runs: requiring this file (the adapter
-- presence check does) must neither touch ffi.C nor exit the caller.
local DECLARATIONS = [[
struct _XDisplay;
struct _XDisplay *XOpenDisplay(const char *);
int XCloseDisplay(struct _XDisplay *);
int XSync(struct _XDisplay *, int);
int XkbLockGroup(struct _XDisplay *, unsigned int, unsigned int);
typedef struct {
  unsigned char group, locked_group;
  unsigned short base_group, latched_group;
  unsigned char mods, base_mods, latched_mods, locked_mods, compat_state;
  unsigned char grab_mods, compat_grab_mods, lookup_mods, compat_lookup_mods;
  unsigned short ptr_buttons;
} ErgoptiXkbState;
int XkbGetState(struct _XDisplay *, unsigned int, ErgoptiXkbState *);
int getppid(void);
int prctl(int, ...);
]]

--- Locks the core keyboard on its first group for the parent process.
--- @param argv table { parent_pid, x11_soname }
--- @return boolean accepted
function M.run(argv)
	local parent = tonumber(argv[1])
	local soname = argv[2]
	assert(parent and parent > 0 and parent % 1 == 0 and argv[3] == nil, "invalid parent")
	ffi.cdef(DECLARATIONS)
	assert(type(soname) == "string" and soname:match("^[%w_+%.%-]+$"), "invalid X11 soname")
	assert(ffi.C.prctl(1, ffi.cast("unsigned long", 9), 0, 0, 0) == 0, "parent binding failed")
	assert(tonumber(ffi.C.getppid()) == parent, "parent already exited")
	local x = ffi.load(soname)
	local display = assert(x.XOpenDisplay(nil), "X display unavailable")
	local ok, accepted = pcall(function()
		local device = 0x100 -- XkbUseCoreKbd
		if x.XkbLockGroup(display, device, 0) == 0 then return false end
		x.XSync(display, 0)
		local state = ffi.new("ErgoptiXkbState[1]")
		return x.XkbGetState(display, device, state) == 0
			and state[0].group == 0 and state[0].locked_group == 0
	end)
	x.XCloseDisplay(display)
	return ok and accepted == true
end

if type(arg) == "table" and type(arg[0]) == "string"
	and arg[0]:gsub("\\", "/"):match("([^/]+)$") == "input_source_group_worker.lua" then
	local ok, accepted = pcall(M.run, arg)
	os.exit(ok and accepted == true and 0 or 1)
end

return M
