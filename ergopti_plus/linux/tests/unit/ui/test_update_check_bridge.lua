--- tests/unit/ui/test_update_check_bridge.lua

--- ==============================================================================
--- MODULE: Update Check Window Bridge (Linux)
--- DESCRIPTION:
--- Drives the real update-check bridge the way the About row, the webview
--- manager and the shared page call it:
--- 1. opening shows the window and pushes "checking", then the updater's
---    answer, into this page only;
--- 2. Update downloads and installs the offered release with the download
---    window (kind app_update) and hands the result to the restart hook;
--- 3. a switch persists through the updater, refreshes the menu and the
---    Versions page, and checks the new channel at once;
--- 4. a failure names today's log, Report goes through the error window's
---    report and the log through the menu's opener;
--- 5. a message after the window closed is refused;
--- 6. a click while the check runs keeps its answer, and a click while the
---    updater is busy otherwise starts no check that could only fail.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local STUBBED = {
	"ui.webview_manager", "ui.download_window.bridge", "ui.error_dialog.bridge", "ui.changelog.bridge",
}

--- Loads the real bridge with controlled collaborators.
--- @param answer function(channel): table The updater's answer.
--- @return table bridge, table context
local function load_bridge(answer)
	local context = {
		shown = {}, hidden = 0, pushed = {}, checks = {}, sets = {}, downloads = {}, installs = {},
		windows = {}, completed = {}, reports = {}, channel_pushes = {}, menu_changes = 0, finished = {},
		logs_opened = 0, channel = "dev", saved = {}, state = "idle", defer = false, pending = {},
		source_run = false,
	}
	for _, name in ipairs(STUBBED) do context.saved[name] = package.loaded[name] end
	-- The suite runs from a checkout, which is a source run: each case says.
	local Installation = require("infra.installation")
	context.real_is_source_run = Installation.is_source_run
	Installation.is_source_run = function() return context.source_run end
	package.loaded["ui.update_check.bridge"] = nil
	package.loaded["ui.webview_manager"] = {
		show = function(app) context.shown[#context.shown + 1] = app; return true end,
		hide = function() context.hidden = context.hidden + 1; return true end,
		eval_js = function(app, js)
			local payload = js:match("receiveUpdateCheck%((.*)%)$")
			context.pushed[#context.pushed + 1] = { app = app, message = payload and Json.decode(payload) }
			return true
		end,
	}
	package.loaded["ui.download_window.bridge"] = {
		show = function(opts) context.windows[#context.windows + 1] = opts; return 7 end,
		complete = function(id, ok, message) context.completed[#context.completed + 1] = { id, ok, message } end,
	}
	package.loaded["ui.error_dialog.bridge"] = {
		report = function(record) context.reports[#context.reports + 1] = record; return true end,
	}
	package.loaded["ui.changelog.bridge"] = {
		push_subscribed_channel = function(id) context.channel_pushes[#context.channel_pushes + 1] = id end,
	}
	context.release = { tag = "v0.0.0-dev.150", download_url = "https://example.invalid/bundle.tar.gz" }
	context.updater = {
		get_channel = function() return context.channel end,
		current_version = function() return "0.0.0-dev.144" end,
		check_for_updates = function(channel, callback)
			context.checks[#context.checks + 1] = channel
			if context.defer then
				-- A slow network: the updater stays busy until the answer arrives
				context.state = "checking"
				context.pending[#context.pending + 1] = function()
					context.state = "idle"
					callback(false, nil, nil, answer(channel))
				end
				return true
			end
			callback(false, nil, nil, answer(channel))
			return true
		end,
		get_state = function() return context.state end,
		set_channel = function(id) context.sets[#context.sets + 1] = id; context.channel = id; return true end,
		-- The real updater owns one cached record until the next actual offer.
		get_cached_release = function() return context.release end,
		download_update = function(url, callback)
			context.downloads[#context.downloads + 1] = url
			callback("/tmp/update.tar.gz", nil)
			return true
		end,
		install_update = function(path) context.installs[#context.installs + 1] = path; return true end,
		cancel_update = function() return true end,
	}
	context.ctx = {
		updater = context.updater,
		on_menu_changed = function() context.menu_changes = context.menu_changes + 1 end,
		on_update_finished = function(...) context.finished[#context.finished + 1] = { ... } end,
		on_open_today_log = function() context.logs_opened = context.logs_opened + 1; return true end,
	}
	local bridge = require("ui.update_check.bridge")
	return bridge, context
end

local function restore(context)
	for _, name in ipairs(STUBBED) do package.loaded[name] = context.saved[name] end
	require("infra.installation").is_source_run = context.real_is_source_run
	package.loaded["ui.update_check.bridge"] = nil
end

--- Runs one scenario, restoring the collaborators after it.
local function scenario(answer, fn)
	local bridge, context = load_bridge(answer)
	local ok, err = pcall(fn, bridge, context)
	bridge._reset()
	restore(context)
	if not ok then error(err, 0) end
end

local function available(channel)
	return { state = "available", channel = channel, current = "0.0.0-dev.144", latest = "v0.0.0-dev.150",
		others = { { channel = "main", tag = "v1.0.0" } } }
end

local function last(context) return context.pushed[#context.pushed].message end

helpers.describe("update-check window bridge (Linux)", function()
	helpers.it("opens the window, shows checking, then the updater's answer", function()
		scenario(available, function(bridge, context)
			helpers.assert_true(bridge.open(context.ctx))
			helpers.assert_eq(context.shown, { "update_check" })
			helpers.assert_eq(context.checks, { "dev" }, "the subscribed channel is checked")
			helpers.assert_eq(context.pushed[1].app, "update_check", "pushes reach this page only")
			helpers.assert_eq(context.pushed[1].message.state, "checking")
			helpers.assert_eq(last(context).state, "available")
			helpers.assert_eq(last(context).others, { { channel = "main", tag = "v1.0.0" } })
			helpers.assert_true(context.menu_changes >= 1, "the menu follows the answer")
			bridge.on_message("ready")
			helpers.assert_eq(last(context).state, "available", "a page that loads late gets the answer")
		end)
	end)

	helpers.it("downloads and installs the offered release with the download window", function()
		scenario(available, function(bridge, context)
			bridge.open(context.ctx)
			bridge.on_message({ action = "update" })
			helpers.assert_eq(context.windows[1].kind, "app_update", "the download window shows an app update")
			helpers.assert_contains(context.windows[1].label, "v0.0.0-dev.150")
			helpers.assert_eq(context.downloads, { "https://example.invalid/bundle.tar.gz" })
			helpers.assert_eq(context.installs, { "/tmp/update.tar.gz" })
			helpers.assert_eq(context.completed[1][1], 7)
			helpers.assert_eq(context.completed[1][2], true)
			helpers.assert_eq(context.finished[1], { true, "v0.0.0-dev.150", "install" },
				"the daemon restarts on the installed release")
			helpers.assert_eq(context.hidden, 1, "the update-check window closes")
		end)
	end)

	helpers.it("refuses to install a release the updater no longer offers", function()
		scenario(function(channel)
			local answer = available(channel)
			answer.latest = "v0.0.0-dev.149"
			return answer
		end, function(bridge, context)
			bridge.open(context.ctx)
			bridge.on_message({ action = "update" })
			helpers.assert_eq(#context.downloads, 0)
			helpers.assert_eq(last(context), { type = "action", action = "update", ok = false, missing = false })
		end)
	end)

	-- The menu greys its Update row on a source run; the window's Update button
	-- refuses for the same reason, before any download.
	helpers.it("refuses to install on a local version run from source", function()
		scenario(available, function(bridge, context)
			context.source_run = true
			bridge.open(context.ctx)
			bridge.on_message({ action = "update" })
			helpers.assert_eq(#context.downloads, 0, "nothing is downloaded")
			helpers.assert_eq(#context.installs, 0, "nothing is installed")
			helpers.assert_eq(#context.windows, 0, "no download window opens")
			helpers.assert_eq(last(context), { type = "action", action = "update", ok = false, missing = false })
		end)
	end)

	helpers.it("switches through the updater, then checks the new channel", function()
		scenario(available, function(bridge, context)
			bridge.open(context.ctx)
			bridge.on_message({ action = "switch_channel", channel = "main" })
			helpers.assert_eq(context.sets, { "main" })
			helpers.assert_eq(context.channel_pushes, { "main" }, "an open Versions page follows")
			helpers.assert_eq(context.checks, { "dev", "main" })
			bridge.on_message({ action = "switch_channel", channel = "beta" })
			helpers.assert_eq(context.sets, { "main" }, "a channel the answer did not list is refused")
		end)
	end)

	helpers.it("names today's log on a failure and serves Report and the log", function()
		scenario(function(channel)
			return { state = "error", channel = channel, current = "0.0.0-dev.144", others = {},
				reason_key = "updater.no_connection", detail = "Could not resolve host" }
		end, function(bridge, context)
			bridge.open(context.ctx)
			helpers.assert_eq(last(context).reason_key, "updater.no_connection")
			helpers.assert_type(last(context).log_path, "string")
			bridge.on_message({ action = "report" })
			helpers.assert_eq(context.reports[1].module, "updater")
			helpers.assert_contains(context.reports[1].message, "Could not resolve host")
			helpers.assert_eq(last(context).ok, true)
			bridge.on_message({ action = "open_log" })
			helpers.assert_eq(context.logs_opened, 1, "the menu's opener opens today's log")
		end)
	end)

	helpers.it("keeps the running check when the row is clicked again", function()
		scenario(available, function(bridge, context)
			context.defer = true
			helpers.assert_true(bridge.open(context.ctx))
			helpers.assert_true(context.menu_changes >= 1, "the menu greys its check row while the check runs")
			helpers.assert_true(bridge.open(context.ctx), "a second click shows the window")
			helpers.assert_eq(context.shown, { "update_check", "update_check" })
			helpers.assert_eq(context.checks, { "dev" }, "no second check replaces the running one")
			helpers.assert_eq(last(context).state, "checking")
			context.pending[1]()
			helpers.assert_eq(last(context).state, "available", "the running check's answer is shown")
		end)
	end)

	helpers.it("starts no check while the updater is busy without the window", function()
		scenario(available, function(bridge, context)
			context.state = "downloading"
			helpers.assert_true(bridge.open(context.ctx))
			helpers.assert_eq(#context.checks, 0, "a busy updater is not asked for a check it would fail")
			helpers.assert_eq(#context.pushed, 0, "no failure is shown for a busy updater")
		end)
	end)

	helpers.it("refuses a message once the window is closed", function()
		scenario(available, function(bridge, context)
			bridge.open(context.ctx)
			bridge.on_message({ action = "close" })
			helpers.assert_eq(context.hidden, 1)
			local pushed = #context.pushed
			bridge.on_message({ action = "update" })
			helpers.assert_eq(#context.installs, 0, "a closed window installs nothing")
			helpers.assert_eq(#context.pushed, pushed)
		end)
	end)
end)
