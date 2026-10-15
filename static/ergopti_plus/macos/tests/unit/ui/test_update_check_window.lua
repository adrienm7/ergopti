--- tests/unit/ui/test_update_check_window.lua

--- ==============================================================================
--- MODULE: Update Check Window (macOS host)
--- DESCRIPTION:
--- A manual "Check for updates" used to hand the whole check to Sparkle, whose
--- English, left-aligned alert never said which channel it read. The macOS host
--- of the shared update-check window now asks the Lua automatic-check owner for
--- the subscribed channel and hands only the install to Sparkle:
--- 1. the window shows "checking" for the subscribed channel, then the owner's
---    answer, in the exact window it was created for;
--- 2. Update gives Sparkle the channel of the offered release and closes;
--- 3. a switch goes through the menu session's channel owner and the menu is
---    refreshed;
--- 4. a failure's Report goes through the error window's report, naming the
---    updater and the cause;
--- 5. without an automatic-check owner the window shows a failure, not nothing.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local STUBS = { "adapters.update_launcher", "ui.changelog", "ui.error_dialog", "ui.log_openers", "ui.ui_builder" }

--- Loads the host with recording doubles of the launcher, the Versions window,
--- the error window and the log opener. ctx: Host, requests, reports, changelogs.
local function load_host()
	local ctx = { requests = {}, reports = {}, changelogs = {}, saved = {} }
	for _, name in ipairs(STUBS) do ctx.saved[name] = package.loaded[name] end
	package.loaded["adapters.update_launcher"] = {
		request_check = function(channel) ctx.requests[#ctx.requests + 1] = channel; return true end,
	}
	package.loaded["ui.changelog"] = {
		open = function(opts) ctx.changelogs[#ctx.changelogs + 1] = opts.channel end,
	}
	package.loaded["ui.error_dialog"] = {
		report = function(record, complete) ctx.reports[#ctx.reports + 1] = record; complete(true); return { cancel = function() end } end,
	}
	package.loaded["ui.log_openers"] = { open_today_log = function() return true end }
	package.loaded["ui.ui_builder"] = { force_focus = function() ctx.focused = (ctx.focused or 0) + 1 end }
	ctx.Host = helpers.load_with_stubs("ui.update_check")
	return ctx
end

local function restore(ctx)
	for _, name in ipairs(STUBS) do package.loaded[name] = ctx.saved[name] end
	package.loaded["ui.update_check"] = nil
end

--- A window double recording what the page is sent.
local function fake_view()
	local view = { messages = {}, deleted = false }
	function view.evaluateJavaScript(_, js)
		local payload = js:match("receiveUpdateCheck%((.*)%)$")
		view.messages[#view.messages + 1] = payload and Json.decode(payload) or js
	end
	function view.delete() view.deleted = true end
	return view
end

--- The menu session's owners as recording doubles.
local function fake_owners(answer)
	local owners = { sets = {}, checked = {}, changes = 0, subscribed = "dev" }
	owners.channel_owner = {
		get = function() return owners.subscribed end,
		set = function(id) owners.sets[#owners.sets + 1] = id; owners.subscribed = id; return true end,
	}
	owners.checks = {
		check_now = function(channel, on_result)
			owners.checked[#owners.checked + 1] = channel
			on_result(answer(channel))
			return true
		end,
	}
	owners.on_change = function() owners.changes = owners.changes + 1 end
	return owners
end

--- Runs one scenario with the host loaded, restoring the doubles after it.
local function scenario(fn)
	local ctx = load_host()
	local ok, err = pcall(fn, ctx)
	restore(ctx)
	if not ok then error(err, 0) end
end

local function available(channel)
	return { state = "available", channel = channel, current = "v0.0.0-dev.144", latest = "v0.0.0-dev.150",
		others = { { channel = "main", tag = "v1.0.0" } } }
end

helpers.describe("update-check window (macOS host)", function()
	helpers.it("shows checking, then the owner's answer, in its own window only", function()
		scenario(function(ctx)
			local owners = fake_owners(available)
			local view, stale = fake_view(), fake_view()
			local session = ctx.Host._session_for(view, owners)
			ctx.Host._set_window(view, session)
			session.start()
			helpers.assert_eq(owners.checked, { "dev" }, "the subscribed channel is checked by the Lua owner")
			helpers.assert_eq(view.messages[1].state, "checking")
			helpers.assert_eq(view.messages[1].channel, "dev")
			helpers.assert_eq(view.messages[2].state, "available")
			helpers.assert_eq(view.messages[2].latest, "v0.0.0-dev.150")
			helpers.assert_eq(owners.changes, 1, "the menu refreshes so the About row names the release")
			local stale_session = ctx.Host._session_for(stale, owners)
			stale_session.start()
			helpers.assert_eq(#stale.messages, 0, "a window that is not the current one receives nothing")
		end)
	end)

	helpers.it("hands the offered release's channel to Sparkle, then closes", function()
		scenario(function(ctx)
			local owners = fake_owners(available)
			local view = fake_view()
			local session = ctx.Host._session_for(view, owners)
			ctx.Host._set_window(view, session)
			session.start()
			session.on_message({ action = "update" })
			helpers.assert_eq(ctx.requests, { "dev" }, "Sparkle installs from the checked channel")
			helpers.assert_true(view.deleted, "the window closes once Sparkle has the install")
		end)
	end)

	helpers.it("switches through the channel owner and checks the new channel", function()
		scenario(function(ctx)
			local owners = fake_owners(available)
			local view = fake_view()
			local session = ctx.Host._session_for(view, owners)
			ctx.Host._set_window(view, session)
			session.start()
			session.on_message({ action = "switch_channel", channel = "main" })
			helpers.assert_eq(owners.sets, { "main" }, "the menu session's owner persists the switch")
			helpers.assert_eq(owners.checked, { "dev", "main" }, "the new channel is checked at once")
			helpers.assert_true(owners.changes >= 2, "the menu follows the switch")
			session.on_message({ action = "whats_new" })
			helpers.assert_eq(ctx.changelogs, { "main" }, "What's new opens the Versions window on the channel")
		end)
	end)

	helpers.it("reports a failure through the error window's report", function()
		scenario(function(ctx)
			local owners = fake_owners(function(channel)
				return { state = "error", channel = channel, current = "v0.0.0-dev.144", others = {},
					reason_key = "updater.no_connection", detail = "HTTP 503" }
			end)
			local view = fake_view()
			local session = ctx.Host._session_for(view, owners)
			ctx.Host._set_window(view, session)
			session.start()
			local shown = view.messages[#view.messages]
			helpers.assert_eq(shown.state, "error")
			helpers.assert_type(shown.log_path, "string", "the failure names today's log")
			helpers.assert_true(shown.log_path ~= "", "the failure names today's log")
			session.on_message({ action = "report" })
			helpers.assert_eq(#ctx.reports, 1)
			helpers.assert_eq(ctx.reports[1].module, "updater")
			helpers.assert_contains(ctx.reports[1].message, "HTTP 503")
			helpers.assert_contains(ctx.reports[1].message, "dev")
		end)
	end)

	helpers.it("a second open checks again over the owners of the menu session that asked", function()
		scenario(function(ctx)
			local first = fake_owners(available)
			local late = nil
			first.checks.check_now = function(channel, on_result)
				first.checked[#first.checked + 1] = channel
				late = on_result
				return true
			end
			local view = fake_view()
			local session = ctx.Host._session_for(view, first)
			ctx.Host._set_window(view, session)
			session.start()
			local second = fake_owners(available)
			helpers.assert_true(ctx.Host.open(second))
			helpers.assert_eq(ctx.focused, 1, "the open window is focused")
			helpers.assert_eq(second.checked, { "dev" }, "the new menu session's owner checks")
			local shown = #view.messages
			late(available("dev"))
			helpers.assert_eq(#view.messages, shown, "the replaced session's late answer is not shown")
			helpers.assert_true(ctx.Host._session() ~= session, "the window has a new session")
			ctx.Host._set_window(nil, nil)
		end)
	end)

	helpers.it("shows a failure when the menu session has no automatic-check owner", function()
		scenario(function(ctx)
			local owners = fake_owners(available)
			owners.checks = nil
			local view = fake_view()
			local session = ctx.Host._session_for(view, owners)
			ctx.Host._set_window(view, session)
			session.start()
			local shown = view.messages[#view.messages]
			helpers.assert_eq(shown.state, "error")
			helpers.assert_eq(shown.reason_key, "update_check.error_unexpected")
		end)
	end)
end)


helpers.describe("update-check native report completion", function()
	for _, reported in ipairs({ true, false }) do
		helpers.it("completes the native report receipt inline, accepted=" .. tostring(reported), function()
			scenario(function(ctx)
				local owners = fake_owners(function(channel)
					return { state = "error", channel = channel, detail = "HTTP 503", others = {} }
				end)
				local view = fake_view()
				local session = ctx.Host._session_for(view, owners)
				ctx.Host._set_window(view, session)
				session.start()
				local native_records = {}
				package.loaded["ui.error_dialog"].report = function(record, complete)
					native_records[#native_records + 1] = record
					complete(reported)
					return { cancel = function() end }
				end
				session.on_message({ action = "report" })
				helpers.assert_eq(#native_records, 1, "the synchronous native report owner must run exactly once")
				helpers.assert_eq(native_records[1].module, "updater")
				local acknowledgement = view.messages[#view.messages]
				helpers.assert_eq(acknowledgement.type, "action", "completion reaches the page before dispatch returns")
				helpers.assert_eq(acknowledgement.action, "report")
				helpers.assert_eq(acknowledgement.ok, reported, "the page receives the actual native boolean receipt")
				helpers.assert_eq(acknowledgement.missing, false)
			end)
		end)
	end

	helpers.it("a synchronous native report cannot acknowledge into its replacement session", function()
		scenario(function(ctx)
			local owners = fake_owners(function(channel)
				return { state = "error", channel = channel, detail = "HTTP 503", others = {} }
			end)
			local view = fake_view()
			local session = ctx.Host._session_for(view, owners)
			ctx.Host._set_window(view, session)
			session.start()
			local replacement, replacement_messages, reopened
			package.loaded["ui.error_dialog"].report = function(_, complete)
				reopened = ctx.Host.open(owners)
				replacement = ctx.Host._session()
				replacement_messages = #view.messages
				complete(true)
				return { cancel = function() end }
			end
			session.on_message({ action = "report" })
			helpers.assert_true(reopened, "native report reentry may replace the same window's session")
			helpers.assert_true(replacement ~= nil and replacement ~= session)
			helpers.assert_eq(#view.messages, replacement_messages, "the retired report cannot append an acknowledgement")
			helpers.assert_eq(view.messages[#view.messages].state, "error", "the replacement check's own answer remains current")
			ctx.Host._set_window(nil, nil)
		end)
	end)
end)


helpers.describe("update report asynchronous native receipt", function()
	for _, change in ipairs({ "complete", "restart", "retire" }) do
		helpers.it("retains the exact error result while native reporting is pending: " .. change, function()
			scenario(function(ctx)
				local owners = fake_owners(function(channel) return { state = "error", channel = channel, detail = "HTTP 503", others = {} } end)
				local view = fake_view()
				local session = ctx.Host._session_for(view, owners)
				ctx.Host._set_window(view, session)
				session.start()
				local complete, current, cancelled
				package.loaded["ui.error_dialog"].report = function(_, callback, predicate)
					complete, current = callback, predicate
					return { cancel = function() cancelled = true end }
				end
				local before = #view.messages
				session.on_message({ action = "report" })
				helpers.assert_eq(#view.messages, before, "native admission cannot acknowledge success")
				if change == "restart" then session.start() elseif change == "retire" then session.retire() end
				local after = #view.messages
				complete(true)
				if change == "complete" then
					helpers.assert_true(current())
					helpers.assert_eq(#view.messages, after + 1)
					helpers.assert_eq(view.messages[#view.messages].ok, true)
				else
					helpers.assert_eq(current(), false)
					helpers.assert_true(cancelled)
					helpers.assert_eq(#view.messages, after)
				end
			end)
		end)
	end
end)


helpers.describe("update host report cancellation reentry", function()
	helpers.it("native close retires the current report session after reusing its view", function()
		scenario(function(ctx)
			local owners = fake_owners(function(channel) return { state = "error", channel = channel, detail = "HTTP 503", others = {} } end)
			local view, native_options = fake_view(), nil
			hs.webview.windowMasks = { titled = 1, closable = 2 }
			local builder = package.loaded["ui.ui_builder"]
			builder.get_app_geometry = function() return { width = 500, height = 500 } end
			builder.get_centered_frame = function() return {} end
			builder.show_webview = function(options)
				native_options = options
				options.on_webview_created(view)
				return view
			end
			helpers.assert_true(ctx.Host.open(owners))
			local first = ctx.Host._session()
			helpers.assert_true(ctx.Host.open(owners))
			local second = ctx.Host._session()
			helpers.assert_true(second ~= first)
			local complete, current, cancelled
			package.loaded["ui.error_dialog"].report = function(_, callback, predicate)
				complete, current = callback, predicate
				return { cancel = function() cancelled = true end }
			end
			second.on_message({ action = "report" })
			native_options.on_close()
			helpers.assert_true(cancelled, "native close cancels the report of the reused view's current session")
			helpers.assert_eq(current(), false)
			local messages = #view.messages
			complete(true)
			helpers.assert_eq(#view.messages, messages)
			helpers.assert_nil(ctx.Host._session())
		end)
	end)

	helpers.it("reopening from cancelled report retains the newly published session", function()
		scenario(function(ctx)
			local owners = fake_owners(function(channel) return { state = "error", channel = channel, detail = "HTTP 503", others = {} } end)
			local view = fake_view()
			local session = ctx.Host._session_for(view, owners)
			ctx.Host._set_window(view, session)
			session.start()
			local replacement, reentered
			package.loaded["ui.error_dialog"].report = function()
				return { cancel = function()
					if not reentered then
						reentered = true
						ctx.Host.open(owners)
						replacement = ctx.Host._session()
					end
				end }
			end
			session.on_message({ action = "report" })
			ctx.Host.open(owners)
			helpers.assert_true(replacement ~= nil and replacement ~= session)
			helpers.assert_true(ctx.Host._session() == replacement, "outer retirement cannot overwrite the reentrant session")
		end)
	end)
end)
