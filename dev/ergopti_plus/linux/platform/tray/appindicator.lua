--- platform/tray/appindicator.lua

--- ==============================================================================
--- MODULE: Tray Indicator (Linux, LuaJIT FFI)
--- DESCRIPTION:
--- A real StatusNotifierItem: a process that stays on the session bus, owns an
--- icon, and answers the menu protocol for as long as the daemon runs.
---
--- WHY THE PREVIOUS TRAY COULD NOT HAVE WORKED:
--- It was assembled from one-shot `gdbus` invocations. `gdbus call
--- org.freedesktop.DBus.RequestName` acquires a bus name in the gdbus PROCESS,
--- which then exits — releasing the name immediately. The dbusmenu XML was
--- serialised into a temp file nothing read, no icon was ever set, an
--- ItemActivated signal nothing emitted was monitored, and pump() blocked on a
--- pipe read. Every piece of it was individually plausible and none of it could
--- ever have produced a tray icon, because SNI is not a call you make — it is an
--- object you HOST, and a command-line tool cannot host one.
---
--- WHY libayatana-appindicator AND NOT A HAND-ROLLED DBUSMENU:
--- Serving com.canonical.dbusmenu means answering GetLayout,
--- GetGroupProperties, Event and AboutToShow with correctly typed GVariants,
--- and the marshalling alone is more code than the rest of this driver's UI. The
--- library does it, it is packaged on every distribution family, and it is what
--- every Rust and Go daemon that shows a tray icon uses through one binding or
--- another. This module is the binding.
---
--- FEATURES & RATIONALE:
--- 1. Nothing blocks. The menu is a GtkMenu and the event loop is drained with
---    gtk_main_iteration_do(FALSE), so pump() returns whether or not anything
---    happened — unlike the blocking pipe read it replaces, which stalled the
---    keystroke path until someone clicked the tray.
--- 2. Callbacks are pinned. A GCallback cast from a Lua function is collected
---    the moment nothing references it, and the crash lands inside GTK with no
---    Lua traceback. Every one is kept in a table for the life of the menu.
--- 3. Rebuilt wholesale. A menu is discarded and re-created on every change
---    rather than mutated: mutation means tracking which widget corresponds to
---    which row, and the row set changes shape (categories appear, counts move)
---    on nearly every rebuild.
--- 4. Fails loudly and specifically. A missing library is reported with the
---    package name for the running distribution family, because "no tray icon"
---    is otherwise indistinguishable from a daemon that did not start.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "platform.tray.appindicator"




-- ==============================================
-- ==============================================
-- ======= 1/ Library constants =================
-- ==============================================
-- ==============================================

-- AppIndicatorCategory. APPLICATION_STATUS is what a background daemon is; the
-- categories exist so panels can group icons, and a keyboard driver is not
-- hardware, communications or system services.
local CATEGORY_APPLICATION_STATUS = 0

-- AppIndicatorStatus.
local STATUS_ACTIVE = 1

-- The sonames, not the -dev symlinks: a user's machine has libayatana-*.so.1 and
-- no libayatana-*.so, so loading the unversioned name succeeds on every
-- developer's machine and fails on every user's.
local CANDIDATE_LIBS = {
	indicator = { "ayatana-appindicator3.so.1", "ayatana-appindicator3", "appindicator3.so.1" },
	gtk       = { "gtk-3.so.0", "gtk-3" },
	gobject   = { "gobject-2.0.so.0", "gobject-2.0" },
}

-- What to tell a user who has none of them, by package manager.
local PACKAGE_HINTS = {
	{ probe = "apt-get", hint = "sudo apt-get install libayatana-appindicator3-1" },
	{ probe = "dnf",     hint = "sudo dnf install libayatana-appindicator-gtk3" },
	{ probe = "pacman",  hint = "sudo pacman -S libayatana-appindicator" },
	{ probe = "zypper",  hint = "sudo zypper install libayatana-appindicator3-1" },
	{ probe = "apk",     hint = "sudo apk add libayatana-appindicator" },
}




-- ==============================================
-- ==============================================
-- ======= 2/ Binding ===========================
-- ==============================================
-- ==============================================

-- nil until probed, false when this machine cannot host an indicator.
local _lib = nil

-- The live indicator, its current menu, and every callback keeping GTK alive.
local _indicator = nil
local _menu = nil
local _pinned = {}

--- Loads the first of a list of sonames that resolves.
--- @param ffi table The FFI module.
--- @param names table Candidate sonames.
--- @return userdata|nil
local function load_any(ffi, names)
	for _, name in ipairs(names) do
		local ok, lib = pcall(ffi.load, name)
		if ok then return lib end
	end
	return nil
end

