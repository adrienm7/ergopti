-- tools/bench/linux-hot-path.lua
-- Report-only probe of the Linux driver's hot path. Run under Linux LuaJIT:
--   luajit tools/bench/linux-hot-path.lua <repo root> [samples]
-- Counted operations (allocated KB, forks, idle ticks) are the evidence;
-- the CPU figures are medians of `samples` runs and only support them.
local root = assert(arg[1], "repository root required")
local samples = tonumber(arg[2]) or 7
local driver = root .. "/static/ergopti_plus/linux"
local shared = root .. "/static/ergopti_plus/_shared/lua"
package.path = table.concat({
	driver .. "/?.lua", driver .. "/?/init.lua", shared .. "/?.lua", shared .. "/?/init.lua",
	driver .. "/tests/?.lua", driver .. "/tests/?/init.lua", package.path,
}, ";")
local compat = require("compat.utf8")
if compat.install then compat.install() end
local luv = require("luv")

local function median(values)
	table.sort(values)
	return values[math.ceil(#values / 2)]
end

local report = {}
local function record(name, value, unit)
	report[#report + 1] = string.format("%-34s %12.3f %s", name, value, unit)
end

-- Forks and shell-outs are counted, never timed.
local forks = 0
local native_popen, native_execute = io.popen, os.execute
io.popen = function(...) forks = forks + 1; return native_popen(...) end
os.execute = function(...) forks = forks + 1; return native_execute(...) end

-- 1/ Idle event loop: iterations and CPU spent while nothing happens.
do
	local ticks_per_s, cpu = {}, {}
	for _ = 1, samples do
		package.loaded["adapters.event_loop"] = nil
		local loop = require("adapters.event_loop")
		local ticks, started, cpu0 = 0, luv.hrtime(), os.clock()
		local stop_after_ms = 400
		loop.run({
			onIdle = function()
				ticks = ticks + 1
				if (luv.hrtime() - started) / 1e6 >= stop_after_ms then loop.stop() end
			end,
			onPeriodic = function() end,
			periodSec = 0.25,
		})
		local seconds = (luv.hrtime() - started) / 1e9
		ticks_per_s[#ticks_per_s + 1] = ticks / seconds
		cpu[#cpu + 1] = (os.clock() - cpu0) / seconds * 100
	end
	record("idle loop: onIdle calls / s", median(ticks_per_s), "calls/s")
	record("idle loop: CPU of one core", median(cpu), "%")
end

-- 1b/ Idle event loop as the daemon runs it: sleeping on the input descriptors.
-- A FIFO stands in for the keyboard so the real poll(2) path is measured.
do
	local reader = require("adapters.evdev_reader")
	local path = os.tmpname()
	os.remove(path)
	-- A tree without the input wait (an older checkout) skips this section.
	if type(reader.wait_any_readable) == "function" and os.execute("mkfifo '" .. path .. "'")
		and reader.use_ffi_backend() and reader.open(path, reader.KEYBOARD) then
		local ticks_per_s, cpu = {}, {}
		for _ = 1, samples do
			package.loaded["adapters.event_loop"] = nil
			local loop = require("adapters.event_loop")
			local ticks, started, cpu0 = 0, luv.hrtime(), os.clock()
			loop.run({
				onIdle = function()
					ticks = ticks + 1
					if (luv.hrtime() - started) / 1e6 >= 1000 then loop.stop() end
				end,
				onPeriodic = function() end,
				periodSec = 0.25,
				idleWait = function(timeout_ms) return reader.wait_any_readable(timeout_ms) end,
			})
			local seconds = (luv.hrtime() - started) / 1e9
			ticks_per_s[#ticks_per_s + 1] = ticks / seconds
			cpu[#cpu + 1] = (os.clock() - cpu0) / seconds * 100
		end
		record("idle loop + input wait: ticks / s", median(ticks_per_s), "ticks/s")
		record("idle loop + input wait: CPU of one core", median(cpu), "%")
		reader.close(reader.KEYBOARD)
	end
	os.remove(path)
end

-- 2/ Key path: a recorded typing stream through the real hook and the engine.
do
	local helpers = require("tests.helpers")
	local Engine = require("platform.remap.tap_hold_engine")
	local keys = {
		caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = 0.15 },
		left_shift = { tap_action = "", hold_modifier = "shift", time_activation_seconds = 0.15 },
	}
	local letters = { 30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38 }
	local events, per_key = {}, 0
	for repeat_index = 1, 250 do
		local code = letters[repeat_index % #letters + 1]
		events[#events + 1] = { type = 1, code = code, value = 1, at_ms = repeat_index * 40 }
		events[#events + 1] = { type = 1, code = code, value = 0, at_ms = repeat_index * 40 + 20 }
		per_key = per_key + 2
	end
	local function run(with_engine)
		local kh = helpers.load_module("adapters.keyboard_hook")
		if with_engine then
			kh.set_remapper(Engine.new({ keys = keys, tap_min_ms = 0, one_shot_timeout_ms = 2000 }), function() end)
		end
		local emitted = 0
		collectgarbage("collect"); collectgarbage("stop")
		local heap0, cpu0, forks0 = collectgarbage("count"), os.clock(), forks
		kh._test_drive(events, { onEmitRaw = function() emitted = emitted + 1; return true end,
			onChar = function() end }, true)
		local cpu, heap = os.clock() - cpu0, collectgarbage("count") - heap0
		collectgarbage("restart")
		if with_engine then kh.set_remapper(nil) end
		return cpu / per_key * 1e6, heap * 1024 / per_key, forks - forks0
	end
	for _, with_engine in ipairs({ false, true }) do
		local cpus, bytes, spawned = {}, {}, 0
		for _ = 1, samples do
			local cpu, allocated, f = run(with_engine)
			cpus[#cpus + 1], bytes[#bytes + 1], spawned = cpu, allocated, f
		end
		local label = with_engine and "key path + tap-hold" or "key path (no engine)"
		record(label .. ": CPU / event", median(cpus), "us")
		record(label .. ": allocated / event", median(bytes), "bytes")
		record(label .. ": forks", spawned, "count")
	end
end

-- 3/ Startup parsing: the migration registry (decoded on every boot) and the
-- shipped hotstring packs (the bulk of the config stage).
do
	local codec = require("toml_codec")
	local reader = require("toml_codec.reader")
	local function slurp(path)
		local handle = assert(io.open(path, "rb"))
		local content = handle:read("*a")
		handle:close()
		return content
	end
	local registry = slurp(root .. "/static/ergopti_plus/_shared/core/config_schema/migrations.toml")
	local packs = {}
	for path in io.popen("find '" .. root .. "/static/ergopti_plus/_shared/modules/hotstrings' -name '*.toml'"):lines() do
		packs[#packs + 1] = slurp(path)
	end
	local decode_ms, reader_ms = {}, {}
	for _ = 1, samples do
		local started = luv.hrtime()
		codec.decode(registry)
		decode_ms[#decode_ms + 1] = (luv.hrtime() - started) / 1e6
		started = luv.hrtime()
		for _, pack in ipairs(packs) do reader.parse_text(pack) end
		reader_ms[#reader_ms + 1] = (luv.hrtime() - started) / 1e6
	end
	record("startup: migrations.toml decode", median(decode_ms), "ms")
	record("startup: shipped hotstring packs parse", median(reader_ms), "ms")
end

print(table.concat(report, "\n"))
