--- tests/unit/core/ui/webview/test_dialog_host.lua

--- ==============================================================================
--- MODULE: Owned Native Dialog Host
--- DESCRIPTION:
--- Ergopti's own GTK 3 dialog program replaced the host's zenity and kdialog.
--- Its command line is the zenity subset the call sites wrote, so these cases
--- pin the parse of every form a site uses, the refusals, the exit statuses a
--- caller reads, and the resolver that starts it with the daemon's interpreter.
---
--- ROOT CAUSE ENCODED:
--- Every dialog shelled out to a host program the package had to depend on and
--- the owned-runtimes policy forbids; a site that drops the owned prefix, or a
--- host that answers a refusal with the cancel status, fails here.
--- ==============================================================================

local h = require("tests.helpers")
local Host = h.load_module("core.ui.ui.dialog_host")
local NativeDialog = h.load_module("core.ui.ui.native_dialog")

--- A writer double that keeps what it received.
--- @return table writer
local function sink()
	local writer = { text = "" }
	function writer:write(...)
		for index = 1, select("#", ...) do self.text = self.text .. tostring((select(index, ...))) end
		return self
	end
	function writer:flush() return self end
	return writer
end

h.describe("owned dialog host command line (owned-dialog-host)", function()
	h.it("(owned-dialog-host) a question keeps its labels, its plain text and its safe default", function()
		local request = assert(Host.parse({ "--question", "--no-markup", "--default-cancel", "--title=T",
			"--text=a < b", "--ok-label=Go", "--cancel-label", "Stop" }))
		h.assert_eq(request.kind, "question")
		h.assert_eq(request.options.title, "T")
		h.assert_eq(request.options.text, "a < b")
		h.assert_eq(request.options["ok-label"], "Go")
		h.assert_eq(request.options["cancel-label"], "Stop")
		h.assert_true(request.options["no-markup"])
		h.assert_true(request.options["default-cancel"])
	end)

	h.it("(owned-dialog-host) an entry keeps its masked seed and its offered values", function()
		local request = assert(Host.parse({ "--entry", "--title=T", "--text=Key", "--entry-text=", "--hide-text",
			"first", "second 'two'" }))
		h.assert_eq(request.options["entry-text"], "")
		h.assert_true(request.options["hide-text"])
		h.assert_eq(request.values, { "first", "second 'two'" })
	end)

	h.it("(owned-dialog-host) a separator preserves option-shaped choices", function()
		local entry = assert(Host.parse({ "--entry", "--", "--hide-text", "--", "--unknown=value" }))
		h.assert_eq(entry.values, { "--hide-text", "--", "--unknown=value" })
		h.assert_nil(entry.options["hide-text"])
		local list = assert(Host.parse({ "--list", "--column=Value", "--column=Label", "--",
			"--question", "--title=example" }))
		h.assert_eq(Host.rows(list), { { "--question", "--title=example" } })
	end)

	h.it("(owned-dialog-host) a list reads whole rows and its hidden printed column", function()
		local request = assert(Host.parse({ "--list", "--no-markup", "--hide-header", "--title=T", "--text=Pick",
			"--column=", "--column=", "--hide-column=1", "--print-column=1", "v1", "Label 1", "v2", "Label 2" }))
		h.assert_eq(request.columns, { "", "" })
		h.assert_eq(request.options["hide-column"], 1)
		h.assert_eq(request.options["print-column"], 1)
		h.assert_eq(Host.rows(request), { { "v1", "Label 1" }, { "v2", "Label 2" } })
	end)

	h.it("(owned-dialog-host) a file chooser keeps its folder mode, seed and filter", function()
		local request = assert(Host.parse({ "--file-selection", "--directory", "--title=T", "--filename=/home/me/",
			"--file-filter=*.desktop" }))
		h.assert_true(request.options.directory)
		h.assert_eq(request.options.filename, "/home/me/")
		local name, patterns = Host.file_filter(request.options["file-filter"])
		h.assert_eq(name, "*.desktop")
		h.assert_eq(patterns, { "*.desktop" })
		name, patterns = Host.file_filter("Pictures | *.png *.jpg")
		h.assert_eq(name, "Pictures")
		h.assert_eq(patterns, { "*.png", "*.jpg" })
	end)

	h.it("(owned-dialog-host) malformed command lines are refused, never shown", function()
		for _, argv in ipairs({
			{},
			{ "--title=T" },
			{ "--question", "--info" },
			{ "--question", "--bogus" },
			{ "--question", "stray" },
			{ "--list", "a", "b" },
			{ "--list", "--column=A", "--column=B", "only-one" },
			{ "--list", "--column=A", "--print-column=2", "x" },
			{ "--entry", "--width=0" },
			{ "--question", "--title" },
		}) do
			local request, reason = Host.parse(argv)
			h.assert_nil(request, table.concat(argv, " "))
			h.assert_true(type(reason) == "string" and reason ~= "", "a refusal names its reason")
		end
	end)
end)

