--- macos/tests/unit/modules/updater/test_update_auto_check.lua

--- ==============================================================================
--- MODULE: Automatic Update Checks (macOS)
--- DESCRIPTION:
--- The Lua driver owns the automatic-check cadence and the check; Sparkle only
--- installs when the user asks. Sparkle's scheduler ran once a day whatever the
--- menu said (the menu had no frequency at all), could not follow a preset
--- under an hour, and its checks ignored the pause.
---
--- The owner runs over injected ports — a recording timer, a fake Storage port,
--- a scripted HTTP transport and a clock — so every case is deterministic and
--- no request leaves the machine.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

local SEED = "7f3a9c21e5b04d68"
local T0 = 1700000000
local URL = "https://api.github.com/repos/adrienm7/ergopti/releases?per_page=100"
local FEED_URL = "https://github.com/adrienm7/ergopti/releases.atom"

local function read_defaults()
	local handle = assert(io.open(helpers.shared("updater/data/defaults.json"), "rb"))
	local decoded = Json.decode(handle:read("*a"))
	handle:close()
	return decoded
end

local function load_module()
	package.loaded["modules.updater.auto_check"] = nil
	return require("modules.updater.auto_check")
end

local LIST = '[{"tag_name":"v0.0.0-dev.150","prerelease":true,"published_at":"2026-09-02T00:00:00Z","assets":[]},'
	.. '{"tag_name":"v0.0.0-dev.149","prerelease":true,"published_at":"2026-09-01T00:00:00Z","assets":[]}]'

