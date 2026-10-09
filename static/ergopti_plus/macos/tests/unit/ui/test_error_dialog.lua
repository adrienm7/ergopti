--- tests/unit/ui/test_error_dialog.lua

--- ==============================================================================
--- MODULE: Error Window (macOS)
--- DESCRIPTION:
--- Drives the real error window through the logger's error handler and its
--- usercontent message handler, the way init.lua and the shared page do:
--- 1. a logged ERROR opens nothing synchronously: it arms one timer, and the
---    window opens when that timer fires;
--- 2. the shared policy holds: the same signature never opens twice, an error
---    logged while the window is pending or open is folded into it, nothing
---    opens while the Debug menu setting is unticked;
--- 3. the window is presented once through the shared focus helper;
--- 4. "ready" answers with the error and its report, redacted;
--- 5. copy, report and open go through the diagnostics actions with the
---    report the page showed; an unknown action is refused;
--- 6. closing frees the policy, so the next new error opens a window again;
--- 7. the setting persists through Storage and defaults to the manifest.
--- ==============================================================================

local helpers = require("tests.helpers")

local HOME = "/Users/jdoe"
local ERRORS_FILE = HOME .. "/Library/Logs/ergopti_plus/ErgoptiPlus_errors_2026-09-24.log"

--- Loads the real window over controlled natives and collaborators.
--- @param controls table|nil { stored = boolean|nil }
--- @return table dialog, table context
local function load_dialog(controls)
	controls = controls or {}
	local Json = require("json")
	local function document(name)
		local file = assert(io.open(helpers.driver_root() .. "/../_shared/modules/diagnostics/" .. name .. ".json", "rb"))
		local value = Json.decode(file:read("*a")); assert(file:close()); return value
	end
	local sharing_schema = document("schema")
	for _, name in ipairs({
		"ui.error_dialog", "ui.healthcheck.core", "ui.healthcheck.report", "infra.logger", "infra.i18n",
		"infra.locale", "ui.ui_builder", "adapters.timer_scheduler", "adapters.storage", "infra.manifest_reader",
	}) do package.loaded[name] = nil end
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local context = {
		timers = {}, scripts = {}, deleted = 0, released = 0, focused = 0, performed = {}, stored = {},
		errors = {}, warnings = {},
	}
	local logger = helpers.make_logger_stub()
	logger.error = function(_, message, ...) context.errors[#context.errors + 1] = string.format(message, ...) end
	logger.warn = function(_, message, ...) context.warnings[#context.warnings + 1] = string.format(message, ...) end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.i18n"] = { get = function(key) return key end, get_locale = function() return "en" end }
	package.loaded["infra.locale"] = { all = function() return { ["common.error_title"] = "Error" } end }
	package.loaded["adapters.timer_scheduler"] = {
		after = function(delay, fn)
			context.timers[#context.timers + 1] = { delay = delay, fn = fn }
			return { timer = {} }, true
		end,
		now_ns = function() return (context.now or 0) * 1e9 end,
		cancel = function() return true end,
	}
	package.loaded["adapters.storage"] = {
		get = function(key, default)
			if controls.stored ~= nil and key == "script.show_error_dialog" then return controls.stored end
			return default
		end,
		set = function(key, value) context.stored[key] = value; return true end,
	}
	package.loaded["infra.manifest_reader"] = {
		default_for = function(path) return path == "script.show_error_dialog" and true or nil end,
	}
	package.loaded["ui.ui_builder"] = {
		build_injected_html = function() return "<html></html>" end,
		window_chrome_steps = function() return {} end,
		window_title = function(title) return "ErgoptiPlus — " .. tostring(title) end,
		get_app_geometry = function(id) return id == "error_dialog" and { width = 560, height = 460 } or nil end,
		force_focus = function() context.focused = context.focused + 1; return true end,
	}
	package.loaded["ui.healthcheck.core"] = {
		DRIVER = "macos",
		config = function()
			return {
				redaction = { home_placeholder = "~", account_placeholder = "<user>", secret_placeholder = "<secret>",
					min_account_name_length = 3, token_prefixes = {}, bearer_min_length = 8, secret_keys = {},
					secret_value_min_length = 6 },
				templates = document("issue_templates"), repository = document("../updater/defaults").github, schema = sharing_schema,
			}
		end,
		run = function()
			return {
				driver = "macos",
				generated_at = "2026-09-24T08:15:02Z",
				probes = { appleevent_transport = { state = "error", native_status = -1744, ms = 12, cleanup = "settled" } },
				sections = {
					versions = { ergopti_version = context.version or "2.1.0", commit = "abc1234 (build)" },
					system = { os = "macOS 15.1" },
					issues = { warn_count = 1, err_count = 2, recent = { "2026-09-24 10:15:02:117 [ERROR] [keylogger] x" } },
					paths = { errors_today = ERRORS_FILE, diagnostics_dir = HOME .. "/Library/Logs/ergopti_plus/diagnostics" },
				},
			}
		end,
	}
	package.loaded["ui.healthcheck.report"] = {
		redaction_context = function() return { home = HOME, user = "jdoe", case_insensitive = true } end,
		perform = function(action, paths)
			context.performed[#context.performed + 1] = { action = action, paths = paths }
			return { ok = true }
		end,
	}


	if controls.real_report then
		package.loaded["ui.healthcheck.report"] = nil
		local actual = require("ui.healthcheck.report")
		package.loaded["ui.healthcheck.report"] = {
			redaction_context = function() return actual.redaction_context({ identity = function() return { home = HOME, user = "synthetic" } end }) end,
			perform = function(action, paths, documents, context_value, _, snapshot)
				return actual.perform(action, paths, documents, context_value, {
					copy = function(text)
						context.copied = text
						return controls.copy ~= false
					end,
					open_url = function(url) context.opened = url; return true end,
				}, snapshot)
			end,
		}
	end

	local webview = {}
	for _, method in ipairs({
		"windowStyle", "windowTitle", "allowTextEntry", "allowNewWindows", "allowGestures", "level", "html",
		"show", "shadow",
	}) do webview[method] = function(self) return self end end
	webview.windowTitle = function(self, title) context.title = title; return self end
	webview.windowCallback = function(self, callback) context.window_callback = callback; return self end
	webview.navigationCallback = function(self, callback) context.navigation_callback = callback; return self end
	webview.evaluateJavaScript = function(self, script)
		context.scripts[#context.scripts + 1] = script
		return self
	end
	webview.delete = function() context.deleted = context.deleted + 1 end
	hs_stub.webview.new = function() context.windows = (context.windows or 0) + 1; return webview end
	hs_stub.webview.usercontent.new = function(name)
		context.handler_name = name
		return {
			setCallback = function(self, callback)
				if callback == nil then context.released = context.released + 1 end
				context.page = callback
				return self
			end,
		}
	end
	hs_stub.webview.windowMasks = { titled = 1, closable = 2, miniaturizable = 4, resizable = 8 }

	local dialog = require("ui.error_dialog")
	return dialog, context
end

--- Fires every armed timer once, in order.
--- @param context table
local function fire_timers(context)
	local timers = context.timers
	context.timers = {}
	for _, timer in ipairs(timers) do timer.fn() end
end

--- The messages the host evaluated in the page, decoded.
--- @param context table
--- @return table
local function page_messages(context)
	local messages = {}
	for _, script in ipairs(context.scripts) do
		local json = script:match("window%.receiveErrorDialog%((.*)%)$")
		if json then messages[#messages + 1] = hs.json.decode(json) end
	end
	return messages
end

helpers.describe("error window (macOS): policy and deferral (error-dialog-macos)", function()
	for _, failure in ipairs({ "frame", "chrome" }) do
		helpers.it("presentation failure releases resources and admits the next error: " .. failure .. " (error-dialog-exception)", function()
			local dialog, context = load_dialog()
			local builder = package.loaded["ui.ui_builder"]
			local saved_screen, saved_chrome = hs.screen.mainScreen, builder.window_chrome_steps
			if failure == "frame" then
				hs.screen.mainScreen = function() return { frame = function() error("frame refused") end } end
			else
				builder.window_chrome_steps = function() error("chrome refused") end
			end
			helpers.assert_true(dialog.init())
			dialog.on_error("old", "Old failure", "Old failure")
			local ok, err = pcall(fire_timers, context)
			hs.screen.mainScreen, builder.window_chrome_steps = saved_screen, saved_chrome
			helpers.assert_true(ok, "presentation exceptions must be contained: " .. tostring(err))
			helpers.assert_true(#context.errors > 0, "the presentation failure must be reported")
			if failure == "chrome" then
				helpers.assert_eq(context.deleted, 1, "the partially created window must be released")
				helpers.assert_eq(context.released, 1, "the partial message handler must be released")
			end
			dialog.on_error("new", "New failure", "New failure")
			helpers.assert_eq(#context.timers, 1, "a failed presentation must release the pending slot")
			fire_timers(context)
			context.page({ body = "ready" })
			helpers.assert_eq(page_messages(context)[1].module, "new")
		end)
	end

	helpers.it("disabling invalidates queued windows across reactivation (error-dialog-cancel)", function()
		local dialog, context = load_dialog()
		helpers.assert_true(dialog.init())
		dialog.on_error("old", "Old failure", "Old failure")
		local stale = context.timers[1].fn
		context.timers = {}
		helpers.assert_true(dialog.set_enabled(false))
		stale()
		helpers.assert_eq(context.windows, nil, "disabled windows must not open")
		helpers.assert_true(dialog.set_enabled(true))
		dialog.on_error("new", "New failure", "New failure")
		helpers.assert_eq(#context.timers, 1, "cancellation must release the pending slot")
		stale()
		helpers.assert_eq(context.windows, nil, "reactivation must not revive an old callback")
		fire_timers(context)
		helpers.assert_eq(context.windows, 1)
		context.page({ body = "ready" })
		helpers.assert_eq(page_messages(context)[1].module, "new")
	end)

	helpers.it("a logged ERROR arms one timer and opens nothing synchronously (error-dialog-macos)", function()
		local dialog, context = load_dialog()
		helpers.assert_true(dialog.init(), "the shipped policy must load")
		dialog.on_error("keylogger", "Flush failed: %s", "Flush failed: disk full")
		helpers.assert_eq(#context.timers, 1, "one timer must be armed")
		helpers.assert_eq(context.windows, nil, "no window may open inside the logging call")
		helpers.assert_true(context.timers[1].delay > 0, "the window must open later, on the timer")
		fire_timers(context)
		helpers.assert_eq(context.windows, 1, "the timer must open the window")
		helpers.assert_eq(context.handler_name, "error_dialog", "the page posts to the error_dialog handler")
		helpers.assert_eq(context.focused, 1,
			"the error window is raised and focused once through the shared helper (ui-focus-not-topmost)")
		helpers.assert_eq(context.title, "ErgoptiPlus — common.error_title", "the window is titled Error")
	end)

	helpers.it("the same signature opens once; errors while pending or open are folded (error-dialog-macos)", function()
		local dialog, context = load_dialog()
		dialog.init()
		dialog.on_error("keylogger", "Flush failed: %s", "Flush failed: disk full")
		dialog.on_error("keylogger", "Other failure", "Other failure")
		helpers.assert_eq(#context.timers, 1, "an error logged while a window is pending must not arm another")
		fire_timers(context)
		context.page({ body = "ready" })
		local init = page_messages(context)[1]
		helpers.assert_eq(init.more, 1, "the folded error must be counted in the window")
		dialog.on_error("gestures", "Third", "Third")
		local more = page_messages(context)[2]
		helpers.assert_eq(more and more.type, "more", "a fold while open must update the window")
		helpers.assert_eq(more and more.count, 2)
		context.page({ body = { action = "close" } })
		helpers.assert_eq(context.deleted, 1, "close must delete the window")
		dialog.on_error("keylogger", "Flush failed: %s", "Flush failed: again")
		helpers.assert_eq(#context.timers, 0, "a signature already shown this session must not open again")
		dialog.on_error("menu", "New failure", "New failure")
		helpers.assert_eq(#context.timers, 1, "after close, a new error opens a window again")
	end)

	helpers.it("nothing opens while the setting is unticked (error-dialog-macos)", function()
		local dialog, context = load_dialog({ stored = false })
		dialog.init()
		helpers.assert_eq(dialog.is_enabled(), false)
		dialog.on_error("keylogger", "Flush failed: %s", "Flush failed: disk full")
		helpers.assert_eq(#context.timers, 0, "an unticked setting must keep every error quiet")
		helpers.assert_true(dialog.set_enabled(true))
		helpers.assert_eq(context.stored["script.show_error_dialog"], true, "the setting must persist")
		dialog.on_error("keylogger", "Flush failed: %s", "Flush failed: disk full")
		helpers.assert_eq(#context.timers, 1, "ticked again, the error opens a window")
	end)

	helpers.it("a second init is refused (error-dialog-macos)", function()
		local dialog, context = load_dialog()
		helpers.assert_true(dialog.init())
		helpers.assert_eq(dialog.init(), false, "a duplicate initialisation must be refused")
		helpers.assert_true(#context.errors == 1, "the refusal must be logged")
	end)
end)

helpers.describe("error window (macOS): page and actions (error-dialog-macos)", function()
	helpers.it("ready sends the error and its report, redacted (error-dialog-macos)", function()
		local dialog, context = load_dialog()
		dialog.init()
		dialog.on_error("keylogger", "Flush failed: %s", "Flush failed: " .. HOME .. "/notes.txt")
		fire_timers(context)
		context.page({ body = "ready" })
		local init = page_messages(context)[1]
		helpers.assert_eq(init.type, "init")
		helpers.assert_eq(init.kind, "error")
		helpers.assert_eq(init.module, "keylogger")
		helpers.assert_eq(init.message, "Flush failed: ~/notes.txt", "the message must be redacted")
		helpers.assert_eq(init.log_path, "~/Library/Logs/ergopti_plus/ErgoptiPlus_errors_2026-09-24.log")
		helpers.assert_true(init.text:find("# ErgoptiPlus diagnostics", 1, true) ~= nil, "the report must be sent")
		helpers.assert_true(init.text:find(HOME, 1, true) == nil, "the report must be redacted")
		helpers.assert_true(init.text:find("keylogger", 1, true) ~= nil, "the report must name the module")
	end)

	helpers.it("copy, report and open act on the report the page showed (error-dialog-macos)", function()
		local dialog, context = load_dialog()
		dialog.init()
		dialog.on_error("keylogger", "Flush failed: %s", "Flush failed: disk full")
		fire_timers(context)
		local focused_at_open = context.focused
		context.page({ body = "ready" })
		context.page({ body = { action = "copy" } })
		context.page({ body = { action = "report" } })
		context.page({ body = { action = "open_log" } })
		helpers.assert_eq(#context.performed, 3, "three actions must reach the diagnostics actions")
		local copy, report, open = context.performed[1].action, context.performed[2].action, context.performed[3].action
		helpers.assert_eq(copy.action, "copy")
		helpers.assert_true(copy.text:find("Flush failed: disk full", 1, true) == nil, "shared copy excludes free error text")
		helpers.assert_eq(report.action, "report")
		helpers.assert_eq(report.text, copy.text, "report sends the same report")
		helpers.assert_eq(report.fields.title, nil, "a shared title never contains free error text")
		-- The host prefills the report itself and saves no file (report-focus)
		helpers.assert_eq(report.name, nil, "a report names no file to save")
		helpers.assert_eq(report.fields.diagnostics, nil, "the report field is filled from the text, not a summary")
		helpers.assert_eq(report.fields.driver, "macos")
		helpers.assert_eq(context.focused, focused_at_open, "reporting never brings the error window back to the front")
		helpers.assert_eq(open.action, "open_path")
		helpers.assert_eq(open.id, "errors_today", "open_log opens today's errors file, by id")
		helpers.assert_eq(context.performed[3].paths.errors_today, ERRORS_FILE)
		local results = page_messages(context)
		helpers.assert_eq(results[#results].type, "action")
		helpers.assert_eq(results[#results].ok, true)
	end)

	helpers.it("an unknown action is refused and changes nothing (error-dialog-macos)", function()
		local dialog, context = load_dialog()
		dialog.init()
		dialog.on_error("keylogger", "Flush failed: %s", "Flush failed: disk full")
		fire_timers(context)
		context.page({ body = { action = "open_path", id = "config_dir" } })
		context.page({ body = { action = "copy", text = "forged" } })
		helpers.assert_eq(#context.performed, 1, "only the named copy runs, and never the forged text")
		helpers.assert_true(context.performed[1].action.text ~= "forged", "the page cannot choose what is copied")
		helpers.assert_eq(#context.warnings, 1, "the refusal must be logged")
	end)

	helpers.it("the close box frees the policy too (error-dialog-macos)", function()
		local dialog, context = load_dialog()
		dialog.init()
		dialog.on_error("a", "one", "one")
		fire_timers(context)
		local page = context.page
		context.window_callback("closing")
		helpers.assert_eq(context.released, 1, "the message handler must be released")
		dialog.on_error("a", "two", "two")
		helpers.assert_eq(#context.timers, 1, "after the close box, a new error opens a window again")
		page({ body = { action = "copy" } })
		helpers.assert_eq(#context.performed, 0, "a message of the closed window is inert")
	end)
end)


helpers.describe("error window sharing uses the real report sink", function()
	helpers.it("retains the host snapshot and excludes the local error from the issue (error-sharing-owner)", function()
		local dialog, context = load_dialog({ real_report = true })
		helpers.assert_true(dialog.report({ kind = "error", module = "synthetic", message = "CANARY-private.invalid/notes", time = "local" }))
		helpers.assert_type(context.copied, "string")
		helpers.assert_type(context.opened, "string")
		helpers.assert_true(context.copied:find("CANARY", 1, true) == nil)
		helpers.assert_true(context.opened:find("CANARY", 1, true) == nil)
		local refusing, refusal = load_dialog({ real_report = true, copy = false })
		helpers.assert_eq(refusing.report({ kind = "error", module = "synthetic", message = "CANARY", time = "local" }), false)
		helpers.assert_nil(refusal.opened, "clipboard refusal must prevent the browser")
	end)
end)


helpers.describe("error window retains its captured sharing identity", function()
	helpers.it("keeps local details and shares its own snapshot after another collection (error-sharing-owner)", function()
		local dialog, context = load_dialog({ real_report = true })
		dialog.init()
		dialog.on_error("synthetic", "Private sentinel", "CANARY-private.invalid/notes")
		fire_timers(context)
		context.page({ body = "ready" })
		helpers.assert_true(page_messages(context)[1].text:find("CANARY", 1, true) ~= nil, "local detail remains visible")
		context.version = "9.9.9"
		context.page({ body = { action = "copy", text = "forged" } })
		helpers.assert_type(context.copied, "string")
		helpers.assert_true(context.copied:find("CANARY", 1, true) == nil)
		helpers.assert_true(context.copied:find("2.1.0", 1, true) ~= nil)
		helpers.assert_true(context.copied:find("9.9.9", 1, true) == nil)
		helpers.assert_true(context.copied:find("-1744", 1, true) ~= nil, "admitted technical status remains useful")
	end)
end)
