--- tests/unit/ui/test_healthcheck_bridge_actions.lua

--- ==============================================================================
--- MODULE: Diagnostics Window Bridge (macOS)
--- DESCRIPTION:
--- Drives the real diagnostics window through its usercontent message handler,
--- the way the shared page posts to it:
--- 1. "ready" answers with the page's configuration and the first snapshot,
---    and keeps subprocess probes opt-in;
--- 2. an action the allowlist refuses changes nothing and is logged;
--- 3. copy writes the redacted report, and a refused clipboard keeps the
---    window open and says so to the page;
--- 4. a message of a closed window is inert, and closing releases the handler
---    and cancels the probes;
--- 5. no timer polls the page: the old copy button was a 200 ms poll of a JS
---    flag, which leaked a timer per reopen more than once.
--- ==============================================================================

local helpers = require("tests.helpers")

local HOME = "/Users/jdoe"

--- Loads the real window over controlled natives and collaborators.
--- @param controls table|nil { clipboard = boolean }
--- @return table core, table context
local function load_window(controls)
	controls = controls or {}
	for _, name in ipairs({
		"ui.healthcheck.core", "ui.healthcheck.helpers", "ui.healthcheck.probes", "ui.healthcheck.report",
		"infra.logger", "infra.i18n", "infra.locale", "ui.ui_builder", "adapters.timer_scheduler",
		"adapters.clipboard", "adapters.webview_result",
	}) do package.loaded[name] = nil end
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local context = {
		scripts = {}, deleted = 0, released = 0, every = 0, cancelled_probes = 0, started_probes = 0,
		copied = {}, warnings = {}, errors = {}, opened_urls = {}, spawned = {}, focused = 0, effects = {},
	}
	local logger = helpers.make_logger_stub()
	logger.warn = function(_, message, ...) context.warnings[#context.warnings + 1] = string.format(message, ...) end
	logger.error = function(_, message, ...) context.errors[#context.errors + 1] = string.format(message, ...) end
	logger.ring_buffer_snapshot = function() return {} end
	logger.session_issues = function() return { warn_count = 0, err_count = 0 } end
	logger.ERRORS_LOG_FILE = HOME .. "/Library/Logs/ergopti_plus/ErgoptiPlus_errors_2026-09-24.log"
	logger.UNIFIED_LOG_FILE = HOME .. "/Library/Logs/ergopti_plus/ErgoptiPlus_2026-09-24.log"
	package.loaded["infra.logger"] = logger
	package.loaded["infra.i18n"] = { get = function(key) return key end, get_locale = function() return "en" end }
	package.loaded["infra.locale"] = { all = function() return { ["menu.debug.healthcheck"] = "Diagnostics" } end }
	package.loaded["adapters.timer_scheduler"] = {
		every = function() context.every = context.every + 1; return { timer = {} }, true end,
		after = function() return { timer = {} }, true end,
		cancel = function() return true end,
	}
	package.loaded["adapters.clipboard"] = {
		write = function(text)
			context.copied[#context.copied + 1] = text
			context.effects[#context.effects + 1] = "copy"
			return controls.clipboard ~= false
		end,
	}
	package.loaded["ui.healthcheck.probes"] = {
		start = function(_, snapshot, on_result)
			context.probe_result = on_result
			context.started_probes = context.started_probes + 1
			context.probe_snapshot = snapshot
			return { cancel = function() context.cancelled_probes = context.cancelled_probes + 1 end }
		end,
	}
	package.loaded["ui.ui_builder"] = {
		build_injected_html = function() return "<html></html>" end,
		window_chrome_steps = function() return {} end,
		window_title = function(title) return "ErgoptiPlus — " .. tostring(title) end,
		get_app_geometry = function() return { width = 860, height = 720 } end,
		force_focus = function()
			context.focused = context.focused + 1
			context.effects[#context.effects + 1] = "focus"
			return true
		end,
		open_http_url = function(url)
			context.opened_urls[#context.opened_urls + 1] = url
			context.effects[#context.effects + 1] = "open_url"
			return true
		end,
	}

	local webview = {}
	for _, method in ipairs({
		"windowStyle", "windowTitle", "allowTextEntry", "allowNewWindows", "allowGestures", "level", "html",
		"show", "shadow",
	}) do webview[method] = function(self) return self end end
	webview.windowCallback = function(self, callback) context.window_callback = callback; return self end
	webview.navigationCallback = function(self, callback) context.navigation_callback = callback; return self end
	webview.evaluateJavaScript = function(self, script, callback)
		context.scripts[#context.scripts + 1] = script
		if callback then callback(nil, nil) end
		return self
	end
	webview.delete = function() context.deleted = context.deleted + 1 end
	hs_stub.webview.new = function(_, _, controller)
		context.new_controller = controller
		return webview
	end
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
	package.loaded["ui.healthcheck.report"] = nil

	local core = require("ui.healthcheck.core")
	core.run = function(opts)
		return {
			schema_version = 2, driver = "macos", generated_at = "2026-09-24T10:00:00Z",
			detailed = type(opts) == "table" and opts.detailed == true or false,
			extensive = type(opts) == "table" and opts.extensive == true or false,
			sections = { paths = { diagnostics_dir = HOME .. "/Library/Logs/ergopti_plus/diagnostics" } },
			probes = { github_api = { state = "pending" } },
		}
	end
	return core, context
end

--- The messages the host evaluated in the page, decoded.
--- @param context table
--- @return table
local function page_messages(context)
	local messages = {}
	for _, script in ipairs(context.scripts) do
		local json = script:match("window%.receiveDiagnostics%((.*)%)$")
		if json then messages[#messages + 1] = hs.json.decode(json) end
	end
	return messages
end

--- Runs a body with HOME and USER set to the fixture's account.
--- @param body function
local function as_jdoe(body)
	local getenv = os.getenv
	os.getenv = function(name)
		if name == "HOME" then return HOME end
		if name == "USER" then return "jdoe" end
		return getenv(name)
	end
	local ok, err = xpcall(body, debug.traceback)
	os.getenv = getenv
	if not ok then error(err, 0) end
end

helpers.describe("diagnostics window: the page's bridge (macOS)", function()
	helpers.it("registers the handler host_bridge.js posts to, and polls nothing", function()
		local core, context = load_window()
		helpers.assert_true(core.show_window())
		helpers.assert_eq(context.handler_name, "healthcheck")
		helpers.assert_true(context.new_controller ~= nil, "the webview must be created with its controller")
		helpers.assert_type(context.page, "function")
		helpers.assert_eq(context.every, 0, "no recurring timer may poll the page")
	end)

	helpers.it("answers ready with a quick snapshot and starts probes only after explicit opt-in", function()
		as_jdoe(function()
			local core, context = load_window()
			core.show_window({ mode = "report" })
			context.page({ body = "ready" })
			local messages = page_messages(context)
			helpers.assert_eq(#messages, 1)
			helpers.assert_eq(messages[1].type, "init")
			helpers.assert_eq(messages[1].config.mode, "report")
			helpers.assert_eq(messages[1].config.schema.schema_version, 2)
			helpers.assert_eq(messages[1].config.context.home, HOME)
			helpers.assert_eq(messages[1].config.context.case_insensitive, true)
			helpers.assert_eq(messages[1].snapshot.driver, "macos")
			helpers.assert_eq(context.started_probes, 0, "opening the window must not start subprocess probes")
			helpers.assert_eq(messages[1].snapshot.extensive, false)
			context.page({ body = { action = "refresh", extensive = true } })
			helpers.assert_eq(context.started_probes, 1)
			-- The probes complete the snapshot the page shows: its paths, its
			-- peripherals and whether details are included (bluetooth-peripherals)
			helpers.assert_true(type(context.probe_snapshot) == "table"
				and type(context.probe_snapshot.sections) == "table"
				and context.probe_snapshot.sections.paths ~= nil,
				"the probes must receive the window's snapshot")
		end)
	end)

	helpers.it("refuses and logs an action outside the allowlist, doing nothing", function()
		local core, context = load_window()
		core.show_window()
		context.page({ body = { action = "open_path", id = "/etc/passwd" } })
		context.page({ body = { action = "run", command = "rm -rf ~" } })
		helpers.assert_eq(#page_messages(context), 0, "a refused action must not reach the page")
		helpers.assert_eq(context.deleted, 0)
		helpers.assert_eq(#context.warnings, 2)
		helpers.assert_contains(context.warnings[1], "unknown_path")
		helpers.assert_contains(context.warnings[2], "unknown_action")
	end)

	helpers.it("copies the redacted report and tells the page", function()
		as_jdoe(function()
			local core, context = load_window()
			core.show_window()
			context.page({ body = { action = "copy", text = "log at /Users/jdoe/Library/Logs by jdoe" } })
			helpers.assert_eq(context.copied, { "log at ~/Library/Logs by <user>" })
			local messages = page_messages(context)
			helpers.assert_eq(messages[#messages].type, "action")
			helpers.assert_eq(messages[#messages].action, "copy")
			helpers.assert_eq(messages[#messages].ok, true)
		end)
	end)

	-- The report was also saved and revealed in Finder, which finished after
	-- the browser opened and took the focus from the form (report-focus)
	helpers.it("report copies, then opens the prefilled form last, with no Finder (report-focus)", function()
		as_jdoe(function()
			local core, context = load_window()
			core.show_window()
			local focused_at_open = context.focused
			context.effects = {}
			-- /usr/bin/open: what revealing a file in Finder would run
			package.loaded["adapters.shell_runner"] = {
				spawn = function(bin, args)
					context.spawned[#context.spawned + 1] = { bin = bin, args = args }
					context.effects[#context.effects + 1] = "spawn"
					return { start = function() return true end }
				end,
			}
			local ok, err = pcall(context.page, { body = { action = "report",
				text = "log at /Users/jdoe/Library/Logs by jdoe",
				fields = { version = "2.4.0", os = "macOS 15.1", driver = "macos" } } })
			package.loaded["adapters.shell_runner"] = nil
			helpers.assert_true(ok, tostring(err))
			helpers.assert_eq(context.copied, { "log at ~/Library/Logs by <user>" })
			helpers.assert_eq(#context.opened_urls, 1, "the bug form opens once")
			local encoded = context.opened_urls[1]:match("[?&]diagnostics=([^&]*)")
			local diagnostics = encoded and encoded:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
			helpers.assert_eq(diagnostics, context.copied[1], "the form holds the report the clipboard holds")
			helpers.assert_eq(context.spawned, {}, "nothing is revealed in Finder")
			helpers.assert_eq(context.focused, focused_at_open, "the window is not brought back to the front")
			helpers.assert_eq(context.effects, { "copy", "open_url" }, "the browser opens last")
			local messages = page_messages(context)
			helpers.assert_eq(messages[#messages].action, "report")
			helpers.assert_eq(messages[#messages].ok, true)
		end)
	end)

	helpers.it("keeps the window open when the clipboard refuses, and says so (healthcheck-copy-receipt)", function()
		as_jdoe(function()
			local core, context = load_window({ clipboard = false })
			core.show_window()
			context.page({ body = { action = "copy", text = "report" } })
			helpers.assert_eq(context.deleted, 0, "a refused copy must not close the only copy source")
			local messages = page_messages(context)
			helpers.assert_eq(messages[#messages].ok, false)
			helpers.assert_true(#context.errors > 0, "the refusal must reach the log")
		end)
	end)

	helpers.it("ignores a message of a closed window and releases its handler", function()
		local core, context = load_window()
		core.show_window()
		local stale = context.page
		context.window_callback("closing")
		helpers.assert_eq(context.released, 1, "closing must release the message handler")
		stale({ body = "ready" })
		helpers.assert_eq(#page_messages(context), 0, "a closed window's page must reach nothing")
	end)

	helpers.it("closes on the page's close button, cancelling its probes", function()
		as_jdoe(function()
			local core, context = load_window()
			core.show_window()
			context.page({ body = "ready" })
			context.page({ body = { action = "refresh", extensive = true } })
			context.page({ body = { action = "close" } })
			helpers.assert_eq(context.deleted, 1)
			helpers.assert_eq(context.cancelled_probes, 1)
			helpers.assert_eq(context.released, 1)
		end)
	end)

	helpers.it("reopening releases the previous window's handler before the new one exists", function()
		local core, context = load_window()
		core.show_window()
		local first = context.page
		core.show_window()
		helpers.assert_eq(context.deleted, 1)
		helpers.assert_eq(context.released, 1)
		first({ body = "ready" })
		helpers.assert_eq(#page_messages(context), 0, "the first window's page must be inert")
	end)

	helpers.it("refresh collects again with details and restarts the probes", function()
		as_jdoe(function()
			local core, context = load_window()
			core.show_window()
			context.page({ body = "ready" })
			context.page({ body = { action = "refresh", extensive = true } })
			context.page({ body = { action = "refresh", detailed = true, extensive = true } })
			local messages = page_messages(context)
			helpers.assert_eq(messages[#messages].type, "snapshot")
			helpers.assert_eq(messages[#messages].snapshot.detailed, true)
			helpers.assert_eq(context.started_probes, 2)
			helpers.assert_eq(context.cancelled_probes, 1)
		end)
	end)
end)


helpers.describe("diagnostics user presentation admission", function()
	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("diagnostics foreground refuses focus " .. mode, function()
			as_jdoe(function()
			local core, context = load_window()
			package.loaded["ui.ui_builder"].force_focus = function()
				if mode == "throw" then error("owned presentation failure") end
				return false
			end
			helpers.assert_eq(core.show_window(), false)
			helpers.assert_eq(context.deleted, 0, "Presentation refusal must preserve the shown report")
			helpers.assert_eq(context.released, 0, "The current page handler remains owned")
			context.page({ body = "ready" })
			local messages = page_messages(context)
			helpers.assert_eq(messages[#messages].type, "init", "The retained report remains usable")
			helpers.assert_true(#context.errors > 0)
			end)
		end)
	end

	helpers.it("diagnostics background probe completion never steals window focus", function()
		as_jdoe(function()
			local core, context = load_window()
			helpers.assert_true(core.show_window())
			context.page({ body = "ready" })
			context.page({ body = { action = "refresh", extensive = true } })
			helpers.assert_eq(context.started_probes, 1)
			helpers.assert_type(context.probe_result, "function")
			context.probe_result("github_api", { state = "ok", ms = 1 }, {})
			helpers.assert_eq(context.focused, 1, "Only the user's original open may request focus")
			context.page({ body = { action = "close" } })
			context.probe_result("github_api", { state = "ok", ms = 2 }, {})
			helpers.assert_eq(context.focused, 1, "Late retired completion must stay inert")
		end)
	end)
end)
