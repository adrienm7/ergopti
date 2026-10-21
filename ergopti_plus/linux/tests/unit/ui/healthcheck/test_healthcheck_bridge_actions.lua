--- tests/unit/ui/healthcheck/test_healthcheck_bridge_actions.lua

--- ==============================================================================
--- MODULE: Diagnostics Window Bridge (Linux)
--- DESCRIPTION:
--- Drives the real diagnostics bridge the way the shared page and the webview
--- manager call it:
--- 1. "ready" answers with the page's configuration and the first version 2
---    snapshot, and starts that page's local probes only (the configuration)
---    until the extensive checks are chosen;
--- 2. an action the allowlist refuses changes nothing and is logged;
--- 3. copy writes the redacted report through the clipboard adapter, and a
---    refused clipboard is answered as a failure;
--- 4. refresh collects again (with details when asked) and restarts the
---    probes; close closes the page it came from;
--- 5. a message from a page that is gone is inert, and a probe answer is
---    pushed only into the page it was started for;
--- 6. opening replaces an open window, so its mode and snapshot are fresh.
--- ==============================================================================

local helpers = require("tests.helpers")

local HOME = "/home/jdoe"

--- Loads the real bridge with controlled collaborators.
--- @param controls table|nil { clipboard = boolean }
--- @return table bridge, table context
local function load_bridge(controls)
	controls = controls or {}
	local replaced = { "ui.healthcheck.bridge", "ui.healthcheck.report", "ui.healthcheck.probes",
		"ui.webview_manager", "adapters.clipboard", "infra.config_paths" }
	local loaded = {}
	for _, name in ipairs(replaced) do loaded[name] = package.loaded[name] end
	local context = { pushed = {}, copied = {}, warnings = {}, starts = 0, cancels = 0, closed = 0, epoch = 7 }
	for _, name in ipairs({ "ui.healthcheck.bridge", "ui.healthcheck.report", "ui.healthcheck.probes" }) do
		package.loaded[name] = nil
	end
	package.loaded["ui.healthcheck.probes"] = {
		start = function(_, _, _, publish, options)
			context.starts = context.starts + 1
			context.publish = publish
			context.local_only = options and options.local_only
			return { cancel = function() context.cancels = context.cancels + 1 end }
		end,
	}
	package.loaded["ui.webview_manager"] = {
		current_epoch = function() return context.epoch end,
		eval_js = function(_, js)
			context.pushed[#context.pushed + 1] = js
			return true
		end,
		get_daemon_state = function() return {} end,
	}
	package.loaded["adapters.clipboard"] = {
		write = function(text)
			context.copied[#context.copied + 1] = text
			return controls.clipboard ~= false
		end,
	}
	package.loaded["infra.config_paths"] = setmetatable({ home = function() return HOME end },
		{ __index = require("infra.config_paths") })
	local sink = require("infra.logger_sink")
	local previous_log_dir = sink.log_dir
	if controls.logs_dir ~= nil then
		assert(type(controls.logs_dir) == "string" and controls.logs_dir:sub(1, #HOME) == HOME)
		sink.log_dir = function() return controls.logs_dir end
	end
	local bridge = helpers.load_module("ui.healthcheck.bridge")
	local logger = require("logger.shim")
	local warn = logger.warn
	context.restore = function()
		sink.log_dir = previous_log_dir
		logger.warn = warn
		for _, name in ipairs(replaced) do package.loaded[name] = loaded[name] end
	end
	logger.warn = function(_, message, ...) context.warnings[#context.warnings + 1] = string.format(message, ...) end
	return bridge, context
end

--- Runs a body over a fresh bridge, restoring the collaborators afterwards.
--- @param controls table|nil
--- @param body function(bridge, context)
local function with_bridge(controls, body)
	local bridge, context = load_bridge(controls)
	local getenv = os.getenv
	os.getenv = function(name) if name == "USER" then return "jdoe" end return getenv(name) end
	local ok, err = xpcall(function() body(bridge, context) end, debug.traceback)
	os.getenv = getenv
	local restored, restore_error = pcall(context.restore)
	if not ok then error(err, 0) end
	if not restored then error(restore_error, 0) end
end

--- The page context the webview manager hands every message.
--- @param context table
--- @return table
local function page(context)
	return { app_name = "healthcheck", epoch = context.epoch, close_owned_window = function()
		context.closed = context.closed + 1
		return true
	end }
end

helpers.describe("diagnostics bridge (linux): the page's messages", function()
	helpers.it("answers ready with a quick version 2 snapshot starting only the local probes", function()
		with_bridge(nil, function(bridge, context)
			local answer = bridge.on_message("ready", {}, page(context))
			helpers.assert_eq(answer.type, "init")
			helpers.assert_eq(answer.config.schema.schema_version, 2)
			helpers.assert_eq(answer.config.context.home, HOME)
			helpers.assert_eq(answer.config.context.case_insensitive, false)
			helpers.assert_eq(answer.snapshot.driver, "linux")
			helpers.assert_eq(answer.snapshot.schema_version, 2)
			helpers.assert_eq(context.starts, 1)
			helpers.assert_eq(context.local_only, true, "only the configuration probe runs without the opt-in")
			helpers.assert_eq(answer.snapshot.probes.configuration.state, "pending")
			helpers.assert_eq(answer.snapshot.extensive, false)
		end)
	end)

	helpers.it("refuses and logs an action outside the allowlist", function()
		with_bridge(nil, function(bridge, context)
			bridge.on_message("ready", {}, page(context))
			context.warnings = {}
			helpers.assert_nil(bridge.on_message({ action = "open_path", id = "/etc/shadow" }, {}, page(context)))
			helpers.assert_nil(bridge.on_message({ action = "open_settings", id = "accessibility" }, {}, page(context)))
			helpers.assert_eq(#context.warnings, 2)
			helpers.assert_contains(context.warnings[1], "unknown_path")
			helpers.assert_contains(context.warnings[2], "unknown_settings")
		end)
	end)

	helpers.it("copies the redacted report", function()
		with_bridge(nil, function(bridge, context)
			local ready = bridge.on_message("ready", {}, page(context))
			local redacted = require("diagnostics.redact").apply("at /home/jdoe/x by jdoe",
				ready.config.redaction, ready.config.context)
			helpers.assert_eq({ redacted }, { "at ~/x by <user>" })
			local exported = bridge.on_message({ action = "export_snapshot", export_sequence = 1 }, {}, page(context))
			helpers.assert_true(rawequal(exported.snapshot, ready.snapshot), "The preview belongs to the retained snapshot")
			local answer = bridge.on_message({ action = "copy", text = exported.share_text }, {}, page(context))
			helpers.assert_eq(context.copied, { exported.share_text })
			helpers.assert_eq(answer.type, "action")
			helpers.assert_eq(answer.ok, true)
		end)
	end)

	helpers.it("answers a refused clipboard as a failure", function()
		with_bridge({ clipboard = false }, function(bridge, context)
			local ready = bridge.on_message("ready", {}, page(context))
			local exported = bridge.on_message({ action = "export_snapshot", export_sequence = 2 }, {}, page(context))
			helpers.assert_true(rawequal(exported.snapshot, ready.snapshot))
			local answer = bridge.on_message({ action = "copy", text = exported.share_text }, {}, page(context))
			helpers.assert_eq(context.copied, { exported.share_text }, "Clipboard refusal follows the actual adapter call")
			helpers.assert_eq(answer.ok, false)
			helpers.assert_eq(context.closed, 0)
		end)
	end)

	helpers.it("refreshes with details and restarts the probes", function()
		with_bridge(nil, function(bridge, context)
			bridge.on_message("ready", {}, page(context))
			local answer = bridge.on_message({ action = "refresh", detailed = true, extensive = true }, {}, page(context))
			helpers.assert_eq(answer.type, "snapshot")
			helpers.assert_eq(answer.snapshot.detailed, true)
			helpers.assert_eq(context.starts, 2)
			helpers.assert_eq(context.local_only, false)
			helpers.assert_eq(context.cancels, 1, "the local run of the quick page is replaced")
		end)
	end)

	helpers.it("closes the page it came from and cancels its probes", function()
		with_bridge(nil, function(bridge, context)
			bridge.on_message("ready", {}, page(context))
			bridge.on_message({ action = "refresh", extensive = true }, {}, page(context))
			helpers.assert_nil(bridge.on_message({ action = "close" }, {}, page(context)))
			helpers.assert_eq(context.closed, 1)
			helpers.assert_eq(context.cancels, 2)
		end)
	end)

	helpers.it("ignores a message from a page that is gone", function()
		with_bridge(nil, function(bridge, context)
			bridge.on_message("ready", {}, page(context))
			local stale = page(context)
			stale.epoch = context.epoch - 1
			helpers.assert_nil(bridge.on_message({ action = "copy", text = "x" }, {}, stale))
			helpers.assert_eq(#context.copied, 0)
		end)
	end)

	helpers.it("reports the pause the daemon hands over", function()
		with_bridge(nil, function(bridge, context)
			local answer = bridge.on_message("ready", { is_paused = function() return true end }, page(context))
			helpers.assert_eq(answer.snapshot.sections.input.paused, true)
		end)
	end)

	helpers.it("replaces an open window", function()
		with_bridge(nil, function(bridge, context)
			local manager = package.loaded["ui.webview_manager"]
			local hidden, shown = {}, {}
			manager.hide = function(app, epoch) hidden[#hidden + 1] = app .. "#" .. tostring(epoch); return true end
			manager.show = function(app) shown[#shown + 1] = app; return true end
			helpers.assert_eq(bridge.open(), true)
			helpers.assert_eq(hidden, { "healthcheck#7" }, "the open page must be closed, not brought forward")
			helpers.assert_eq(shown, { "healthcheck" })
			helpers.assert_eq(bridge.on_message("ready", {}, page(context)).config.mode, nil, "the page has no report mode")
		end)
	end)

	helpers.it("pushes a probe answer into its page only", function()
		with_bridge(nil, function(bridge, context)
			bridge.on_message("ready", {}, page(context))
			bridge.on_message({ action = "refresh", extensive = true }, {}, page(context))
			context.publish("github_api", { state = "ok", ms = 12 }, { network = { github_api = "HTTP 200" } })
			helpers.assert_eq(#context.pushed, 1)
			helpers.assert_contains(context.pushed[1], "window.receiveDiagnostics(")
			helpers.assert_contains(context.pushed[1], '"github_api"')
			context.epoch = context.epoch + 1
			context.publish("ai_health", { state = "disabled", ms = 0 })
			helpers.assert_eq(#context.pushed, 1, "a probe of a closed page must not reach its successor")
		end)
	end)
end)

helpers.describe("diagnostics bridge (linux): extensive admission", function()
	helpers.it("privacy-only refresh remains quick and starts only the local probes", function()
		with_bridge(nil, function(bridge, context)
			bridge.on_message("ready", {}, page(context))
			local answer = bridge.on_message({ action = "refresh", detailed = true }, {}, page(context))
			helpers.assert_eq(answer.snapshot.detailed, true)
			helpers.assert_eq(answer.snapshot.extensive, false)
			helpers.assert_eq(context.starts, 2)
			helpers.assert_eq(context.local_only, true)
			helpers.assert_eq(answer.snapshot.probes.github_api.state, "not_run")
		end)
	end)
	helpers.it("cancel retains partial results and does not invent a cleanup acknowledgement", function()
		with_bridge(nil, function(bridge, context)
			bridge.on_message("ready", {}, page(context))
			bridge.on_message({ action = "refresh", extensive = true }, {}, page(context))
			context.publish("github_api", { state = "ok", ms = 12 })
			local answer = bridge.on_message({ action = "cancel" }, {}, page(context))
			helpers.assert_eq(context.starts, 2)
			helpers.assert_eq(context.cancels, 2)
			helpers.assert_eq(answer.snapshot.probes.github_api.state, "ok")
			helpers.assert_eq(answer.snapshot.probes.github_api.ms, 12)
			helpers.assert_eq(answer.snapshot.probes.ai_health.state, "cancelled")
			helpers.assert_eq(answer.snapshot.probes.ai_health.cleanup, "pending")
		end)
	end)
	helpers.it("export observation returns the exact owned snapshot without any export side effect", function()
		with_bridge(nil, function(bridge, context)
			local ready = bridge.on_message("ready", {}, page(context))
			local starts = context.starts
			local answer = bridge.on_message({ action = "export_snapshot", export_sequence = 12 }, {}, page(context))
			helpers.assert_true(answer.snapshot == ready.snapshot)
			helpers.assert_eq(answer.export_sequence, 12)
			helpers.assert_eq(answer.action, "export_snapshot")
			helpers.assert_eq(context.starts, starts)
			helpers.assert_eq(#context.copied, 0)
		end)
	end)
end)

helpers.describe("diagnostics bridge (linux): cleanup history", function()
	helpers.it("cancel then refresh then export retains unconfirmed cleanup metadata", function()
		with_bridge(nil, function(bridge, context)
			bridge.on_message("ready", {}, page(context))
			bridge.on_message({ action = "refresh", extensive = true }, {}, page(context))
			context.publish("github_api", { state = "timeout", cleanup = "unknown", ms = 23 })
			bridge.on_message({ action = "cancel" }, {}, page(context))
			local refreshed = bridge.on_message({ action = "refresh" }, {}, page(context))
			helpers.assert_eq(type(refreshed.snapshot.retired_probes), "table", "refresh must retain prior cleanup metadata")
			helpers.assert_eq(#refreshed.snapshot.retired_probes, 1)
			bridge.on_message({ action = "refresh" }, {}, page(context))
			local exported = bridge.on_message({ action = "export_snapshot", export_sequence = 3 }, {}, page(context))
			helpers.assert_eq(#exported.snapshot.retired_probes, 1, "idle refresh must not duplicate a cohort")
			local rows = exported.snapshot.retired_probes[1].probes
			helpers.assert_eq(rows.github_api.state, "timeout")
			helpers.assert_eq(rows.github_api.cleanup, "unknown")
			helpers.assert_eq(rows.github_api.ms, 23)
			helpers.assert_eq(rows.ai_health.state, "cancelled")
			helpers.assert_eq(rows.ai_health.cleanup, "pending")
			helpers.assert_nil(rows.configuration, "a local probe owns nothing to clean up")
			helpers.assert_eq(context.starts, 4)
			helpers.assert_eq(context.cancels, 3)
			helpers.assert_eq(#context.copied, 0)
		end)
	end)
end)

helpers.describe("diagnostics bridge (linux): sharing preview admission", function()
	helpers.it("refuses free text before calling the clipboard adapter", function()
		with_bridge(nil, function(bridge, context)
			bridge.on_message("ready", {}, page(context))
			local answer = bridge.on_message({ action = "copy", text = "at /home/jdoe/x by jdoe" }, {}, page(context))
			helpers.assert_eq(answer.ok, false)
			helpers.assert_eq(#context.copied, 0)
		end)
	end)

	helpers.it("refuses a stale preview and accepts only the current retained snapshot's text", function()
		with_bridge(nil, function(bridge, context)
			bridge.on_message("ready", {}, page(context))
			local exported = bridge.on_message({ action = "export_snapshot", export_sequence = 3 }, {}, page(context))
			local refreshed = bridge.on_message({ action = "refresh" }, { is_paused = function() return true end }, page(context))
			helpers.assert_eq(refreshed.snapshot.sections.input.paused, true)
			local current = bridge.on_message({ action = "export_snapshot", export_sequence = 4 }, {}, page(context))
			helpers.assert_true(rawequal(current.snapshot, refreshed.snapshot))
			helpers.assert_true(current.share_text ~= exported.share_text, "A typed state change makes the old preview stale")
			local refused = bridge.on_message({ action = "copy", text = exported.share_text }, {}, page(context))
			helpers.assert_eq(refused.ok, false)
			helpers.assert_eq(#context.copied, 0)
			local accepted = bridge.on_message({ action = "copy", text = current.share_text }, {}, page(context))
			helpers.assert_eq(accepted.ok, true)
			helpers.assert_eq(context.copied, { current.share_text })
		end)
	end)
end)

helpers.describe("diagnostics bridge stable-metadata report", function()
	helpers.it("completes the actual attachment before opening a form without editable query defaults", function()
		with_bridge({ logs_dir = HOME .. "/.local/state/ergopti_plus" }, function(bridge, context)
			local ready = bridge.on_message("ready", {}, page(context))
			local exported = bridge.on_message({ action = "export_snapshot", export_sequence = 77 }, {}, page(context))
			local fs = require("adapters.file_system")
			local old_write, old_shell = fs.write, package.loaded["adapters.shell_runner"]
			local old_desktop = package.loaded["adapters.desktop_opener"]
			local calls, written = {}, {}
			fs.write = function(path, value)
				assert(path:sub(1, #HOME) == HOME and path:find("/diagnostics/", 1, true))
				written[#written + 1] = value; calls[#calls + 1] = "write"; return true
			end
			package.loaded["adapters.shell_runner"] = {
				quote = function(value) return string.format("%q", value) end,
				run = function(command) calls[#calls + 1] = command; return true end,
			}
			package.loaded["adapters.desktop_opener"] = {
				open = function(target, done)
					calls[#calls + 1] = { executable = "xdg-open", args = { target } }
					done({ ok = true, code = 0 })
				end,
			}
			local ok, err = xpcall(function()
				local answer = bridge.on_message({ action = "report", text = exported.share_text,
					fields = { version = "2.4.0", driver = "foreign" } }, {}, page(context))
				helpers.assert_eq(answer.ok, true)
				helpers.assert_eq(context.copied, { exported.share_text })
				helpers.assert_eq(written, { exported.share_text })
				helpers.assert_eq(#calls, 4, "mkdir, completed write, reveal, then browser")
				helpers.assert_true(calls[1]:find("mkdir -p", 1, true) == 1)
				helpers.assert_eq(calls[2], "write")
				local repo = bridge.config().repository
				local stable = require("healthcheck.share").document(exported.snapshot, bridge.config().schema, "ignored").fields
				local url = require("diagnostics.issue_link").build_url(bridge.config().templates, repo, "bug", stable)
				helpers.assert_eq(calls[4], { executable = "xdg-open", args = { url } })
			end, debug.traceback)
			fs.write, package.loaded["adapters.shell_runner"] = old_write, old_shell
			package.loaded["adapters.desktop_opener"] = old_desktop
			if not ok then error(err, 0) end
		end)
	end)
end)


--- Owns only a deferred launcher port; every returned native-style receipt is
--- delivered explicitly by the subject, outside the producer's protected call.
local function with_deferred_opener(body)
	with_bridge({ logs_dir = HOME .. "/.local/state/ergopti_plus" }, function(bridge, context)
		local shell, fs = package.loaded["adapters.shell_runner"], require("adapters.file_system")
		local held_write, desktop = fs.write, package.loaded["adapters.desktop_opener"]
		context.openers, context.writes = {}, 0
		fs.write = function()
			context.writes = context.writes + 1
			if context.after_write then context.after_write() end
			return true
		end
		package.loaded["adapters.shell_runner"] = {
			quote = require("adapters.shell_runner").quote, run = function() return true end,
		}
		package.loaded["adapters.desktop_opener"] = {
			open = function(target, done)
				local call = { program = "xdg-open", args = { target }, done = done, cancelled = 0 }
				context.openers[#context.openers + 1] = call
				return { cancel = function() call.cancelled = call.cancelled + 1; if context.on_cancel then context.on_cancel() end end }
			end,
		}
		local function request()
			local exported = bridge.on_message({ action = "export_snapshot", export_sequence = 90 }, {}, page(context))
			return bridge.on_message({ action = "report", text = exported.share_text, fields = {} }, {}, page(context))
		end
		local ok, detail = xpcall(function()
			bridge.on_message("ready", {}, page(context)); body(bridge, context, request)
		end, debug.traceback)
		fs.write, package.loaded["adapters.shell_runner"] = held_write, shell
		package.loaded["adapters.desktop_opener"] = desktop
		if not ok then error(detail, 0) end
	end)
end

helpers.describe("diagnostics asynchronous opener ownership", function()
	helpers.it("(diagnostic-opener-session) awaits reveal and browser, then delivers the actual failure", function()
		with_deferred_opener(function(_, c, request)
			helpers.assert_nil(request()); helpers.assert_eq(#c.openers, 1); helpers.assert_eq(#c.pushed, 0)
			c.openers[1].done({ ok = false, code = 23, error = "native reveal refused" })
			helpers.assert_eq(#c.openers, 2, "reveal refusal stays warning-only after the completed save")
			helpers.assert_eq(#c.pushed, 0, "browser admission does not acknowledge report completion")
			c.openers[2].done({ ok = false, code = 24, error = "native browser refused" })
			helpers.assert_eq(#c.pushed, 1)
			local result = require("json").decode(c.pushed[1]:match("receiveDiagnostics%((.*)%)$"))
			helpers.assert_eq(result.ok, false); helpers.assert_eq(result.action, "report")
			c.openers[2].done({ ok = true, code = 0 }); helpers.assert_eq(#c.pushed, 1)
		end)
	end)
	for _, retirement in ipairs({ "refresh", "ready", "close", "native_close", "epoch" }) do
		helpers.it("(diagnostic-opener-session) " .. retirement .. " revokes pending continuation", function()
			with_deferred_opener(function(bridge, c, request)
				helpers.assert_nil(request())
				if retirement == "refresh" then bridge.on_message({ action = "refresh", detailed = false, extensive = false }, {}, page(c))
				elseif retirement == "ready" then bridge.on_message("ready", {}, page(c))
				elseif retirement == "close" then bridge.on_message({ action = "close" }, {}, page(c))
				elseif retirement == "native_close" then bridge.on_window_closed(c.epoch)
				else c.epoch = c.epoch + 1 end
				c.openers[1].done({ ok = true, code = 0 })
				helpers.assert_eq(#c.openers, 1, "retired reveal cannot open a browser")
				helpers.assert_eq(#c.pushed, 0, "no old action receipt reaches the replacement generation")
			end)
		end)
	end
	helpers.it("(diagnostic-opener-session) a newer action owns the only completion", function()
		with_deferred_opener(function(_, c, request)
			helpers.assert_nil(request())
			helpers.assert_nil(request()); helpers.assert_true(c.openers[1].cancelled > 0)
			c.openers[1].done({ ok = true, code = 0 }); helpers.assert_eq(#c.openers, 2)
			c.openers[2].done({ ok = true, code = 0 }); helpers.assert_eq(#c.openers, 3)
			c.openers[3].done({ ok = true, code = 0 }); helpers.assert_eq(#c.pushed, 1)
		end)
	end)
	helpers.it("(diagnostic-opener-session) synchronous save reentry cannot dispatch the retired reveal", function()
		with_deferred_opener(function(bridge, c, request)
			c.after_write = function() bridge.on_message({ action = "refresh", detailed = false, extensive = false }, {}, page(c)) end
			helpers.assert_nil(request()); helpers.assert_eq(c.writes, 1); helpers.assert_eq(#c.openers, 0)
			helpers.assert_eq(#c.pushed, 0)
		end)
	end)
end)

helpers.describe("diagnostic opener cancellation reentry", function()
	helpers.it("(opener-cancel-reentry) preserves a nested action instead of overwriting it", function()
		with_deferred_opener(function(_, c, request)
			request()
			c.on_cancel = function() c.on_cancel = nil; request() end
			request()
			helpers.assert_eq(#c.openers, 2)
			c.openers[2].done({ ok = true, code = 0 })
			helpers.assert_eq(#c.openers, 3)
			c.openers[3].done({ ok = true, code = 0 }); helpers.assert_eq(#c.pushed, 1)
		end)
	end)
	for _, transition in ipairs({ "ready", "native_close" }) do
		helpers.it("(opener-cancel-reentry) " .. transition .. " retains the replacement page", function()
			with_deferred_opener(function(bridge, c, request)
				request()
				c.on_cancel = function() c.on_cancel = nil; bridge.on_message("ready", {}, page(c)); request() end
				if transition == "ready" then bridge.on_message("ready", {}, page(c)) else bridge.on_window_closed(c.epoch) end
				helpers.assert_eq(#c.openers, 2)
				c.openers[2].done({ ok = true, code = 0 }); helpers.assert_eq(#c.openers, 3)
				c.openers[3].done({ ok = true, code = 0 }); helpers.assert_eq(#c.pushed, 1)
			end)
		end)
	end
end)

helpers.describe("diagnostics bridge fixture ownership", function()
	helpers.it("restores exact collaborators and warm preference paths after a body failure", function()
		local paths = require("infra.config_paths")
		local preferences = require("infra.metrics_preferences")
		local names = { "infra.config_paths", "infra.metrics_preferences", "ui.webview_manager", "adapters.clipboard",
			"ui.healthcheck.bridge", "ui.healthcheck.report", "ui.healthcheck.probes" }
		local before = {}
		for _, name in ipairs(names) do before[name] = package.loaded[name] end
		local logger, sink = require("logger.shim"), require("infra.logger_sink")
		local warn, log_dir, getenv = logger.warn, sink.log_dir, os.getenv
		local failure, visited = {}, 0
		local ok, detail = pcall(with_bridge, nil, function(bridge, context)
			local answer = bridge.on_message("ready", {}, page(context))
			helpers.assert_eq(answer.config.context.home, HOME)
			visited = visited + 1
			error(failure, 0)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_true(rawequal(detail, failure), "preserve the original body failure after cleanup")
		helpers.assert_eq(visited, 1, "the real bridge ran before the controlled body failure")
		for _, name in ipairs(names) do
			helpers.assert_true(rawequal(package.loaded[name], before[name]), "restore original cache identity: " .. name)
		end
		helpers.assert_true(rawequal(require("infra.config_paths"), paths))
		helpers.assert_true(rawequal(require("infra.metrics_preferences"), preferences))
		helpers.assert_true(logger.warn == warn and sink.log_dir == log_dir and os.getenv == getenv)
	end)
end)
