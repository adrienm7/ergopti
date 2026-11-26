--- tests/hardware/run_dialog_keyboard_walk.lua

--- ==============================================================================
--- MODULE: Live Keyboard Walk of the Owned Dialogs (Linux)
--- DESCRIPTION:
--- WCAG 2.1.1, 2.1.2 and 2.4.3 for the Linux driver's native windows: every
--- dialog of core/ui/ui/dialog_host.lua (question, message, entry, entry with
--- offered values, list, file and folder choosers) is built by the real
--- module, shown on a real X server, and walked with real Tab and Shift+Tab
--- key presses sent through XTest. The Windows driver's walk
--- (test_native_keyboard_walk.ahk) holds the same rules: every focusable
--- control is reached, no control keeps the focus, no stop is met twice in a
--- round, and Shift+Tab retraces Tab. Escape then closes the dialog. A
--- refusal case, a dialog whose window swallows Tab, proves the walk fails on
--- a trap.
---
--- FEATURES & RATIONALE:
--- 1. The dialogs come from M.main through its binder seam, which wraps the
---    module's own binding and replaces only gtk_dialog_run: the controls,
---    their order and their focus flags are the production ones.
--- 2. Keys go through the X server (XTest) to the dialog's own X window, as
---    a user's would, not through gtk_widget_child_focus.
--- 3. The file and folder choosers are GTK's own widget: its sidebar and path
---    bar are GTK's layout, whose Shift+Tab takes one stop Tab skips (the
---    path bar's scroll button). They are held to no trap in either
---    direction and to reaching the file list and the answer buttons.
--- 4. Run under xvfb-run with LuaJIT; it exits non-zero when a check fails.
--- ==============================================================================

local here = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/tests/hardware/[^/]+$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. here .. "/../_shared/?.lua;" .. here
	.. "/../_shared/?/init.lua;" .. package.path

local ffi = require("ffi")
local Host = require("core.ui.ui.dialog_host")

assert(os.getenv("DISPLAY"), "the keyboard walk needs an X display (run it under xvfb-run)")
assert(os.getenv(Host.GUARD_VARIABLE) == nil, "the keyboard walk must run an unguarded dialog host")

ffi.cdef([[
	typedef unsigned long XID;
	void*  gtk_window_get_focus(void *window);
	void   gtk_window_present(void *window);
	void*  gtk_widget_get_window(void *widget);
	const char* gtk_widget_get_name(void *widget);
	int    gtk_widget_get_can_focus(void *widget);
	int    gtk_widget_get_mapped(void *widget);
	int    gtk_widget_is_sensitive(void *widget);
	void   gtk_widget_set_can_focus(void *widget, int can_focus);
	void   gtk_widget_show(void *widget);
	void*  gtk_window_get_type(void);
	size_t gtk_container_get_type(void);
	int    g_type_check_instance_is_a(void *instance, size_t type);
	typedef void (*ErgoptiWalkEach)(void *widget, void *data);
	typedef void (*ErgoptiWalkResponse)(void *dialog, int response, void *data);
	typedef int (*ErgoptiWalkKey)(void *widget, void *event, void *data);
	void   gtk_container_forall(void *container, ErgoptiWalkEach callback, void *data);
	int    gtk_events_pending(void);
	int    gtk_main_iteration_do(int blocking);
	void*  gdk_display_get_default(void);
	void*  gdk_x11_display_get_xdisplay(void *display);
	XID    gdk_x11_window_get_xid(void *window);
	int    XSetInputFocus(void *display, XID focus, int revert, unsigned long time);
	unsigned char XKeysymToKeycode(void *display, unsigned long keysym);
	int    XFlush(void *display);
	int    XSync(void *display, int discard);
	int    XTestFakeKeyEvent(void *display, unsigned int keycode, int is_press, unsigned long delay);
]])