h.describe("owned dialog host exit statuses (owned-dialog-host)", function()
	h.it("(owned-dialog-host) refused arguments exit 2 before any display is opened", function()
		local out, err, bound = sink(), sink(), false
		local status = Host.main({ "--bogus" }, out, err, function() bound = true end)
		h.assert_eq(status, Host.EXIT_USAGE)
		h.assert_eq(bound, false)
		h.assert_eq(out.text, "")
		h.assert_true(err.text:find("unknown option --bogus", 1, true) ~= nil, err.text)
	end)

	h.it("(owned-dialog-output) refuses acceptance when stdout cannot flush", function()
		local full = io.open("/dev/full", "wb")
		if not full then return end
		local gtk = setmetatable({
			gtk_dialog_run = function() return -5 end,
			gtk_entry_get_text = function() return "selected answer" end,
		}, { __index = function() return function() return {} end end })
		local lib = { gtk = gtk, ffi = { string = function(value) return value end }, glib = {} }
		local ok, status = pcall(Host.main, { "--entry", "--ok-label=OK", "--cancel-label=Cancel" }, full, sink(), function() return lib end)
		pcall(full.close, full)
		h.assert_true(ok, tostring(status))
		h.assert_true(status ~= Host.EXIT_ACCEPTED and status ~= Host.EXIT_CANCELLED,
			"a lost answer is neither acceptance nor user cancellation")
	end)

	h.it("(owned-dialog-output) refuses a rejected write without logging the answer", function()
		local out, err = { write = function() return nil, "refused" end, flush = function() return true end }, sink()
		local gtk = setmetatable({
			gtk_dialog_run = function() return -5 end,
			gtk_entry_get_text = function() return "sensitive-answer-canary" end,
		}, { __index = function() return function() return {} end end })
		local lib = { gtk = gtk, ffi = { string = function(value) return value end }, glib = {} }
		local status = Host.main({ "--entry", "--ok-label=OK", "--cancel-label=Cancel" }, out, err, function() return lib end)
		h.assert_eq(status, Host.EXIT_IO_ERROR)
		h.assert_nil(err.text:find("sensitive-answer-canary", 1, true))
	end)

	h.it("(owned-dialog-host) no GTK 3 or no display exits 69, never the cancel status", function()
		local out, err = sink(), sink()
		local status = Host.main({ "--question", "--text=Q" }, out, err, function() return nil, "GTK 3 is not installed" end)
		h.assert_eq(status, Host.EXIT_UNAVAILABLE)
		h.assert_eq(status, NativeDialog.EXIT_UNAVAILABLE)
		h.assert_true(status ~= NativeDialog.EXIT_CANCELLED)
		h.assert_true(err.text:find("GTK 3 is not installed", 1, true) ~= nil, err.text)
	end)
end)

