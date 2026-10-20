--- tests/unit/modules/updater/lifecycle/test_manual_check_retirement.lua

--- ==============================================================================
--- MODULE: Manual Update Check Retirement
--- DESCRIPTION:
--- Real updater owner and shared release rules over injected recording ports.
--- Lifecycle retirement must revoke late manual callbacks before cache, durable
--- notification watermark or UI publication. No native transport or timer runs.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED = {
	"modules.updater.auto_check", "modules.updater", "infra.logger", "infra.paths",
	"adapters.file_system", "adapters.json_codec", "adapters.update_launcher",
	"infra.notifications", "infra.i18n", "json", "updater.channels", "updater.schedule",
	"updater.release_parser", "updater.check_result", "updater.rate_limit", "updater.version",
}

--- Runs exact owner logic while restoring injected modules and real pure consumers.
local function with_owner(run)
	helpers.with_stub_scope(OWNED, function()
		local Json = require("json")
		local function shared(relative)
			local file = assert(io.open(helpers.shared(relative), "rb"))
			local raw = assert(file:read("*a"))
			assert(file:close())
			return Json.decode(raw)
		end
		local defaults = shared("modules/updater/defaults.json")
		local registry = assert(require("updater.channels").load(shared("modules/updater/channels.json")))
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.paths"] = {}
		package.loaded["adapters.file_system"] = {}
		package.loaded["adapters.json_codec"] = { encode = Json.encode, decode = Json.decode }
		package.loaded["modules.updater"] = { channels = function() return registry end }
		package.loaded["adapters.update_launcher"] = {}
		package.loaded["infra.notifications"] = {}
		package.loaded["infra.i18n"] = {}
		local AutoCheck = require("modules.updater.auto_check")
		local state_key, list_key = defaults.check_state.storage_key, defaults.check_state.list_storage_key
		local env = {
			values = { [state_key] = { seed = "7f3a9c21e5b04d68" } },
			state_key = state_key, list_key = list_key, writes = 0, now = 1700000000,
		}
		function env.owner()
			local ctx = { channel = "dev", pending = {}, timers = {}, notified = 0 }
			ctx.owner = AutoCheck.new({
				state = {}, save = function() return true end,
				channel = function() return ctx.channel end, is_paused = function() return false end,
				on_available = function() ctx.notified = ctx.notified + 1; return true end,
				config = { timing = defaults.timing, state_key = state_key, list_key = list_key,
					releases_url = "https://fixture.test/releases", timeout_sec = 15 },
				timer = {
					after = function(_, callback)
						local timer = { armed = true, callback = callback }
						ctx.timers[#ctx.timers + 1] = timer
						return timer, true
					end,
					cancel = function(timer) timer.armed = false; return true end,
				},
				storage = {
					get = function(key, default) local value = env.values[key]; if value == nil then return default end; return value end,
					set = function(key, value) env.writes = env.writes + 1; env.values[key] = value; return true end,
				},
				http = { get = function(_, _, callback) ctx.pending[#ctx.pending + 1] = callback; return true end },
				now = function() return env.now end,
				current_version = function() return "0.0.0-dev.140" end,
				installed_channel = function() return "dev" end,
			})
			return ctx
		end
		run(env)
	end)
end

local function response(version)
	return { ok = true, status = 200, headers = { ETag = '"release-' .. version .. '"' },
		body = '[{"tag_name":"v0.0.0-dev.' .. version .. '","prerelease":true,"published_at":"2026-09-02T00:00:00Z"}]' }
end

local function check(ctx)
	local answers = {}
	helpers.assert_true(ctx.owner.check_now("dev", function(result) answers[#answers + 1] = result end))
	return answers, ctx.pending[#ctx.pending]
end

--- Asserts outside deferred callbacks so a protected callback cannot swallow a failure.
local function assert_unchanged(env, owner, answers, callback, result)
	local record, cache, writes, latest = env.values[env.state_key], env.values[env.list_key], env.writes, owner.latest()
	env.now = env.now + 1
	callback(result)
	helpers.assert_eq(#answers, 0, "retired manual UI callback must remain inert")
	helpers.assert_eq(env.writes, writes, "retired response must not write either durable key")
	helpers.assert_true(env.values[env.state_key] == record, "the exact current check record survives")
	helpers.assert_true(env.values[env.list_key] == cache, "the exact current release cache survives")
	helpers.assert_true(owner.latest() == latest, "the current About row survives")
end

helpers.describe("manual updater request follows its owner lifetime", function()
	for _, started in ipairs({ false, true }) do
		helpers.it("answers a current request once with schedule started=" .. tostring(started), function()
			with_owner(function(env)
				local ctx = env.owner()
				if started then helpers.assert_true(ctx.owner.start()) end
				local answers, callback = check(ctx)
				callback(response("150"))
				local writes = env.writes
				callback({ ok = false, status = 0, error = "duplicate failure" })
				helpers.assert_eq(#answers, 1)
				helpers.assert_eq(answers[1].state, "available")
				helpers.assert_eq(ctx.owner.latest().tag, "v0.0.0-dev.150")
				helpers.assert_eq(env.values[env.state_key].last_notified_tag, "v0.0.0-dev.150")
				helpers.assert_eq(env.writes, writes, "duplicate terminal response cannot rewrite state")
				helpers.assert_eq(ctx.notified, 0, "manual window already presents the result")
				helpers.assert_true(ctx.owner.stop())
			end)
		end)
	end

	for _, restart in ipairs({ "none", "same", "replacement", "before_start", "start" }) do
		helpers.it("retires a successful manual response across " .. restart, function()
			with_owner(function(env)
				local a = env.owner()
				if restart ~= "before_start" then helpers.assert_true(a.owner.start()) end
				local old_answers, old_response = check(a)
				if restart ~= "start" then helpers.assert_true(a.owner.stop()) end
				local current = a
				if restart ~= "none" then
					if restart == "replacement" then current = env.owner() end
					helpers.assert_true(current.owner.start())
					local answers, callback = check(current)
					callback(response("151"))
					helpers.assert_eq(#answers, 1)
					helpers.assert_eq(env.values[env.state_key].last_notified_tag, "v0.0.0-dev.151")
				end
				assert_unchanged(env, current.owner, old_answers, old_response, response("150"))
				helpers.assert_true(current.owner.stop())
			end)
		end)
	end

	for _, result in ipairs({ { ok = false, status = 0, error = "late network failure" },
		{ ok = true, status = 200, body = "[", headers = {} } }) do
		helpers.it("retires a failed manual response with body=" .. tostring(result.body), function()
			with_owner(function(env)
				local ctx = env.owner()
				helpers.assert_true(ctx.owner.start())
				local answers, callback = check(ctx)
				helpers.assert_true(ctx.owner.stop())
				assert_unchanged(env, ctx.owner, answers, callback, result)
			end)
		end)
	end

	helpers.it("preserves the manual answer across a channel change without retiring its owner", function()
		with_owner(function(env)
			local ctx = env.owner()
			local answers, callback = check(ctx)
			ctx.channel = "main"
			helpers.assert_true(ctx.owner.on_channel_changed())
			callback(response("150"))
			helpers.assert_eq(#answers, 1, "channel change preserves the requested window answer")
			helpers.assert_eq(answers[1].state, "available")
			helpers.assert_nil(ctx.owner.latest(), "new channel keeps its About row")
			helpers.assert_nil(env.values[env.state_key].last_notified_tag)
		end)
	end)
end)