--- The install command for this machine, or a generic sentence.
--- @return string
local function package_hint()
	local ok_shell, Shell = pcall(require, "adapters.shell_runner")
	if ok_shell then
		for _, entry in ipairs(PACKAGE_HINTS) do
			if Shell.has_command(entry.probe) then return entry.hint end
		end
	end
	return "install the libayatana-appindicator3 package for your distribution"
end

--- Binds GTK, GObject and libayatana, or records that it cannot.
--- @return table|nil { ffi, gtk, gobject, indicator }
local function bind()
	if _lib ~= nil then return _lib or nil end
	_lib = false

	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi or type(ffi) ~= "table" then
		Logger.error(LOG, "No LuaJIT FFI — the tray needs it.")
		return nil
	end

	local ok_cdef, cdef_err = pcall(ffi.cdef, [[
		typedef void  GtkWidget;
		typedef void  AppIndicator;
		typedef void* gpointer;
		typedef int   gboolean;
		typedef unsigned long gulong;
		typedef void (*GCallback)(void);

		GtkWidget*   gtk_menu_new(void);
		GtkWidget*   gtk_menu_item_new_with_label(const char *label);
		GtkWidget*   gtk_check_menu_item_new_with_label(const char *label);
		GtkWidget*   gtk_separator_menu_item_new(void);
		void         gtk_check_menu_item_set_active(GtkWidget *item, gboolean is_active);
		void         gtk_menu_item_set_submenu(GtkWidget *item, GtkWidget *submenu);
		void         gtk_menu_shell_append(GtkWidget *shell, GtkWidget *child);
		void         gtk_widget_set_sensitive(GtkWidget *widget, gboolean sensitive);
		void         gtk_widget_show_all(GtkWidget *widget);
		gboolean     gtk_init_check(int *argc, char ***argv);
		gboolean     gtk_events_pending(void);
		gboolean     gtk_main_iteration_do(gboolean blocking);

		gulong       g_signal_connect_data(gpointer instance, const char *detailed_signal,
		                                   GCallback c_handler, gpointer data,
		                                   void *destroy_data, int connect_flags);

		AppIndicator* app_indicator_new(const char *id, const char *icon_name, int category);
		void          app_indicator_set_status(AppIndicator *self, int status);
		void          app_indicator_set_menu(AppIndicator *self, GtkWidget *menu);
		void          app_indicator_set_icon_full(AppIndicator *self, const char *icon_name,
		                                          const char *icon_desc);
		void          app_indicator_set_title(AppIndicator *self, const char *title);
	]])
	if not ok_cdef and not tostring(cdef_err):find("redefin", 1, true) then
		Logger.error(LOG, "ffi.cdef failed: %s", tostring(cdef_err))
		return nil
	end

	local gtk = load_any(ffi, CANDIDATE_LIBS.gtk)
	local gobject = load_any(ffi, CANDIDATE_LIBS.gobject)
	local indicator = load_any(ffi, CANDIDATE_LIBS.indicator)
	if not gtk or not gobject or not indicator then
		Logger.error(LOG, "Tray unavailable — %s is missing. Try: %s",
			(not indicator) and "libayatana-appindicator3" or "GTK 3", package_hint())
		return nil
	end

	-- gtk_init_check rather than gtk_init: the latter calls exit() when there is
	-- no display, which would take the whole daemon down on a TTY — and hotstring
	-- expansion has nothing to do with having a tray.
	if gtk.gtk_init_check(nil, nil) == 0 then
		Logger.error(LOG, "GTK could not connect to a display — no tray on this session.")
		return nil
	end

	_lib = { ffi = ffi, gtk = gtk, gobject = gobject, indicator = indicator }
	Logger.success(LOG, "Tray backend bound (libayatana-appindicator).")
	return _lib
end

--- Test seam: forces the binding state without touching any library.
--- @param value table|false|nil
function M._set_binding_for_test(value)
	_lib = value
end

--- Whether this machine can host a tray icon.
--- @return boolean
function M.is_available()
	return bind() ~= nil
end




-- ==============================================
-- ==============================================
-- ======= 3/ Building the menu =================
-- ==============================================
-- ==============================================

