--- ui/dialog_host.lua
-- The application-owned child is invoked directly, without a global Lua init.
local literal_driver = os.getenv("ERGOPTI_LITERAL_DRIVER_ROOT")
if literal_driver and literal_driver ~= "" then
	local literal_shared = assert(os.getenv("ERGOPTI_LITERAL_SHARED_ROOT"), "literal shared root unavailable")
	assert(loadfile(literal_driver .. "/core/lifecycle/engine/literal_module_loader.lua"))().install(literal_driver, literal_shared, os.getenv("ERGOPTI_RUNTIME_PREFIX"), os.getenv("ERGOPTI_LITERAL_DIRECT") == "1" and "child-direct" or (os.getenv("ERGOPTI_LITERAL_DAEMON") == "1" and "daemon" or nil))
end


--- ==============================================================================
--- MODULE: Owned Native Dialog Host (Linux)
--- DESCRIPTION:
--- Ergopti's own GTK 3 dialog program, run as a child of the daemon by
--- ui/native_dialog.lua: a question, a message, a text entry, a list or a file
--- chooser, answered on stdout and through the exit status. It replaces the
--- host's zenity and kdialog (owned runtimes registry, Linux row « zenity,
--- kdialog »: drive our own GTK window instead).
---
--- FEATURES & RATIONALE:
--- 1. GTK through the LuaJIT FFI, as the tray binds it: the AppImage carries no
---    lgi, and GTK 3 is already the host library every format relies on.
--- 2. A separate process, not a window inside the daemon: a dialog that blocks
---    runs under ui/modal.lua, which hands the grabbed keyboard to the desktop
---    while the daemon waits for this child (keyboard_hook.while_released).
--- 3. The command line is the subset of zenity's the driver used, so every call
---    site keeps its arguments and its exit-status reading: 0 accepted, 1
---    cancelled or closed, 2 refused arguments, 69 no display or no GTK 3.
--- 4. Text is plain unless the caller omits --no-markup, in which case it is
---    Pango markup, as zenity read it.
--- 5. Importing the module (tests) parses only; it never opens a display.
--- ==============================================================================

local M = {}

--- Exit statuses the callers read.
M.EXIT_ACCEPTED = 0
M.EXIT_CANCELLED = 1
M.EXIT_USAGE = 2
M.EXIT_UNAVAILABLE = 69
M.EXIT_IO_ERROR = 74

--- The dialog kinds, one of which every command line names exactly once.
M.KINDS = { question = true, info = true, warning = true, error = true, entry = true, list = true,
	["file-selection"] = true }

-- Options that take a value, written --name=value or --name value.
local VALUE_OPTIONS = { title = true, text = true, ["ok-label"] = true, ["cancel-label"] = true,
	["entry-text"] = true, column = true, ["print-column"] = true, ["hide-column"] = true,
	filename = true, ["file-filter"] = true, width = true, height = true }

-- Options that are switches.
local FLAG_OPTIONS = { ["no-markup"] = true, ["default-cancel"] = true, ["hide-text"] = true,
	["hide-header"] = true, directory = true }

-- GTK enumerations (gtk/gtkenums.h, gtk/gtkdialog.h, gtk/gtkmessagedialog.h).
local GTK_DIALOG_MODAL = 1
local GTK_MESSAGE_INFO, GTK_MESSAGE_WARNING, GTK_MESSAGE_QUESTION, GTK_MESSAGE_ERROR = 0, 1, 2, 3
local GTK_BUTTONS_NONE = 0
local GTK_RESPONSE_OK, GTK_RESPONSE_CANCEL = -5, -6
local GTK_FILE_CHOOSER_ACTION_OPEN, GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER = 0, 2
local GTK_WIN_POS_CENTER = 1
local G_TYPE_STRING = 16 * 4

-- The message type each message kind shows.
local MESSAGE_TYPES = { question = GTK_MESSAGE_QUESTION, info = GTK_MESSAGE_INFO,
	warning = GTK_MESSAGE_WARNING, error = GTK_MESSAGE_ERROR }

-- The list window's size when the caller names none, in pixels.
local LIST_DEFAULT_WIDTH, LIST_DEFAULT_HEIGHT = 420, 360




-- ==================================
-- ==================================
-- ======= 1/ Command line ==========
-- ==================================
-- ==================================

