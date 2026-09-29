--- macos/tests/unit/modules/updater/test_update_check_session.lua

--- ==============================================================================
--- MODULE: Update Check Window Session (shared Lua, macOS suite)
--- DESCRIPTION:
--- The session behind the shared update-check window (_shared/lua/updater/
--- check_session.lua), run over recording ports: it shows "checking" for the
--- subscribed channel, then the answer; Update installs only the release the
--- answer offered; a switch goes only to a channel the answer listed and checks
--- that channel at once; a superseded answer is inert; a failure's Report and
--- log actions reach their ports; unknown messages are refused.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_session()
	package.loaded["updater.check_session"] = nil
	return require("updater.check_session")
end

--- Builds a session over recording ports. ctx: session, pushed, checks,
--- installs, switches, closes, logs, reports, opened, changelogs.
local function build(opts)
	opts = opts or {}
	local ctx = {
		pushed = {}, checks = {}, installs = {}, switches = {}, closes = 0, logs = {}, reports = {},
		opened = 0, changelogs = {}, channel = opts.channel or "dev",
	}
	ctx.session = load_session().new({
		push = function(message) ctx.pushed[#ctx.pushed + 1] = message; return true end,
		check = function(channel, on_result)
			if opts.check_throws then error("transport unavailable") end
			ctx.checks[#ctx.checks + 1] = { channel = channel, answer = on_result }
			return opts.check_refused ~= true
		end,
		channel = function() return ctx.channel end,
		current = function() return "v0.0.0-dev.144" end,
		set_channel = function(id)
			ctx.switches[#ctx.switches + 1] = id
			if opts.switch_refused then return false end
			ctx.channel = id
			return true
		end,
		install = function(result) ctx.installs[#ctx.installs + 1] = result.latest; return opts.install_refused ~= true end,
		open_changelog = function(channel) ctx.changelogs[#ctx.changelogs + 1] = channel; return true end,
		report = function(result) ctx.reports[#ctx.reports + 1] = result; return true end,
		open_log = function() ctx.opened = ctx.opened + 1; return false, true end,
		close = function() ctx.closes = ctx.closes + 1 end,
		log_path = function()
			if opts.log_path_throws then error("no log sink") end
			return "/logs/ErgoptiPlus_2026-09-29.log"
		end,
		log = function(level, message, ...) ctx.logs[#ctx.logs + 1] = { level = level, text = string.format(message, ...) } end,
	})
	return ctx
end

local function last(ctx) return ctx.pushed[#ctx.pushed] end

local AVAILABLE = {
	state = "available", channel = "dev", current = "v0.0.0-dev.144", latest = "v0.0.0-dev.150",
	others = { { channel = "main", tag = "v1.0.0" } },
}

helpers.describe("updater.check_session: the update-check window's session", function()
	helpers.it("shows checking for the subscribed channel, then the answer", function()
		local ctx = build()
		helpers.assert_true(ctx.session.start())
		helpers.assert_eq(last(ctx).state, "checking")
		helpers.assert_eq(last(ctx).channel, "dev")
		helpers.assert_eq(last(ctx).current, "v0.0.0-dev.144")
		helpers.assert_eq(ctx.checks[1].channel, "dev", "the subscribed channel is checked")
		ctx.checks[1].answer(AVAILABLE)
		helpers.assert_eq(last(ctx).type, "state")
		helpers.assert_eq(last(ctx).state, "available")
		helpers.assert_eq(last(ctx).latest, "v0.0.0-dev.150")
		helpers.assert_eq(last(ctx).others, AVAILABLE.others)
		ctx.session.on_message("ready")
		helpers.assert_eq(last(ctx).state, "available", "a page that loads late receives the answer")
	end)

	helpers.it("installs only the offered release, then closes", function()
		local ctx = build()
		ctx.session.start()
		ctx.session.on_message({ action = "update" })
		helpers.assert_eq(#ctx.installs, 0, "nothing installs while checking")
		helpers.assert_eq(last(ctx).type, "action")
		helpers.assert_eq(last(ctx).ok, false)
		ctx.checks[1].answer(AVAILABLE)
		ctx.session.on_message({ action = "update" })
		helpers.assert_eq(ctx.installs, { "v0.0.0-dev.150" })
		helpers.assert_eq(ctx.closes, 1, "the window closes once the installer has it")
	end)

	helpers.it("keeps the window and says so when the installer refuses", function()
		local ctx = build({ install_refused = true })
		ctx.session.start()
		ctx.checks[1].answer(AVAILABLE)
		ctx.session.on_message({ action = "update" })
		helpers.assert_eq(ctx.closes, 0)
		helpers.assert_eq(last(ctx), { type = "action", action = "update", ok = false, missing = false })
	end)

	helpers.it("refuses Update when the answer is up to date", function()
		local ctx = build()
		ctx.session.start()
		ctx.checks[1].answer({ state = "up_to_date", channel = "dev", current = "v0.0.0-dev.144",
			latest = "v0.0.0-dev.144", others = {} })
		ctx.session.on_message({ action = "update" })
		helpers.assert_eq(#ctx.installs, 0)
	end)

	helpers.it("switches only to a listed channel, then checks it at once", function()
		local ctx = build()
		ctx.session.start()
		ctx.checks[1].answer(AVAILABLE)
		ctx.session.on_message({ action = "switch_channel", channel = "beta" })
		helpers.assert_eq(#ctx.switches, 0, "an unlisted channel is refused")
		ctx.session.on_message({ action = "switch_channel", channel = "main" })
		helpers.assert_eq(ctx.switches, { "main" })
		helpers.assert_eq(#ctx.checks, 2, "the new channel is checked")
		helpers.assert_eq(ctx.checks[2].channel, "main")
		helpers.assert_eq(last(ctx).state, "checking")
		helpers.assert_eq(last(ctx).channel, "main")
	end)

	helpers.it("keeps the answer when the channel owner refuses a switch", function()
		local ctx = build({ switch_refused = true })
		ctx.session.start()
		ctx.checks[1].answer(AVAILABLE)
		ctx.session.on_message({ action = "switch_channel", channel = "main" })
		helpers.assert_eq(#ctx.checks, 1, "no check of a channel that was not saved")
		helpers.assert_eq(last(ctx).ok, false)
		helpers.assert_eq(ctx.session.result().state, "available")
	end)

	helpers.it("ignores the answer of a superseded check", function()
		local ctx = build()
		ctx.session.start()
		ctx.session.start()
		ctx.checks[1].answer(AVAILABLE)
		helpers.assert_eq(last(ctx).state, "checking", "the older answer does not replace the new check")
		ctx.checks[2].answer({ state = "no_release", channel = "dev", current = "v0.0.0-dev.144", others = {} })
		helpers.assert_eq(last(ctx).state, "no_release")
	end)

	helpers.it("shows a failure with today's log, and serves Report and the log", function()
		local ctx = build()
		ctx.session.start()
		ctx.checks[1].answer({ state = "error", channel = "dev", current = "v0.0.0-dev.144", others = {},
			reason_key = "updater.no_connection", detail = "timed out" })
		helpers.assert_eq(last(ctx).reason_key, "updater.no_connection")
		helpers.assert_eq(last(ctx).log_path, "/logs/ErgoptiPlus_2026-09-29.log")
		ctx.session.on_message({ action = "report" })
		helpers.assert_eq(#ctx.reports, 1)
		helpers.assert_eq(ctx.reports[1].detail, "timed out", "the report carries the cause")
		helpers.assert_eq(last(ctx), { type = "action", action = "report", ok = true, missing = false })
		ctx.session.on_message({ action = "open_log" })
		helpers.assert_eq(ctx.opened, 1)
		helpers.assert_eq(last(ctx), { type = "action", action = "open_log", ok = false, missing = true })
	end)

	helpers.it("logs why a failure shows no log path", function()
		local ctx = build({ log_path_throws = true })
		ctx.session.start()
		ctx.checks[1].answer({ state = "error", channel = "dev", current = "v0.0.0-dev.144", others = {},
			reason_key = "updater.no_connection", detail = "timed out" })
		helpers.assert_eq(last(ctx).state, "error", "the failure is still shown")
		helpers.assert_eq(last(ctx).log_path, "", "the page hides the log it cannot name")
		local logged = false
		for _, entry in ipairs(ctx.logs) do
			if entry.level == "error" and entry.text:find("log path is unavailable", 1, true) then logged = true end
		end
		helpers.assert_true(logged, "the log says why the log line is missing")
	end)

	helpers.it("turns a refused or raising check into a visible failure", function()
		local refused = build({ check_refused = true })
		helpers.assert_eq(refused.session.start(), false)
		helpers.assert_eq(last(refused).state, "error")
		helpers.assert_eq(last(refused).reason_key, "update_check.error_unexpected")
		local raising = build({ check_throws = true })
		raising.session.start()
		helpers.assert_eq(last(raising).state, "error")
	end)

	helpers.it("refuses messages that are not its actions, and opens What's new on an offer", function()
		local ctx = build()
		ctx.session.start()
		ctx.session.on_message({ action = "run", command = "rm" })
		ctx.session.on_message(42)
		helpers.assert_eq(#ctx.pushed, 1, "a refused message changes nothing")
		ctx.checks[1].answer(AVAILABLE)
		ctx.session.on_message({ action = "whats_new" })
		helpers.assert_eq(ctx.changelogs, { "dev" })
		ctx.session.on_message({ action = "close" })
		helpers.assert_eq(ctx.closes, 1)
	end)

	helpers.it("a retired session shows and does nothing more", function()
		local ctx = build()
		ctx.session.start()
		local pushed = #ctx.pushed
		ctx.session.retire()
		ctx.checks[1].answer(AVAILABLE)
		ctx.session.on_message("ready")
		ctx.session.on_message({ action = "close" })
		helpers.assert_eq(#ctx.pushed, pushed, "a late answer of a retired session is not shown")
		helpers.assert_eq(ctx.closes, 0, "a retired session's page acts on nothing")
		helpers.assert_eq(ctx.session.start(), false, "a retired session starts no check")
		helpers.assert_eq(#ctx.checks, 1)
	end)

	helpers.it("refuses to start without every port", function()
		local ok = pcall(load_session().new, { push = function() return true end })
		helpers.assert_eq(ok, false, "a missing port is an error, not a silent no-op")
	end)
end)
