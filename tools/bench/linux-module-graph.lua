-- tools/bench/linux-module-graph.lua
-- Report-only probe of the Linux daemon's start-up module graph. Run under
-- Linux LuaJIT:
--   luajit tools/bench/linux-module-graph.lua <repo root> [samples]
-- Each sample is a fresh `luajit ergopti_hotstrings.lua --help` under a
-- throwaway HOME: every file-scope require of the entry runs, then main()
-- prints the usage and exits before any boot stage. The child reports the
-- modules loaded, the Lua source they cost, the process CPU spent until the
-- exit, the forks, and the CPU of compiling the same sources alone and of
-- loading their bytecode (the share no lazy require can save versus the share
-- a precompiled package would). CPU figures are medians; wall time is noisy
-- on a shared machine and only supports them.
local root = assert(arg[1], "repository root required")
local samples = tonumber(arg[2]) or 7
local CHILD_FLAG = "--module-graph-child"

local ffi = require("ffi")
ffi.cdef([[
	typedef struct { long tv_sec; long tv_nsec; } module_graph_timespec;
	int clock_gettime(int clock_id, module_graph_timespec *tp);
	char *getcwd(char *buf, size_t size);
]])
local CLOCK_MONOTONIC, CLOCK_PROCESS_CPUTIME_ID = 1, 2
local stamp = ffi.new("module_graph_timespec")
local function clock_ms(id)
	assert(ffi.C.clock_gettime(id, stamp) == 0, "clock_gettime refused")
	return tonumber(stamp.tv_sec) * 1e3 + tonumber(stamp.tv_nsec) / 1e6
end

local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end

