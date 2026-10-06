--- tests/unit/ui/test_error_dialog_bridge.lua

--- ==============================================================================
--- MODULE: Error Window Bridge (Linux)
--- DESCRIPTION:
--- Drives the real error window bridge the way the shared logger core, the
--- webview manager and the shared page call it:
--- 1. a logged ERROR opens nothing synchronously: the window opens from a
---    callback deferred on the daemon's loop;
--- 2. the shared policy holds: the same signature never opens twice, an error
---    logged while the window is pending or open is folded into it, nothing
---    opens while the Debug menu setting is unticked;
--- 3. "ready" answers with the error and its report, redacted;
--- 4. copy, report and open go through the diagnostics actions with the
---    report the page showed; an unknown action is refused;
--- 5. closing, by the page or by the close box, frees the policy;
--- 6. the newest crash dump is announced once, as a crash notice.
--- ==============================================================================

local helpers = require("tests.helpers")

local HOME = "/home/jdoe"
local ERRORS_FILE = HOME .. "/.local/state/ergopti_plus/logs/ErgoptiPlus_errors_2026-09-24.log"

--- Loads the real bridge with controlled collaborators.
--- @param controls table|nil { stored = boolean|nil, show = boolean|nil, newest = string|nil }
--- @return table bridge, table context
local function load_bridge(controls)
	controls = controls or {}
	local context = {
		deferred = {}, shown = 0, hidden = 0, pushed = {}, performed = {}, stored = {}, warnings = {},
		notified = {}, epoch = nil, now = 0,
	}
	for _, name in ipairs({ "ui.error_dialog.bridge", "ui.healthcheck.bridge", "ui.healthcheck.report" }) do
		package.loaded[name] = nil
	end
	local stubs = {
		["ui.webview_manager"] = {
			current_epoch = function() return context.epoch end,
			show = function(app)
				context.shown = context.shown + 1
				context.shown_app = app
				if controls.show == false then return false end
				context.epoch = (context.epoch or 0) + 1
				return true
			end,
			hide = function() context.hidden = context.hidden + 1; context.epoch = nil; return true end,
			eval_js = function(_, js) context.pushed[#context.pushed + 1] = js; return true end,
			get_daemon_state = function() return {} end,
		},
		["ui.healthcheck.bridge"] = {
			DRIVER = "linux",
			config = function()
				return { redaction = context.redaction, templates = {}, repository = {} }
			end,
			build_snapshot = function()
				return {
					generated_at = "2026-09-24T08:15:02Z",
					sections = {
						versions = { ergopti_version = "2.1.0", commit = "abc1234 (git)" },
						system = { os = "Fedora Linux 41" },
						issues = { warn_count = 0, err_count = 1, recent = {} },
						paths = { errors_today = ERRORS_FILE, diagnostics_dir = HOME .. "/diagnostics" },
					},
				}
			end,
		},
		["ui.healthcheck.report"] = {
			redaction_context = function() return { home = HOME, user = "jdoe", case_insensitive = false } end,
			perform = function(action, paths)
				context.performed[#context.performed + 1] = { action = action, paths = paths }
				return { ok = true }
			end,
		},
		["adapters.storage"] = {
			get = function(key, default)
				if controls.stored ~= nil and key == "script.show_error_dialog" then return controls.stored end
				return default
			end,
			set = function(key, value) context.stored[key] = value; return true end,
		},
		["infra.manifest_reader"] = {
			default_for = function(path) return path == "script.show_error_dialog" and true or nil end,
		},
		["infra.i18n"] = { get = function(key) return key end, get_locale = function() return "en" end },
		["adapters.application_notifier"] = {
			send = function(message, opts) context.notified[#context.notified + 1] = { message = message, opts = opts } end,
		},
	}
	local saved = {}
	for name, stub in pairs(stubs) do
		saved[name] = package.loaded[name]
		package.loaded[name] = stub
	end
	local fh = io.open(helpers.driver_root() .. "/../_shared/modules/diagnostics/redaction.json", "rb")
	context.redaction = require("json").decode(fh:read("*a"))
	fh:close()

	local bridge = helpers.load_module("ui.error_dialog.bridge")
	bridge.defer = function(fn, delay_ms)
		context.deferred[#context.deferred + 1] = { fn = fn, delay = delay_ms }
		return true
	end
	bridge.clock = function() return context.now end
	local logger = require("logger.shim")
	local warn = logger.warn
	logger.warn = function(_, message, ...) context.warnings[#context.warnings + 1] = string.format(message, ...) end
	context.restore = function()
		logger.warn = warn
		for name in pairs(stubs) do package.loaded[name] = saved[name] end
		package.loaded["ui.error_dialog.bridge"] = nil
	end
	return bridge, context
end

--- Runs a body over a fresh bridge, restoring the collaborators afterwards.
--- @param controls table|nil
--- @param body function(bridge, context)
local function with_bridge(controls, body)
	local bridge, context = load_bridge(controls)
	local ok, err = xpcall(function() body(bridge, context) end, debug.traceback)
	context.restore()
	if not ok then error(err, 0) end
end

--- Runs every deferred callback once, in order.
--- @param context table
local function run_deferred(context)
	local queued = context.deferred
	context.deferred = {}
	for _, item in ipairs(queued) do item.fn() end
end

--- The page context the webview manager hands every message.
--- @param context table
--- @return table
local function page(context)
	return { app_name = "error_dialog", epoch = context.epoch, close_owned_window = function()
		context.closed = (context.closed or 0) + 1
		return true
	end }
end

helpers.describe("error window bridge (linux): policy and deferral (error-dialog-linux)", function()
	helpers.it("disabling invalidates queued windows across reactivation (error-dialog-cancel)", function()
		with_bridge(nil, function(bridge, context)
			helpers.assert_true(bridge.init())
			bridge.on_error("old", "Old failure", "Old failure")
			local stale = context.deferred[1].fn
			context.deferred = {}
			helpers.assert_true(bridge.set_enabled(false))
			stale()
			helpers.assert_eq(context.shown, 0, "disabled windows must not open")
			helpers.assert_true(bridge.set_enabled(true))
			bridge.on_error("new", "New failure", "New failure")
			helpers.assert_eq(#context.deferred, 1, "cancellation must release the pending slot")
			stale()
			helpers.assert_eq(context.shown, 0, "reactivation must not revive an old callback")
			run_deferred(context)
			helpers.assert_eq(context.shown, 1)
			helpers.assert_eq(bridge.on_message("ready", {}, page(context)).module, "new")
		end)
	end)

	helpers.it("a logged ERROR defers the window; nothing opens inside the logging call (error-dialog-linux)", function()
		with_bridge(nil, function(bridge, context)
			helpers.assert_true(bridge.init(), "the shipped policy must load")
			bridge.on_error("keylogger", "Flush failed: %s", "Flush failed: disk full")
			helpers.assert_eq(context.shown, 0, "no window may open inside the logging call")
			helpers.assert_eq(#context.deferred, 1, "one callback must be deferred")
			helpers.assert_true(context.deferred[1].delay > 0, "the window opens after the policy's delay")
			run_deferred(context)
			helpers.assert_eq(context.shown, 1, "the deferred callback opens the window")
			helpers.assert_eq(context.shown_app, "error_dialog")
		end)
	end)

	helpers.it("the same signature opens once; errors while pending or open are folded (error-dialog-linux)", function()
		with_bridge(nil, function(bridge, context)
			bridge.init()
			bridge.on_error("keylogger", "Flush failed: %s", "Flush failed: disk full")
			bridge.on_error("menu", "Other: %s", "Other: x")
			helpers.assert_eq(#context.deferred, 1, "an error logged while a window is pending must not queue another")
			run_deferred(context)
			local init = bridge.on_message("ready", {}, page(context))
			helpers.assert_eq(init.more, 1, "the folded error is counted in the window")
			bridge.on_error("gestures", "Third", "Third")
			run_deferred(context)
			helpers.assert_true(#context.pushed == 1 and context.pushed[1]:find('"count":2', 1, true) ~= nil,
				"a fold while open updates the window")
			bridge.on_message({ action = "close" }, {}, page(context))
			helpers.assert_eq(context.closed, 1, "close closes the page it came from")
			bridge.on_error("keylogger", "Flush failed: %s", "Flush failed: again")
			helpers.assert_eq(#context.deferred, 0, "a signature already shown this session never opens again")
			bridge.on_error("updater", "New failure", "New failure")
			helpers.assert_eq(#context.deferred, 1, "after close, a new error opens a window again")
		end)
	end)

	helpers.it("nothing opens while the setting is unticked (error-dialog-linux)", function()
		with_bridge({ stored = false }, function(bridge, context)
			bridge.init()
			bridge.on_error("keylogger", "Flush failed: %s", "Flush failed: disk full")
			helpers.assert_eq(#context.deferred, 0, "an unticked setting keeps every error quiet")
			helpers.assert_true(bridge.set_enabled(true))
			helpers.assert_eq(context.stored["script.show_error_dialog"], true, "the setting must persist")
			bridge.on_error("keylogger", "Flush failed: %s", "Flush failed: disk full")
			helpers.assert_eq(#context.deferred, 1)
		end)
	end)

	helpers.it("a window that cannot open is announced and frees the policy (error-dialog-linux)", function()
		with_bridge({ show = false }, function(bridge, context)
			bridge.init()
			bridge.on_error("keylogger", "Flush failed: %s", "Flush failed: disk full")
			run_deferred(context)
			helpers.assert_eq(#context.notified, 1, "without a window the error is announced")
			bridge.on_error("menu", "Other", "Other")
			helpers.assert_eq(#context.deferred, 1, "the policy is free for the next error")
		end)
	end)
end)

helpers.describe("error window bridge (linux): page and actions (error-dialog-linux)", function()
	helpers.it("ready answers with the error and its report, redacted (error-dialog-linux)", function()
		with_bridge(nil, function(bridge, context)
			bridge.init()
			bridge.on_error("keylogger", "Flush failed: %s", "Flush failed: " .. HOME .. "/notes.txt")
			run_deferred(context)
			local init = bridge.on_message("ready", {}, page(context))
			helpers.assert_eq(init.type, "init")
			helpers.assert_eq(init.kind, "error")
			helpers.assert_eq(init.message, "Flush failed: ~/notes.txt", "the message is redacted")
			helpers.assert_eq(init.log_path, "~/.local/state/ergopti_plus/logs/ErgoptiPlus_errors_2026-09-24.log")
			helpers.assert_true(init.text:find("# ErgoptiPlus diagnostics", 1, true) ~= nil, "the report is sent")
			helpers.assert_true(init.text:find(HOME, 1, true) == nil, "the report is redacted")
		end)
	end)

	helpers.it("copy, report and open act on the report the page showed (error-dialog-linux)", function()
		with_bridge(nil, function(bridge, context)
			bridge.init()
			bridge.on_error("keylogger", "Flush failed: %s", "Flush failed: disk full")
			run_deferred(context)
			bridge.on_message("ready", {}, page(context))
			local copied = bridge.on_message({ action = "copy" }, {}, page(context))
			bridge.on_message({ action = "report" }, {}, page(context))
			bridge.on_message({ action = "open_log" }, {}, page(context))
			helpers.assert_eq(copied.type, "action")
			helpers.assert_eq(copied.ok, true)
			helpers.assert_eq(#context.performed, 3)
			local copy, report, open = context.performed[1].action, context.performed[2].action, context.performed[3].action
			helpers.assert_eq(copy.action, "copy")
			helpers.assert_eq(report.action, "report")
			helpers.assert_eq(report.text, copy.text, "report sends the report copy sends")
			helpers.assert_eq(report.fields.title, "keylogger: Flush failed: disk full")
			-- The host prefills the report itself and saves no file (report-focus)
			helpers.assert_eq(report.name, nil, "a report names no file to save")
			helpers.assert_eq(report.fields.diagnostics, nil, "the report field is filled from the text, not a summary")
			helpers.assert_eq(open.action, "open_path")
			helpers.assert_eq(open.id, "errors_today")
			helpers.assert_eq(context.performed[3].paths.errors_today, ERRORS_FILE)
		end)
	end)

	helpers.it("an unknown action is refused; the page cannot choose the text (error-dialog-linux)", function()
		with_bridge(nil, function(bridge, context)
			bridge.init()
			bridge.on_error("keylogger", "Flush failed: %s", "Flush failed: disk full")
			run_deferred(context)
			bridge.on_message("ready", {}, page(context))
			helpers.assert_eq(bridge.on_message({ action = "open_path", id = "config_dir" }, {}, page(context)), nil)
			bridge.on_message({ action = "copy", text = "forged" }, {}, page(context))
			helpers.assert_eq(#context.performed, 1)
			helpers.assert_true(context.performed[1].action.text ~= "forged")
			helpers.assert_eq(#context.warnings, 1, "the refusal is logged")
		end)
	end)

	helpers.it("the close box frees the policy (error-dialog-linux)", function()
		with_bridge(nil, function(bridge, context)
			bridge.init()
			bridge.on_error("a", "one", "one")
			run_deferred(context)
			bridge.on_message("ready", {}, page(context))
			bridge.on_window_closed(context.epoch)
			helpers.assert_eq(bridge.on_message({ action = "copy" }, {}, page(context)), nil,
				"a message of a closed window is inert")
			bridge.on_error("a", "two", "two")
			helpers.assert_eq(#context.deferred, 1, "after the close box a new error opens a window again")
		end)
	end)
end)

helpers.describe("error window bridge (linux): crash notice (error-dialog-linux)", function()
	helpers.it("parses a crash dump's module, error and stack (error-dialog-linux)", function()
		with_bridge(nil, function(bridge)
			local module_name, message = bridge.parse_crash_dump(table.concat({
				"=== Ergopti Linux Crash Dump ===", "Timestamp: Wed Sep 23 21:04:11 2026", "Module:    ergopti_hotstrings",
				"Error:     boom", "Version:   2.1.0 (build)", "Stack:", "boom", "stack traceback:", "\tmain.lua:3", "",
			}, "\n"))
			helpers.assert_eq(module_name, "ergopti_hotstrings")
			helpers.assert_eq(message, "boom\nboom\nstack traceback:\n\tmain.lua:3")
		end)
	end)

	helpers.it("announces the newest crash dump once (error-dialog-linux)", function()
		with_bridge(nil, function(bridge, context)
			local dir = os.tmpname()
			os.remove(dir)
			os.execute("mkdir -p '" .. dir .. "'")
			local dump = "crash_2026-09-23T21-04-11_ergopti_hotstrings.txt"
			local fh = io.open(dir .. "/" .. dump, "wb")
			fh:write("=== Ergopti Linux Crash Dump ===\nModule:    ergopti_hotstrings\nError:     boom\n")
			fh:close()
			local Shell = require("adapters.shell_runner")
			local exec_line = Shell.exec_line
			Shell.exec_line = function() return dump end
			local ok, err = pcall(function()
				bridge.init()
				helpers.assert_true(bridge.notify_last_crash(dir), "an unannounced dump is announced")
				helpers.assert_eq(#context.deferred, 1)
				run_deferred(context)
				local init = bridge.on_message("ready", {}, page(context))
				helpers.assert_eq(init.kind, "crash")
				helpers.assert_eq(init.module, "ergopti_hotstrings")
				helpers.assert_eq(init.message, "boom")
				bridge.on_message({ action = "open_log" }, {}, page(context))
				helpers.assert_eq(context.performed[1].action.id, "crash_report")
				helpers.assert_eq(context.performed[1].paths.crash_report, dir .. "/" .. dump)
				bridge.on_message({ action = "close" }, {}, page(context))
				helpers.assert_eq(bridge.notify_last_crash(dir), false, "a dump already announced is not announced again")
			end)
			Shell.exec_line = exec_line
			os.remove(dir .. "/" .. dump)
			os.remove(dir .. "/.last_crash_notice")
			os.remove(dir)
			if not ok then error(err, 0) end
		end)
	end)
end)
