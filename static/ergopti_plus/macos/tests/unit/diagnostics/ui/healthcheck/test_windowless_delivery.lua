--- tests/unit/diagnostics/ui/healthcheck/test_windowless_delivery.lua

--- ==============================================================================
--- MODULE: Diagnostics Without Their Window (macOS)
--- DESCRIPTION:
--- When hs.webview refuses the diagnostics window, the click must still be
--- answered (diagnostics-without-window, maintainer 2026-11-25): the approved
--- report is written as a self-contained HTML file in the logs' diagnostics
--- folder and opened in the browser, as on Linux; when even that fails, a
--- native alert names the log and offers « Report a bug ».
---
--- ROOT CAUSE ENCODED: show_window returned false with one log line and the
--- Debug menu ignored it, so the click did nothing visible, on the very path a
--- user takes when something is broken.
--- ==============================================================================

local helpers = require("tests.helpers")
local AppDirs = require("core.fs.engine.app_dirs")
local Json = require("core.text.engine.json")
local Share = require("diagnostics.engine.healthcheck.share")

local HOME = "/Users/jdoe"
local LOGS = HOME .. "/" .. AppDirs.macos.relative
local LOG_TODAY = LOGS .. "/ErgoptiPlus_2026-11-25.log"





-- ===============================
-- ===============================
-- ======= 1/ Fixtures ===========
-- ===============================
-- ===============================

--- Reads a shared JSON document.
--- @param rel string Path under _shared/.
--- @return table
local function shared_json(rel)
	local fh = assert(io.open(helpers.shared(rel), "rb"))
	local data = Json.decode(fh:read("*a"))
	fh:close()
	return data
end

--- The documents a host works from, read from their single sources.
--- @return table
local function documents()
	local schema = shared_json("diagnostics/data/schema.json")
	schema.export_strings = shared_json("core/i18n/data/locales/en.json")
	return {
		schema     = schema,
		templates  = shared_json("diagnostics/data/issue_templates.json"),
		redaction  = shared_json("diagnostics/data/redaction.json"),
		repository = shared_json("updater/data/defaults.json").github,
	}
end

--- A host snapshot with the folders the report is written under.
--- @return table
local function host_snapshot()
	return { schema_version = 2, driver = "macos", generated_at = "2026-11-25T10:00:00Z",
		sections = { versions = { ergopti_version = "2.4.0" }, system = { os = "macOS 15.1" },
			hardware = { arch = "arm64" }, issues = { recent = {} },
			paths = { logs_dir = LOGS, diagnostics_dir = LOGS .. "/diagnostics" } } }
end

