--- tests/unit/ui/webview/test_dialog_host.lua

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
local Host = h.load_module("ui.dialog_host")
local NativeDialog = h.load_module("ui.native_dialog")

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
		h.assert_eq(command, "</opt/ergopti/runtime/bin/luajit> </usr/lib/ergopti/ui/dialog_host.lua>")
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
			local status = os.execute("kill -HUP $$")
			h.assert_eq(status, 1, "the child really terminated by SIGHUP")
			h.assert_nil(NativeDialog.exit_code(status), "a killed dialog is not a user cancellation")
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
