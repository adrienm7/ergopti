--- tests/unit/ui/test_healthcheck_bridge_actions.lua

--- ==============================================================================
--- MODULE: Diagnostics Window Bridge (Linux)
--- DESCRIPTION:
--- Drives the real diagnostics bridge the way the shared page and the webview
--- manager call it:
--- 1. "ready" answers with the page's configuration and the first version 2
---    snapshot, and starts the probes of that page;
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
	local context = { pushed = {}, copied = {}, warnings = {}, starts = 0, cancels = 0, closed = 0, epoch = 7 }
	for _, name in ipairs({ "ui.healthcheck.bridge", "ui.healthcheck.report", "ui.healthcheck.probes" }) do
		package.loaded[name] = nil
	end
	package.loaded["ui.healthcheck.probes"] = {
		start = function(_, _, _, publish)
			context.starts = context.starts + 1
			context.publish = publish
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
	local bridge = helpers.load_module("ui.healthcheck.bridge")
	local logger = require("logger.shim")
	local warn = logger.warn
	context.restore = function()
		logger.warn = warn
		package.loaded["ui.webview_manager"] = nil
		package.loaded["adapters.clipboard"] = nil
		package.loaded["infra.config_paths"] = nil
		package.loaded["ui.healthcheck.probes"] = nil
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
	context.restore()
	if not ok then error(err, 0) end
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
	helpers.it("answers ready with a quick version 2 snapshot without starting probes", function()
		with_bridge(nil, function(bridge, context)
			local answer = bridge.on_message("ready", {}, page(context))
			helpers.assert_eq(answer.type, "init")
			helpers.assert_eq(answer.config.schema.schema_version, 2)
			helpers.assert_eq(answer.config.context.home, HOME)
			helpers.assert_eq(answer.config.context.case_insensitive, false)
			helpers.assert_eq(answer.snapshot.driver, "linux")
			helpers.assert_eq(answer.snapshot.schema_version, 2)
			helpers.assert_eq(context.starts, 0)
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
			bridge.on_message("ready", {}, page(context))
			local answer = bridge.on_message({ action = "copy", text = "at /home/jdoe/x by jdoe" }, {}, page(context))
			helpers.assert_eq(context.copied, { "at ~/x by <user>" })
			helpers.assert_eq(answer.type, "action")
			helpers.assert_eq(answer.ok, true)
		end)
	end)

	helpers.it("answers a refused clipboard as a failure", function()
		with_bridge({ clipboard = false }, function(bridge, context)
			bridge.on_message("ready", {}, page(context))
			local answer = bridge.on_message({ action = "copy", text = "report" }, {}, page(context))
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
			helpers.assert_eq(context.starts, 1)
			helpers.assert_eq(context.cancels, 0)
		end)
	end)

	helpers.it("closes the page it came from and cancels its probes", function()
		with_bridge(nil, function(bridge, context)
			bridge.on_message("ready", {}, page(context))
			bridge.on_message({ action = "refresh", extensive = true }, {}, page(context))
			helpers.assert_nil(bridge.on_message({ action = "close" }, {}, page(context)))
			helpers.assert_eq(context.closed, 1)
			helpers.assert_eq(context.cancels, 1)
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

	helpers.it("replaces an open window, in report mode", function()
		with_bridge(nil, function(bridge, context)
			local manager = package.loaded["ui.webview_manager"]
			local hidden, shown = {}, {}
			manager.hide = function(app, epoch) hidden[#hidden + 1] = app .. "#" .. tostring(epoch); return true end
			manager.show = function(app) shown[#shown + 1] = app; return true end
			helpers.assert_eq(bridge.open("report"), true)
			helpers.assert_eq(hidden, { "healthcheck#7" }, "the open page must be closed, not brought forward")
			helpers.assert_eq(shown, { "healthcheck" })
			helpers.assert_eq(bridge.on_message("ready", {}, page(context)).config.mode, "report")
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
	helpers.it("privacy-only refresh remains quick without creating a probe owner", function()
		with_bridge(nil, function(bridge, context)
			bridge.on_message("ready", {}, page(context))
			local answer = bridge.on_message({ action = "refresh", detailed = true }, {}, page(context))
			helpers.assert_eq(answer.snapshot.detailed, true)
			helpers.assert_eq(answer.snapshot.extensive, false)
			helpers.assert_eq(context.starts, 0)
			helpers.assert_eq(answer.snapshot.probes.github_api.state, "not_run")
		end)
	end)
	helpers.it("cancel retains partial results and does not invent a cleanup acknowledgement", function()
		with_bridge(nil, function(bridge, context)
			bridge.on_message("ready", {}, page(context))
			bridge.on_message({ action = "refresh", extensive = true }, {}, page(context))
			context.publish("github_api", { state = "ok", ms = 12 })
			local answer = bridge.on_message({ action = "cancel" }, {}, page(context))
			helpers.assert_eq(context.starts, 1)
			helpers.assert_eq(context.cancels, 1)
			helpers.assert_eq(answer.snapshot.probes.github_api.state, "ok")
			helpers.assert_eq(answer.snapshot.probes.github_api.ms, 12)
			helpers.assert_eq(answer.snapshot.probes.ai_health.state, "cancelled")
			helpers.assert_eq(answer.snapshot.probes.ai_health.cleanup, "pending")
		end)
	end)
	helpers.it("export observation returns the exact owned snapshot without any export side effect", function()
		with_bridge(nil, function(bridge, context)
			local ready = bridge.on_message("ready", {}, page(context))
			local answer = bridge.on_message({ action = "export_snapshot", export_sequence = 12 }, {}, page(context))
			helpers.assert_true(answer.snapshot == ready.snapshot)
			helpers.assert_eq(answer.export_sequence, 12)
			helpers.assert_eq(answer.action, "export_snapshot")
			helpers.assert_eq(context.starts, 0)
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
			helpers.assert_eq(context.starts, 1)
			helpers.assert_eq(context.cancels, 1)
			helpers.assert_eq(#context.copied, 0)
		end)
	end)
end)
