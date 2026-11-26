--- tests/hardware/bench_sqlite_store_boot.lua

--- ==============================================================================
--- MODULE: Metrics Store Boot Benchmark (Linux)
--- DESCRIPTION:
--- `luajit tests/hardware/bench_sqlite_store_boot.lua <driver root> [boots]`.
--- Times the synchronous writer's warm store boot (open_db, register_device,
--- both migration checks, read_open_walk) on a scratch store, one process per
--- statement against the persistent sqlite3 child, interleaved, in three sets,
--- and prints each set's median, p95 and maximum. Wall clock (CLOCK_MONOTONIC);
--- the persistent figure includes the child's start, and close_db is timed
--- apart. Never run by the unit suite; it never touches the user's store.
--- ==============================================================================

local root = assert(arg[1], "usage: bench_sqlite_store_boot.lua <linux driver root> [boots]")
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/../_shared/?.lua;" .. root
	.. "/../_shared/?/init.lua;" .. package.path
assert(rawget(_G, "jit"), "the persistent child needs LuaJIT")
local ok_utf8, compat_utf8 = pcall(require, "core.lifecycle.engine.compat.utf8")
if ok_utf8 and compat_utf8.install then compat_utf8.install() end

local ffi = require("ffi")
pcall(ffi.cdef, "int ergopti_bench_clock_gettime(int clock, void *spec) __asm__(\"clock_gettime\");")
local function now_ms()
	local spec = ffi.new("int64_t[2]")
	ffi.C.ergopti_bench_clock_gettime(1, spec)
	return tonumber(spec[0]) * 1000 + tonumber(spec[1]) / 1e6
end

local BOOTS = tonumber(arg[2]) or 21
local DEVICE = "linux-bench"
local scratch = assert(io.popen("mktemp -d")):read("*l")
local db = scratch .. "/metrics.sqlite"

--- One warm boot on a freshly loaded writer, as a new daemon process has.
local function boot(persistent)
	package.loaded["modules.keystats.sqlite_writer"] = nil
	local Writer = require("modules.keystats.sqlite_writer")
	local started = now_ms()
	assert(Writer.open_db(db, { persistent_child = persistent }), "open_db")
	assert(Writer.register_device(DEVICE, "bench", "linux", "6", "bench"), "register_device")
	assert(Writer.ensure_token_encoding(), "ensure_token_encoding")
	assert(Writer.ensure_awake_definition(DEVICE, os.date("%Y-%m-%d")), "ensure_awake_definition")
	Writer.read_open_walk(DEVICE)
	local booted = now_ms()
	Writer.close_db()
	return booted - started, now_ms() - booted
end

local function summary(values)
	table.sort(values)
	return string.format("median %.1f ms, p95 %.1f ms, max %.1f ms", values[math.ceil(#values / 2)],
		values[math.ceil(#values * 0.95)], values[#values])
end

boot(false) -- Creates and migrates the store: every timed boot is warm.
boot(true)
for set = 1, 3 do
	local samples = { [false] = { boot = {}, close = {} }, [true] = { boot = {}, close = {} } }
	for _ = 1, BOOTS do
		for _, persistent in ipairs({ false, true }) do
			local spent, closed = boot(persistent)
			table.insert(samples[persistent].boot, spent)
			table.insert(samples[persistent].close, closed)
		end
	end
	for _, persistent in ipairs({ false, true }) do
		print(string.format("set %d %-18s store boot %s; close_db %s", set,
			persistent and "persistent child" or "process per call", summary(samples[persistent].boot),
			summary(samples[persistent].close)))
	end
end
os.execute("rm -rf '" .. scratch .. "'")
