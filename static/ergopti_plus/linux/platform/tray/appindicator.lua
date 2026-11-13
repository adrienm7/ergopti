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

local Logger = require("core.logger.engine.shim")
local Perf = require("infra.perf_counters")

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

-- The component names a refusal shows, the same words in every language.
M.GTK_COMPONENT = "GTK 3"
M.INDICATOR_COMPONENT = "libayatana-appindicator3"

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
-- The library the binding could not load, named as the start check reports
-- it (infra/gui_stack.lua); nil when every library loaded.
local _missing = nil

-- The live indicator, its current menu, and every callback keeping GTK alive.
local _indicator = nil
local _menu = nil
-- The status window, created on first show and kept (hidden on close) until
-- destroy(), so a second show re-presents it instead of stacking copies.
local _window = nil

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

-- The idle wait's GLib half (M.wait_companion): the default main context, its
-- last queried GPollFD records (regrown on demand, so a wait allocates nothing
-- in steady state), and whether this tick holds the context.
local _glib_wait = { native = nil, context = nil, fds = nil, capacity = 0, count = 0,
	priority = nil, timeout = nil, held = false }

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
		void         gtk_widget_show(GtkWidget *widget);
		gboolean     gtk_init_check(int *argc, char ***argv);
		gboolean     gtk_events_pending(void);
		gboolean     gtk_main_iteration_do(gboolean blocking);
		GtkWidget*   gtk_window_new(int type);
		void         gtk_window_set_title(GtkWidget *window, const char *title);
		void         gtk_window_set_position(GtkWidget *window, int position);
		void         gtk_window_set_default_size(GtkWidget *window, int width, int height);
		void         gtk_window_present(GtkWidget *window);
		void         gtk_container_add(GtkWidget *container, GtkWidget *widget);
		void         gtk_container_set_border_width(GtkWidget *container, unsigned int width);
		GtkWidget*   gtk_label_new(const char *text);
		void         gtk_label_set_line_wrap(GtkWidget *label, gboolean wrap);
		void         gtk_label_set_max_width_chars(GtkWidget *label, int n_chars);
		void         gtk_label_set_selectable(GtkWidget *label, gboolean selectable);
		gboolean     gtk_widget_hide_on_delete(GtkWidget *widget);
		void         gtk_widget_destroy(GtkWidget *widget);

		gulong       g_signal_connect_data(gpointer instance, const char *detailed_signal,
		                                   GCallback c_handler, gpointer data,
		                                   void *destroy_data, int connect_flags);
		void         g_signal_handler_block(gpointer instance, gulong handler_id);
		void         g_signal_handler_unblock(gpointer instance, gulong handler_id);
		void         g_object_unref(gpointer object);

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
		_missing = (not indicator) and M.INDICATOR_COMPONENT or M.GTK_COMPONENT
		Logger.error(LOG, "Tray unavailable — %s is missing. Try: %s", _missing, package_hint())
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
--- @return table|false|nil Previous binding state.
function M._set_binding_for_test(value)
	local previous = _lib
	_lib = value
	return previous
end

--- Whether this machine can host a tray icon.
--- @return boolean
function M.is_available()
	return bind() ~= nil
end

--- The system library the tray cannot load, for the start check's refusal.
--- nil when the libraries loaded, even if no display then accepted GTK: that
--- is a session without a desktop, not a missing package.
--- @return string|nil M.GTK_COMPONENT or M.INDICATOR_COMPONENT.
function M.missing_component()
	bind()
	return _missing
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