-- 1/ Child: instrument require, os.exit and the fork primitives, then run the
-- entry as the launcher does.
if arg[3] == CHILD_FLAG then
	local cpu0, wall0 = clock_ms(CLOCK_PROCESS_CPUTIME_ID), clock_ms(CLOCK_MONOTONIC)
	local native_require = require
	local exclusive, order, stack, forks = {}, {}, {}, 0
	require = function(name)
		if package.loaded[name] ~= nil then return native_require(name) end
		local started = clock_ms(CLOCK_PROCESS_CPUTIME_ID)
		stack[#stack + 1] = 0
		local ok, result = pcall(native_require, name)
		local elapsed = clock_ms(CLOCK_PROCESS_CPUTIME_ID) - started
		local nested = table.remove(stack)
		if #stack > 0 then stack[#stack] = stack[#stack] + elapsed end
		if not ok then error(result, 0) end
		if exclusive[name] == nil then
			exclusive[name] = elapsed - nested
			order[#order + 1] = name
		end
		return result
	end
	local popen, execute = io.popen, os.execute
	io.popen = function(...) forks = forks + 1; return popen(...) end
	os.execute = function(...) forks = forks + 1; return execute(...) end
	local native_exit = os.exit
	os.exit = function(...)
		local cpu, wall = clock_ms(CLOCK_PROCESS_CPUTIME_ID) - cpu0, clock_ms(CLOCK_MONOTONIC) - wall0
		local loaded = 0
		for _ in pairs(package.loaded) do loaded = loaded + 1 end
		local sources = {}
		for _, name in ipairs(order) do
			local path = package.searchpath(name, package.path)
			if path then
				local handle = assert(io.open(path, "rb"))
				sources[#sources + 1] = { path = path, text = handle:read("*a") }
				handle:close()
			end
		end
		local bytes, compile_started = 0, clock_ms(CLOCK_PROCESS_CPUTIME_ID)
		for _, source in ipairs(sources) do
			bytes = bytes + #source.text
			source.chunk = assert(loadstring(source.text, "@" .. source.path))
		end
		local compile = clock_ms(CLOCK_PROCESS_CPUTIME_ID) - compile_started
		for _, source in ipairs(sources) do source.bytecode = string.dump(source.chunk) end
		local load_started = clock_ms(CLOCK_PROCESS_CPUTIME_ID)
		for _, source in ipairs(sources) do assert(loadstring(source.bytecode)) end
		local bytecode = clock_ms(CLOCK_PROCESS_CPUTIME_ID) - load_started
		io.stdout:write(string.format("MODULE_GRAPH totals %d %d %d %d %.3f %.3f %.3f %.3f\n",
			loaded, #order, bytes, forks, cpu, wall, compile, bytecode))
		for _, name in ipairs(order) do
			io.stdout:write(string.format("MODULE_GRAPH module %s %.3f\n", name, exclusive[name]))
		end
		io.stdout:flush()
		return native_exit(...)
	end
	arg = { [0] = "ergopti_hotstrings.lua", "--help" }
	dofile("ergopti_hotstrings.lua")
	error("ergopti_hotstrings.lua --help returned without exiting")
end

-- 2/ Parent: one fresh process per sample, medians across them.
local function median(values)
	table.sort(values)
	return values[math.ceil(#values / 2)]
end

local driver = root .. "/static/ergopti_plus/linux"
-- The child runs from the driver folder, so this script needs its absolute path.
local script = arg[0]
if script:sub(1, 1) ~= "/" then
	local buffer = ffi.new("char[?]", 4096)
	assert(ffi.C.getcwd(buffer, 4096) ~= nil, "getcwd refused")
	script = ffi.string(buffer) .. "/" .. script
end
local home = os.tmpname()
os.remove(home)
local created = os.execute("mkdir -p " .. quote(home))
assert(created == true or created == 0, "could not create the throwaway HOME")
local columns = { "loaded", "required", "bytes", "forks", "cpu", "wall", "compile", "bytecode" }
local totals, per_module = {}, {}
for _ = 1, samples do
	local command = table.concat({
		"cd", quote(driver), "&&", "env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME",
		"HOME=" .. quote(home), "USER=" .. quote(os.getenv("USER") or "bench"),
		"luajit", quote(script), quote(root), "1", CHILD_FLAG, "2>&1",
	}, " ")
	local pipe = assert(io.popen(command, "r"))
	local seen = false
	for line in pipe:lines() do
		local fields = {}
		for field in line:gmatch("%S+") do fields[#fields + 1] = field end
		if fields[1] == "MODULE_GRAPH" and fields[2] == "totals" then
			seen = true
			for index, name in ipairs(columns) do
				totals[name] = totals[name] or {}
				table.insert(totals[name], tonumber(fields[index + 2]))
			end
		elseif fields[1] == "MODULE_GRAPH" and fields[2] == "module" then
			per_module[fields[3]] = per_module[fields[3]] or {}
			table.insert(per_module[fields[3]], tonumber(fields[4]))
		end
	end
	pipe:close()
	assert(seen, "the child never reached os.exit: run it by hand to see why")
end
os.execute("rm -rf -- " .. quote(home))

local function row(label, value, unit) print(string.format("%-42s %12.1f %s", label, value, unit)) end
row("package.loaded at --help exit", median(totals.loaded), "modules")
row("modules required", median(totals.required), "modules")
row("Lua source of those modules", median(totals.bytes) / 1024, "KB")
row("forks before exit", median(totals.forks), "count")
row("process CPU to exit", median(totals.cpu), "ms")
row("wall to exit (noisy)", median(totals.wall), "ms")
row("compile the same sources alone", median(totals.compile), "ms CPU")
row("load their bytecode instead (debug info kept)", median(totals.bytecode), "ms CPU")
local ranked = {}
for name, values in pairs(per_module) do ranked[#ranked + 1] = { name = name, cpu = median(values) } end
table.sort(ranked, function(a, b) return a.cpu > b.cpu end)
print("heaviest modules (exclusive CPU, load and top-level work):")
for index = 1, math.min(15, #ranked) do row("  " .. ranked[index].name, ranked[index].cpu, "ms CPU") end
