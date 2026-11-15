--- tests/hardware/lib/x11_active_layout.lua

--- ==============================================================================
--- MODULE: The Layout An X Server Types With
--- DESCRIPTION:
--- Prints what the key right of Tab (<AD01>) types on the first level of the
--- X server's (or XWayland's) locked XKB group: "q" on us, "a" on fr. Read
--- from the server's own state and keymap, independent of the input source
--- adapter under test, which reads gsettings, the KDE daemon or setxkbmap.
--- XWayland under mutter publishes no layout names, so the key is the name.
--- ==============================================================================

local ffi = require("ffi")
ffi.cdef([[
	struct _XDisplay;
	struct _XDisplay *XOpenDisplay(const char *);
	int XCloseDisplay(struct _XDisplay *);
	typedef struct {
		unsigned char group, locked_group;
		unsigned short base_group, latched_group;
		unsigned char mods, base_mods, latched_mods, locked_mods, compat_state;
		unsigned char grab_mods, compat_grab_mods, lookup_mods, compat_lookup_mods;
		unsigned short ptr_buttons;
	} ActiveLayoutXkbState;
	int XkbGetState(struct _XDisplay *, unsigned int, ActiveLayoutXkbState *);
]])

local CORE_KEYBOARD = 0x100
local x11 = ffi.load("libX11.so.6")
local display = x11.XOpenDisplay(nil)
assert(display ~= nil, "cannot open $DISPLAY")
local state = ffi.new("ActiveLayoutXkbState[1]")
assert(x11.XkbGetState(display, CORE_KEYBOARD, state) == 0, "XkbGetState failed")
local group = tonumber(state[0].group) + 1
x11.XCloseDisplay(display)

local handle = assert(io.popen('xkbcomp -xkb "$DISPLAY" - 2>/dev/null', "r"))
local keymap = handle:read("*a")
handle:close()
-- What <AD01> (the key right of Tab) types on the group's first level.
local block = assert(keymap:match("key <AD01>%s*(%b{})"), "the keymap has no <AD01>")
local symbols = block:match("symbols%[[Gg]roup" .. group .. "%]%s*=%s*(%b[])")
	or (group == 1 and block:match("(%b[])")) or nil
assert(symbols, "group " .. group .. " has no symbols on <AD01>")
print((symbols:match("^%[%s*([%w_]+)")))
