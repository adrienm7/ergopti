--- tests/unit/modules/updater/lifecycle/test_update_check_transport_isolation.lua

--- ==============================================================================
--- MODULE: Automatic and Manual Update Transport Isolation
--- DESCRIPTION:
--- Drives the real updater owner, HTTP client and timeout scheduler over native
--- callback recorders. The native HTTP API faithfully returns no request handle.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED = {
	"modules.updater.auto_check", "modules.updater", "infra.paths", "infra.logger",
	"adapters.http_client", "adapters.timer_scheduler", "adapters.file_system",
	"adapters.json_codec", "adapters.update_launcher", "infra.notifications", "infra.i18n",
}
local FEED = '<feed xmlns="http://www.w3.org/2005/Atom"><entry>'
	.. '<id>tag:github.com,2008:Repository/1/v0.0.0-dev.150</id><updated>2026-09-02T00:00:00Z</updated>'
	.. '<link href="https://github.com/adrienm7/ergopti/releases/tag/v0.0.0-dev.150"/>'
	.. '<title>v0.0.0-dev.150</title></entry></feed>'
local BODY = '[{"tag_name":"v0.0.0-dev.150","prerelease":true,"published_at":"2026-09-02T00:00:00Z"}]'

local function with_owner(run)
	helpers.with_stub_scope(OWNED, function()
		local Json = require("json")
		local function shared(path)
			local file = assert(io.open(helpers.shared(path), "rb"))
			local raw = assert(file:read("*a"))
			assert(file:close())
			return Json.decode(raw)
		end
		local defaults = shared("modules/updater/defaults.json")
		local registry = assert(require("updater.channels").load(shared("modules/updater/channels.json")))
		local ctx = { now = 1700000000, requests = {}, schedule = {}, values = {}, writes = 0, notices = 0 }
		local Http = helpers.load_with_stubs("adapters.http_client", {
			timer = { new = function(_, callback)
				local native = { callback = callback, armed = false }
				function native:start() self.armed = true; return self end
				function native:stop() self.armed = false; return self end
				function native:running() return self.armed end
				return native
			end },
			http = { asyncGet = function(url, _, callback)
				ctx.requests[#ctx.requests + 1] = { url = url, callback = callback }
				return nil
			end },
		})
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.paths"] = {}
		package.loaded["adapters.file_system"] = {}
		package.loaded["adapters.json_codec"] = { encode = Json.encode, decode = Json.decode }
		package.loaded["modules.updater"] = { channels = function() return registry end, GH_OWNER = "adrienm7", GH_REPO = "ergopti" }
		package.loaded["adapters.update_launcher"] = {}
		package.loaded["infra.notifications"] = {}
		package.loaded["infra.i18n"] = {}
		local AutoCheck = require("modules.updater.auto_check")
		ctx.timing = defaults.timing
		ctx.state_key = defaults.check_state.storage_key
		ctx.values[ctx.state_key] = { seed = "7f3a9c21e5b04d68" }
		ctx.http, ctx.manual_http = Http.new(), Http.new()
		ctx.owner = AutoCheck.new({
			state = {}, save = function() return true end,
			channel = function() return "dev" end, is_paused = function() return false end,
			on_available = function() ctx.notices = ctx.notices + 1; return true end,
			config = { timing = defaults.timing, state_key = ctx.state_key,
				list_key = defaults.check_state.list_storage_key,
				releases_url = "http://fixture.test/releases", feed_url = "http://fixture.test/releases.atom", timeout_sec = 15 },
			timer = {
				after = function(_, callback)
					local handle = { callback = callback }
					ctx.schedule[#ctx.schedule + 1] = handle
					return handle, true
				end,
				cancel = function() return true end,
			},
			storage = {
				get = function(key, default) local value = ctx.values[key]; if value == nil then return default end; return value end,
				set = function(key, value) ctx.writes = ctx.writes + 1; ctx.values[key] = value; return true end,
			},
			http = ctx.http, manual_http = ctx.manual_http,
			now = function() return ctx.now end,
			current_version = function() return "0.0.0-dev.140" end,
			installed_channel = function() return "dev" end,
		})
		local ok, err = xpcall(function() run(ctx) end, debug.traceback)
		ctx.owner.stop()
		for _, request in ipairs(ctx.requests) do request.callback(200, BODY, {}) end
		helpers.assert_true(ctx.http.isSettled(), "Background transport must physically settle")
		helpers.assert_true(ctx.manual_http.isSettled(), "Manual transport must physically settle")
		if not ok then error(err, 0) end
	end)
end

local function due(ctx)
	ctx.now = ctx.now + ctx.timing.boot_check_delay_sec
	ctx.schedule[#ctx.schedule].callback()
end

helpers.describe("automatic and manual checks retain independent transports", function()
	for _, first in ipairs({ "automatic", "manual" }) do
		helpers.it("preserves both requests when " .. first .. " starts first (update-check-transport-isolation)", function()
			with_owner(function(ctx)
				helpers.assert_true(ctx.owner.start())
				local answers = {}
				local function manual()
					return ctx.owner.check_now("dev", function(result) answers[#answers + 1] = result end)
				end
				if first == "automatic" then due(ctx); manual() else manual(); due(ctx) end
				helpers.assert_eq(#ctx.requests, 2, "Independent checks must both reach native HTTP without superseding")
				for _, request in ipairs(ctx.requests) do request.callback(200, BODY, {}) end
				helpers.assert_eq(#answers, 1, "The manual window must receive exactly one answer")
				helpers.assert_eq(answers[1].state, "available")
				ctx.now = ctx.now + 2 * ctx.timing.default_check_interval_sec
				ctx.owner._evaluate()
				helpers.assert_eq(#ctx.requests, 3, "A manual check must not leave the automatic owner stuck in flight")
			end)
		end)
	end



	for _, fallback in ipairs({ "automatic", "manual" }) do
		helpers.it("keeps the " .. fallback .. " Atom fallback independent (update-check-transport-isolation)", function()
			with_owner(function(ctx)
				helpers.assert_true(ctx.owner.start())
				due(ctx)
				local answers = {}
				ctx.owner.check_now("dev", function(result) answers[#answers + 1] = result end)
				helpers.assert_eq(#ctx.requests, 2)
				local failed = fallback == "automatic" and 1 or 2
				ctx.requests[failed].callback(503, "service unavailable", {})
				helpers.assert_eq(#ctx.requests, 3, "The failed check owns one independent feed request")
				helpers.assert_eq(ctx.requests[3].url, "http://fixture.test/releases.atom")
				ctx.requests[3 - failed].callback(200, BODY, {})
				ctx.requests[3].callback(200, FEED, {})
				helpers.assert_eq(#answers, 1)
				helpers.assert_eq(answers[1].state, "available")
				helpers.assert_eq(ctx.owner.latest().tag, "v0.0.0-dev.150")
				ctx.now = ctx.now + 2 * ctx.timing.default_check_interval_sec
				ctx.owner._evaluate()
				helpers.assert_eq(#ctx.requests, 4, "The fallback cannot strand the automatic in-flight owner")
			end)
		end)
	end

	for _, cancelled in ipairs({ "automatic", "manual" }) do
		helpers.it("keeps the sibling request after " .. cancelled .. " cancellation (update-check-transport-isolation)", function()
			with_owner(function(ctx)
				helpers.assert_true(ctx.owner.start())
				due(ctx)
				local answers = 0
				ctx.owner.check_now("dev", function() answers = answers + 1 end)
				helpers.assert_eq(#ctx.requests, 2)
				if cancelled == "automatic" then ctx.http.cancel() else ctx.manual_http.cancel() end
				for _, request in ipairs(ctx.requests) do request.callback(200, BODY, {}) end
				helpers.assert_eq(answers, cancelled == "automatic" and 1 or 0)
				helpers.assert_eq(ctx.notices, cancelled == "manual" and 1 or 0)
			end)
		end)
	end

	helpers.it("fences the background result when the manual answer stops the owner (update-check-transport-isolation)", function()
		with_owner(function(ctx)
			helpers.assert_true(ctx.owner.start())
			due(ctx)
			local answers = 0
			ctx.owner.check_now("dev", function()
				answers = answers + 1
				ctx.owner.stop()
			end)
			helpers.assert_eq(#ctx.requests, 2)
			ctx.requests[2].callback(200, BODY, {})
			local writes = ctx.writes
			ctx.requests[1].callback(200, BODY, {})
			helpers.assert_eq(answers, 1)
			helpers.assert_eq(ctx.notices, 0)
			helpers.assert_eq(ctx.writes, writes)
		end)
	end)

	helpers.it("retires both pending completions when stopped (update-check-transport-isolation)", function()
		with_owner(function(ctx)
			helpers.assert_true(ctx.owner.start())
			due(ctx)
			local answers = 0
			ctx.owner.check_now("dev", function() answers = answers + 1 end)
			helpers.assert_eq(#ctx.requests, 2)
			helpers.assert_true(ctx.owner.stop())
			local writes = ctx.writes
			for _, request in ipairs(ctx.requests) do request.callback(200, BODY, {}) end
			helpers.assert_eq(answers, 0)
			helpers.assert_eq(ctx.notices, 0)
			helpers.assert_eq(ctx.writes, writes)
			helpers.assert_nil(ctx.owner.latest())
		end)
	end)
end)