--- Builds an owner over recording ports. ctx: owner, timers, requests,
--- storage (values), clock, announced, state, saves.
local function build(opts)
	local AutoCheck = load_module()
	local defaults = read_defaults()
	local ctx = {
		timers = {}, requests = {}, values = {}, clock = { now = opts.now }, announced = {},
		state = opts.state or {}, saves = 0, paused = opts.paused == true, responses = opts.responses or {},
		channel = "dev", pending = {},
	}
	ctx.state_key = defaults.check_state.storage_key
	ctx.list_key = defaults.check_state.list_storage_key
	if opts.record then ctx.values[ctx.state_key] = opts.record end
	if opts.list_copy then ctx.values[ctx.list_key] = opts.list_copy end
	ctx.timing = defaults.timing
	local function transport()
		return {
			get = function(url, headers, callback)
				ctx.requests[#ctx.requests + 1] = { url = url, headers = headers }
				if opts.http_throw then error("transport refused") end
				if opts.defer then ctx.pending[#ctx.pending + 1] = callback; return true end
				local response = table.remove(ctx.responses, 1)
				callback(response)
				return true
			end,
		}
	end
	ctx.owner = AutoCheck.new({
		state = ctx.state,
		save = function() ctx.saves = ctx.saves + 1; return opts.save_refused ~= true end,
		channel = function() return ctx.channel end,
		is_paused = function()
			if opts.pause_error then error("pause state unavailable") end
			if opts.pause_unknown then return nil end
			return ctx.paused
		end,
		on_available = function(release)
			ctx.announced[#ctx.announced + 1] = release.tag
			if ctx.notification_hook then ctx.notification_hook() end
			if ctx.notification_refusal == "throw" then error("notification unavailable") end
			return ctx.notification_refusal ~= "false"
		end,
		config = {
			timing = defaults.timing, state_key = ctx.state_key, list_key = ctx.list_key, releases_url = URL,
			feed_url = FEED_URL, timeout_sec = 15,
		},
		timer = {
			after = function(delay, fn)
				if opts.timer_refused == true then return nil, false end
				local handle = { delay = delay, fn = fn, armed = true }
				ctx.timers[#ctx.timers + 1] = handle
				return handle, opts.timer_refused ~= "live"
			end,
			cancel = function(handle)
				if opts.cancel_refused then return false end
				handle.armed = false
				return true
			end,
		},
		storage = {
			get = function(key, default)
				if key == ctx.state_key and ctx.record_read_error then return default end
				local v = ctx.values[key]; if v == nil then return default end; return v
			end,
			read_exact = function(key)
				if key == ctx.state_key and ctx.record_read_error then return false, nil end
				return true, ctx.values[key]
			end,
			set = function(key, value) ctx.values[key] = value; return true end,
		},
		http = transport(), manual_http = transport(),
		now = function() return ctx.clock.now end,
		current_version = function() return "0.0.0-dev.140" end,
		installed_channel = function() return "dev" end,
	})
	return ctx
end

local function last_timer(ctx) return ctx.timers[#ctx.timers] end

local function fire(ctx)
	local handle = last_timer(ctx)
	helpers.assert_true(handle ~= nil and handle.armed, "a timer must be armed")
	handle.armed = false
	handle.fn()
end

helpers.describe("updater.auto_check (macOS): Lua owns the cadence and the check", function()
	helpers.it("refuses a storage port without exact-read capability", function()
		local ok, err = pcall(load_module().new, {
			state = {}, save = function() end, channel = function() end, is_paused = function() end,
			on_available = function() end, timer = {}, storage = { get = function() end },
			http = {}, manual_http = {}, now = function() end,
		})
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(err):find("exact storage read", 1, true) ~= nil)
	end)
	helpers.it("retains the stored check record across an unavailable read", function()
		local original = { seed = SEED, last_check_at = T0 - 120, last_notified_tag = "v0.0.0-dev.150" }
		local ctx = build({ now = T0, record = original, defer = true })
		ctx.record_read_error = true
		helpers.assert_true(ctx.owner.start())
		helpers.assert_eq(ctx.values[ctx.state_key], original, "an unavailable read cannot overwrite stored state")
		helpers.assert_eq(#ctx.requests, 0)
		ctx.record_read_error = false
		ctx.clock.now = ctx.clock.now + ctx.timing.reevaluate_sec
		fire(ctx)
		helpers.assert_eq(ctx.values[ctx.state_key], original)
		helpers.assert_eq(#ctx.requests, 0, "the recovered record still controls the schedule")
	end)
	helpers.it("restarts the boot delay if the wall clock moves behind startup", function()
		local ctx = build({ now = T0, record = { seed = SEED }, defer = true })
		helpers.assert_true(ctx.owner.start())
		ctx.clock.now = T0 - 86400
		fire(ctx)
		helpers.assert_eq(last_timer(ctx).delay, ctx.timing.boot_check_delay_sec)
		ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
		fire(ctx)
		helpers.assert_eq(#ctx.requests, 1, "the check resumes without waiting for the old wall clock")
	end)
	helpers.it("does not check automatically while pause state is unknown", function()
		for _, mode in ipairs({ "pause_error", "pause_unknown" }) do
			local options = { now = T0, record = { seed = SEED }, defer = true }
			options[mode] = true
			local ctx = build(options)
			helpers.assert_true(ctx.owner.start())
			ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
			fire(ctx)
			helpers.assert_eq(#ctx.requests, 0, "unknown pause state must not dispatch")
			helpers.assert_nil(ctx.values[ctx.state_key].last_check_at)
			helpers.assert_true(last_timer(ctx).armed, "pause read failures remain retryable")
			options[mode] = false
			ctx.clock.now = ctx.clock.now + ctx.timing.reevaluate_sec
			fire(ctx)
			helpers.assert_eq(#ctx.requests, 1, "the check resumes after pause state recovers")
		end
	end)
	helpers.it("a retired timer cannot replace the current timer (updater-owner-boundary)", function()
		local ctx = build({ now = T0, record = { seed = SEED }, defer = true })
		helpers.assert_true(ctx.owner.start())
		local retired = last_timer(ctx)
		helpers.assert_true(ctx.owner.stop())
		helpers.assert_true(ctx.owner.start())
		local current = last_timer(ctx)
		retired.fn()
		helpers.assert_eq(#ctx.timers, 2, "a retired callback must not arm a replacement")
		helpers.assert_true(ctx.owner.stop())
		helpers.assert_eq(current.armed, false, "stop must release the current timer")
	end)

	helpers.it("duplicate completions cannot rewrite a recorded check (updater-owner-boundary)", function()
		local ctx = build({ now = T0, record = { seed = SEED }, defer = true })
		helpers.assert_true(ctx.owner.start())
		ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
		fire(ctx)
		ctx.pending[1]({ ok = true, status = 200, body = LIST, headers = {} })
		ctx.pending[1]({ ok = false, status = 0, error = "late failure" })
		helpers.assert_eq(ctx.values[ctx.state_key].failures, 0, "one request has one terminal result")
		helpers.assert_eq(ctx.owner.latest().tag, "v0.0.0-dev.150")
	end)

	helpers.it("transport exceptions are recorded and allow a retry (updater-owner-boundary)", function()
		local opts = { now = T0, record = { seed = SEED }, http_throw = true, defer = true }
		local ctx = build(opts)
		helpers.assert_true(ctx.owner.start())
		ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
		local ok, err = pcall(fire, ctx)
		helpers.assert_true(ok, "transport failure must stay inside its owner: " .. tostring(err))
		helpers.assert_eq(ctx.values[ctx.state_key].failures, 1)
		opts.http_throw = false
		ctx.clock.now = ctx.clock.now + 2 * 86400
		ctx.owner._evaluate()
		helpers.assert_eq(#ctx.requests, 2, "a thrown dispatch must release the in-flight slot")
	end)

	helpers.it("a refused live timer remains owned until cleanup succeeds", function()
		local opts = { now = T0, record = { seed = SEED }, timer_refused = "live", cancel_refused = true }
		local ctx = build(opts)
		helpers.assert_eq(ctx.owner.start(), false)
		helpers.assert_true(last_timer(ctx).armed)
		helpers.assert_eq(ctx.owner.stop(), false, "refused cleanup must remain visible")
		opts.cancel_refused = false
		helpers.assert_true(ctx.owner.stop())
		helpers.assert_eq(last_timer(ctx).armed, false, "the retained timer must be released on retry")
	end)

	helpers.it("a refused timer leaves no active schedule", function()
		local ctx = build({ now = T0, record = { seed = SEED }, timer_refused = true })
		helpers.assert_eq(ctx.owner.start(), false, "start must report failed timer admission")
		ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
		ctx.owner._evaluate()
		helpers.assert_eq(#ctx.requests, 0, "a failed start must revoke evaluation")
	end)

	helpers.it("a stopped session cannot complete into its restarted owner", function()
		local ctx = build({ now = T0, record = { seed = SEED }, defer = true })
		helpers.assert_true(ctx.owner.start())
		ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
		fire(ctx)
		helpers.assert_eq(#ctx.pending, 1)
		helpers.assert_true(ctx.owner.stop())
		helpers.assert_true(ctx.owner.start())
		ctx.pending[1]({ ok = true, status = 200, body = LIST, headers = {} })
		helpers.assert_eq(#ctx.announced, 0, "an old session cannot announce into a new session")
		helpers.assert_nil(ctx.values[ctx.state_key].last_check_at)
	end)

	helpers.it("a channel change discards the previous in-flight offer", function()
		local ctx = build({ now = T0, record = { seed = SEED }, defer = true })
		helpers.assert_true(ctx.owner.start())
		ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
		fire(ctx)
		helpers.assert_eq(#ctx.pending, 1)
		ctx.channel = "main"
		ctx.pending[1]({ ok = true, status = 200, body = LIST, headers = {} })
		helpers.assert_eq(#ctx.announced, 0, "the abandoned channel cannot announce")
		helpers.assert_nil(ctx.owner.latest())
		helpers.assert_nil(ctx.values[ctx.state_key].last_check_at)
	end)

	helpers.it("malformed successful responses use failure backoff", function()
		for _, body in ipairs({ "[", '[{"tag_name":', '[{},]', '[{}]' }) do
			local ctx = build({ now = T0, record = { seed = SEED },
				responses = { { ok = true, status = 200, body = body, headers = {} } } })
			helpers.assert_true(ctx.owner.start())
			ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
			fire(ctx)
			helpers.assert_eq(ctx.values[ctx.state_key].failures, 1, "invalid JSON is a failed check")
			helpers.assert_nil(ctx.values[ctx.state_key].last_success_at)
		end
	end)

	helpers.it("channel changes revoke an old response even after returning to that channel", function()
		local ctx = build({ now = T0, record = { seed = SEED }, defer = true })
		helpers.assert_true(ctx.owner.start())
		ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
		fire(ctx)
		ctx.channel = "main"
		ctx.owner.on_channel_changed()
		ctx.channel = "dev"
		ctx.owner.on_channel_changed()
		ctx.pending[1]({ ok = true, status = 200, body = LIST, headers = {} })
		helpers.assert_eq(#ctx.announced, 0)
		helpers.assert_nil(ctx.values[ctx.state_key].last_check_at)
		ctx.pending[#ctx.pending]({ ok = true, status = 200, body = LIST, headers = {} })
		helpers.assert_eq(#ctx.announced, 1, "the current generation still publishes")
	end)

	helpers.it("does not save an old notification after its callback changes channel", function()
		local ctx = build({ now = T0, record = { seed = SEED }, defer = true })
		helpers.assert_true(ctx.owner.start())
		ctx.notification_hook = function()
			ctx.channel = "main"
			ctx.owner.on_channel_changed()
		end
		ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
		fire(ctx)
		ctx.pending[1]({ ok = true, status = 200, body = LIST, headers = {} })
		helpers.assert_nil(ctx.values[ctx.state_key].last_notified_tag,
			"the retired channel cannot save a notification after reentry")
		helpers.assert_nil(ctx.owner.latest())
	end)

	helpers.it("notification refusal leaves the release retryable", function()
		for _, refusal in ipairs({ "false", "throw" }) do
			local response = { ok = true, status = 200, body = LIST, headers = {} }
			local ctx = build({ now = T0, record = { seed = SEED }, responses = { response, response } })
			ctx.notification_refusal = refusal
			helpers.assert_true(ctx.owner.start())
			ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
			fire(ctx)
			helpers.assert_eq(#ctx.announced, 1, "the refusal must occur at the notification boundary")
			helpers.assert_nil(ctx.values[ctx.state_key].last_notified_tag,
				"a refused notification must not consume the release: " .. refusal)
			ctx.notification_refusal = nil
			ctx.clock.now = ctx.clock.now + 2 * 86400
			ctx.owner.on_wake()
			ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
			fire(ctx)
			helpers.assert_eq(#ctx.announced, 2, "the next successful check must retry the announcement")
			helpers.assert_eq(ctx.values[ctx.state_key].last_notified_tag, "v0.0.0-dev.150")
		end
	end)

	helpers.it("a restart mid-interval does not check at boot", function()
		local ctx = build({ now = T0 + 3600, record = { seed = SEED, last_check_at = T0, failures = 0 } })
		helpers.assert_true(ctx.owner.start())
		helpers.assert_eq(last_timer(ctx).delay, ctx.timing.reevaluate_sec,
			"a far due time is re-evaluated after the bounded period")
		ctx.clock.now = ctx.clock.now + ctx.timing.reevaluate_sec
		fire(ctx)
		helpers.assert_eq(#ctx.requests, 0, "a check done an hour ago is not due")
	end)

	helpers.it("an overdue check catches up, reads the registry and announces once", function()
		local ctx = build({
			now = T0 + 10 * 86400,
			record = { seed = SEED, last_check_at = T0, failures = 0 },
			responses = {
				{ ok = true, status = 200, body = LIST, headers = { ETag = 'W/"abc"' } },
				{ ok = false, status = 304, body = "", headers = {}, error = "HTTP 304" },
			},
		})
		helpers.assert_true(ctx.owner.start())
		helpers.assert_eq(last_timer(ctx).delay, ctx.timing.boot_check_delay_sec, "the boot delay comes first")
		ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
		fire(ctx)
		helpers.assert_eq(#ctx.requests, 1, "the overdue check is sent")
		helpers.assert_eq(ctx.requests[1].url, URL, "the shared release list")
		helpers.assert_nil(ctx.requests[1].headers["If-None-Match"], "a session without the list sends a full request")
		helpers.assert_eq(ctx.announced, { "v0.0.0-dev.150" }, "the dev channel's latest release is announced")
		helpers.assert_eq(ctx.owner.latest().tag, "v0.0.0-dev.150", "and offered by the About row")
		local saved = ctx.values[ctx.state_key]
		helpers.assert_eq(saved.last_check_at, ctx.clock.now)
		helpers.assert_eq(saved.failures, 0)
		helpers.assert_eq(saved.last_notified_tag, "v0.0.0-dev.150", "the announcement is persisted")

		ctx.clock.now = ctx.clock.now + 2 * 86400
		ctx.owner.on_wake()
		ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
		fire(ctx)
		helpers.assert_eq(#ctx.requests, 2, "the next check is sent")
		helpers.assert_eq(ctx.requests[2].headers["If-None-Match"], 'W/"abc"', "the second request is conditional")
		helpers.assert_eq(ctx.owner.latest().tag, "v0.0.0-dev.150", "a 304 keeps the release this session read")
		helpers.assert_eq(#ctx.announced, 1, "a release is announced once")
	end)

	helpers.it("a paused driver sends nothing and leaves the record", function()
		local ctx = build({ now = T0, paused = true, record = { seed = SEED, last_check_at = T0 - 3 * 86400 } })
		helpers.assert_true(ctx.owner.start())
		ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
		fire(ctx)
		helpers.assert_eq(#ctx.requests, 0, "the pause holds the due check")
		helpers.assert_eq(ctx.values[ctx.state_key].last_check_at, T0 - 3 * 86400, "the record is left as it is")
		helpers.assert_true(last_timer(ctx).armed, "the schedule survives the pause")
		ctx.paused = false
		ctx.clock.now = ctx.clock.now + ctx.timing.reevaluate_sec
		ctx.responses[1] = { ok = true, status = 200, body = "[]", headers = {} }
		fire(ctx)
		helpers.assert_eq(#ctx.requests, 1, "the check runs at the first evaluation after the pause")
	end)

	helpers.it("a failed check retries on the shared backoff", function()
		local ctx = build({
			now = T0, record = { seed = SEED },
			responses = { { ok = false, status = 0, body = "", error = "Network request failed" } },
		})
		helpers.assert_true(ctx.owner.start())
		ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
		fire(ctx)
		local saved = ctx.values[ctx.state_key]
		helpers.assert_eq(saved.failures, 1, "the failure is counted")
		helpers.assert_nil(saved.last_success_at)
		helpers.assert_eq(#ctx.announced, 0)
	end)

	helpers.it("the interval is the persisted preference snapped to a preset", function()
		local ctx = build({ now = T0, state = { update_check_interval_seconds = 7200 } })
		helpers.assert_eq(ctx.owner.interval(), 3600, "a retired 2 hours reads as 1 hour")
		helpers.assert_eq(ctx.owner.interval_code(), "1h")
		helpers.assert_true(ctx.owner.set_interval(21600))
		helpers.assert_eq(ctx.state.update_check_interval_seconds, 21600, "the choice is in the preferences state")
		helpers.assert_eq(ctx.saves, 1, "through the preferences transaction")
		helpers.assert_eq(ctx.owner.set_interval(7200), false, "a value outside the presets is refused")
		local fresh = build({ now = T0 })
		helpers.assert_eq(fresh.owner.interval(), fresh.timing.default_check_interval_sec, "absent: the shared default")
	end)

	helpers.it("uses the default for an infinite saved interval", function()
		local ctx = build({ now = T0, state = { update_check_interval_seconds = math.huge } })
		helpers.assert_eq(ctx.owner.interval(), ctx.timing.default_check_interval_sec)
	end)

	helpers.it("a refused save keeps the previous interval", function()
		local ctx = build({ now = T0, state = { update_check_interval_seconds = 3600 }, save_refused = true })
		helpers.assert_eq(ctx.owner.set_interval(86400), false)
		helpers.assert_eq(ctx.state.update_check_interval_seconds, 3600)
	end)

	helpers.it("a menu session wires the production ports and a wake watcher", function()
		local native = { started = 0, stopped = 0 }
		for _, name in ipairs({ "adapters.wake_watcher", "adapters.http_client", "adapters.storage",
			"adapters.timer_scheduler" }) do
			package.loaded[name] = nil
		end
		local AutoCheck = helpers.load_with_stubs("modules.updater.auto_check", {
			caffeinate = {
				watcher = {
					systemDidWake = 1,
					new = function()
						local object = {}
						function object:start() native.started = native.started + 1; return self end
						function object:stop() native.stopped = native.stopped + 1; return self end
						return object
					end,
				},
			},
		})
		local owner = AutoCheck.start_session({
			-- Never: the session starts without arming a timer or sending a request.
			state = { update_check_interval_seconds = 0 },
			save = function() return true end,
			channel = function() return "dev" end,
			is_paused = function() return false end,
			on_available = function() end,
		})
		helpers.assert_eq(native.started, 1, "the session watches for wakes")
		helpers.assert_eq(owner.interval(), 0)
		owner.on_wake()
		helpers.assert_true(owner.stop(), "the session stops cleanly")
		helpers.assert_eq(native.stopped, 1, "stopping the session stops the wake watcher")
		package.loaded["modules.updater.auto_check"] = nil
	end)

	helpers.it("retains failed startup cleanup until the next session retries it", function()
		local AutoCheck = load_module()
		local old_new, old_config = AutoCheck.new, AutoCheck.load_config
		local created, first_stops = 0, 0
		local ok, err = pcall(function()
			helpers.with_stub_scope({ "adapters.wake_watcher", "adapters.http_client", "adapters.storage",
				"adapters.timer_scheduler" }, function()
				package.loaded["adapters.wake_watcher"] = { new = function() return {
					start = function() return true end, stop = function() return true end,
				} end }
				package.loaded["adapters.http_client"] = { new = function() return {} end }
				package.loaded["adapters.storage"] = {}
				package.loaded["adapters.timer_scheduler"] = {}
				AutoCheck.load_config = function() return { timeout_sec = 1 } end
				AutoCheck.new = function()
					created = created + 1
					local id = created
					return {
						on_wake = function() end,
						start = function() return id ~= 1 end,
						stop = function()
							if id == 1 then first_stops = first_stops + 1; return first_stops > 2 end
							return true
						end,
					}
				end
				local started = pcall(AutoCheck.start_session, {})
				helpers.assert_eq(started, false)
				helpers.assert_eq(first_stops, 1)
				helpers.assert_eq(pcall(AutoCheck.start_session, {}), false, "unreleased cleanup blocks a successor")
				helpers.assert_eq(created, 1)
				local owner = AutoCheck.start_session({})
				helpers.assert_eq(first_stops, 3, "the previous owner is retried before its successor")
				helpers.assert_true(owner.stop())
			end)
		end)
		AutoCheck.new, AutoCheck.load_config = old_new, old_config
		if not ok then error(err, 0) end
	end)

	-- Windows opens its update prompt from the balloon; here a click on the
	-- notification asks Sparkle for the found release on its channel.
	helpers.it("announces a release with a click that asks Sparkle for it", function()
		local sent, checks = {}, {}
		local previous = {
			notifications = package.loaded["infra.notifications"],
			launcher = package.loaded["adapters.update_launcher"],
		}
		package.loaded["infra.notifications"] = {
			notify = function(title, body, kind, on_click)
				sent[#sent + 1] = { title = title, body = body, kind = kind, on_click = on_click }
				return true
			end,
		}
		package.loaded["adapters.update_launcher"] = {
			request_check = function(channel) checks[#checks + 1] = channel; return true end,
		}
		local ok, err = pcall(function()
			local AutoCheck = load_module()
			helpers.assert_true(AutoCheck.announce({ tag = "v0.0.0-dev.150%", channel = "dev" }))
			helpers.assert_eq(#sent, 1, "one notification")
			helpers.assert_true(sent[1].body:find("v0.0.0-dev.150%", 1, true) ~= nil,
				"the body names the release, a % included")
			-- Notify only: Sparkle hears of the release on the click, never before.
			helpers.assert_eq(#checks, 0, "nothing asks Sparkle for the release before the click")
			sent[1].on_click()
			helpers.assert_eq(checks, { "dev" }, "the click asks Sparkle for the release's channel")
		end)
		package.loaded["infra.notifications"] = previous.notifications
		package.loaded["adapters.update_launcher"] = previous.launcher
		package.loaded["modules.updater.auto_check"] = nil
		if not ok then error(err, 0) end
	end)

	helpers.it("never is never checked", function()
		local ctx = build({ now = T0, state = { update_check_interval_seconds = 0 }, record = { seed = SEED } })
		helpers.assert_true(ctx.owner.start())
		helpers.assert_eq(#ctx.timers, 0, "no timer is armed when checks are off")
	end)
end)

-- A list where the installed dev.140 is listed, dev.150 is newer on its own
-- channel and a stable release was published after the installed build.
local MIXED = '[{"tag_name":"v1.0.0","prerelease":false,"published_at":"2026-09-03T00:00:00Z","assets":[]},'
	.. '{"tag_name":"v0.0.0-dev.150","prerelease":true,"published_at":"2026-09-02T00:00:00Z","assets":[]},'
	.. '{"tag_name":"v0.0.0-dev.140","prerelease":true,"published_at":"2026-08-01T00:00:00Z","assets":[]}]'

local UP_TO_DATE = '[{"tag_name":"v0.0.0-dev.140","prerelease":true,"published_at":"2026-08-01T00:00:00Z","assets":[]},'
	.. '{"tag_name":"v0.0.0-dev.139","prerelease":true,"published_at":"2026-07-31T00:00:00Z","assets":[]}]'

--- Runs one manual check and returns its answers.
local function check_now(ctx, channel)
	local answers = {}
	local dispatched = ctx.owner.check_now(channel, function(result) answers[#answers + 1] = result end)
	return answers, dispatched
end

helpers.describe("updater.auto_check (macOS): the manual check answers the update-check window", function()
	helpers.it("answers a manual check without overwriting an unreadable record", function()
		local original = { seed = SEED, last_check_at = T0 - 120, last_notified_tag = "v0.0.0-dev.149" }
		local ctx = build({ now = T0, record = original,
			responses = { { ok = true, status = 200, body = MIXED, headers = {} } } })
		ctx.record_read_error = true
		local answers = check_now(ctx, "dev")
		helpers.assert_eq(answers[1].latest, "v0.0.0-dev.150")
		helpers.assert_eq(ctx.values[ctx.state_key], original)
	end)
	helpers.it("a late automatic check cannot overwrite a newer manual check", function()
		local ctx = build({ now = T0, record = { seed = SEED }, defer = true })
		helpers.assert_true(ctx.owner.start())
		ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
		fire(ctx)
		local manual = check_now(ctx, "dev")
		ctx.pending[2]({ ok = true, status = 200, body = MIXED, headers = { etag = '"new"' } })
		helpers.assert_eq(manual[1].latest, "v0.0.0-dev.150")
		ctx.pending[1]({ ok = true, status = 200, body = UP_TO_DATE, headers = { etag = '"old"' } })
		helpers.assert_eq(ctx.owner.latest().tag, "v0.0.0-dev.150")
		helpers.assert_eq(ctx.values[ctx.list_key].etag, '"new"')
		helpers.assert_eq(#ctx.announced, 0)
	end)

	helpers.it("a late manual check cannot overwrite a newer automatic check", function()
		local ctx = build({ now = T0, record = { seed = SEED }, defer = true })
		helpers.assert_true(ctx.owner.start())
		local manual = check_now(ctx, "dev")
		ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
		fire(ctx)
		ctx.pending[2]({ ok = true, status = 200, body = MIXED, headers = { etag = '"new"' } })
		ctx.pending[1]({ ok = true, status = 200, body = UP_TO_DATE, headers = { etag = '"old"' } })
		helpers.assert_eq(manual[1].latest, "v0.0.0-dev.140")
		helpers.assert_eq(ctx.owner.latest().tag, "v0.0.0-dev.150")
		helpers.assert_eq(ctx.values[ctx.list_key].etag, '"new"')
	end)
	helpers.it("a late older manual check cannot replace the latest result", function()
		local ctx = build({ now = T0, record = { seed = SEED }, defer = true })
		local older = check_now(ctx, "dev")
		local newer = check_now(ctx, "dev")
		ctx.pending[2]({ ok = true, status = 200, body = MIXED, headers = { etag = '"new"' } })
		helpers.assert_eq(newer[1].latest, "v0.0.0-dev.150")
		ctx.pending[1]({ ok = true, status = 200, body = UP_TO_DATE, headers = { etag = '"old"' } })
		helpers.assert_eq(older[1].latest, "v0.0.0-dev.140", "the older window still gets its own answer")
		helpers.assert_eq(ctx.owner.latest().tag, "v0.0.0-dev.150", "the newer check owns the About row")
		helpers.assert_eq(ctx.values[ctx.list_key].etag, '"new"', "the older response cannot replace the list cache")
	end)
	helpers.it("a late older failure cannot replace a newer successful check record", function()
		local ctx = build({ now = T0, record = { seed = SEED }, defer = true })
		local older = check_now(ctx, "dev")
		check_now(ctx, "dev")
		ctx.pending[2]({ ok = true, status = 200, body = MIXED, headers = {} })
		ctx.pending[1]({ ok = true, status = 200, body = "[", headers = {} })
		helpers.assert_eq(older[1].reason_key, "updater.parse_failed")
		helpers.assert_eq(ctx.values[ctx.state_key].failures, 0)
		helpers.assert_eq(ctx.values[ctx.state_key].last_notified_tag, "v0.0.0-dev.150")
	end)
	helpers.it("pairs each 304 with the list used by its own request", function()
		local ctx = build({ now = T0, record = { seed = SEED }, defer = true,
			list_copy = { url = URL, etag = '"old"', body = UP_TO_DATE } })
		local first = check_now(ctx, "dev")
		local second = check_now(ctx, "dev")
		helpers.assert_eq(ctx.requests[1].headers["If-None-Match"], '"old"')
		ctx.pending[2]({ ok = true, status = 200, body = MIXED, headers = { etag = '"new"' } })
		helpers.assert_eq(second[1].latest, "v0.0.0-dev.150")
		ctx.pending[1]({ ok = false, status = 304, headers = {} })
		helpers.assert_eq(first[1].latest, "v0.0.0-dev.140", "304 answers only its own validator")
	end)
	helpers.it("does not answer an unconditional 304 from another request's cache", function()
		local ctx = build({ now = T0, record = { seed = SEED }, defer = true })
		local first = check_now(ctx, "dev")
		check_now(ctx, "dev")
		helpers.assert_nil(ctx.requests[1].headers["If-None-Match"])
		ctx.pending[2]({ ok = true, status = 200, body = MIXED, headers = { etag = '"new"' } })
		ctx.pending[1]({ ok = false, status = 304, headers = {} })
		helpers.assert_eq(#first, 0, "an unassociated 304 triggers fallback")
		helpers.assert_eq(ctx.requests[3].url, FEED_URL)
	end)
	helpers.it("ignores duplicate API callbacks while the fallback feed is pending", function()
		local ctx = build({ now = T0, record = { seed = SEED }, defer = true })
		local answers = check_now(ctx, "dev")
		ctx.pending[1]({ ok = false, status = 500, error = "HTTP 500" })
		helpers.assert_eq(#ctx.pending, 2)
		ctx.pending[1]({ ok = true, status = 200, body = MIXED, headers = {} })
		helpers.assert_eq(#answers, 0, "the first completion owns the pending fallback")
		ctx.pending[2]({ ok = false, status = 500, error = "HTTP 500" })
		helpers.assert_eq(#answers, 1)
		helpers.assert_eq(answers[1].reason_key, "updater.no_connection")
	end)

	helpers.it("offers a newer release of the checked channel without announcing it", function()
		local ctx = build({ now = T0, record = { seed = SEED },
			responses = { { ok = true, status = 200, body = MIXED, headers = {} } } })
		local answers, dispatched = check_now(ctx, "dev")
		helpers.assert_true(dispatched, "the manual check is dispatched")
		helpers.assert_eq(#answers, 1, "one answer")
		helpers.assert_eq(answers[1].state, "available")
		helpers.assert_eq(answers[1].latest, "v0.0.0-dev.150")
		helpers.assert_eq(answers[1].current, "0.0.0-dev.140")
		helpers.assert_eq(answers[1].channel, "dev")
		helpers.assert_eq(answers[1].others, { { channel = "main", tag = "v1.0.0" } },
			"the stable release published after the installed build is listed")
		helpers.assert_eq(ctx.owner.latest().tag, "v0.0.0-dev.150", "the About row names the offered release")
		helpers.assert_eq(#ctx.announced, 0, "the window shows it: no notification")
		local record = ctx.values[ctx.state_key]
		helpers.assert_eq(record.last_notified_tag, "v0.0.0-dev.150", "no later announcement of the same release")
		helpers.assert_eq(record.last_check_at, T0, "the manual check is recorded")
		helpers.assert_eq(record.failures, 0)
	end)

	helpers.it("leaves the About row to a channel switched to while the check ran", function()
		local ctx = build({ now = T0, record = { seed = SEED }, defer = true })
		local answers, dispatched = check_now(ctx, "dev")
		helpers.assert_true(dispatched)
		ctx.channel = "main"
		ctx.owner.on_channel_changed()
		ctx.pending[1]({ ok = true, status = 200, body = MIXED, headers = {} })
		helpers.assert_eq(answers[1].state, "available", "the window still gets its answer")
		helpers.assert_nil(ctx.owner.latest(), "the About row offers no release of the previous channel")
		helpers.assert_nil(ctx.values[ctx.state_key].last_notified_tag,
			"a release of the previous channel does not silence the new channel's announcement")
	end)

	helpers.it("does not republish a manual result after the channel changes away and back", function()
		local ctx = build({ now = T0, record = { seed = SEED }, defer = true })
		local answers = check_now(ctx, "dev")
		ctx.channel = "main"
		ctx.owner.on_channel_changed()
		ctx.channel = "dev"
		ctx.owner.on_channel_changed()
		ctx.pending[1]({ ok = true, status = 200, body = MIXED, headers = {} })
		helpers.assert_eq(answers[1].latest, "v0.0.0-dev.150", "the original window still gets its result")
		helpers.assert_nil(ctx.owner.latest(), "a previous channel epoch cannot republish the About row")
		helpers.assert_nil(ctx.values[ctx.state_key].last_notified_tag)
	end)

	helpers.it("says up to date and still lists newer releases of other channels", function()
		local list = UP_TO_DATE:gsub("^%[", '[{"tag_name":"v1.0.0","prerelease":false,'
			.. '"published_at":"2026-08-05T00:00:00Z","assets":[]},')
		local ctx = build({ now = T0, record = { seed = SEED },
			responses = { { ok = true, status = 200, body = list, headers = {} } } })
		local answers = check_now(ctx, "dev")
		helpers.assert_eq(answers[1].state, "up_to_date")
		helpers.assert_eq(answers[1].latest, "v0.0.0-dev.140")
		helpers.assert_eq(answers[1].others, { { channel = "main", tag = "v1.0.0" } })
		helpers.assert_nil(ctx.owner.latest(), "nothing to install on the subscribed channel")
	end)

	helpers.it("says the checked channel has no release yet", function()
		local ctx = build({ now = T0, record = { seed = SEED },
			responses = { { ok = true, status = 200, body = UP_TO_DATE, headers = {} } } })
		local answers = check_now(ctx, "main")
		helpers.assert_eq(answers[1].state, "no_release")
		helpers.assert_eq(answers[1].channel, "main")
		helpers.assert_eq(answers[1].others, {}, "the installed dev build is the newest dev release")
	end)

	helpers.it("answers a failed request with the connection reason and records the failure", function()
		local ctx = build({ now = T0, record = { seed = SEED },
			responses = { { ok = false, status = 0, error = "timed out" } } })
		local answers = check_now(ctx, "dev")
		helpers.assert_eq(#answers, 1)
		helpers.assert_eq(answers[1].state, "error")
		helpers.assert_eq(answers[1].reason_key, "updater.no_connection")
		helpers.assert_contains(answers[1].detail, "timed out")
		helpers.assert_eq(ctx.values[ctx.state_key].failures, 1)
	end)

	helpers.it("stores the fields it reads from a listed release with its ETag", function()
		local ctx = build({ now = T0, record = { seed = SEED },
			responses = { { ok = true, status = 200, body = LIST, headers = { ETag = '"v1"' } } } })
		check_now(ctx, "dev")
		local copy = ctx.values[ctx.list_key]
		helpers.assert_eq(copy.url, URL)
		helpers.assert_eq(copy.etag, '"v1"')
		local kept = Json.decode(copy.body)
		helpers.assert_eq(#kept, 2)
		helpers.assert_eq(kept[1].tag_name, "v0.0.0-dev.150")
		helpers.assert_eq(kept[1].published_at, "2026-09-02T00:00:00Z")
		helpers.assert_eq(kept[1].prerelease, true)
		helpers.assert_nil(kept[1].assets, "asset lists and notes are not kept")
	end)

	helpers.it("a restarted owner revalidates the stored copy and reads a 304 from it", function()
		local first = build({ now = T0, record = { seed = SEED },
			responses = { { ok = true, status = 200, body = LIST, headers = { etag = '"v1"' } } } })
		check_now(first, "dev")
		local ctx = build({ now = T0, record = { seed = SEED }, list_copy = first.values[first.list_key],
			responses = { { ok = false, status = 304, headers = {} } } })
		local answers = check_now(ctx, "dev")
		helpers.assert_eq(ctx.requests[1].headers["If-None-Match"], '"v1"')
		helpers.assert_eq(answers[1].state, "available")
		helpers.assert_eq(answers[1].latest, "v0.0.0-dev.150")
	end)

	helpers.it("does not cache or send a malformed release ETag", function()
		for _, etag in ipairs({ "garbage", "   ", '"unfinished' }) do
			local ctx = build({ now = T0, record = { seed = SEED }, responses = {
				{ ok = true, status = 200, body = LIST, headers = { etag = etag } },
				{ ok = true, status = 200, body = LIST, headers = {} },
			} })
			check_now(ctx, "dev")
			helpers.assert_nil(ctx.values[ctx.list_key], "an invalid validator must not be saved")
			check_now(ctx, "dev")
			helpers.assert_nil(ctx.requests[2].headers["If-None-Match"])
		end
		local restored = build({ now = T0, record = { seed = SEED },
			list_copy = { url = URL, etag = "garbage", body = LIST },
			responses = { { ok = true, status = 200, body = LIST, headers = {} } } })
		check_now(restored, "dev")
		helpers.assert_nil(restored.requests[1].headers["If-None-Match"], "a restored invalid ETag is dropped")
	end)

	helpers.it("drops a stored copy of another list URL and sends a full request", function()
		local ctx = build({ now = T0, record = { seed = SEED },
			list_copy = { url = URL .. "&page=2", etag = '"v1"', body = "[]" },
			responses = { { ok = true, status = 200, body = LIST, headers = {} } } })
		check_now(ctx, "dev")
		helpers.assert_nil(ctx.requests[1].headers["If-None-Match"], "no validator from another list")
		helpers.assert_nil(ctx.values[ctx.list_key], "a response without an ETag leaves no copy")
	end)

	helpers.it("drops a damaged stored list before sending a conditional request", function()
		for _, body in ipairs({ '[{"tag_name":"v0.0.0-dev.150"', '[{}]' }) do
			local ctx = build({ now = T0, record = { seed = SEED },
				list_copy = { url = URL, etag = '"v1"', body = body },
				responses = { { ok = true, status = 200, body = LIST, headers = {} } } })
			local answers = check_now(ctx, "dev")
			helpers.assert_nil(ctx.requests[1].headers["If-None-Match"])
			helpers.assert_eq(answers[1].state, "available")
		end
	end)

	helpers.it("names an exhausted GitHub rate limit and its reset time", function()
		local ctx = build({ now = T0, record = { seed = SEED }, responses = { { ok = false, status = 403,
			headers = { ["X-RateLimit-Remaining"] = "0", ["x-ratelimit-reset"] = "86400" } } } })
		local answers = check_now(ctx, "dev")
		helpers.assert_eq(answers[1].reason_key, "updater.no_connection")
		helpers.assert_contains(answers[1].detail, "rate limit is exhausted")
		helpers.assert_contains(answers[1].detail, "1970-01-02 00:00:00 UTC")
	end)

	helpers.it("answers an unusable list with the parse reason", function()
		local ctx = build({ now = T0, record = { seed = SEED },
			responses = { { ok = true, status = 200, body = '[{"name":"no tag"}]', headers = {} } } })
		local answers = check_now(ctx, "dev")
		helpers.assert_eq(answers[1].state, "error")
		helpers.assert_eq(answers[1].reason_key, "updater.parse_failed")
	end)

	helpers.it("answers once when the transport throws", function()
		local ctx = build({ now = T0, record = { seed = SEED }, http_throw = true })
		local answers, dispatched = check_now(ctx, "dev")
		helpers.assert_eq(dispatched, false)
		helpers.assert_eq(#answers, 1, "exactly one answer")
		helpers.assert_eq(answers[1].reason_key, "updater.no_connection")
	end)

	helpers.it("refuses a channel the registry does not declare, without a request", function()
		local ctx = build({ now = T0, record = { seed = SEED } })
		local answers, dispatched = check_now(ctx, "beta")
		helpers.assert_eq(dispatched, false)
		helpers.assert_eq(#ctx.requests, 0, "no request for an unknown channel")
		helpers.assert_eq(answers[1].reason_key, "update_check.error_unexpected")
	end)

	helpers.it("runs while the driver is paused: the user asked for it", function()
		local ctx = build({ now = T0, record = { seed = SEED }, paused = true,
			responses = { { ok = true, status = 200, body = MIXED, headers = {} } } })
		local answers = check_now(ctx, "dev")
		helpers.assert_eq(#ctx.requests, 1)
		helpers.assert_eq(answers[1].state, "available")
	end)

	helpers.it("reuses the session's list on a 304 with the same ETag", function()
		local ctx = build({ now = T0, record = { seed = SEED }, responses = {
			{ ok = true, status = 200, body = MIXED, headers = { ETag = '"abc"' } },
			{ ok = false, status = 304, headers = {} },
		} })
		check_now(ctx, "dev")
		local answers = check_now(ctx, "dev")
		helpers.assert_eq(ctx.requests[2].headers["If-None-Match"], '"abc"', "the second request is conditional")
		helpers.assert_eq(answers[1].state, "available", "the unchanged list still offers the release")
	end)
end)





-- ======================================================================
-- ======================================================================
-- ======= The Atom feed answers when the API gives no list (#99) =======
-- ======================================================================
-- ======================================================================

--- One entry of GitHub's releases feed.
--- @param repo string owner/repo the entry links to.
--- @param tag string URL-encoded tag.
--- @param updated string The entry's <updated>.
--- @return string
local function feed_entry(repo, tag, updated)
	return '<entry><id>tag:github.com,2008:Repository/1/' .. tag .. '</id><updated>' .. updated .. '</updated>'
		.. '<link rel="alternate" type="text/html" href="https://github.com/' .. repo .. '/releases/tag/' .. tag .. '"/>'
		.. '<title>' .. tag .. '</title><content type="html">&lt;p&gt;Notes&lt;/p&gt;</content></entry>'
end

local FEED = '<?xml version="1.0" encoding="UTF-8"?><feed xmlns="http://www.w3.org/2005/Atom">'
	.. feed_entry("adrienm7/ergopti", "v0.0.0-dev.150", "2026-09-02T00:00:00Z")
	.. feed_entry("someone/else", "v9.9.9", "2026-09-03T00:00:00Z")
	.. feed_entry("adrienm7/ergopti", "v1.0.0", "2026-08-05T00:00:00Z")
	.. feed_entry("adrienm7/ergopti", "v0.0.0-dev.149", "2026-09-01T00:00:00Z")
	.. '</feed>'

local RATE_LIMITED = { ok = false, status = 403,
	headers = { ["X-RateLimit-Remaining"] = "0", ["x-ratelimit-reset"] = "86400" } }

helpers.describe("updater.auto_check (macOS): the Atom feed answers when the API gives no list (update-check-feed-99)", function()
	helpers.it("reads the feed's repository tags in order, as the update check's list", function()
		local ReleaseSources = require("updater.engine.release_sources")
		local list = assert(ReleaseSources.feed_release_list(FEED, "adrienm7", "ergopti"))
		helpers.assert_eq(Json.decode(list), {
			{ tag_name = "v0.0.0-dev.150", published_at = "2026-09-02T00:00:00Z" },
			{ tag_name = "v1.0.0", published_at = "2026-08-05T00:00:00Z" },
			{ tag_name = "v0.0.0-dev.149", published_at = "2026-09-01T00:00:00Z" },
		}, "another repository's entry is dropped")
		local encoded = assert(ReleaseSources.feed_release_list('<feed>'
			.. feed_entry("adrienm7/ergopti", "v1.0.0%2Bbuild", '"broken"') .. '</feed>', "adrienm7", "ergopti"))
		helpers.assert_eq(Json.decode(encoded), { { tag_name = "v1.0.0+build", published_at = "" } },
			"an escaped tag is decoded and a non-timestamp date never reaches the JSON")
		helpers.assert_nil(ReleaseSources.feed_release_list("<html>blocked</html>", "adrienm7", "ergopti"))
		helpers.assert_nil(ReleaseSources.feed_release_list("<feed></feed>", "adrienm7", "ergopti"))
	end)

	helpers.it("a manual check offers the release the feed lists when the API rate limit is spent", function()
		local ctx = build({ now = T0, record = { seed = SEED }, responses = {
			RATE_LIMITED, { ok = true, status = 200, body = FEED, headers = {} } } })
		local answers = check_now(ctx, "dev")
		helpers.assert_eq(#ctx.requests, 2, "the API, then the feed")
		helpers.assert_eq(ctx.requests[2].url, FEED_URL)
		helpers.assert_eq(ctx.requests[2].headers.Accept, "application/atom+xml")
		helpers.assert_eq(#answers, 1, "one answer")
		helpers.assert_eq(answers[1].state, "available", "the user can update: Sparkle installs from the appcast")
		helpers.assert_eq(answers[1].latest, "v0.0.0-dev.150")
		helpers.assert_eq(answers[1].others, { { channel = "main", tag = "v1.0.0" } })
		helpers.assert_eq(ctx.owner.latest().tag, "v0.0.0-dev.150", "the About row names it too")
		helpers.assert_eq(ctx.values[ctx.state_key].failures, 0, "a check the feed answered succeeded")
		helpers.assert_nil(ctx.values[ctx.list_key], "the feed never replaces the API copy and its ETag")
	end)

	helpers.it("a manual check names both causes when the feed fails too", function()
		local ctx = build({ now = T0, record = { seed = SEED }, responses = {
			RATE_LIMITED, { ok = true, status = 200, body = "<html>proxy page</html>", headers = {} } } })
		local answers = check_now(ctx, "dev")
		helpers.assert_eq(answers[1].state, "error")
		helpers.assert_eq(answers[1].reason_key, "updater.no_connection")
		helpers.assert_contains(answers[1].detail, "rate limit is exhausted")
		helpers.assert_contains(answers[1].detail, "Atom feed: HTTP 200 without an Atom feed")
		helpers.assert_eq(ctx.values[ctx.state_key].failures, 1)
	end)

	-- UPD-1 (decided by the maintainer on 2026-11-11): the three drivers read a
	-- 200 that does not open a JSON array as no connection through one shared
	-- rule (updater.release_sources.opens_release_array), then the feed.
	helpers.it("a captive-portal page from the API is no list: the feed answers (upd1-captive-portal)", function()
		local ctx = build({ now = T0, record = { seed = SEED }, responses = {
			{ ok = true, status = 200, body = "<html>Please sign in to the hotel Wi-Fi</html>", headers = {} },
			{ ok = true, status = 200, body = FEED, headers = {} } } })
		local answers = check_now(ctx, "dev")
		helpers.assert_eq(#ctx.requests, 2, "the API, then the feed")
		helpers.assert_eq(ctx.requests[2].url, FEED_URL)
		helpers.assert_eq(answers[1].state, "available")
		helpers.assert_eq(answers[1].latest, "v0.0.0-dev.150")
	end)

	helpers.it("a cut array stays a list that could not be read, with no feed (upd1-captive-portal)", function()
		local ctx = build({ now = T0, record = { seed = SEED }, responses = {
			{ ok = true, status = 200, body = '[{"tag_name":"v1.0.0"}', headers = {} } } })
		local answers = check_now(ctx, "dev")
		helpers.assert_eq(#ctx.requests, 1, "a release list cut short is no connection problem")
		helpers.assert_eq(answers[1].reason_key, "updater.parse_failed")
	end)

	helpers.it("a page opening after a byte-order mark is still read as a list (upd1-captive-portal)", function()
		local ctx = build({ now = T0, record = { seed = SEED }, responses = {
			{ ok = true, status = 200, body = "\239\187\191[]", headers = {} } } })
		local answers = check_now(ctx, "dev")
		helpers.assert_eq(#ctx.requests, 1, "a BOM before the array is the list, not a portal page")
	end)

	helpers.it("a manual check reads no feed for a list the API answered unusable", function()
		local ctx = build({ now = T0, record = { seed = SEED },
			responses = { { ok = true, status = 200, body = '[{"name":"no tag"}]', headers = {} } } })
		local answers = check_now(ctx, "dev")
		helpers.assert_eq(#ctx.requests, 1, "a reachable API with a bad list is no connection problem")
		helpers.assert_eq(answers[1].reason_key, "updater.parse_failed")
	end)

	helpers.it("a background check announces the release the feed lists", function()
		local ctx = build({ now = T0, record = { seed = SEED }, responses = {
			RATE_LIMITED, { ok = true, status = 200, body = FEED, headers = {} } } })
		helpers.assert_true(ctx.owner.start())
		ctx.clock.now = ctx.clock.now + ctx.timing.boot_check_delay_sec
		fire(ctx)
		helpers.assert_eq(#ctx.requests, 2)
		helpers.assert_eq(ctx.requests[2].url, FEED_URL)
		helpers.assert_eq(ctx.announced, { "v0.0.0-dev.150" })
		helpers.assert_eq(ctx.values[ctx.state_key].failures, 0)
		helpers.assert_true(ctx.owner.stop())
	end)
end)