--- Registers a Lua function under a fresh action id and connects `signal` of
--- `widget` to the shared dispatcher with that id.
--- @param lib table
--- @param widget userdata
--- @param signal string "activate" or "map".
--- @param fn function
--- @param owned table Receives the id.
--- @return integer action_id
--- @return integer signal_id
local function connect(lib, widget, signal, fn, owned)
	_next_action = _next_action + 1
	local action_id = _next_action
	_actions[action_id] = fn
	owned[#owned + 1] = action_id
	local signal_id = lib.gobject.g_signal_connect_data(widget, signal, dispatcher(lib),
		lib.ffi.cast("gpointer", action_id), nil, 0)
	return action_id, signal_id
end

--- The widget kind a row needs; a row only changes in place within its kind.
--- @param item table
--- @return string "separator", "check" or "plain".
local function row_kind(item)
	if item.separator or item.title == "-" then return "separator" end
	if item.checked ~= nil then return "check" end
	return "plain"
end

--- @param item table
--- @return boolean
local function has_submenu(item)
	return type(item.menu) == "table" and #item.menu > 0
end

--- The action a row may run: none for a parent, a disabled row or an inert one.
--- @param row table
--- @param item table
--- @param disabled boolean
--- @return function|nil
local function row_action(row, item, disabled)
	if row.has_sub or disabled or type(item.fn) ~= "function" then return nil end
	return item.fn
end

--- Sets a check row's mark without running its action: set_active emits
--- activate, so the row's own handler is blocked meanwhile.
--- @param lib table
--- @param row table
--- @param checked boolean
local function set_check(lib, row, checked)
	-- A check row with a submenu opens it on activate: blocked too, or a
	-- changed check would build a submenu nobody opened.
	local signal = row.signal or (row.sub and row.sub.parent_signal)
	if signal then lib.gobject.g_signal_handler_block(row.widget, signal) end
	local restored, err = pcall(lib.gtk.gtk_check_menu_item_set_active, row.widget, checked and 1 or 0)
	if signal then lib.gobject.g_signal_handler_unblock(row.widget, signal) end
	if not restored then error(err, 0) end
end

--- Connects a row's activate handler, once, the first time it has an action.
--- The handler reads the row's current action and check, so an in-place update
--- never needs a new callback.
--- @param lib table
--- @param row table
--- @param owned table
local function arm_row(lib, row, owned)
	if row.action_id or not row.fn then return end
	row.action_id, row.signal = connect(lib, row.widget, "activate", function()
		if row.kind == "check" then
			-- GTK toggles before activate handlers run. Only the owning rebuild
			-- may publish a changed setting; rejected writes must keep its check.
			set_check(lib, row, row.checked)
		end
		local fn = row.fn
		if fn then return fn() end
	end, owned)
end

local fill_node

--- Retires every action of a node and of its filled descendants: a click on a
--- destroyed or rebuilt row must run nothing, least of all its successor.
--- @param node table
local function retire_node(node)
	for _, id in ipairs(node.fill_ids or {}) do _actions[id] = nil end
	for _, row in ipairs(node.rows or {}) do
		if row.action_id then _actions[row.action_id] = nil end
		if row.sub then retire_node(row.sub) end
	end
end

--- A submenu node, empty until it is opened. A hidden placeholder keeps the
--- parent a submenu row for dbusmenu (an empty GtkMenu is published as a plain
--- item, and AboutToShow on it is ignored). libdbusmenu-gtk turns a client's
--- AboutToShow into the parent's "activate", and a native GtkMenu popup (the
--- XEmbed fallback) maps the submenu: either fills it, once. Not "show": the
--- indicator shows every submenu when the menu is set, opened or not.
--- @param lib table
--- @param parent userdata The parent row's widget.
--- @param items table
--- @param disabled boolean
--- @param owned table
--- @param path string The branch's position from the root ("root/3/2"), for timing lines.
--- @return table node
local function lazy_node(lib, parent, items, disabled, owned, path)
	local menu = lib.gtk.gtk_menu_new()
	local node = { menu = menu, items = items, disabled = disabled, filled = false, rows = {}, fill_ids = {},
		path = path }
	node.placeholder = lib.gtk.gtk_menu_item_new_with_label("")
	lib.gtk.gtk_menu_shell_append(menu, node.placeholder)
	local function fill() fill_node(lib, node, owned) end
	node.fill_ids[1], node.parent_signal = connect(lib, parent, "activate", fill, owned)
	node.fill_ids[2] = connect(lib, menu, "map", fill, owned)
	lib.gtk.gtk_menu_item_set_submenu(parent, menu)
	return node
end