h.describe("owned dialog resolver (owned-dialog-host)", function()
	h.it("(owned-dialog-host) the command is the daemon's interpreter and the host beside this module", function()
		local command = NativeDialog.command({
			exepath = function() return "/opt/ergopti/runtime/bin/luajit" end,
			driver_root = function() return "/usr/lib/ergopti" end,
			quote = function(value) return "<" .. value .. ">" end,
		})
		h.assert_eq(command, "</opt/ergopti/runtime/bin/luajit> </usr/lib/ergopti/core/ui/ui/dialog_host.lua>")
		-- The real resolution names an existing host file under the driver root
		local real = NativeDialog.command()
		local resolved = real:match("'([^']+)'$") or real:match("(%S+)$")
		h.assert_true(resolved:sub(1, #h.driver_root() + 1) == h.driver_root() .. "/", real)
		local host = io.open(resolved, "rb")
		h.assert_true(host ~= nil, "the resolved host exists: " .. resolved)
		host:close()
	end)

	h.it("(owned-dialog-host) a relative interpreter or root is refused", function()
		h.assert_eq(false, pcall(NativeDialog.command, { exepath = function() return "luajit" end,
			driver_root = function() return "/root" end, quote = tostring }))
		h.assert_eq(false, pcall(NativeDialog.command, { exepath = function() return "/bin/luajit" end,
			driver_root = function() return nil end, quote = tostring }))
	end)

	h.it("(owned-dialog-host) os.execute results read as the host's exit code on every interpreter", function()
		if jit then
			local status, how, code = os.execute("kill -HUP $$")
			if how == nil then
				h.assert_eq(status, 1, "the child really terminated by SIGHUP")
			else
				-- A LuaJIT built with LUA52COMPAT (Fedora, Alpine) reports the
				-- signal as Lua 5.2 does instead of a raw wait status.
				h.assert_eq({ status = status, how = how, code = code }, { how = "signal", code = 1 },
					"the child really terminated by SIGHUP")
			end
			h.assert_nil(NativeDialog.exit_code(status, how, code), "a killed dialog is not a user cancellation")
		end
		h.assert_eq(NativeDialog.exit_code(0), 0)
		h.assert_eq(NativeDialog.exit_code(true), 0)
		h.assert_eq(NativeDialog.exit_code(256), NativeDialog.EXIT_CANCELLED)
		h.assert_eq(NativeDialog.exit_code(nil, "exit", 1), NativeDialog.EXIT_CANCELLED)
		h.assert_eq(NativeDialog.exit_code(69 * 256), NativeDialog.EXIT_UNAVAILABLE)
		h.assert_eq(NativeDialog.exit_code(nil, "signal", 9), nil)
		h.assert_eq(NativeDialog.exit_code(256 + 9), nil)
	end)

	h.it("(owned-dialog-host) text read as markup is escaped once", function()
		h.assert_eq(NativeDialog.plain_markup("a < b & c > d"), "a &lt; b &amp; c &gt; d")
	end)
end)


--- A GTK double recording every call, its handles distinct tables.
--- @return table lib, table calls
local function recording_lib()
	local calls = {}
	local gtk = setmetatable({
		gtk_dialog_run = function() return -6 end,
	}, { __index = function(_, name)
		return function(...)
			calls[#calls + 1] = { name = name, args = { ... } }
			return { from = name }
		end
	end })
	local ffi = {
		new = function() return {} end,
		cast = function(_, value) return value end,
		string = function(value) return value end,
	}
	return { gtk = gtk, ffi = ffi, glib = {}, gobject = { g_signal_connect_data = function() return 0 end } }, calls
end

--- The arguments of the recorded calls to one GTK function.
--- @param calls table
--- @param name string
--- @return table
local function calls_to(calls, name)
	local found = {}
	for _, call in ipairs(calls) do
		if call.name == name then found[#found + 1] = call.args end
	end
	return found
end

h.describe("owned dialog host names its windows and fields (a11y-dialog-host)", function()
	h.it("(a11y-dialog-host) a window without a title is named after the product", function()
		h.assert_eq(Host.window_title({ options = {} }), "Ergopti+")
		h.assert_eq(Host.window_title({ options = { title = "" } }), "",
			"an empty title the caller gives is the unbranded-titles choice, kept")
		h.assert_eq(Host.window_title({ options = { title = "Clé" } }), "Clé")
		local lib, calls = recording_lib()
		Host.main({ "--question", "--no-markup", "--text=Q", "--ok-label=Y", "--cancel-label=N" }, sink(), sink(),
			function() return lib end)
		h.assert_eq(calls_to(calls, "gtk_window_set_title")[1][2], "Ergopti+")
	end)

	h.it("(a11y-dialog-host) an entry's caption names its text field", function()
		local lib, calls = recording_lib()
		Host.main({ "--entry", "--no-markup", "--text=Key", "--ok-label=OK", "--cancel-label=Cancel" }, sink(), sink(),
			function() return lib end)
		local bound = calls_to(calls, "gtk_label_set_mnemonic_widget")
		h.assert_eq(#bound, 1, "the caption is bound to exactly one field")
		h.assert_eq(bound[1][1].from, "gtk_label_new")
		h.assert_eq(bound[1][2].from, "gtk_entry_new")
	end)

	h.it("(a11y-dialog-host) an entry with offered values binds the combo's own entry", function()
		local lib, calls = recording_lib()
		Host.main({ "--entry", "--no-markup", "--text=Key", "--ok-label=OK", "--cancel-label=Cancel", "a", "b" },
			sink(), sink(), function() return lib end)
		h.assert_eq(calls_to(calls, "gtk_label_set_mnemonic_widget")[1][2].from, "gtk_bin_get_child")
	end)

	h.it("(a11y-dialog-host) a list's caption names its table", function()
		local lib, calls = recording_lib()
		Host.main({ "--list", "--no-markup", "--text=Pick", "--column=Value", "--ok-label=OK", "--cancel-label=Cancel",
			"one" }, sink(), sink(), function() return lib end)
		local bound = calls_to(calls, "gtk_label_set_mnemonic_widget")
		h.assert_eq(#bound, 1)
		h.assert_eq(bound[1][2].from, "gtk_tree_view_new_with_model")
	end)

	h.it("(a11y-dialog-host) no caption, no binding", function()
		local lib, calls = recording_lib()
		Host.main({ "--entry", "--ok-label=OK", "--cancel-label=Cancel" }, sink(), sink(), function() return lib end)
		h.assert_eq(#calls_to(calls, "gtk_label_set_mnemonic_widget"), 0)
	end)
end)

-- ==============================================================================
-- The host reads its guard's names from the shared tree in every launch mode.
-- ==============================================================================

local quote = require("core.text.engine.utils_core").shell_quote

--- The file a module loads from, and its path inside its tree.
--- @param name string Dotted module name.
--- @return string file Absolute source file.
--- @return string relative Its path below the tree root.
local function module_file(name)
	local file = assert(package.searchpath(name, package.path), "module unresolved: " .. name)
	return file, (name:gsub("%.", "/")) .. ".lua"
end

--- Copies one module into a tree at its own relative path.
--- @param name string Dotted module name.
--- @param tree string Destination root.
local function copy_module(name, tree)
	local file, relative = module_file(name)
	local target = tree .. "/" .. relative
	assert(os.execute("mkdir -p " .. quote(target:match("^(.*)/[^/]+$")) .. " && cp " .. quote(file) .. " "
		.. quote(target)), "copy " .. name)
end

--- A fresh, empty directory.
--- @return string path
local function fresh_directory()
	local path = os.tmpname()
	os.remove(path)
	assert(os.execute("mkdir -p " .. quote(path)), "temporary directory")
	return path
end

--- Starts a host script under the guard as a child, in the given environment.
--- @param prefix string Shell words before the interpreter (cd and env).
--- @param host string The host script as the child names it.
--- @return number|nil code The host's exit code.
--- @return string|nil recorded What the guarded host recorded.
local function run_guarded(prefix, host)
	local record = os.tmpname()
	os.remove(record)
	local command = prefix .. " env -u LUA_INIT -u LUA_INIT_5_1 " .. Host.GUARD_VARIABLE .. "=" .. quote(record) .. " "
		.. Host.GUARD_CASE_VARIABLE .. "=mode " .. quote(require("luv").exepath()) .. " " .. quote(host)
		.. " --error --title=T 2>/dev/null"
	local code = NativeDialog.exit_code(os.execute(command))
	local file = io.open(record, "rb")
	local recorded = file and file:read("*a")
	if file then file:close() end
	os.remove(record)
	return code, recorded
end

-- What a guarded host records for the request run_guarded sends.
local EXPECTED_RECORD = "mode\t--error T\n"

-- No launcher variable reaches the child unless the mode exports it.
local CLEAN = "env -u LUA_PATH -u ERGOPTI_LITERAL_DRIVER_ROOT -u ERGOPTI_LITERAL_SHARED_ROOT -u ERGOPTI_LITERAL_DIRECT"
	.. " -u ERGOPTI_LITERAL_DAEMON -u ERGOPTI_LITERAL_NATIVE_MODULES"

h.describe("owned dialog host launch modes (dialog-host-shared-names)", function()
	local host_file, host_relative = module_file("core.ui.ui.dialog_host")
	local root = host_file:sub(1, #host_file - #host_relative - 1)

	h.it("(dialog-host-shared-names) a checkout run without LUA_PATH finds the sibling shared tree", function()
		local code, recorded = run_guarded(CLEAN, host_file)
		h.assert_eq(code, Host.EXIT_UNAVAILABLE)
		h.assert_eq(recorded, EXPECTED_RECORD)
	end)

	h.it("(dialog-host-shared-names) a relative run from the driver directory finds it too", function()
		local code, recorded = run_guarded("cd " .. quote(root) .. " && " .. CLEAN, host_relative)
		h.assert_eq(code, Host.EXIT_UNAVAILABLE)
		h.assert_eq(recorded, EXPECTED_RECORD)
	end)

	h.it("(dialog-host-shared-names) a system package nests the shared tree in the driver", function()
		local base = fresh_directory()
		local package_root = base .. "/ergopti"
		copy_module("core.ui.ui.dialog_host", package_root)
		copy_module("core.text.engine.identifiers", package_root .. "/_shared")
		local bare_code, bare = run_guarded(CLEAN .. " LUA_PATH=';;'", package_root .. "/" .. host_relative)
		local exported = package_root .. "/?.lua;" .. package_root .. "/_shared/?.lua;;"
		local wrapped_code, wrapped = run_guarded(CLEAN .. " LUA_PATH=" .. quote(exported),
			package_root .. "/" .. host_relative)
		os.execute("rm -rf " .. quote(base))
		h.assert_eq(bare_code, Host.EXIT_UNAVAILABLE)
		h.assert_eq(bare, EXPECTED_RECORD)
		h.assert_eq(wrapped_code, Host.EXIT_UNAVAILABLE, "the AppImage and package wrappers export LUA_PATH")
		h.assert_eq(wrapped, EXPECTED_RECORD)
	end)

	h.it("(dialog-host-shared-names) a root with template bytes resolves through the literal loader", function()
		local base = fresh_directory()
		local install = base .. "/a;b?c"
		copy_module("core.ui.ui.dialog_host", install .. "/linux")
		copy_module("core.lifecycle.engine.literal_module_loader", install .. "/linux")
		copy_module("core.text.engine.identifiers", install .. "/_shared")
		local code, recorded = run_guarded(CLEAN .. " LUA_PATH=';;' ERGOPTI_LITERAL_DRIVER_ROOT=" .. quote(install .. "/linux")
			.. " ERGOPTI_LITERAL_SHARED_ROOT=" .. quote(install .. "/_shared"), install .. "/linux/" .. host_relative)
		os.execute("rm -rf " .. quote(base))
		h.assert_eq(code, Host.EXIT_UNAVAILABLE)
		h.assert_eq(recorded, EXPECTED_RECORD)
	end)

	h.it("(dialog-host-shared-names) a tree without its shared names fails before any window", function()
		local base = fresh_directory()
		copy_module("core.ui.ui.dialog_host", base .. "/ergopti")
		local code, recorded = run_guarded(CLEAN .. " LUA_PATH=';;'", base .. "/ergopti/" .. host_relative)
		os.execute("rm -rf " .. quote(base))
		h.assert_true(code ~= Host.EXIT_UNAVAILABLE and code ~= Host.EXIT_ACCEPTED, tostring(code))
		h.assert_nil(recorded, "the host stopped before reading the guard")
	end)
end)