--- Loads the real report module over a stubbed core and recorded effects.
--- @return table Report, table calls, table overrides
local function load_report()
	package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
	package.loaded["diagnostics.ui.healthcheck.report"] = nil
	local Report = require("diagnostics.ui.healthcheck.report")
	local calls = { save = {}, open = {}, notify = {}, alert = {}, run = {} }
	package.loaded["diagnostics.ui.healthcheck.core"] = {
		DRIVER = "macos",
		config = documents,
		run = function(opts) calls.run[#calls.run + 1] = opts; return host_snapshot() end,
	}
	local overrides = {
		identity = function() return { home = HOME, user = "jdoe" } end,
		save = function(dir, name, text)
			calls.save[#calls.save + 1] = { dir = dir, name = name, text = text }
			return dir .. "/" .. name
		end,
		open = function(target, done)
			calls.open[#calls.open + 1] = target
			done({ ok = true, code = 0 })
			return { cancel = function() end }
		end,
		notify = function(title, body, kind)
			calls.notify[#calls.notify + 1] = { title = title, body = body, kind = kind }
			return true
		end,
	}
	return Report, calls, overrides
end

--- Runs a case with the report module's collaborators restored afterwards.
--- @param body function
local function with_report(body)
	helpers.with_stub_scope({ "diagnostics.ui.healthcheck.report", "diagnostics.ui.healthcheck.core",
		"core.logger.engine.logger" }, body)
end

--- Loads the real diagnostics window over a refusing hs.webview.new and a
--- recording report module.
--- @param controls table { delivered = boolean }
--- @param body function body(core, calls)
local function with_refused_window(controls, body)
	helpers.with_stub_scope({
		"diagnostics.ui.healthcheck.core", "diagnostics.ui.healthcheck.helpers", "diagnostics.engine.healthcheck.snapshot",
		"diagnostics.ui.healthcheck.report", "core.logger.engine.logger", "core.fs.engine.paths", "core.i18n.engine.i18n",
		"core.ui.ui.builder", "core.ui.ui.webview_close_owner", "core.timing.engine.deferred_work",
		"core.ui.engine.dialog_util", "core.events.timer_scheduler", "hs", "tests.stubs.hs",
	}, function()
		package.loaded["tests.stubs.hs"] = nil
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		_G.hs = hs_stub
		package.loaded.hs = hs_stub
		local calls = { delivered = {}, alerts = {} }
		package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
		package.loaded["diagnostics.ui.healthcheck.helpers"] = {}
		package.loaded["diagnostics.engine.healthcheck.snapshot"] = {}
		package.loaded["core.fs.engine.paths"] = { shared = function() return "/shared" end }
		package.loaded["core.i18n.engine.i18n"] = {
			get = function(key) return key end,
			format = function(key, ...) return table.concat({ key, ... }, "|") end,
		}
		package.loaded["core.ui.engine.dialog_util"] = { block_alert = function() error("the report module owns the alert") end }
		package.loaded["core.events.timer_scheduler"] = {
			every = function() error("the diagnostics window polls nothing") end,
			cancel = function() return true end,
			after = function() return true end,
		}
		package.loaded["core.ui.ui.builder"] = {
			build_injected_html = function() return "<html></html>" end,
			window_chrome_steps = function() return {} end,
			get_app_geometry = function() return { width = 860, height = 720 } end,
			window_title = function(title) return "ErgoptiPlus — " .. tostring(title) end,
			force_focus = function() return true end,
		}
		package.loaded["diagnostics.ui.healthcheck.report"] = {
			deliver_without_window = function(opts)
				calls.delivered[#calls.delivered + 1] = opts
				return controls.delivered
			end,
			alert_window_unavailable = function(window_id, body_text, opts)
				calls.alerts[#calls.alerts + 1] = { id = window_id, body = body_text, opts = opts }
				return false
			end,
			log_path_for_alert = function() return LOG_TODAY end,
		}
		hs_stub.webview.usercontent.new = function() return { setCallback = function(self) return self end } end
		-- hs.webview.new answers nil when WebKit refuses the window
		hs_stub.webview.new = function() return nil end
		hs_stub.screen.mainScreen = function()
			return { frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
		end
		local core = require("diagnostics.ui.healthcheck.core")
		core.run = function() return {} end
		body(core, calls)
	end)
end





-- ====================================
-- ====================================
-- ======= 2/ The Click Answers =======
-- ====================================
-- ====================================

helpers.describe("diagnostics without their window (diagnostics-without-window)", function()

	helpers.it("(diagnostics-without-window) a refused web view delivers the report without it", function()
		with_refused_window({ delivered = true }, function(core, calls)
			local state = {}
			helpers.assert_eq(core.show_window({ state = state }), false, "no window opened")
			helpers.assert_eq(#calls.delivered, 1, "the click is answered with the report file")
			helpers.assert_true(calls.delivered[1].state == state, "the menu state reaches the report")
			helpers.assert_eq(#calls.alerts, 0, "a delivered report needs no alert")
		end)
	end)

	helpers.it("(diagnostics-without-window) a report that cannot be written either names the log in an alert", function()
		with_refused_window({ delivered = false }, function(core, calls)
			helpers.assert_eq(core.show_window(), false)
			helpers.assert_eq(#calls.alerts, 1, "the user is told, not left with a dead click")
			helpers.assert_eq(calls.alerts[1].id, "healthcheck")
			helpers.assert_true(calls.alerts[1].body:find(LOG_TODAY, 1, true) ~= nil, "the alert names the log file")
			helpers.assert_true(calls.alerts[1].body:find("dialog.window_unavailable.body", 1, true) == 1,
				"through the translated explanation")
		end)
	end)

	helpers.it("(diagnostics-without-window) the report is a self-contained HTML file opened in the browser", function()
		with_report(function()
			local Report, calls, overrides = load_report()
			local state = {}
			helpers.assert_true(Report.deliver_without_window({ state = state }, overrides))
			helpers.assert_eq(calls.run[1].complete_local, true, "a complete local snapshot, as Report a bug takes")
			helpers.assert_true(calls.run[1].state == state)
			local saved = calls.save[1]
			helpers.assert_eq(saved.dir, LOGS .. "/diagnostics", "written in the logs' diagnostics folder")
			helpers.assert_true(saved.name:match("%.html$") ~= nil, "as an HTML file: " .. saved.name)
			helpers.assert_true(saved.text:sub(1, 15) == "<!doctype html>", "a whole page")
			helpers.assert_true(saved.text:find("<script", 1, true) == nil, "with no script")
			local config = documents()
			local approved = Share.document(host_snapshot(), config.schema,
				require("core.i18n.engine.i18n").get(config.schema.share_policy.notice_key)).text
			local first_line = approved:match("^[^\n]+")
			helpers.assert_true(saved.text:find((first_line:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")), 1, true) ~= nil,
				"the approved report, escaped")
			helpers.assert_true(saved.text:find("jdoe", 1, true) == nil, "no account name leaves in the page")
			helpers.assert_eq(calls.open[1], saved.dir .. "/" .. saved.name, "the browser opens the file")
			helpers.assert_eq(#calls.notify, 1, "a notice names the file")
			helpers.assert_true(calls.notify[1].body:find(calls.open[1], 1, true) ~= nil, "with its path")
		end)
	end)

	helpers.it("(diagnostics-without-window) a refused save delivers nothing and says so", function()
		with_report(function()
			local Report, calls, overrides = load_report()
			overrides.save = function() return nil, "disk full" end
			helpers.assert_eq(Report.deliver_without_window(nil, overrides), false)
			helpers.assert_eq(#calls.open, 0, "nothing to open")
			helpers.assert_eq(#calls.notify, 0, "no notice claims a file")
		end)
	end)

	helpers.it("(diagnostics-without-window) the alert offers Report a bug, which runs without a window", function()
		with_report(function()
			local Report, _, overrides = load_report()
			local i18n = require("core.i18n.engine.i18n")
			local reported = {}
			Report.report_bug = function(opts) reported[#reported + 1] = opts end
			local asked = {}
			overrides.alert = function(title, body, default_button, other_button)
				asked[#asked + 1] = { title = title, body = body, default_button = default_button, other_button = other_button }
				return other_button
			end
			local opts = { state = {} }
			helpers.assert_true(Report.alert_window_unavailable("healthcheck", "body text", opts, overrides))
			helpers.assert_eq(asked[1].title, i18n.get("dialog.window_unavailable.title"))
			helpers.assert_eq(asked[1].body, "body text")
			helpers.assert_eq(asked[1].default_button, i18n.get("common.close"), "closing is the default")
			helpers.assert_eq(asked[1].other_button, i18n.get("menu.debug.report_bug"))
			helpers.assert_true(reported[1] == opts, "Report a bug runs with the menu state")

			overrides.alert = function(_, _, default_button) return default_button end
			helpers.assert_eq(Report.alert_window_unavailable("healthcheck", "body text", opts, overrides), false)
			helpers.assert_eq(#reported, 1, "Close reports nothing")
		end)
	end)

end)