--- Creates the widget of one row and appends it.
--- @param lib table
--- @param node table
--- @param item table
--- @param owned table
--- @return table row
local function add_row(lib, node, item, owned)
	local disabled = node.disabled or item.disabled == true
	local row = { kind = row_kind(item), has_sub = has_submenu(item) }
	if row.kind == "separator" then
		row.widget = lib.gtk.gtk_separator_menu_item_new()
	else
		row.label = tostring(item.title or "")
		if row.kind == "check" then
			row.widget = lib.gtk.gtk_check_menu_item_new_with_label(row.label)
			row.checked = item.checked == true
			lib.gtk.gtk_check_menu_item_set_active(row.widget, row.checked and 1 or 0)
		else
			row.widget = lib.gtk.gtk_menu_item_new_with_label(row.label)
		end
	end
	if row.has_sub then
		row.sub = lazy_node(lib, row.widget, item.menu, disabled, owned,
			node.path .. "/" .. (#node.rows + 1))
	else
		-- dbusmenu Event can activate an insensitive GTK item directly.
		-- Unavailable rows therefore never receive an action capability.
		row.fn = row_action(row, item, disabled)
		arm_row(lib, row, owned)
	end
	row.sensitive = not disabled
	if disabled then lib.gtk.gtk_widget_set_sensitive(row.widget, 0) end
	lib.gtk.gtk_menu_shell_append(node.menu, row.widget)
	lib.gtk.gtk_widget_show(row.widget)
	return row
end

--- Builds the rows of a node that has none yet. Never show_all: it recurses
--- into every submenu and shows rows nobody opened.
--- @param lib table
--- @param node table
--- @param owned table
fill_node = function(lib, node, owned)
	if node.filled then return end
	local started = Perf.trace("tray.fill")
	node.filled = true
	if node.placeholder ~= nil then
		lib.gtk.gtk_widget_destroy(node.placeholder)
		node.placeholder = nil
	end
	for _, id in ipairs(node.fill_ids) do _actions[id] = nil end
	node.rows = {}
	for _, item in ipairs(node.items or {}) do
		node.rows[#node.rows + 1] = add_row(lib, node, item, owned)
	end
	Perf.count("tray.rows", #node.rows)
	Perf.count("tray.fills")
	-- The branch by position, never by label: a label can be a user's own name.
	Perf.done("tray.fill", started, string.format("branch %s, %d row(s)", node.path, #node.rows))
end

--- Whether a node's rows can take `items` in place: the same kinds, the same
--- submenu parents and the same titles. A changed title rebuilds the node,
--- so a click aimed at one row can never land on the row that took its place.
--- @param node table
--- @param items table
--- @return boolean
local function same_shape(node, items)
	if #node.rows ~= #items then return false end
	for index, item in ipairs(items) do
		local row = node.rows[index]
		if row.kind ~= row_kind(item) or row.has_sub ~= has_submenu(item) then return false end
		if row.kind ~= "separator" and row.label ~= tostring(item.title or "") then return false end
	end
	return true
end

local patch_node

--- Updates one row in place: its check, its sensitivity and its action.
--- @param lib table
--- @param node table
--- @param row table
--- @param item table
--- @param owned table
local function patch_row(lib, node, row, item, owned)
	local disabled = node.disabled or item.disabled == true
	if row.kind == "check" and row.checked ~= (item.checked == true) then
		row.checked = item.checked == true
		set_check(lib, row, row.checked)
	end
	if row.sensitive ~= not disabled then
		row.sensitive = not disabled
		lib.gtk.gtk_widget_set_sensitive(row.widget, disabled and 0 or 1)
	end
	if row.has_sub then
		patch_node(lib, row.sub, item.menu, disabled, owned)
	else
		row.fn = row_action(row, item, disabled)
		arm_row(lib, row, owned)
	end
end

--- Brings a node to `items`: in place when the shape is unchanged, otherwise
--- by destroying its rows and building them again. A node never opened only
--- keeps the new rows for when it is.
--- @param lib table
--- @param node table
--- @param items table
--- @param disabled boolean
--- @param owned table
patch_node = function(lib, node, items, disabled, owned)
	items = items or {}
	local reshaped = node.disabled ~= disabled
	node.items, node.disabled = items, disabled
	if not node.filled then return end
	if not reshaped and same_shape(node, items) then
		for index, item in ipairs(items) do patch_row(lib, node, node.rows[index], item, owned) end
		return
	end
	retire_node(node)
	for _, row in ipairs(node.rows) do lib.gtk.gtk_widget_destroy(row.widget) end
	node.filled = false
	fill_node(lib, node, owned)
end

--- Builds a top-level menu node from the neutral tree the renderer emits: its
--- own rows now, every submenu when it is opened.
---
--- The tree shape is the shared one: { title, fn, menu, checked, disabled }.
--- Nothing here knows what a hotstring is, which is what lets the whole menu be
--- decided by the manifest and this file be the only part that is GTK.
--- @param lib table
--- @param items table
--- @param owned table Receives the action ids the menu registers.
--- @return table node { menu = GtkMenu, ... }
local function build_menu(lib, items, owned)
	local node = { menu = lib.gtk.gtk_menu_new(), items = items or {}, disabled = false, filled = false,
		rows = {}, fill_ids = {}, path = "root" }
	fill_node(lib, node, owned)
	lib.gtk.gtk_widget_show(node.menu)
	return node
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
	lib.indicator.app_indicator_set_menu(_indicator, _menu.menu)

	Logger.success(LOG, "Tray icon created (id=%s).", tostring(id))
	return true
end

--- Replaces the menu's rows. The indicator keeps one GtkMenu: rows whose
--- shape is unchanged are updated in place (a toggle changes one check), a
--- changed node is rebuilt, and a submenu never opened is only re-pointed at
--- its new rows.
--- @param items table Neutral menu tree.
--- @return boolean
function M.set_menu(items)
	local lib = bind()
	if not lib or not _indicator then return false end
	patch_node(lib, _menu, items, false, _menu_actions)
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

-- GTK can enter a Lua callback during any iteration. LuaJIT forbids that
-- transition from compiled FFI calls, even after many callback-free iterations.
if jit then jit.off(M.pump) end

--- Binds the GLib main-context calls the idle wait needs, once.
--- @param lib table
--- @return boolean
local function bind_glib_wait(lib)
	if _glib_wait.native ~= nil then return _glib_wait.native ~= false end
	_glib_wait.native = false
	-- GPollFD is struct pollfd on every Unix GLib supports (gpoll.h).
	local ok_cdef, cdef_err = pcall(lib.ffi.cdef, [[
		typedef struct { int fd; unsigned short events; unsigned short revents; } ErgoptiGPollFD;
		void*    g_main_context_default(void);
		gboolean g_main_context_acquire(void *context);
		void     g_main_context_release(void *context);
		gboolean g_main_context_prepare(void *context, int *priority);
		int      g_main_context_query(void *context, int max_priority, int *timeout_, ErgoptiGPollFD *fds, int n_fds);
		gboolean g_main_context_check(void *context, int max_priority, ErgoptiGPollFD *fds, int n_fds);
	]])
	if not ok_cdef and not tostring(cdef_err):find("redefin", 1, true) then
		Logger.error(LOG, "GLib wait bindings refused: %s; tray requests wait for the idle tick.", tostring(cdef_err))
		return false
	end
	_glib_wait.native = lib.gobject
	_glib_wait.context = lib.gobject.g_main_context_default()
	_glib_wait.priority = lib.ffi.new("int[1]")
	_glib_wait.timeout = lib.ffi.new("int[1]")
	return true
end

--- Opens the GLib half of one idle wait: acquires the default main context,
--- prepares it and queries its descriptors, so the daemon's poll also wakes on
--- a D-Bus request (the panel opening a submenu) or a window event instead of
--- sleeping out its timeout first. Nothing is dispatched here: the next idle
--- tick's pump() does that, outside the input reader. GLib's own timeout is
--- not adopted, so a source that is always ready cannot turn the wait into a
--- spin; GLib timers keep the idle tick's cadence, as before.
--- @return cdata|nil fds ErgoptiGPollFD records, nil when this tick has none.
--- @return integer count
local function glib_wait_begin()
	local lib = bind()
	if not lib or not _indicator or not bind_glib_wait(lib) then return nil, 0 end
	local native, context = _glib_wait.native, _glib_wait.context
	if native.g_main_context_acquire(context) == 0 then return nil, 0 end
	_glib_wait.held = true
	native.g_main_context_prepare(context, _glib_wait.priority)
	local priority = _glib_wait.priority[0]
	local count = native.g_main_context_query(context, priority, _glib_wait.timeout, _glib_wait.fds,
		_glib_wait.capacity)
	if count > _glib_wait.capacity then
		_glib_wait.capacity = count * 2
		_glib_wait.fds = lib.ffi.new("ErgoptiGPollFD[?]", _glib_wait.capacity)
		count = native.g_main_context_query(context, priority, _glib_wait.timeout, _glib_wait.fds,
			_glib_wait.capacity)
	end
	_glib_wait.count = count
	return _glib_wait.fds, count
end

--- Closes the GLib half of the wait: hands GLib the descriptors' readiness
--- (check acknowledges its wakeup) and releases the context. Runs on every
--- path glib_wait_begin() acquired, a failed poll included.
local function glib_wait_finish()
	if not _glib_wait.held then return end
	local native, context = _glib_wait.native, _glib_wait.context
	_glib_wait.held = false
	native.g_main_context_check(context, _glib_wait.priority[0], _glib_wait.fds, _glib_wait.count)
	native.g_main_context_release(context)
end

-- Compiled FFI frames must not be entered by a GLib callback (see pump()).
if jit then jit.off(glib_wait_begin); jit.off(glib_wait_finish) end

-- One companion for the process, so the input reader can retire a failing one.
local _companion = { begin = glib_wait_begin, finish = glib_wait_finish }

--- The companion the input reader's idle wait polls with
--- (evdev_reader.wait_any_readable): { begin() -> fds, count; finish() }.
--- @return table
function M.wait_companion()
	return _companion
end

--- Hides the icon and releases the menu.
function M.destroy()
	local lib = bind()
	if not lib or not _indicator then return end
	-- Status PASSIVE (0) is what removes it from the panel; there is no
	-- app_indicator_destroy, and dropping the reference alone leaves the icon on
	-- screen until the process exits. Release the constructor's reference too:
	-- PASSIVE hides the icon but retains its menu and D-Bus registration.
	lib.indicator.app_indicator_set_status(_indicator, STATUS_PASSIVE)
	lib.gobject.g_object_unref(_indicator)
	_indicator = nil
	_menu = nil
	if _window ~= nil then
		lib.gtk.gtk_widget_destroy(_window)
		_window = nil
	end
	for _, id in ipairs(_menu_actions) do _actions[id] = nil end
	_menu_actions = {}
	Logger.info(LOG, "Tray icon removed.")
end

--- @return boolean True when an icon is live.
function M.is_live()
	return _indicator ~= nil
end

-- GtkWindowType TOPLEVEL and GtkWindowPosition CENTER. Centred because,
-- without a window manager, a window maps at 0,0, which is where an XEmbed
-- tray such as stalonetray docks the icon: the window would cover it.
local GTK_WINDOW_TOPLEVEL = 0
local GTK_WIN_POS_CENTER = 1

--- Shows a plain window carrying a message, or brings the existing one back.
---
--- The degraded no-keyboard state needs something a desktop launch can see
--- without knowing where the tray is. The AppImage catalogue looks for a named
--- window first and screenshots it; a tray menu, being an override-redirect
--- popup, is never the active window it can capture. Closing the window only
--- hides it: the tray menu can show it again.
--- @param title string The window title.
--- @param text string The message, wrapped.
--- @return boolean shown
function M.show_window(title, text)
	local lib = bind()
	if not lib then return false end
	if _window == nil then
		local window = lib.gtk.gtk_window_new(GTK_WINDOW_TOPLEVEL)
		if window == nil then
			Logger.error(LOG, "gtk_window_new returned nothing — no status window.")
			return false
		end
		lib.gtk.gtk_window_set_title(window, tostring(title))
		lib.gtk.gtk_window_set_position(window, GTK_WIN_POS_CENTER)
		lib.gtk.gtk_window_set_default_size(window, 420, -1)
		lib.gtk.gtk_container_set_border_width(window, 18)
		local label = lib.gtk.gtk_label_new(tostring(text))
		lib.gtk.gtk_label_set_line_wrap(label, 1)
		lib.gtk.gtk_label_set_max_width_chars(label, 60)
		lib.gtk.gtk_label_set_selectable(label, 1)
		lib.gtk.gtk_container_add(window, label)
		-- A C handler, not a Lua callback: hiding needs no Lua and spends no
		-- FFI callback slot.
		lib.gobject.g_signal_connect_data(window, "delete-event",
			lib.ffi.cast("GCallback", lib.gtk.gtk_widget_hide_on_delete), nil, nil, 0)
		_window = window
	end
	lib.gtk.gtk_widget_show_all(_window)
	lib.gtk.gtk_window_present(_window)
	Logger.info(LOG, "Status window shown (%s).", tostring(title))
	return true
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
	lib.indicator.app_indicator_set_menu(ptr, handle.menu.menu)
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
--- @return boolean acknowledged
function M.remove_item(handle)
	if type(handle) ~= "table" then return false end
	if handle.ptr == nil then return true end
	local lib = bind()
	if not lib then return false end
	local called, result = pcall(lib.indicator.app_indicator_set_status, handle.ptr, STATUS_PASSIVE)
	-- This native setter returns void; normal completion acknowledges its work.
	if not called or result == false then
		Logger.error(LOG, "The extra tray item did not acknowledge removal.")
		return false
	end
	for _, id in ipairs(handle.owned) do _actions[id] = nil end
	lib.gobject.g_object_unref(handle.ptr)
	handle.owned = {}
	handle.ptr = nil
	handle.menu = nil
	handle.active = false
	return true
end

return M
