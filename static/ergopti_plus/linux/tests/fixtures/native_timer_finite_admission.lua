--- tests/fixtures/native_timer_finite_admission.lua
--- ==============================================================================
--- MODULE: Native Timer Finite Admission Regression
--- DESCRIPTION:
--- Tests real libuv admission, callback delivery and retirement for invalid
--- numeric durations, plus healthy clamped, fractional and deferred work. Invalid
--- numeric arguments are supplied explicitly; no clock or backend is mocked.
--- Stock Lua already refuses some conversions, so those remain healthy controls.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_timer_finite_admission%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. package.path
local uv = require("luv")
local checks, failures = 0, 0

local function handle_count()
	local count = 0
	uv.walk(function() count = count + 1 end)
	return count
end

local function fresh(name)
	package.loaded[name] = nil
	return require(name)
end

local function drain()
	for _ = 1, 4 do uv.run("nowait") end
end

assert(handle_count() == 0, "native fixture requires exclusive loop ownership")

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	uv.walk(function(handle) if not uv.is_closing(handle) then uv.close(handle) end end)
	drain()
	assert(handle_count() == 0 and not uv.loop_alive(), "native fixture retained a handle")
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

local invalid = {
	{ name = "NaN", value = 0 / 0 },
	{ name = "positive infinity", value = math.huge },
	{ name = "negative infinity", value = -math.huge },
	{ name = "positive conversion overflow", value = 1e308 },
	{ name = "negative conversion overflow", value = -1e308 },
}

for _, method in ipairs({ "after", "every" }) do
	for _, case in ipairs(invalid) do
		check(method .. " rejects " .. case.name, function()
			local scheduler = fresh("adapters.timer_scheduler")
			local calls = 0
			local token = scheduler[method](case.value, function() calls = calls + 1 end)
			local armed_on_return, handles_on_return = token.armed, handle_count()
			uv.sleep(3)
			uv.run("nowait")
			print(string.format("RECEIPT %s %s: armed=%s handles=%d callbacks=%d",
				method, case.name, tostring(armed_on_return), handles_on_return, calls))
			assert(armed_on_return == false and calls == 0, "invalid duration admitted native user work")
			assert(token.fired == true and token.timer == nil, "refused duration retained native token ownership")
			assert(scheduler.activeCount() == 0, "refused duration retained scheduler ownership")
			drain()
			assert(handle_count() == 0, "refused duration leaked a native resource")
			local healthy_calls = 0
			scheduler.after(0, function() healthy_calls = healthy_calls + 1 end)
			drain()
			assert(healthy_calls == 1 and scheduler.activeCount() == 0,
				"refused duration prevented the following healthy timer")
		end)
	end
end

for _, case in ipairs({ invalid[1], invalid[2], invalid[3] }) do
	check("defer rejects " .. case.name .. " without queue ownership", function()
		local loop = fresh("adapters.event_loop")
		local calls = 0
		local weak = setmetatable({}, { __mode = "v" })
		local function owned_callback()
			local marker = {}
			weak[1] = marker
			return function() calls = calls + 1; return marker end
		end
		local callback = owned_callback()
		assert(loop.defer(callback, case.value) == false, "invalid delay entered the deferred queue")
		callback = nil
		collectgarbage("collect")
		collectgarbage("collect")
		assert(weak[1] == nil, "refused deferred callback retained its captured payload")
		loop._run_idle_tick()
		assert(calls == 0, "refused callback was delivered")
		assert(loop.defer(function() calls = calls + 1 end))
		loop._run_idle_tick()
		assert(calls == 1, "refused delay starved following healthy deferred work")
	end)
end

for _, method in ipairs({ "after", "every" }) do
	for _, case in ipairs({ { name = "zero", value = 0 },
		{ name = "finite negative", value = -0.05 }, { name = "fractional", value = 0.003 } }) do
		check(method .. " preserves " .. case.name .. " semantics", function()
			local scheduler = fresh("adapters.timer_scheduler")
			local calls = 0
			local token = scheduler[method](case.value, function() calls = calls + 1 end)
			assert(token.armed == true and uv.is_active(token.timer), "healthy timer was not armed")
			for _ = 1, 3 do uv.sleep(4); uv.run("nowait") end
			assert(method == "after" and calls == 1 or method == "every" and calls >= 3,
				"healthy one-shot/repeating delivery changed")
			assert(scheduler.cancel(token) == true)
			local settled_calls = calls
			uv.sleep(4)
			drain()
			assert(calls == settled_calls and scheduler.activeCount() == 0, "retired timer delivered more work")
		end)
	end
end

for _, method in ipairs({ "after", "every" }) do
	check(method .. " preserves large finite native delays", function()
		local scheduler = fresh("adapters.timer_scheduler")
		local calls = 0
		local token = scheduler[method](1e12, function() calls = calls + 1 end)
		assert(token.armed == true and uv.is_active(token.timer), "large representable delay was refused")
		uv.sleep(3)
		uv.run("nowait")
		assert(calls == 0, "large finite delay was shortened")
		assert(scheduler.cancel(token) == true)
		drain()
		assert(scheduler.activeCount() == 0 and handle_count() == 0, "large timer retained ownership")
	end)
end

check("defer preserves zero and nested next-tick delivery", function()
	local loop = fresh("adapters.event_loop")
	local calls = 0
	assert(loop.defer(function()
		calls = calls + 1
		assert(loop.defer(function() calls = calls + 1 end))
	end))
	loop._run_idle_tick()
	assert(calls == 1, "nested work must wait for the following idle tick")
	loop._run_idle_tick()
	assert(calls == 2, "nested healthy work was lost")
	loop._run_idle_tick()
	assert(calls == 2, "one-shot deferred work was repeated")
end)

check("defer preserves fractional native elapsed delay", function()
	local loop = fresh("adapters.event_loop")
	local calls = 0
	assert(loop.defer(function() calls = calls + 1 end, 8.5))
	loop._run_idle_tick()
	assert(calls == 0, "positive delay was delivered immediately")
	uv.sleep(12)
	loop._run_idle_tick()
	assert(calls == 1, "native elapsed time failed to release due work")
end)

check("defer preserves huge finite delays without starving ordinary work", function()
	local loop = fresh("adapters.event_loop")
	local delayed, ordinary = 0, 0
	assert(loop.defer(function() delayed = delayed + 1 end, 1e308))
	assert(loop.defer(function() ordinary = ordinary + 1 end))
	loop._run_idle_tick()
	assert(delayed == 0 and ordinary == 1, "finite delayed work affected ordinary delivery")
end)

assert(checks == 24, "native finite-admission fixture lost a case")
print(string.format("Native finite timer admission: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
