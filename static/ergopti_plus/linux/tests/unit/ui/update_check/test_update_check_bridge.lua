--- tests/unit/ui/update_check/test_update_check_bridge.lua

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
---    updater is busy otherwise starts no check that could only fail;
--- 7. an offered release shows its changelog in the window (the page has no
---    other source of it), and the links of those notes open with xdg-open only
---    on this repository.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

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
	local Installation = require("core.lifecycle.engine.installation")
	context.real_is_source_run = Installation.is_source_run
	Installation.is_source_run = function() return context.source_run end
	package.loaded["ui.update_check.bridge"] = nil
	package.loaded["ui.webview_manager"] = {
		show = function(app)
			context.shown[#context.shown + 1] = app
			if context.on_show then return context.on_show(app) end
			return true
		end,
		hide = function()
			context.hidden = context.hidden + 1
			if context.on_hide then return context.on_hide() end
			return true
		end,
		eval_js = function(app, js)
			if context.on_push then context.on_push() end
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
		report = function(record, complete)
			context.reports[#context.reports + 1] = record
			if context.on_report then return context.on_report() end
			complete(true)
		end,
	}
	package.loaded["ui.changelog.bridge"] = {
		push_subscribed_channel = function(id) context.channel_pushes[#context.channel_pushes + 1] = id end,
	}
	context.release = { tag = "v0.0.0-dev.150", download_url = "https://example.invalid/bundle.tar.gz" }
	context.updater = {
		get_channel = function() return context.channel end,
		current_version = function() return "0.0.0-dev.144" end,
		repo_info = function() return { owner = "adrienm7", repo = "ergopti" } end,
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
	require("core.lifecycle.engine.installation").is_source_run = context.real_is_source_run
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
	for _, old_result in ipairs({ false, true }) do
		helpers.it("(update-check-open-owner) old opening preserves replacement when result is " .. tostring(old_result), function()
		scenario(available, function(bridge, context)
			context.on_show = function()
				context.on_show = nil
				bridge.on_window_closed()
				helpers.assert_true(bridge.open(context.ctx))
				return old_result
			end
			helpers.assert_eq(bridge.open(context.ctx), false)
			local before = #context.pushed
			bridge.on_message("ready")
			helpers.assert_true(#context.pushed > before, "the replacement still answers")
		end)
		end)
	end

	for _, operation in ipairs({ "close", "replace", "page-close" }) do
		helpers.it("(update-check-retire-owner) preserves replacement during " .. operation, function()
			scenario(function(channel) return { state = "error", channel = channel, current = "0.0.0-dev.144", others = {} } end,
				function(bridge, context)
					bridge.open(context.ctx)
					context.on_report = function()
						return { cancel = function()
							context.on_report = nil
							helpers.assert_true(bridge.open(context.ctx))
						end }
					end
					bridge.on_message({ action = "report" })
					if operation == "close" then bridge.on_window_closed()
					elseif operation == "page-close" then bridge.on_message({ action = "close" })
					else bridge.open(context.ctx) end
					local before = #context.pushed
					bridge.on_message("ready")
					helpers.assert_true(#context.pushed > before, "replacement remains active")
					helpers.assert_eq(#context.checks, 2, "old operation must not start another check")
					helpers.assert_eq(context.hidden, 0, "old operation must not hide the replacement")
				end)
		end)
	end

	helpers.it("(update-check-close-owner) keeps the session when native close is refused", function()
		scenario(available, function(bridge, context)
			bridge.open(context.ctx)
			context.on_hide = function() return false end
			bridge.on_message({ action = "close" })
			local before = #context.pushed
			bridge.on_message("ready")
			helpers.assert_true(#context.pushed > before, "a refused close retains the session")
			context.on_hide = nil
			bridge.on_message({ action = "close" })
			before = #context.pushed
			bridge.on_message("ready")
			helpers.assert_eq(#context.pushed, before, "an accepted close retires the session")
		end)
	end)

	helpers.it("(update-check-close-owner) preserves a successor opened during close", function()
		scenario(available, function(bridge, context)
			bridge.open(context.ctx)
			context.on_hide = function()
				context.on_hide = nil
				bridge.on_window_closed()
				helpers.assert_true(bridge.open(context.ctx))
				return true
			end
			bridge.on_message({ action = "close" })
			local before = #context.pushed
			bridge.on_message("ready")
			helpers.assert_true(#context.pushed > before, "the successor remains active")
		end)
	end)

	helpers.it("(update-check-start-owner) retired session cannot start a check after reentrant publication", function()
		scenario(available, function(bridge, context)
			context.on_push = function()
				context.on_push = nil
				bridge.on_window_closed()
				helpers.assert_true(bridge.open(context.ctx))
			end
			helpers.assert_eq(bridge.open(context.ctx), false)
			helpers.assert_eq(#context.checks, 1, "only the replacement may start its check")
			local before = #context.pushed
			bridge.on_message("ready")
			helpers.assert_true(#context.pushed > before, "the replacement session remains active")
		end)
	end)

	for _, kind in ipairs({ "fifo", "regular" }) do
		helpers.it("(update-log-fifo) inspects " .. kind .. " logs without blocking", function()
			if package.config:sub(1, 1) == "\\" then return end
			local path = os.tmpname(); os.remove(path)
			local quote, root = require("core.text.engine.utils_core").shell_quote, helpers.driver_root()
			if kind == "fifo" then
				local made = os.execute("mkfifo " .. quote(path))
				assert(made == true or made == 0)
			else
				local file = assert(io.open(path, "w")); assert(file:write("log")); assert(file:close())
			end
			local source = "package.path=" .. string.format("%q", root .. "/?.lua;" .. root .. "/?/init.lua;"
				.. root .. "/../_shared/?.lua;" .. root .. "/../_shared/?/init.lua;") .. "..package.path;"
				.. "package.loaded['core.lifecycle.engine.installation']={is_source_run=function()return false end};"
				.. "package.loaded['core.logger.engine.sink']={main_log_path=function()return " .. string.format("%q", path) .. " end};"
				.. "package.loaded['core.process.adapters.shell_runner']={has_command=function()return true end};"
				.. "local window; package.loaded['ui.download_window.bridge']={show=function(v)window=v;return 1 end};"
				.. "local release={tag='v1',download_url='https://example.invalid/a'}; local u={"
				.. "get_cached_release=function()return release end,get_state=function()return 'idle' end,"
				.. "get_channel=function()return 'dev' end,download_update=function()return true end};"
				.. "assert(require('ui.update_check.bridge').download_offered(u,release,{on_open_today_log=function()end}));"
				.. "assert(window.can_open_diagnostics()==" .. tostring(kind == "regular") .. ")"
			local status = os.execute("timeout 3 " .. quote(assert(require("luv").exepath())) .. " -e " .. quote(source))
			assert(os.remove(path))
			helpers.assert_true(status == true or status == 0, "special logs must be refused without waiting")
		end)
	end
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
	local RELEASE = '{"tag_name":"v0.0.0-dev.150","body":"## Changelog\\n- **Fix: A thing**"}'
	local function with_notes(channel)
		local answer = available(channel)
		answer.release = RELEASE
		return answer
	end

	helpers.it("seeds the offered release's notes into the window", function()
		scenario(with_notes, function(bridge, context)
			bridge.open(context.ctx)
			helpers.assert_eq(last(context).notes,
				{ body = "## Changelog\n- **Fix: A thing**", owner = "adrienm7", repo = "ergopti" })
		end)
	end)

	helpers.it("opens a repository link of the notes with xdg-open, nothing else", function()
		scenario(with_notes, function(bridge, context)
			local saved, commands = package.loaded["core.process.adapters.shell_runner"], {}
			package.loaded["core.process.adapters.shell_runner"] = {
				has_command = function(binary) return binary == "xdg-open" end,
				quote = function(text) return "'" .. text .. "'" end,
				run = function(command) commands[#commands + 1] = command; return true end,
			}
			local ok, err = pcall(function()
				bridge.open(context.ctx)
				local url = "https://github.com/adrienm7/ergopti/releases/tag/v0.0.0-dev.150"
				bridge.on_message({ action = "open_url", url = url })
				helpers.assert_eq(commands, { "xdg-open '" .. url .. "' >/dev/null 2>&1 &" })
				helpers.assert_eq(last(context), { type = "action", action = "open_url", ok = true, missing = false })
				bridge.on_message({ action = "open_url", url = "https://example.com/" })
				bridge.on_message({ action = "open_url", url = "https://github.com/adrienm7/ergopti'; rm -rf ~ #" })
				helpers.assert_eq(#commands, 1, "a link outside the repository never reaches the shell")
				helpers.assert_eq(last(context).ok, false)
			end)
			package.loaded["core.process.adapters.shell_runner"] = saved
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("says so when xdg-open is missing", function()
		scenario(with_notes, function(bridge, context)
			local saved, ran = package.loaded["core.process.adapters.shell_runner"], 0
			package.loaded["core.process.adapters.shell_runner"] = {
				has_command = function() return false end,
				quote = function(text) return text end,
				run = function() ran = ran + 1; return true end,
			}
			local ok, err = pcall(function()
				bridge.open(context.ctx)
				bridge.on_message({ action = "open_url", url = "https://github.com/adrienm7/ergopti" })
				helpers.assert_eq(ran, 0)
				helpers.assert_eq(last(context).ok, false)
			end)
			package.loaded["core.process.adapters.shell_runner"] = saved
			if not ok then error(err, 0) end
		end)
	end)
end)