--- Parses a command line into a dialog request.
--- @param argv table The arguments, without the program name.
--- @return table|nil request { kind, options, columns, values }; nil on refusal.
--- @return string|nil reason Why the arguments were refused.
function M.parse(argv)
	assert(type(argv) == "table", "argv must be a table")
	local request = { kind = nil, options = {}, columns = {}, values = {} }
	local index, positional = 1, false
	while index <= #argv do
		local word = argv[index]
		if type(word) ~= "string" then return nil, "argument " .. index .. " is not a string" end
		local name, value
		if not positional then
			name, value = word:match("^%-%-([%a][%w%-]*)=(.*)$")
			if not name then name = word:match("^%-%-([%a][%w%-]*)$") end
		end
		if not positional and word == "--" then
			positional = true
		elseif name == nil then
			request.values[#request.values + 1] = word
		elseif M.KINDS[name] and value == nil then
			if request.kind then return nil, "two dialog kinds: " .. request.kind .. " and " .. name end
			request.kind = name
		elseif FLAG_OPTIONS[name] and value == nil then
			request.options[name] = true
		elseif VALUE_OPTIONS[name] then
			if value == nil then
				index = index + 1
				value = argv[index]
				if type(value) ~= "string" then return nil, "--" .. name .. " needs a value" end
			end
			if name == "column" then
				request.columns[#request.columns + 1] = value
			else
				request.options[name] = value
			end
		else
			return nil, "unknown option " .. word
		end
		index = index + 1
	end
	if not request.kind then return nil, "no dialog kind" end
	for _, name in ipairs({ "width", "height", "print-column", "hide-column" }) do
		local raw = request.options[name]
		if raw ~= nil then
			local number = tonumber(raw)
			if not number or number < 1 or number % 1 ~= 0 then return nil, "--" .. name .. " must be a positive integer" end
			request.options[name] = number
		end
	end
	if request.kind == "list" then
		local count = #request.columns
		if count == 0 then return nil, "a list needs at least one --column" end
		if #request.values % count ~= 0 then return nil, "the list values do not fill whole rows" end
		for _, name in ipairs({ "print-column", "hide-column" }) do
			if (request.options[name] or 1) > count then return nil, "--" .. name .. " names no column" end
		end
	elseif #request.values > 0 and request.kind ~= "entry" then
		return nil, "unexpected value " .. request.values[1]
	end
	return request
end

--- The rows of a list request, each a table of its column values.
--- @param request table A parsed list request.
--- @return table rows
function M.rows(request)
	local count, rows = #request.columns, {}
	for start = 1, #request.values, count do
		local row = {}
		for column = 1, count do row[column] = request.values[start + column - 1] end
		rows[#rows + 1] = row
	end
	return rows
end

--- Splits a « Name | *.a *.b » file filter into its name and patterns.
--- @param filter string
--- @return string name, table patterns
function M.file_filter(filter)
	local name, rest = filter:match("^%s*(.-)%s*|%s*(.-)%s*$")
	if not name then name, rest = filter, filter end
	local patterns = {}
	for pattern in rest:gmatch("%S+") do patterns[#patterns + 1] = pattern end
	return name, patterns
end




-- ==========================
-- ==========================
-- ======= 2/ GTK ===========
-- ==========================
-- ==========================

-- The sonames tried for each library, newest first.
local LIBRARIES = {
	gtk = { "libgtk-3.so.0", "libgtk-3.so" },
	glib = { "libglib-2.0.so.0", "libglib-2.0.so" },
	gobject = { "libgobject-2.0.so.0", "libgobject-2.0.so" },
}

local DECLARATIONS = [[
	typedef void GtkWidget;
	typedef void* gpointer;
	typedef int gboolean;
	typedef unsigned long gulong;
	typedef size_t GType;
	typedef void (*GCallback)(void);
	typedef void (*ErgoptiDialogRowActivated)(void *view, void *path, void *column, void *data);
	typedef struct { int stamp; gpointer user_data; gpointer user_data2; gpointer user_data3; } GtkTreeIter;

	gboolean   gtk_init_check(int *argc, char ***argv);
	GtkWidget* gtk_message_dialog_new(GtkWidget *parent, int flags, int type, int buttons, const char *format, ...);
	void       gtk_message_dialog_set_markup(GtkWidget *dialog, const char *markup);
	GtkWidget* gtk_dialog_new(void);
	GtkWidget* gtk_dialog_add_button(GtkWidget *dialog, const char *text, int response);
	void       gtk_dialog_set_default_response(GtkWidget *dialog, int response);
	GtkWidget* gtk_dialog_get_content_area(GtkWidget *dialog);
	int        gtk_dialog_run(GtkWidget *dialog);
	void       gtk_dialog_response(GtkWidget *dialog, int response);
	void       gtk_window_set_title(GtkWidget *window, const char *title);
	void       gtk_window_set_default_size(GtkWidget *window, int width, int height);
	void       gtk_window_set_position(GtkWidget *window, int position);
	void       gtk_container_add(GtkWidget *container, GtkWidget *widget);
	void       gtk_container_set_border_width(GtkWidget *container, unsigned int width);
	void       gtk_box_pack_start(GtkWidget *box, GtkWidget *child, gboolean expand, gboolean fill, unsigned int padding);
	void       gtk_box_set_spacing(GtkWidget *box, int spacing);
	GtkWidget* gtk_label_new(const char *text);
	void       gtk_label_set_markup(GtkWidget *label, const char *markup);
	void       gtk_label_set_line_wrap(GtkWidget *label, gboolean wrap);
	void       gtk_label_set_xalign(GtkWidget *label, float xalign);
	GtkWidget* gtk_entry_new(void);
	void       gtk_entry_set_text(GtkWidget *entry, const char *text);
	const char* gtk_entry_get_text(GtkWidget *entry);
	void       gtk_entry_set_visibility(GtkWidget *entry, gboolean visible);
	void       gtk_entry_set_activates_default(GtkWidget *entry, gboolean setting);
	GtkWidget* gtk_combo_box_text_new_with_entry(void);
	void       gtk_combo_box_text_append_text(GtkWidget *combo, const char *text);
	GtkWidget* gtk_bin_get_child(GtkWidget *bin);
	GtkWidget* gtk_scrolled_window_new(void *hadjustment, void *vadjustment);
	void*      gtk_list_store_newv(int n_columns, GType *types);
	void       gtk_list_store_append(void *store, GtkTreeIter *iter);
	void       gtk_list_store_set(void *store, GtkTreeIter *iter, ...);
	GtkWidget* gtk_tree_view_new_with_model(void *model);
	void       gtk_tree_view_set_headers_visible(GtkWidget *view, gboolean visible);
	int        gtk_tree_view_append_column(GtkWidget *view, void *column);
	void*      gtk_tree_view_get_selection(GtkWidget *view);
	void*      gtk_cell_renderer_text_new(void);
	void*      gtk_tree_view_column_new_with_attributes(const char *title, void *cell, ...);
	void       gtk_tree_view_column_set_visible(void *column, gboolean visible);
	gboolean   gtk_tree_selection_get_selected(void *selection, void **model, GtkTreeIter *iter);
	void       gtk_tree_model_get(void *model, GtkTreeIter *iter, ...);
	GtkWidget* gtk_file_chooser_dialog_new(const char *title, GtkWidget *parent, int action, const char *first, ...);
	gboolean   gtk_file_chooser_set_filename(GtkWidget *chooser, const char *filename);
	gboolean   gtk_file_chooser_set_current_folder(GtkWidget *chooser, const char *folder);
	char*      gtk_file_chooser_get_filename(GtkWidget *chooser);
	void       gtk_file_chooser_add_filter(GtkWidget *chooser, void *filter);
	void*      gtk_file_filter_new(void);
	void       gtk_file_filter_set_name(void *filter, const char *name);
	void       gtk_file_filter_add_pattern(void *filter, const char *pattern);
	void       gtk_widget_show_all(GtkWidget *widget);
	void       gtk_widget_destroy(GtkWidget *widget);
	void       gtk_widget_grab_focus(GtkWidget *widget);
	const char* g_dgettext(const char *domain, const char *msgid);
	void       g_free(gpointer memory);
	gulong     g_signal_connect_data(gpointer instance, const char *signal, GCallback handler, gpointer data,
	                                 void *destroy, int flags);
]]

--- Loads the first soname of a list that resolves.
--- @param ffi table
--- @param names table
--- @return userdata|nil
local function load_any(ffi, names)
	for _, name in ipairs(names) do
		local loaded, library = pcall(ffi.load, name)
		if loaded then return library end
	end
	return nil
end

--- Binds GTK 3 and opens the display.
--- @return table|nil gtk { ffi, gtk, glib, gobject }; nil with a reason when it cannot.
--- @return string|nil reason
local function bind()
	local ffi = require("ffi")
	ffi.cdef(DECLARATIONS)
	local gtk, glib, gobject = load_any(ffi, LIBRARIES.gtk), load_any(ffi, LIBRARIES.glib), load_any(ffi, LIBRARIES.gobject)
	if not gtk or not glib or not gobject then return nil, "GTK 3 is not installed" end
	-- gtk_init_check, not gtk_init: the latter exits with its own status when
	-- there is no display, which a caller would read as a refusal.
	if gtk.gtk_init_check(nil, nil) == 0 then return nil, "GTK 3 cannot open the display" end
	return { ffi = ffi, gtk = gtk, glib = glib, gobject = gobject }
end

--- A button label: the caller's, else GTK's own translated stock word.
--- @param lib table
--- @param given string|nil
--- @param stock string A GTK 3 message id, such as "_OK".
--- @return string
local function label(lib, given, stock)
	if given ~= nil and given ~= "" then return given end
	return lib.ffi.string(lib.glib.g_dgettext("gtk30", stock))
end

--- Sets the window title and centres it.
--- @param lib table
--- @param window userdata
--- @param request table
local function frame(lib, window, request)
	lib.gtk.gtk_window_set_title(window, request.options.title or "")
	lib.gtk.gtk_window_set_position(window, GTK_WIN_POS_CENTER)
	-- Focused when it opens (gtk_dialog_run presents it), never kept on top:
	-- tools/test/test-ui-focus-fix.cjs holds every window to that rule.
	if request.options.width or request.options.height then
		lib.gtk.gtk_window_set_default_size(window, request.options.width or -1, request.options.height or -1)
	end
end

--- Adds the request's text above a dialog's own content, plain or markup.
--- @param lib table
--- @param dialog userdata
--- @param request table
--- @return userdata content The dialog's content box.
local function content_with_text(lib, dialog, request)
	local content = lib.gtk.gtk_dialog_get_content_area(dialog)
	lib.gtk.gtk_container_set_border_width(content, 12)
	lib.gtk.gtk_box_set_spacing(content, 8)
	local text = request.options.text
	if text ~= nil and text ~= "" then
		local caption = lib.gtk.gtk_label_new(request.options["no-markup"] and text or nil)
		if not request.options["no-markup"] then lib.gtk.gtk_label_set_markup(caption, text) end
		lib.gtk.gtk_label_set_line_wrap(caption, 1)
		lib.gtk.gtk_label_set_xalign(caption, 0)
		lib.gtk.gtk_box_pack_start(content, caption, 0, 0, 0)
	end
	return content
end

--- Adds Cancel and OK to a dialog, OK the default.
--- @param lib table
--- @param dialog userdata
--- @param request table
local function add_answer_buttons(lib, dialog, request)
	lib.gtk.gtk_dialog_add_button(dialog, label(lib, request.options["cancel-label"], "_Cancel"), GTK_RESPONSE_CANCEL)
	lib.gtk.gtk_dialog_add_button(dialog, label(lib, request.options["ok-label"], "_OK"), GTK_RESPONSE_OK)
	lib.gtk.gtk_dialog_set_default_response(dialog, GTK_RESPONSE_OK)
end

--- Runs a question or a message.
--- @param lib table
--- @param request table
--- @return number status
local function run_message(lib, request)
	local plain = request.options["no-markup"] and (request.options.text or "") or ""
	local dialog = lib.gtk.gtk_message_dialog_new(nil, GTK_DIALOG_MODAL, MESSAGE_TYPES[request.kind], GTK_BUTTONS_NONE,
		"%s", plain)
	if not request.options["no-markup"] then lib.gtk.gtk_message_dialog_set_markup(dialog, request.options.text or "") end
	frame(lib, dialog, request)
	if request.kind == "question" then
		lib.gtk.gtk_dialog_add_button(dialog, label(lib, request.options["cancel-label"], "_No"), GTK_RESPONSE_CANCEL)
		lib.gtk.gtk_dialog_add_button(dialog, label(lib, request.options["ok-label"], "_Yes"), GTK_RESPONSE_OK)
		-- A destructive question defaults to the safe answer when asked to.
		lib.gtk.gtk_dialog_set_default_response(dialog,
			request.options["default-cancel"] and GTK_RESPONSE_CANCEL or GTK_RESPONSE_OK)
	else
		lib.gtk.gtk_dialog_add_button(dialog, label(lib, request.options["ok-label"], "_OK"), GTK_RESPONSE_OK)
		lib.gtk.gtk_dialog_set_default_response(dialog, GTK_RESPONSE_OK)
	end
	local response = lib.gtk.gtk_dialog_run(dialog)
	lib.gtk.gtk_widget_destroy(dialog)
	-- A message is acknowledged however it closes; only a question has a no.
	if request.kind ~= "question" then return M.EXIT_ACCEPTED end
	return response == GTK_RESPONSE_OK and M.EXIT_ACCEPTED or M.EXIT_CANCELLED
end

--- Runs a text entry; offered values become the entry's drop-down list.
--- @param lib table
--- @param request table
--- @return number status, string|nil answer
local function run_entry(lib, request)
	local dialog = lib.gtk.gtk_dialog_new()
	frame(lib, dialog, request)
	local content = content_with_text(lib, dialog, request)
	local field, entry
	if #request.values > 0 then
		field = lib.gtk.gtk_combo_box_text_new_with_entry()
		for _, value in ipairs(request.values) do lib.gtk.gtk_combo_box_text_append_text(field, value) end
		entry = lib.gtk.gtk_bin_get_child(field)
	else
		field = lib.gtk.gtk_entry_new()
		entry = field
	end
	lib.gtk.gtk_entry_set_text(entry, request.options["entry-text"] or "")
	if request.options["hide-text"] then lib.gtk.gtk_entry_set_visibility(entry, 0) end
	lib.gtk.gtk_entry_set_activates_default(entry, 1)
	lib.gtk.gtk_box_pack_start(content, field, 0, 0, 0)
	add_answer_buttons(lib, dialog, request)
	lib.gtk.gtk_widget_show_all(dialog)
	lib.gtk.gtk_widget_grab_focus(entry)
	local response = lib.gtk.gtk_dialog_run(dialog)
	local answer = response == GTK_RESPONSE_OK and lib.ffi.string(lib.gtk.gtk_entry_get_text(entry)) or nil
	lib.gtk.gtk_widget_destroy(dialog)
	if answer == nil then return M.EXIT_CANCELLED end
	return M.EXIT_ACCEPTED, answer
end

--- Runs a single-choice list; a double click or Enter on a row accepts it.
--- @param lib table
--- @param request table
--- @return number status, string|nil answer
local function run_list(lib, request)
	local ffi, gtk = lib.ffi, lib.gtk
	local count = #request.columns
	local types = ffi.new("GType[?]", count)
	for column = 0, count - 1 do types[column] = G_TYPE_STRING end
	local store = gtk.gtk_list_store_newv(count, types)
	local iter = ffi.new("GtkTreeIter")
	for _, row in ipairs(M.rows(request)) do
		gtk.gtk_list_store_append(store, iter)
		for column = 1, count do
			gtk.gtk_list_store_set(store, iter, ffi.cast("int", column - 1), row[column], ffi.cast("int", -1))
		end
	end
	local dialog = gtk.gtk_dialog_new()
	frame(lib, dialog, request)
	if not (request.options.width or request.options.height) then
		gtk.gtk_window_set_default_size(dialog, LIST_DEFAULT_WIDTH, LIST_DEFAULT_HEIGHT)
	end
	local content = content_with_text(lib, dialog, request)
	local view = gtk.gtk_tree_view_new_with_model(store)
	gtk.gtk_tree_view_set_headers_visible(view, request.options["hide-header"] and 0 or 1)
	for column = 1, count do
		local renderer = gtk.gtk_cell_renderer_text_new()
		local shown = gtk.gtk_tree_view_column_new_with_attributes(request.columns[column], renderer,
			"text", ffi.cast("int", column - 1), ffi.cast("void *", nil))
		if request.options["hide-column"] == column then gtk.gtk_tree_view_column_set_visible(shown, 0) end
		gtk.gtk_tree_view_append_column(view, shown)
	end
	-- One process, one dialog: this single callback is never released early.
	local activated = ffi.cast("ErgoptiDialogRowActivated", function() gtk.gtk_dialog_response(dialog, GTK_RESPONSE_OK) end)
	lib.gobject.g_signal_connect_data(view, "row-activated", ffi.cast("GCallback", activated), nil, nil, 0)
	local scrolled = gtk.gtk_scrolled_window_new(nil, nil)
	gtk.gtk_container_add(scrolled, view)
	gtk.gtk_box_pack_start(content, scrolled, 1, 1, 0)
	add_answer_buttons(lib, dialog, request)
	gtk.gtk_widget_show_all(dialog)
	gtk.gtk_widget_grab_focus(view)
	local response = gtk.gtk_dialog_run(dialog)
	local answer
	if response == GTK_RESPONSE_OK then
		local model = ffi.new("void *[1]")
		if gtk.gtk_tree_selection_get_selected(gtk.gtk_tree_view_get_selection(view), model, iter) ~= 0 then
			local value = ffi.new("char *[1]")
			gtk.gtk_tree_model_get(model[0], iter, ffi.cast("int", (request.options["print-column"] or 1) - 1), value,
				ffi.cast("int", -1))
			answer = value[0] ~= nil and ffi.string(value[0]) or ""
			if value[0] ~= nil then lib.glib.g_free(value[0]) end
		else
			answer = ""
		end
	end
	gtk.gtk_widget_destroy(dialog)
	if answer == nil then return M.EXIT_CANCELLED end
	return M.EXIT_ACCEPTED, answer
end

--- Runs a file or folder chooser.
--- @param lib table
--- @param request table
--- @return number status, string|nil answer
local function run_file(lib, request)
	local ffi, gtk = lib.ffi, lib.gtk
	local folder = request.options.directory == true
	local dialog = gtk.gtk_file_chooser_dialog_new(request.options.title or "", nil,
		folder and GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER or GTK_FILE_CHOOSER_ACTION_OPEN,
		label(lib, request.options["cancel-label"], "_Cancel"), ffi.cast("int", GTK_RESPONSE_CANCEL),
		label(lib, request.options["ok-label"], folder and "_Select" or "_Open"), ffi.cast("int", GTK_RESPONSE_OK),
		ffi.cast("void *", nil))
	frame(lib, dialog, request)
	gtk.gtk_dialog_set_default_response(dialog, GTK_RESPONSE_OK)
	local seed = request.options.filename
	if seed ~= nil and seed ~= "" then
		-- A trailing slash names a folder to open in, as zenity reads it.
		if seed:sub(-1) == "/" then gtk.gtk_file_chooser_set_current_folder(dialog, seed)
		else gtk.gtk_file_chooser_set_filename(dialog, seed) end
	end
	local filter = request.options["file-filter"]
	if filter ~= nil then
		local name, patterns = M.file_filter(filter)
		local native = gtk.gtk_file_filter_new()
		gtk.gtk_file_filter_set_name(native, name)
		for _, pattern in ipairs(patterns) do gtk.gtk_file_filter_add_pattern(native, pattern) end
		gtk.gtk_file_chooser_add_filter(dialog, native)
	end
	local response = gtk.gtk_dialog_run(dialog)
	local answer
	if response == GTK_RESPONSE_OK then
		local chosen = gtk.gtk_file_chooser_get_filename(dialog)
		if chosen ~= nil then
			answer = ffi.string(chosen)
			lib.glib.g_free(chosen)
		end
	end
	gtk.gtk_widget_destroy(dialog)
	if answer == nil then return M.EXIT_CANCELLED end
	return M.EXIT_ACCEPTED, answer
end




-- ===========================
-- ===========================
-- ======= 3/ Entry ==========
-- ===========================
-- ===========================

--- Runs one dialog from a command line and reports its exit status.
--- @param argv table The arguments, without the program name.
--- @param io_out table|nil io.stdout by default; where the answer is written.
--- @param io_err table|nil io.stderr by default; where a refusal is written.
--- @param binder function|nil The GTK binding; a test seam.
--- @return number status
function M.main(argv, io_out, io_err, binder)
	local out, err = io_out or io.stdout, io_err or io.stderr
	local request, refusal = M.parse(argv)
	if not request then
		err:write("ergopti dialog: ", refusal, "\n")
		return M.EXIT_USAGE
	end
	local lib, reason = (binder or bind)()
	if not lib then
		err:write("ergopti dialog: ", reason, "\n")
		return M.EXIT_UNAVAILABLE
	end
	local status, answer
	if MESSAGE_TYPES[request.kind] then
		status = run_message(lib, request)
	elseif request.kind == "entry" then
		status, answer = run_entry(lib, request)
	elseif request.kind == "list" then
		status, answer = run_list(lib, request)
	else
		status, answer = run_file(lib, request)
	end
	if answer ~= nil then
		local called, written = pcall(out.write, out, answer, "\n")
		local flushed, accepted = pcall(out.flush, out)
		if not called or not written or not flushed or not accepted then
			pcall(err.write, err, "ergopti dialog: could not publish the answer\n")
			return M.EXIT_IO_ERROR
		end
	end
	return status
end

-- Importing the module parses nothing and opens no display.
local invoked_source = debug.getinfo(1, "S").source:gsub("^@", "")
if type(arg) == "table" and arg[0] == invoked_source then
	local argv = {}
	for index = 1, #arg do argv[index] = arg[index] end
	os.exit(M.main(argv))
end

return M
