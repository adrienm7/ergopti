--- tests/unit/infra/lifecycle/test_startup_inventory_soak.lua

--- ==============================================================================
--- MODULE: Startup Native Inventory Soak Regression Tests
--- DESCRIPTION:
--- Executes the actual E2E bootstrap fragment with independent native callback
--- and coarse-clock owners. SQLite inactivity must not starve model discovery.
--- ==============================================================================

local helpers = require("tests.helpers")
local source_file = assert(io.open("tests/e2e/startup_child.lua", "rb"))
local source = source_file:read("*a")
source_file:close()
local first = assert(source:find('\tlocal adapter = dofile("adapters/event_loop.lua")', 1, true))
local last = assert(source:find("\tlocal native_run = adapter.run", first, true))
local body = source:sub(first, last - 1)
assert(#body > 100 and body:find("local function soak", 1, true), "the actual soak fragment must be nonempty")

local function fixture(options)
	options = options or {}
	local world = { now = 0, runs = 0, sleeps = 0, closing = false, closed = false, expired = false, reads = 0 }
	local profiles = {}
	local loaded = { ["modules.llm.profiles"] = profiles }
	if options.no_owner then loaded["modules.llm.profiles"] = nil end
	local uv = {
		hrtime = function() return world.now end,
		sleep = function(ms)
			helpers.assert_eq(ms, 1)
			world.sleeps = world.sleeps + 1
			world.now = world.now + ms * 1e6
		end,
	}
	local env = setmetatable({ clock_seconds = 0, SOAK_SECONDS = 30, package = { loaded = loaded } }, { __index = _G })
	profiles.model_inventory_pending = function()
		world.reads = world.reads + 1
		if options.read_replaces_owner then loaded["modules.llm.profiles"] = {} end
		if options.non_boolean then return "false" end
		return not world.closed
	end
	local function forbidden() error("inventory observation must not construct, refresh, query or cancel work") end
	profiles.get_models, profiles.refresh, profiles.cancel_model_inventory, profiles.init = forbidden, forbidden, forbidden, forbidden
	if options.missing_api then profiles.model_inventory_pending = nil end
	if options.already_closed then world.closed = true end
	function uv.run(mode)
		helpers.assert_eq(mode, "nowait")
		world.runs = world.runs + 1
		world.closing = true
		if options.replace_owner then loaded["modules.llm.profiles"] = {} end
		if options.remove_owner then loaded["modules.llm.profiles"] = nil end
		if options.replace_api then profiles.model_inventory_pending = function() return false end end
		if options.exhaust or options.late_ack then world.now = 30 * 1e9 end
		if options.late_ack then world.closed = true end
		if not options.exhaust and world.runs >= 2 then world.closed = true end
	end
	local collector = { has_flush_debt = function() return false end }
	env.require = function(name)
		if name == "luv" then return uv end
		if name == "modules.keylogger.keylogger" then return collector end
		error("unexpected bootstrap dependency: " .. name)
	end
	env.dofile = function(path)
		helpers.assert_eq(path, "adapters/event_loop.lua")
		return { _run_idle_tick = function() end }
	end
	env.record = function() error("the no-debt metrics owner must remain inactive") end
	local chunk, reason
	if setfenv then
		chunk, reason = loadstring(body .. "\nreturn soak", "@actual startup bootstrap/soak")
		if chunk then setfenv(chunk, env) end
	else
		chunk, reason = load(body .. "\nreturn soak", "@actual startup bootstrap/soak", "t", env)
	end
	assert(chunk, reason)
	local soak = chunk()
	function world.play()
		soak({ onIdle = function()
			if env.clock_seconds >= 6 and not world.closed then world.expired = true end
			if env.clock_seconds > 1 and not options.no_owner and not options.already_closed then
				helpers.assert_true(world.closed, "native inventory must acknowledge closure before the next virtual second")
			end
		end })
	end
	world.env = env
	return world
end

local function case(name, fn) helpers.it("startup inventory soak: " .. name, fn) end

helpers.describe("startup inventory soak: physical acknowledgement", function()
	case("settles cold discovery without SQLite debt before its virtual HTTP deadline", function()
		local world = fixture()
		world.play()
		helpers.assert_true(world.closed, "the native callback must acknowledge inventory closure")
		helpers.assert_eq(world.expired, false, "the existing five-second request deadline must not age before callbacks")
		helpers.assert_eq(world.env.clock_seconds, 30)
	end)

	case("keeps closing intent pending until a distinct native acknowledgement", function()
		local world = fixture()
		world.play()
		helpers.assert_true(world.closing)
		helpers.assert_eq(world.runs, 2, "one callback only starts closing; the next callback acknowledges it")
		helpers.assert_eq(world.sleeps, 1)
	end)

	case("does not construct an absent inventory owner", function()
		local world = fixture({ no_owner = true })
		world.play()
		helpers.assert_eq(world.runs, 0)
		helpers.assert_eq(world.reads, 0)
		helpers.assert_eq(world.env.clock_seconds, 30)
	end)

	case("accepts an already acknowledged inventory without pumping", function()
		local world = fixture({ already_closed = true })
		world.play()
		helpers.assert_eq(world.runs, 0)
		helpers.assert_eq(world.env.clock_seconds, 30)
	end)

	for _, field in ipairs({ "replace_owner", "remove_owner", "replace_api", "read_replaces_owner" }) do
		local mutation = field
		case("refuses " .. mutation .. " instead of accepting a different acknowledgement", function()
			local world = fixture({ [mutation] = true })
			local ok, reason = pcall(world.play)
			helpers.assert_eq(ok, false)
			helpers.assert_contains(tostring(reason), "owner or pending API changed")
		end)
	end

	case("refuses an inventory owner without its pending API", function()
		local world = fixture({ missing_api = true })
		local ok, reason = pcall(world.play)
		helpers.assert_eq(ok, false)
		helpers.assert_contains(tostring(reason), "physical pending API")
	end)

	case("requires a typed boolean acknowledgement", function()
		local world = fixture({ non_boolean = true })
		local ok, reason = pcall(world.play)
		helpers.assert_eq(ok, false)
		helpers.assert_contains(tostring(reason), "must be boolean")
	end)

	case("bounds native waiting by the existing soak window without advancing coarse time", function()
		local world = fixture({ exhaust = true })
		local ok, reason = pcall(world.play)
		helpers.assert_eq(ok, false)
		helpers.assert_contains(tostring(reason), "native soak window")
		helpers.assert_eq(world.env.clock_seconds, 1)
		helpers.assert_eq(world.runs, 1)
		helpers.assert_eq(world.closed, false)
	end)

	case("rejects an acknowledgement received beyond the existing native soak window", function()
		local world = fixture({ late_ack = true })
		local ok, reason = pcall(world.play)
		helpers.assert_eq(ok, false)
		helpers.assert_contains(tostring(reason), "native soak window")
		helpers.assert_eq(world.env.clock_seconds, 1)
	end)
end)