--- Connects a Lua function to "activate", keeping the callback alive.
---
--- The pin is not defensive coding. `ffi.cast` returns a callback object owned
--- by Lua; the moment nothing references it, LuaJIT frees the trampoline and the
--- next click jumps into freed memory — inside GTK, with no Lua traceback and no
--- indication that a menu callback was involved.
--- @param lib table
--- @param widget userdata
--- @param fn function
local function on_activate(lib, widget, fn)
	local cb = lib.ffi.cast("GCallback", function()
		local ok, err = pcall(fn)
		if not ok then Logger.error(LOG, "Menu action failed — %s", tostring(err)) end
	end)
	_pinned[#_pinned + 1] = cb
	lib.gobject.g_signal_connect_data(widget, "activate", cb, nil, nil, 0)
end

--- Builds a GtkMenu from the neutral tree the renderer emits.
---
--- The tree shape is the shared one: { title, fn, menu, checked, disabled }.
--- Nothing here knows what a hotstring is, which is what lets the whole menu be
--- decided by the manifest and this file be the only part that is GTK.
--- @param lib table
--- @param items table
--- @return userdata GtkMenu
local function build_menu(lib, items)
	local menu = lib.gtk.gtk_menu_new()

	for _, item in ipairs(items or {}) do
		local widget
		if item.separator or item.title == "-" then
			widget = lib.gtk.gtk_separator_menu_item_new()
		elseif item.checked ~= nil then
			widget = lib.gtk.gtk_check_menu_item_new_with_label(tostring(item.title or ""))
			lib.gtk.gtk_check_menu_item_set_active(widget, item.checked and 1 or 0)
		else
			widget = lib.gtk.gtk_menu_item_new_with_label(tostring(item.title or ""))
		end

		if type(item.menu) == "table" and #item.menu > 0 then
			lib.gtk.gtk_menu_item_set_submenu(widget, build_menu(lib, item.menu))
		elseif type(item.fn) == "function" then
			on_activate(lib, widget, item.fn)
		end

		if item.disabled then
			lib.gtk.gtk_widget_set_sensitive(widget, 0)
		end

		lib.gtk.gtk_menu_shell_append(menu, widget)
	end

	lib.gtk.gtk_widget_show_all(menu)
	return menu
end




-- ==============================================
-- ==============================================
-- ======= 4/ Lifecycle =========================
-- ==============================================
-- ==============================================

--- Creates the tray icon.
--- @param id string Application id, used by panels to remember position.
--- @param icon_name string Icon theme name or absolute path.
--- @param title string Accessible title.
--- @return boolean
function M.create(id, icon_name, title)
	local lib = bind()
	if not lib then return false end
	if _indicator then return true end

	_indicator = lib.indicator.app_indicator_new(
		tostring(id), tostring(icon_name), CATEGORY_APPLICATION_STATUS)
	if _indicator == nil then
		Logger.error(LOG, "app_indicator_new returned nothing.")
		return false
	end

	lib.indicator.app_indicator_set_status(_indicator, STATUS_ACTIVE)
	if title and title ~= "" then
		lib.indicator.app_indicator_set_title(_indicator, tostring(title))
	end

	-- An indicator with no menu is not shown by most panels, so an empty one is
	-- set immediately rather than waiting for the first setMenu().
	_menu = build_menu(lib, {})
	lib.indicator.app_indicator_set_menu(_indicator, _menu)

	Logger.success(LOG, "Tray icon created (id=%s).", tostring(id))
	return true
end

--- Replaces the menu.
--- @param items table Neutral menu tree.
--- @return boolean
function M.set_menu(items)
	local lib = bind()
	if not lib or not _indicator then return false end

	-- The pins are dropped with the menu they belonged to. Keeping them would
	-- leak one trampoline per row per rebuild, and the menu is rebuilt on every
	-- toggle.
	_pinned = {}
	_menu = build_menu(lib, items)
	lib.indicator.app_indicator_set_menu(_indicator, _menu)
	return true
end

--- Replaces the icon.
--- @param icon_name string
--- @return boolean
function M.set_icon(icon_name)
	local lib = bind()
	if not lib or not _indicator then return false end
	lib.indicator.app_indicator_set_icon_full(_indicator, tostring(icon_name), "")
	return true
end

--- Drains pending GTK events without blocking.
---
--- The blocking flag is 0, deliberately and load-bearingly: the previous tray
--- read a pipe and stalled the keystroke path until the user clicked the icon.
--- @param budget integer|nil Maximum iterations, default 32.
--- @return integer Iterations performed.
function M.pump(budget)
	local lib = bind()
	if not lib then return 0 end
	local done = 0
	for _ = 1, budget or 32 do
		if lib.gtk.gtk_events_pending() == 0 then break end
		lib.gtk.gtk_main_iteration_do(0)
		done = done + 1
	end
	return done
end

--- Hides the icon and releases the menu.
function M.destroy()
	local lib = bind()
	if not lib or not _indicator then return end
	-- Status PASSIVE (0) is what removes it from the panel; there is no
	-- app_indicator_destroy, and dropping the reference alone leaves the icon on
	-- screen until the process exits.
	lib.indicator.app_indicator_set_status(_indicator, 0)
	_indicator = nil
	_menu = nil
	_pinned = {}
	Logger.info(LOG, "Tray icon removed.")
end

--- @return boolean True when an icon is live.
function M.is_live()
	return _indicator ~= nil
end

return M
