--- tests/unit/modules/shortcuts/actions/test_open_selection.lua

--- ==============================================================================
--- MODULE: copy_selected_path opens what the selection names (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/shortcuts/open_target_vectors.json, which the
--- macOS and Windows suites replay too, through _shared/shortcuts/engine with
--- the corpus's POSIX environment, then drives the real gesture dispatcher
--- with a recorded primary selection and a recording desktop opener.
---
--- ROOT CAUSE ENCODED:
--- The action did not exist on Linux, and the macOS and Windows versions sent
--- a selected IP address (192.168.1.1, 10.0.0.1:8080/admin) to a web search
--- instead of the browser (open-target-ip-address).
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("core.text.engine.json")
local OpenTarget = require("shortcuts.engine.open_target")

local CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/shortcuts/open_target_vectors.json"

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the open-target corpus is not valid JSON")
end

helpers.describe("opening selected content privacy", function()
	for _, failure in ipairs({ false, true }) do
		helpers.it("does not log selected search text on " .. (failure and "failure" or "success"), function()
			local old_logger, old_subject = package.loaded["core.logger.engine.shim"], package.loaded["modules.shortcuts.open_selection"]
			local logger = assert(dofile(require("core.fs.engine.paths").shared("core/logger/engine/init.lua")))
			local logs, opened = {}, nil
			logger.set_level("trace"); logger.set_sink(function(line) logs[#logs + 1] = line end)
			package.loaded["core.logger.engine.shim"] = logger
			package.loaded["modules.shortcuts.open_selection"] = nil
			local ok, err = xpcall(function()
				local subject = require("modules.shortcuts.open_selection")
				subject._set_deps_for_test({
					open = function(target, done)
						opened = target
						done(failure and { ok = false, error = "secretmarker" } or { ok = true })
						return {}
					end,
					notify = function() return true end, message = function() return "%s" end,
					getenv = function() return "/tmp" end,
				})
				helpers.assert_true(subject.open("secretmarker"))
				helpers.assert_true(opened:find("secretmarker", 1, true) ~= nil)
				helpers.assert_true(not table.concat(logs, "\n"):find("secretmarker", 1, true),
					"the selected query and native error details must not enter logs")
			end, debug.traceback)
			package.loaded["core.logger.engine.shim"], package.loaded["modules.shortcuts.open_selection"] = old_logger, old_subject
			if not ok then error(err, 0) end
		end)
	end
end)

helpers.describe("opening selected content notifier privacy", function()
	for _, mode in ipairs({ "unavailable", "refused" }) do
		helpers.it("keeps the selected path out of the real notifier fallback when " .. mode, function()
			local names = { "core.logger.engine.shim", "modules.shortcuts.open_selection", "adapters.notifier", "core.process.adapters.shell_runner" }
			local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name] end
			local logs = {}
			local logger = assert(dofile(require("core.fs.engine.paths").shared("core/logger/engine/init.lua")))
			logger.set_level("trace"); logger.set_sink(function(line) logs[#logs + 1] = line end)
			package.loaded["core.logger.engine.shim"] = logger
			package.loaded["core.process.adapters.shell_runner"] = {
				has_command = function() return mode ~= "unavailable" end,
				quote = function(value) return "'" .. value .. "'" end,
				run = function() return false end,
				run_async = function() return nil, "controlled spawn refusal" end,
			}
			package.loaded["adapters.notifier"] = nil
			package.loaded["modules.shortcuts.open_selection"] = nil
			local ok, err = xpcall(function()
				local subject = require("modules.shortcuts.open_selection")
				subject._set_deps_for_test({ exists = function() return false end,
					message = function() return "Cannot open %s" end, getenv = function() return "/tmp" end })
				helpers.assert_eq(subject.open("/tmp/secretmarker"), false)
				local output = table.concat(logs, "\n")
				helpers.assert_true(not output:find("secretmarker", 1, true), "notifier fallback must not expose the path")
				helpers.assert_true(output:find("Cannot open", 1, true) ~= nil, "the fallback still reports the failure")
			end, debug.traceback)
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
			if not ok then error(err, 0) end
		end)
	end
end)

helpers.describe("copied path notifier privacy", function()
	for _, mode in ipairs({ "unavailable", "refused" }) do
		helpers.it("keeps copied file paths out of the real notifier fallback when " .. mode, function()
			local names = { "core.logger.engine.shim", "modules.shortcuts.open_selection", "adapters.notifier", "core.process.adapters.shell_runner" }
			local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name] end
			local logs, written = {}, nil
			local logger = assert(dofile(require("core.fs.engine.paths").shared("core/logger/engine/init.lua")))
			logger.set_level("trace"); logger.set_sink(function(line) logs[#logs + 1] = line end)
			package.loaded["core.logger.engine.shim"] = logger
			package.loaded["core.process.adapters.shell_runner"] = {
				has_command = function() return mode ~= "unavailable" end,
				quote = function(value) return "'" .. value .. "'" end,
				run = function() return false end,
				run_async = function() return nil, "controlled spawn refusal" end,
			}
			package.loaded["adapters.notifier"] = nil
			package.loaded["modules.shortcuts.open_selection"] = nil
			local ok, err = xpcall(function()
				local subject = require("modules.shortcuts.open_selection")
				subject._set_deps_for_test({ focused_context = function() return "nautilus", "window:one" end,
					read_uri_list = function() return true, "file:///tmp/secretmarker\n" end,
					write_clipboard = function(text) written = text; return true end,
					message = function() return "Copied %s" end })
				helpers.assert_true(subject.copy_selected_path(function() return "" end))
				helpers.assert_eq(written, "/tmp/secretmarker")
				local output = table.concat(logs, "\n")
				helpers.assert_true(not output:find("secretmarker", 1, true), "notifier fallback must not expose the path")
				helpers.assert_true(output:find("Copied", 1, true) ~= nil)
			end, debug.traceback)
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
			if not ok then error(err, 0) end
		end)
	end
end)

--- Runs body with the session PRIMARY reader answering `selection`.
local function with_selection(selection, body)
	local previous = package.loaded["adapters.clipboard"]
	package.loaded["adapters.clipboard"] = { read_primary = function() return true, selection end }
	local ok, err = pcall(body)
	package.loaded["adapters.clipboard"] = previous
	if not ok then error(err, 0) end
end

--- Installs recording deps on the real open_selection module.
--- @param existing table|nil Paths that exist.
--- @return table world { opened, notices }
local function record(existing)
	local world = { opened = {}, notices = {} }
	local Subject = require("modules.shortcuts.open_selection")
	Subject._set_deps_for_test({
		open = function(target, on_done)
			world.opened[#world.opened + 1] = target
			on_done({ ok = true })
			return {}
		end,
		exists = function(path) return (existing or {})[path] == true end,
		path_status = function(path) return (existing or {})[path] and "present" or "absent" end,
		notify = function(message) world.notices[#world.notices + 1] = message; return true end,
		getenv = function(name) return ({ HOME = "/home/ada" })[name] end,
		focused_app = function() return "" end,
		focused_context = function() return "", nil end,
		active_frame_app = function() return nil end,
	})
	return world, Subject
end

--- Installs recording deps for a focused application and its copied selection.
--- @param app string The focused application identity.
--- @param read table|nil { ok, uri_list, reason } the clipboard answers.
--- @return table world { opened, notices, successes, written, copies, primary_reads }
--- @return table Subject
local function record_in(app, read, frame_app)
	local world = { opened = {}, notices = {}, successes = {}, written = {}, copies = 0, primary_reads = 0,
		frame_queries = 0 }
	local Subject = require("modules.shortcuts.open_selection")
	Subject._set_deps_for_test({
		open = function(target, on_done)
			world.opened[#world.opened + 1] = target
			on_done({ ok = true })
			return {}
		end,
		exists = function() return true end,
		notify = function(message) world.notices[#world.notices + 1] = message; return true end,
		notify_success = function(message) world.successes[#world.successes + 1] = message; return true end,
		message = function(key) return key == "shortcuts.copy_path_notif" and "Path copied: %s" or key end,
		getenv = function(name) return ({ HOME = "/home/ada" })[name] end,
		focused_app = function() return app end,
		focused_context = function()
			if app == "" then world.frame_queries = world.frame_queries + 1; return frame_app, "test:file-manager-window" end
			return app, "test:file-manager-window"
		end,
		active_frame_app = function()
			world.frame_queries = world.frame_queries + 1
			return frame_app
		end,
		read_uri_list = function()
			world.copies = world.copies + 1
			return read.ok, read.uri_list or "", read.reason
		end,
		write_clipboard = function(text) world.written[#world.written + 1] = text; return true end,
	})
	local function primary()
		world.primary_reads = world.primary_reads + 1
		return "https://example.com"
	end
	return world, Subject, primary
end

helpers.describe("copy_selected_path replays the shared open-target corpus", function()
	local corpus = read_corpus()
	local env = corpus.env.posix

	helpers.it("open-target: the corpus is loaded and exercises every kind", function()
		helpers.assert_true(#corpus.vectors >= 60, "the corpus must hold its vectors")
		local kinds = {}
		for _, vector in ipairs(corpus.vectors) do
			kinds[OpenTarget.classify(vector.text, function(name) return env[name] end).kind] = true
		end
		for _, kind in ipairs(OpenTarget.KINDS) do
			if kind ~= "registry" then
				helpers.assert_true(kinds[kind] == true, "the corpus must exercise the " .. kind .. " kind on Linux")
			end
		end
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("open-target vector '" .. vector.id .. "'", function()
			local want = vector.linux or vector.posix or vector.expect
			local got = OpenTarget.classify(vector.text, function(name) return env[name] end)
			helpers.assert_eq(got.kind, want.kind, vector.id .. ": kind")
			helpers.assert_eq(got.target, want.target, vector.id .. ": target")
			helpers.assert_eq(got.reason, want.reason, vector.id .. ": reason")
		end)
	end
end)

helpers.describe("copy_selected_path opens the primary selection (open-target-ip-address)", function()
	local G = helpers.load_module("modules.gestures.manager")
	G.init({ enabled = false })

	helpers.it("open-target: copy_selected_path is a Linux action now", function()
		local Catalogue = require("_generated.action_catalogue")
		local found = false
		for id in pairs(Catalogue.ACTIONS or Catalogue.actions or {}) do
			if id == "copy_selected_path" then found = true end
		end
		helpers.assert_true(found, "the Linux catalogue must offer copy_selected_path")
	end)

	for _, case in ipairs({
		{ "192.168.1.1", "http://192.168.1.1" },
		{ "10.0.0.1:8080/admin", "http://10.0.0.1:8080/admin" },
		{ "localhost:3000", "http://localhost:3000" },
		{ "example.com", "https://example.com" },
	}) do
		helpers.it("open-target: opens '" .. case[1] .. "' as " .. case[2] .. ", not a web search", function()
			local world, Subject = record()
			with_selection(case[1], function() G.execute_action("copy_selected_path", "tap_3") end)
			Subject._set_deps_for_test(nil)
			helpers.assert_eq(world.opened, { case[2] })
			helpers.assert_eq(#world.notices, 0)
		end)
	end

	helpers.it("open-target: opens an existing home-relative folder, reports a missing one (open-target-missing-path-reported)", function()
		local world, Subject = record({ ["/home/ada/Documents"] = true })
		Subject.open("~/Documents")
		Subject.open("/home/ada/nowhere")
		Subject._set_deps_for_test(nil)
		helpers.assert_eq(world.opened, { "/home/ada/Documents" })
		helpers.assert_eq(#world.notices, 1, "the missing path must be reported, not searched")
		helpers.assert_true(world.notices[1]:find("/home/ada/nowhere", 1, true) == nil,
			"the notice must not carry the private path to fallback logs")
	end)

	helpers.it("open-target: reports a registry key and a bare file name instead of searching them", function()
		local world, Subject = record()
		Subject.open("HKLM\\SOFTWARE")
		Subject.open("notes.txt")
		Subject._set_deps_for_test(nil)
		helpers.assert_eq(#world.opened, 0, "nothing must be opened, not even a search")
		helpers.assert_eq(#world.notices, 2)
	end)

	helpers.it("open-target: searches plain text with the shared default engine", function()
		local world, Subject = record()
		Subject.open("bonjour le monde")
		Subject._set_deps_for_test(nil)
		helpers.assert_eq(world.opened, { OpenTarget.DEFAULT_SEARCH_URL .. "bonjour%20le%20monde" })
	end)
end)

helpers.describe("copy_selected_path copies the selected files' paths in a file manager (linux-copy-path-file-manager)", function()
	local NAUTILUS_COPY = "file:///home/ada/Docs/r%C3%A9sum%C3%A9.pdf\r\nfile:///home/ada/My%20Folder\r\n"

	helpers.it("captures app and native window together before copy (copy-focus-snapshot)", function()
		local Subject = require("modules.shortcuts.open_selection")
		local window, presses = "x11:first", 0
		Subject._set_deps_for_test({
			focused_app = function() window = "x11:second"; return "nautilus" end,
			focused_identity = function() return window end,
			focused_context = function()
				local captured = window; window = "x11:second"; return "nautilus", captured
			end,
			read_uri_list = function(admitted)
				if admitted() then presses = presses + 1 end
				return false, "", "copy_chord_failed"
			end,
		})
		local result = Subject.copy_selected_path(function() return "" end)
		Subject._set_deps_for_test(nil)
		helpers.assert_eq(result, false)
		helpers.assert_eq(presses, 0, "a window changed during acquisition must not receive Ctrl+C")
	end)

	for _, mode in ipairs({ "x11", "wayland", "missing_identity" }) do
		helpers.it("uses one native " .. mode .. " focus snapshot for file copy (copy-focus-snapshot)", function()
			local Subject = require("modules.shortcuts.open_selection")
			local previous_window, previous_atspi = package.loaded["platform.focus.window_info"], package.loaded["platform.focus.atspi_focus"]
			local copied, queries = {}, 0
			package.loaded["platform.focus.window_info"] = {
				focused_snapshot = function()
					if mode == "x11" then return { appId = "nautilus" }, "x11:one" end
					if mode == "missing_identity" then return { appId = "nautilus" }, nil end
					return { appId = "" }, nil
				end,
			}
			package.loaded["platform.focus.atspi_focus"] = { get_context_snapshot = function()
				queries = queries + 1
				return { app_id = "nautilus", window_bus_name = ":1.42", window_object_path = "/window/1" }, true
			end }
			Subject._set_deps_for_test({ read_uri_list = function(admitted)
				assert(admitted()); return true, "file:///tmp/a\n"
			end, write_clipboard = function(text) copied[#copied + 1] = text; return true end,
				message = function() return "%s" end, notify_success = function() return true end })
			local called, result = pcall(Subject.copy_selected_path, function() return "" end)
			Subject._set_deps_for_test(nil)
			package.loaded["platform.focus.window_info"], package.loaded["platform.focus.atspi_focus"] = previous_window, previous_atspi
			helpers.assert_true(called and result)
			helpers.assert_eq(copied, { "/tmp/a" })
			helpers.assert_eq(queries, mode ~= "x11" and 3 or 0, "one observation per boundary")
		end)
	end

	helpers.it("refuses an AT-SPI fallback from another application (copy-focus-snapshot)", function()
		local Subject = require("modules.shortcuts.open_selection")
		local previous_window, previous_atspi = package.loaded["platform.focus.window_info"], package.loaded["platform.focus.atspi_focus"]
		local reads = 0
		package.loaded["platform.focus.window_info"] = { focused_snapshot = function() return { appId = "nautilus" }, nil end }
		package.loaded["platform.focus.atspi_focus"] = { get_context_snapshot = function()
			return { app_id = "dolphin", window_bus_name = ":1.42", window_object_path = "/window/1" }, true
		end }
		Subject._set_deps_for_test({ read_uri_list = function() reads = reads + 1; return false end })
		local called, result = pcall(Subject.copy_selected_path, function() error("unexpected fallback") end)
		Subject._set_deps_for_test(nil)
		package.loaded["platform.focus.window_info"], package.loaded["platform.focus.atspi_focus"] = previous_window, previous_atspi
		helpers.assert_true(called)
		helpers.assert_eq(result, false)
		helpers.assert_eq(reads, 0)
	end)

	helpers.it("refuses to copy after focus moves to another window of the same manager (copy-same-app-window)", function()
		local Subject = require("modules.shortcuts.open_selection")
		local window, presses = "x11:first", 0
		Subject._set_deps_for_test({ focused_app = function() return "nautilus" end,
			focused_context = function() return "nautilus", window end,
			read_uri_list = function(admitted)
				window = "x11:second"
				if admitted() then presses = presses + 1 end
				return false, "", "copy_chord_failed"
			end })
		local retained = assert(Subject.capture_file_manager())
		local result = Subject.copy_selected_path(function() return "" end)
		local still_current = retained()
		Subject._set_deps_for_test(nil)
		helpers.assert_eq(result, false)
		helpers.assert_eq(presses, 0, "the second window did not authorize Ctrl+C")
		helpers.assert_eq(still_current, false, "deferred file actions must also lose authority")
	end)

	helpers.it("does not publish a file selection after the manager window changes (copy-same-app-window)", function()
		local Subject = require("modules.shortcuts.open_selection")
		local window, written = "x11:first", 0
		Subject._set_deps_for_test({ focused_app = function() return "nautilus" end,
			focused_context = function() return "nautilus", window end,
			read_uri_list = function(admitted)
				assert(admitted()); window = "x11:second"
				return true, "file:///tmp/a\n"
			end,
			write_clipboard = function() written = written + 1; return true end })
		local result = Subject.copy_selected_path(function() return "" end)
		Subject._set_deps_for_test(nil)
		helpers.assert_eq(result, false)
		helpers.assert_eq(written, 0)
	end)

	helpers.it("refuses a file-manager copy without a native window identity (copy-same-app-window)", function()
		local Subject = require("modules.shortcuts.open_selection")
		local reads = 0
		Subject._set_deps_for_test({ focused_app = function() return "nautilus" end,
			focused_context = function() return "nautilus", nil end,
			read_uri_list = function() reads = reads + 1; return false end })
		local result = Subject.copy_selected_path(function() error("must not fall back to another selection") end)
		Subject._set_deps_for_test(nil)
		helpers.assert_eq(result, false)
		helpers.assert_eq(reads, 0)
	end)

	helpers.it("(linux-copy-path-file-manager) copies the decoded paths, one per line, and opens nothing", function()
		local world, Subject, primary = record_in("nautilus", { ok = true, uri_list = NAUTILUS_COPY })
		local done = Subject.copy_selected_path(primary)
		Subject._set_deps_for_test(nil)
		helpers.assert_true(done)
		helpers.assert_eq(world.written, { "/home/ada/Docs/résumé.pdf\n/home/ada/My Folder" })
		helpers.assert_eq(world.successes, { "Path copied: …" }, "the notice must not leak paths through fallback logs")
		helpers.assert_eq(world.opened, {}, "a file manager's selection is copied, never opened or searched")
		helpers.assert_eq(world.primary_reads, 0)
	end)

	for _, app in ipairs({ "org.gnome.Nautilus", "org.kde.dolphin", "Thunar", "nemo", "pcmanfm-qt" }) do
		helpers.it("(linux-copy-path-file-manager) recognises " .. app .. " as a file manager", function()
			local world, Subject, primary = record_in(app, { ok = true, uri_list = "file:///tmp/a\n" })
			Subject.copy_selected_path(primary)
			Subject._set_deps_for_test(nil)
			helpers.assert_eq(world.written, { "/tmp/a" })
		end)
	end

	helpers.it("refuses the copy chord if focus leaves the file manager during preparation", function()
		local Subject = require("modules.shortcuts.open_selection")
		local app, emitted, written = "nautilus", 0, 0
		Subject._set_deps_for_test({
			focused_app = function() return app end,
			focused_context = function() return app, "test:file-manager-window" end,
			read_uri_list = function(admitted)
				app = "gnome-terminal-server"
				helpers.assert_type(admitted, "function")
				if admitted() then emitted = emitted + 1 end
				return false, "", "copy_chord_failed"
			end,
			write_clipboard = function() written = written + 1; return true end,
		})
		local ran = Subject.copy_selected_path(function() return "" end)
		Subject._set_deps_for_test(nil)
		helpers.assert_eq(ran, false)
		helpers.assert_eq(emitted, 0)
		helpers.assert_eq(written, 0)
	end)

	helpers.it("the real URI adapter guards the actual Ctrl+C emitter", function()
		local Subject = require("modules.shortcuts.open_selection")
		local names = { "adapters.clipboard", "modules.gestures.combo_emitter", "core.events.loop" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local app, emitted = "nautilus", 0
		package.loaded[names[1]] = { read_selection_uri_list = function(press)
			app = "gnome-terminal-server"
			helpers.assert_eq(press("ctrl+c"), false)
			return false, "", "copy_chord_failed"
		end }
		package.loaded[names[2]] = { press = function() emitted = emitted + 1; return true end }
		package.loaded[names[3]] = { sleep_ms = function() return true end }
		Subject._set_deps_for_test({ focused_app = function() return app end,
			focused_context = function() return app, "test:file-manager-window" end })
		local ok, err = pcall(function() helpers.assert_eq(Subject.copy_selected_path(function() return "" end), false) end)
		Subject._set_deps_for_test(nil)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
		helpers.assert_eq(emitted, 0)
	end)

	helpers.it("(linux-copy-path-file-manager) sends no Ctrl+C outside a file manager", function()
		for _, app in ipairs({ "gnome-terminal-server", "firefox", "" }) do
			local world, Subject, primary = record_in(app, { ok = true, uri_list = "file:///tmp/a\n" })
			Subject.copy_selected_path(primary)
			Subject._set_deps_for_test(nil)
			helpers.assert_eq(world.copies, 0, "Ctrl+C would interrupt a terminal's program in '" .. app .. "'")
			helpers.assert_eq(world.opened, { "https://example.com" })
		end
	end)

	helpers.it("(linux-copy-path-wayland-frame) names the file manager through the AT-SPI active frame when the compositor names none", function()
		for _, frame in ipairs({ "nautilus", "dolphin" }) do
			local world, Subject, primary = record_in("", { ok = true, uri_list = "file:///tmp/a%20b\n" }, frame)
			local done = Subject.copy_selected_path(primary)
			Subject._set_deps_for_test(nil)
			helpers.assert_true(done)
			helpers.assert_eq(world.frame_queries, 2, "the active frame is checked again before publication")
			helpers.assert_eq(world.written, { "/tmp/a b" }, frame .. " selection is copied, not opened")
			helpers.assert_eq(world.opened, {})
		end
	end)

	helpers.it("retains the active Wayland file manager and revokes it on focus change", function()
		local Subject = require("modules.shortcuts.open_selection")
		local frame = "nautilus"
		Subject._set_deps_for_test({ focused_app = function() return "" end, active_frame_app = function() return frame end,
			focused_context = function() return frame, "test:file-manager-window" end })
		local admitted = Subject.capture_file_manager()
		helpers.assert_type(admitted, "function")
		helpers.assert_eq(admitted(), true)
		frame = "gnome-terminal-server"
		helpers.assert_eq(admitted(), false)
		Subject._set_deps_for_test(nil)
	end)

	helpers.it("(linux-copy-path-wayland-frame) keeps opening when the frame is unknown or not a file manager", function()
		for _, frame in ipairs({ false, "gnome-terminal-", "firefox" }) do
			local world, Subject, primary = record_in("", { ok = true, uri_list = "file:///tmp/a\n" }, frame or nil)
			Subject.copy_selected_path(primary)
			Subject._set_deps_for_test(nil)
			helpers.assert_eq(world.copies, 0, "no Ctrl+C is sent when the frame is not a file manager")
			helpers.assert_eq(world.opened, { "https://example.com" })
		end
	end)

	helpers.it("(linux-copy-path-wayland-frame) does not query AT-SPI when the compositor names the application", function()
		local world, Subject, primary = record_in("firefox", { ok = true, uri_list = "file:///tmp/a\n" }, "nautilus")
		Subject.copy_selected_path(primary)
		Subject._set_deps_for_test(nil)
		helpers.assert_eq(world.frame_queries, 0)
		helpers.assert_eq(world.copies, 0)
	end)

	helpers.it("(linux-copy-path-file-manager) opens the primary selection when no file is selected", function()
		local world, Subject, primary = record_in("nautilus", { ok = false, reason = "no_file_selection" })
		Subject.copy_selected_path(primary)
		Subject._set_deps_for_test(nil)
		helpers.assert_eq(world.written, {})
		helpers.assert_eq(world.opened, { "https://example.com" })
	end)

	helpers.it("(linux-copy-path-file-manager) refuses an unreadable or remote selection without opening anything", function()
		for _, read in ipairs({
			{ ok = false, reason = "xsel cannot read a text/uri-list" },
			{ ok = true, uri_list = "file:///tmp/a\nsftp://host/b\n" },
		}) do
			local world, Subject, primary = record_in("dolphin", read)
			local done = Subject.copy_selected_path(primary)
			Subject._set_deps_for_test(nil)
			helpers.assert_eq(done, false)
			helpers.assert_eq(world.written, {}, "no partial list reaches the clipboard")
			helpers.assert_eq(world.opened, {})
			helpers.assert_eq(world.primary_reads, 0)
		end
	end)

	helpers.it("(linux-copy-path-file-manager) the gesture dispatcher runs the file-manager branch", function()
		local G = helpers.load_module("modules.gestures.manager")
		G.init({ enabled = false })
		local world, Subject = record_in("nautilus", { ok = true, uri_list = "file:///home/ada/notes.txt\n" })
		with_selection("ignored", function() G.execute_action("copy_selected_path", "tap_3") end)
		Subject._set_deps_for_test(nil)
		helpers.assert_eq(world.written, { "/home/ada/notes.txt" })
		helpers.assert_eq(world.opened, {})
	end)
end)

helpers.describe('open selected paths ending in punctuation', function()
  for _, item in ipairs({
    { '/tmp/report.', '/tmp/report.' },
    { '"/tmp/report."', '/tmp/report.' },
    { 'file:///tmp/report.', '/tmp/report.' },
    { '$HOME/report.', '/home/ada/report.' },
  }) do
    helpers.it('prefers the exact existing selection '..item[1], function()
      local original = item[2]
      local cleaned = original:sub(1, -2)
      local world, subject = record({ [original]=true, [cleaned]=true })
      local ok, err = pcall(function()
        helpers.assert_true(subject.open(item[1]))
        helpers.assert_eq(world.opened, { original })
      end)
      subject._set_deps_for_test(nil)
      if not ok then error(err, 0) end
    end)
  end
  helpers.it('still strips prose punctuation when only the cleaned path exists', function()
    local world, subject = record({ ['/tmp/report']=true })
    local ok, err = pcall(function()
      helpers.assert_true(subject.open('/tmp/report.'))
      helpers.assert_eq(world.opened, { '/tmp/report' })
    end)
    subject._set_deps_for_test(nil)
    if not ok then error(err, 0) end
  end)
end)

helpers.describe('exact path metadata refusal', function()
  for _, failure in ipairs({'error', 'raise'}) do
    helpers.it('does not open the cleaned path on metadata '..failure, function()
      local subject = require('modules.shortcuts.open_selection')
      local opened, notices = {}, {}
      subject._set_deps_for_test({
        exists = function() return true end,
        path_status = function() if failure == 'raise' then error('native refusal') end; return 'error' end,
        open = function(path) opened[#opened + 1] = path; return {} end,
        message = function() return 'Cannot open %s' end,
        notify = function(text) notices[#notices + 1] = text; return true end,
      })
      local ok, err = pcall(function()
        helpers.assert_eq(subject.open('/tmp/report.'), false)
        helpers.assert_eq(opened, {})
        helpers.assert_eq(notices, { 'Cannot open …' })
      end)
      subject._set_deps_for_test(nil)
      if not ok then error(err, 0) end
    end)
  end
end)