local gdk = ffi.load("libgdk-3.so.0")
local xtest = ffi.load("libXtst.so.6")
local x11 = ffi.load("libX11.so.6")

local XK_TAB, XK_SHIFT_L, XK_ESCAPE = 0xFF09, 0xFFE1, 0xFF1B
local REVERT_TO_PARENT = 2
local GTK_RESPONSE_CANCEL, GTK_RESPONSE_DELETE_EVENT = -6, -4
-- Enough presses to cross the file chooser's controls twice.
local MAX_STOPS = 80
-- How long a key may take to move the focus, in seconds.
local KEY_SETTLE_SECONDS = 2

local failures = 0
-- The walk checks of the case being run, refused ones counted apart.
local walk_refusals = 0

--- Reports one check.
--- @param ok boolean
--- @param message string
local function check(ok, message)
	print((ok and "PASS " or "FAIL ") .. message)
	if not ok then failures = failures + 1 end
end

--- Records one walk check: a failure counts against the case, unless the case
--- is a refusal, which must fail at least one.
--- @param case table
--- @param ok boolean
--- @param message string
local function walk_check(case, ok, message)
	if case.refused then
		if not ok then walk_refusals = walk_refusals + 1 end
		print((ok and "     " or "SEEN ") .. message)
	else
		check(ok, message)
	end
end

--- Runs the GTK main loop until nothing is pending.
--- @param gtk userdata
local function pump(gtk)
	while gtk.gtk_events_pending() ~= 0 do gtk.gtk_main_iteration_do(0) end
end

--- Runs the main loop until a condition holds or the settle time passes.
--- @param gtk userdata
--- @param done function
--- @return boolean
local function settle(gtk, done)
	local deadline = os.clock() + KEY_SETTLE_SECONDS
	repeat
		pump(gtk)
		if done() then return true end
	until os.clock() > deadline
	return done()
end

-- Containers GTK 3 marks focusable that only hand the focus to their child.
local FORWARDING = { GtkScrolledWindow = true, GtkViewport = true }

--- Lists the widgets a user can focus: focusable, mapped and sensitive.
--- @param gtk userdata
--- @param root userdata
--- @return table set Widget address to its name.
local function focusable(gtk, root)
	local found = {}
	local container_type = gtk.gtk_container_get_type()
	local each
	each = ffi.cast("ErgoptiWalkEach", function(widget)
		if gtk.gtk_widget_get_mapped(widget) == 0 then return end
		local name = ffi.string(gtk.gtk_widget_get_name(widget))
		if gtk.gtk_widget_get_can_focus(widget) ~= 0 and gtk.gtk_widget_is_sensitive(widget) ~= 0
			and not FORWARDING[name] then
			found[tostring(ffi.cast("uintptr_t", widget))] = name
		end
		if gtk.g_type_check_instance_is_a(widget, container_type) ~= 0 then
			gtk.gtk_container_forall(widget, each, nil)
		end
	end)
	gtk.gtk_container_forall(root, each, nil)
	each:free()
	return found
end

--- Sends one key press and release through the X server.
--- @param display userdata
--- @param keysym number
--- @param shifted boolean
local function press(display, keysym, shifted)
	local shift = x11.XKeysymToKeycode(display, XK_SHIFT_L)
	local key = x11.XKeysymToKeycode(display, keysym)
	assert(key ~= 0 and shift ~= 0, "the X server has no keycode for Tab, Shift or Escape")
	if shifted then xtest.XTestFakeKeyEvent(display, shift, 1, 0) end
	xtest.XTestFakeKeyEvent(display, key, 1, 0)
	xtest.XTestFakeKeyEvent(display, key, 0, 0)
	if shifted then xtest.XTestFakeKeyEvent(display, shift, 0, 0) end
	x11.XSync(display, 0)
end

