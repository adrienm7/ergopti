--- tests/hardware/run_tray_symbols.lua

--- ==============================================================================
--- MODULE: The Tray Binding Names Libraries and Symbols That Exist
--- DESCRIPTION:
--- Loads the three shared libraries the tray FFI binding declares, and resolves
--- every C symbol it calls, against a real Linux with those packages installed.
---
--- WHY THIS IS WORTH A HARNESS OF ITS OWN:
--- An FFI binding is a set of NAMES — three sonames and thirteen symbols — and
--- every one of them is a claim about a library this project does not ship. A
--- wrong soname or a symbol that moved between releases produces exactly one
--- symptom: no tray icon. Not an error the user can act on, not a crash. The menu
--- simply is not there, and the daemon goes on expanding hotstrings perfectly, so
--- nothing suggests where to look.
---
--- No unit test can catch it, because a unit test has no libayatana to load and
--- must stub it — and a stub answers to whatever name the binding asks for, which
--- is the one thing that must not be assumed.
---
--- WHAT IT DELIBERATELY DOES NOT DO: create the indicator, run a GTK main loop or
--- expect an icon to appear. Those need a panel hosting a StatusNotifierWatcher,
--- which is a desktop rather than a runner. What is checkable here is the half
--- that fails silently; whether the icon is VISIBLE stays in HARDWARE.md §9, with
--- its per-desktop caveats.
---
--- Exit 0 = every name resolves. 1 = one does not. 2 = the libraries are not
--- installed, which is a property of the machine and not of the binding.
--- ==============================================================================

-- Mirrored from platform/tray/appindicator.lua. Written out rather than imported
-- because importing would make the harness agree with the binding by
-- construction: if the binding renamed a symbol to something absent, a shared
-- list would rename it here too and the check would pass.
local CANDIDATE_LIBS = {
	indicator = { "ayatana-appindicator3.so.1", "ayatana-appindicator3", "appindicator3.so.1" },
	gtk       = { "gtk-3.so.0", "gtk-3" },
	gobject   = { "gobject-2.0.so.0", "gobject-2.0" },
}

local EXPECTED_SYMBOLS = {
	indicator = {
		"app_indicator_new",
		"app_indicator_set_status",
		"app_indicator_set_menu",
		"app_indicator_set_icon_full",
		"app_indicator_set_title",
	},
	gtk = {
		"gtk_init_check",
		"gtk_events_pending",
		"gtk_main_iteration_do",
		"gtk_menu_new",
		"gtk_menu_shell_append",
		"gtk_menu_item_set_submenu",
		"gtk_widget_show_all",
		"gtk_widget_set_sensitive",
		"gtk_check_menu_item_set_active",
	},
	gobject = {
		"g_signal_connect_data",
	},
}

local _failures = 0
local _checks   = 0

--- @param condition boolean
--- @param what string
local function check(condition, what)
	_checks = _checks + 1
	if condition then
		print(string.format("  ok   %s", what))
	else
		_failures = _failures + 1
		print(string.format("  FAIL %s", what))
	end
end

--- @param message string
local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

print("=== tray FFI names, against the real libraries ===")

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then abort("no LuaJIT FFI on this interpreter.") end

-- Declared here so the symbol lookups below have a prototype to bind to. Only
-- the names matter; the signatures are the binding's business and are exercised
-- by the driver itself.
pcall(ffi.cdef, [[
	typedef void  GtkWidget;
	typedef void  AppIndicator;
	typedef void* gpointer;
	AppIndicator* app_indicator_new(const char*, const char*, int);
	void  app_indicator_set_status(AppIndicator*, int);
	void  app_indicator_set_menu(AppIndicator*, GtkWidget*);
	void  app_indicator_set_icon_full(AppIndicator*, const char*, const char*);
	void  app_indicator_set_title(AppIndicator*, const char*);
	int   gtk_init_check(int*, char***);
	int   gtk_events_pending(void);
	int   gtk_main_iteration_do(int);
	GtkWidget* gtk_menu_new(void);
	void  gtk_menu_shell_append(GtkWidget*, GtkWidget*);
	void  gtk_menu_item_set_submenu(GtkWidget*, GtkWidget*);
	void  gtk_widget_show_all(GtkWidget*);
	void  gtk_widget_set_sensitive(GtkWidget*, int);
	void  gtk_check_menu_item_set_active(GtkWidget*, int);
	unsigned long g_signal_connect_data(gpointer, const char*, void*, gpointer, void*, int);
]])

--- Loads the first soname that works.
--- @param names table
--- @return userdata|nil handle, string tried
local function load_any(names)
	for _, name in ipairs(names) do
		local ok, handle = pcall(ffi.load, name)
		if ok and handle then return handle, name end
	end
	return nil, table.concat(names, ", ")
end

local missing_libraries = {}
local handles = {}
for key, names in pairs(CANDIDATE_LIBS) do
	local handle, which = load_any(names)
	if handle then
		handles[key] = handle
		print(string.format("  loaded %s as %s", key, which))
	else
		missing_libraries[#missing_libraries + 1] = key .. " (tried: " .. which .. ")"
	end
end

if #missing_libraries > 0 then
	-- Not a failure of the binding: a machine without libayatana simply has no
	-- tray to bind to, and reporting that as a bug sends the reader to the wrong
	-- file. The install script's dependency list is what covers it.
	abort("libraries not installed: " .. table.concat(missing_libraries, "; "))
end

for key, symbols in pairs(EXPECTED_SYMBOLS) do
	for _, symbol in ipairs(symbols) do
		-- Indexing the handle is what forces the dynamic loader to resolve the
		-- symbol; a name that is not there raises rather than returning nil.
		local ok = pcall(function() return handles[key][symbol] end)
		check(ok, string.format("%s exports %s", key, symbol))
	end
end

print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
