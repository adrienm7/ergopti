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
--- 2. One callback for every row. LuaJIT never frees an FFI callback slot and
---    has only a few hundred, so a callback per row per rebuild crashed the
---    daemon at boot ("too many callbacks"). Rows carry an id as signal data;
---    one process-wide handler dispatches it, and ids are never reused.
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

-- AppIndicatorStatus. PASSIVE is what hides an item from the panel.
local STATUS_PASSIVE = 0
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

-- Menu actions by id, and the one C callback that dispatches to them.
--
-- ONE callback for the whole process, never one per row: LuaJIT never
-- garbage-collects FFI callback slots, and there are only a few hundred. The
-- menu has hundreds of rows and is rebuilt on every toggle, so a callback per
-- row exhausted the slots during boot and the daemon died with "too many
-- callbacks" before the first keystroke — every packaged unit runs --tray.
-- Ids are never reused, so a click on a row of a replaced menu finds no action
-- instead of firing whatever the new menu put at the same position.
local _actions = {}
local _next_action = 0
local _dispatcher = nil
-- The action ids the main menu owns. A rebuild drops these and only these: a
-- second tray item (the WPM readout) keeps its own rows alive.
local _menu_actions = {}

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
		typedef void (*ErgoptiActivateHandler)(void *item, void *data);

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

--- The process-wide "activate" handler, created on first use.
--- @param lib table
--- @return userdata GCallback
local function dispatcher(lib)
	if not _dispatcher then
		local handler = lib.ffi.cast("ErgoptiActivateHandler", function(_, data)
			local fn = _actions[tonumber(lib.ffi.cast("intptr_t", data))]
			if not fn then return end
			local ok, err = pcall(fn)
			if not ok then Logger.error(LOG, "Menu action failed — %s", tostring(err)) end
		end)
		_dispatcher = { handler = handler, gcallback = lib.ffi.cast("GCallback", handler) }
	end
	return _dispatcher.gcallback
end

--- Connects a Lua function to "activate" through the shared dispatcher.
--- @param lib table
--- @param widget userdata
--- @param fn function
local function on_activate(lib, widget, fn, owned)
	_next_action = _next_action + 1
	_actions[_next_action] = fn
	owned[#owned + 1] = _next_action
	lib.gobject.g_signal_connect_data(widget, "activate", dispatcher(lib),
		lib.ffi.cast("gpointer", _next_action), nil, 0)
end

--- Builds a GtkMenu from the neutral tree the renderer emits.
---
--- The tree shape is the shared one: { title, fn, menu, checked, disabled }.
--- Nothing here knows what a hotstring is, which is what lets the whole menu be
--- decided by the manifest and this file be the only part that is GTK.
--- @param lib table
--- @param items table
--- @param owned table Receives the action ids the menu registers.
--- @return userdata GtkMenu
local function build_menu(lib, items, owned)
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
			lib.gtk.gtk_menu_item_set_submenu(widget, build_menu(lib, item.menu, owned))
		elseif type(item.fn) == "function" then
			on_activate(lib, widget, item.fn, owned)
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
	_menu = build_menu(lib, {}, _menu_actions)
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

	-- The replaced menu's actions go with it; its ids are never reissued, so a
	-- late click on an old row finds nothing to run.
	for _, id in ipairs(_menu_actions) do _actions[id] = nil end
	_menu_actions = {}
	_menu = build_menu(lib, items, _menu_actions)
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
	lib.indicator.app_indicator_set_status(_indicator, STATUS_PASSIVE)
	_indicator = nil
	_menu = nil
	for _, id in ipairs(_menu_actions) do _actions[id] = nil end
	_menu_actions = {}
	Logger.info(LOG, "Tray icon removed.")
end

--- @return boolean True when an icon is live.
function M.is_live()
	return _indicator ~= nil
end




-- ==============================================
-- ==============================================
-- ======= 5/ Extra items =======================
-- ==============================================
-- ==============================================

--- A second tray item beside the main one, hidden until shown: the WPM
--- readout, which appears only while the user types, like its macOS menu bar
--- counterpart.
--- @param id string Application id, distinct from the main icon's.
--- @param icon_name string Icon theme name or absolute path.
--- @param items table Its menu, in the neutral tree shape.
--- @return table|nil An opaque handle.
function M.new_item(id, icon_name, items)
	local lib = bind()
	if not lib then return nil end
	local ptr = lib.indicator.app_indicator_new(tostring(id), tostring(icon_name), CATEGORY_APPLICATION_STATUS)
	if ptr == nil then
		Logger.error(LOG, "app_indicator_new returned nothing for '%s'.", tostring(id))
		return nil
	end
	local handle = { ptr = ptr, owned = {}, active = false }
	-- Most panels do not show an item without a menu.
	handle.menu = build_menu(lib, items or {}, handle.owned)
	lib.indicator.app_indicator_set_menu(ptr, handle.menu)
	lib.indicator.app_indicator_set_status(ptr, STATUS_PASSIVE)
	return handle
end

--- Updates an extra item's icon, accessible title and presence.
--- @param handle table From new_item().
--- @param opts table { icon?, title?, active? }
--- @return boolean
function M.update_item(handle, opts)
	local lib = bind()
	if not lib or type(handle) ~= "table" or handle.ptr == nil then return false end
	if opts.icon then lib.indicator.app_indicator_set_icon_full(handle.ptr, tostring(opts.icon), "") end
	if opts.title then lib.indicator.app_indicator_set_title(handle.ptr, tostring(opts.title)) end
	if opts.active ~= nil and opts.active ~= handle.active then
		lib.indicator.app_indicator_set_status(handle.ptr, opts.active and STATUS_ACTIVE or STATUS_PASSIVE)
		handle.active = opts.active
	end
	return true
end

--- Removes an extra item from the panel and drops its menu's actions.
--- @param handle table From new_item().
function M.remove_item(handle)
	local lib = bind()
	if not lib or type(handle) ~= "table" or handle.ptr == nil then return end
	lib.indicator.app_indicator_set_status(handle.ptr, STATUS_PASSIVE)
	for _, id in ipairs(handle.owned) do _actions[id] = nil end
	handle.owned = {}
	handle.ptr = nil
	handle.active = false
end

return M