--- The focused widget of a window, as an address.
--- @param gtk userdata
--- @param window userdata
--- @return string|nil
local function focus_of(gtk, window)
	local widget = gtk.gtk_window_get_focus(window)
	if widget == nil then return nil end
	return tostring(ffi.cast("uintptr_t", widget))
end

--- Moves the focus with one key and returns the new stop.
--- @param gtk userdata
--- @param display userdata
--- @param window userdata
--- @param shifted boolean
--- @return string|nil
local function step(gtk, display, window, shifted)
	local before = focus_of(gtk, window)
	press(display, XK_TAB, shifted)
	settle(gtk, function() return focus_of(gtk, window) ~= before end)
	return focus_of(gtk, window)
end

--- Walks a shown dialog with Tab, then back with Shift+Tab.
--- @param gtk userdata
--- @param dialog userdata
--- @param case table { name, expect_all, required }
local function walk(gtk, dialog, case)
	local display = gdk.gdk_x11_display_get_xdisplay(gdk.gdk_display_get_default())
	local controls = focusable(gtk, dialog)

	-- Forward: a round ends when the first stop comes back.
	local forward, seen, repeated = {}, {}, false
	local first = step(gtk, display, dialog, false)
	local stop = first
	for _ = 1, MAX_STOPS do
		if stop == nil then break end
		if seen[stop] then repeated = stop ~= first; break end
		seen[stop] = true
		forward[#forward + 1] = stop
		stop = step(gtk, display, dialog, false)
	end
	walk_check(case, stop == first and not repeated, case.name .. ": Tab comes back to its first stop after one round of "
		.. #forward .. " stops")
	walk_check(case, #forward > 1, case.name .. ": Tab moves the focus between controls")

	local missed = {}
	for address, name in pairs(controls) do
		if case.expect_all and not seen[address] then missed[#missed + 1] = name end
	end
	walk_check(case, #missed == 0, case.name .. ": every focusable control is reached" .. (#missed > 0
		and " (missed " .. table.concat(missed, ", ") .. ")" or ""))
	for _, name in ipairs(case.required or {}) do
		local reached = false
		for address in pairs(seen) do
			if controls[address] == name then reached = true end
		end
		walk_check(case, reached, case.name .. ": Tab reaches a " .. name)
	end

	-- Backward: Shift+Tab from the first stop retraces the round; in GTK's
	-- own chooser it must only come back to its first stop.
	local backward = {}
	stop = first
	for _ = 1, MAX_STOPS do
		stop = step(gtk, display, dialog, true)
		backward[#backward + 1] = stop
		if stop == first or stop == nil or #backward >= #forward and not case.gtk_layout then break end
	end
	if case.gtk_layout then
		walk_check(case, stop == first, case.name .. ": Shift+Tab comes back to its first stop after "
			.. #backward .. " stops")
		return
	end
	local retraced = #forward > 0 and #backward == #forward
	for index = 1, #backward do
		if backward[index] ~= forward[((-index) % #forward) + 1] then retraced = false end
	end
	walk_check(case, retraced, case.name .. ": Shift+Tab retraces Tab")
end

-- The dialogs, as their callers open them.
local CASES = {
	{ name = "question", argv = { "--question", "--no-markup", "--text=Delete the profile?",
		"--ok-label=Delete", "--cancel-label=Keep" }, expect_all = true },
	{ name = "message", argv = { "--error", "--no-markup", "--text=The file could not be saved." },
		expect_all = true, single = true },
	{ name = "entry", argv = { "--entry", "--no-markup", "--text=Delay (ms)", "--entry-text=150" },
		expect_all = true },
	{ name = "entry with offered values", argv = { "--entry", "--no-markup", "--text=Model", "--entry-text=a",
		"a", "b" }, expect_all = true },
	{ name = "list", argv = { "--list", "--no-markup", "--text=Choose an application", "--column=Name",
		"--column=Id", "--hide-column=2", "Files", "org.gnome.Nautilus", "Text", "org.gnome.TextEditor" },
		expect_all = true },
	{ name = "file chooser", argv = { "--file-selection", "--filename=/tmp/" },
		gtk_layout = true, required = { "GtkButton", "GtkTreeView" } },
	{ name = "folder chooser", argv = { "--file-selection", "--directory", "--filename=/tmp/" },
		gtk_layout = true, required = { "GtkButton", "GtkTreeView" } },
	-- A window that swallows every Tab: the walk must refuse it.
	{ name = "refusal, a window that swallows Tab", argv = { "--entry", "--no-markup", "--text=Trap" },
		expect_all = true, refused = true, prepare = function(gtk, dialog)
			local swallow = ffi.cast("ErgoptiWalkKey", function() return 1 end)
			gtk.g_signal_connect_data(dialog, "key-press-event", ffi.cast("GCallback", swallow), nil, nil, 0)
		end },
}

--- Shows a dialog and gives its X window the keyboard.
--- @param gtk userdata
--- @param dialog userdata
--- @return userdata display
local function show(gtk, dialog)
	local display = gdk.gdk_x11_display_get_xdisplay(gdk.gdk_display_get_default())
	gtk.gtk_window_present(dialog)
	settle(gtk, function() return gtk.gtk_widget_get_mapped(dialog) ~= 0 end)
	x11.XSetInputFocus(display, gdk.gdk_x11_window_get_xid(gtk.gtk_widget_get_window(dialog)), REVERT_TO_PARENT, 0)
	x11.XSync(display, 0)
	pump(gtk)
	return display
end

--- Runs one case through the real module.
--- @param case table
local function run_case(case)
	local walked, response = false, nil
	walk_refusals = 0
	local function binder()
		local lib, reason = Host.bind()
		assert(lib, reason)
		local real = lib.gtk
		lib.gtk = setmetatable({
			gtk_dialog_run = function(dialog)
				local display = show(real, dialog)
				if case.prepare then case.prepare(real, dialog) end
				if case.single then
					-- One button: Tab has nowhere to go, the focus must stay on it.
					local first = focus_of(real, dialog)
					local after = step(real, display, dialog, false)
					walk_check(case, first ~= nil and after == first, case.name
						.. ": its one button keeps the focus under Tab")
				else
					walk(real, dialog, case)
				end
				walked = true
				if case.refused then return GTK_RESPONSE_CANCEL end
				-- Escape closes the dialog, as its close box would.
				local answered = ffi.cast("ErgoptiWalkResponse", function(_, given) response = given end)
				real.g_signal_connect_data(dialog, "response", ffi.cast("GCallback", answered), nil, nil, 0)
				-- gtk_dialog_run keeps the window on a delete request and
				-- reports it as a response; the module destroys it after.
				local kept = ffi.cast("ErgoptiWalkKey", function() return 1 end)
				real.g_signal_connect_data(dialog, "delete-event", ffi.cast("GCallback", kept), nil, nil, 0)
				press(display, XK_ESCAPE, false)
				settle(real, function() return response ~= nil end)
				return response or GTK_RESPONSE_CANCEL
			end,
		}, { __index = function(_, name) return real[name] end })
		return lib
	end
	local sink = { write = function() return true end, flush = function() return true end }
	local status = Host.main(case.argv, sink, io.stderr, binder)
	check(walked, case.name .. ": the walk ran on the shown dialog")
	if case.refused then
		check(walk_refusals > 0, case.name .. ": the walk refuses it")
		return
	end
	check(response == GTK_RESPONSE_DELETE_EVENT, case.name .. ": Escape closes it")
	check(status == (case.single and Host.EXIT_ACCEPTED or Host.EXIT_CANCELLED), case.name
		.. ": closed by Escape, it gives no answer")
end

for _, case in ipairs(CASES) do run_case(case) end

print(failures == 0 and "dialog keyboard walk: every case passed" or ("dialog keyboard walk: " .. failures
	.. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
