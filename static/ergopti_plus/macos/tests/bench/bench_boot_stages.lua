--- tests/bench/bench_boot_stages.lua

--- ==============================================================================
--- MODULE: macOS Headless Boot Stage Benchmark
--- DESCRIPTION:
--- Boots the real init.lua of a staged ErgoptiPlus.app N times through the
--- installed-application scenario harness (tests/e2e/boot), with only the
--- operating-system edges replaced, and prints each BootProfile stage's median
--- CPU time. The world's clock is virtual, so wall times read 0 ms; the CPU
--- figure each "Boot stage completed" line carries is real Lua work. Native
--- costs (AppKit, AX, hs.json, Karabiner) are not reproduced: read the Mac's
--- Boot summary and Phase summary lines for those.
---
--- USAGE (from the driver root; USER must name an account, as on a Mac):
---     USER=tester lua5.4 tests/bench/bench_boot_stages.lua
---     USER=tester lua5.4 tests/bench/bench_boot_stages.lua --runs=9 --scenario="the neutral defaults boot"
---
--- FEATURES & RATIONALE:
--- 1. The boot under measurement is the one the scenario judges, so a stage that
---    raises or logs an ERROR also fails the run instead of looking fast.
--- 2. One architecture's child per boot is read (arm64): the harness boots both
---    at once, and the two compete for CPU, so medians over several runs matter.
--- ==============================================================================

local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
local driver_root = self_path:match("^(.*)/tests/bench/bench_boot_stages%.lua$") or "."
-- The harness derives the repository from an absolute driver path.
if driver_root == "." then driver_root = assert(os.getenv("PWD"), "run from the driver root")
elseif driver_root:sub(1, 1) ~= "/" then driver_root = assert(os.getenv("PWD")) .. "/" .. driver_root:gsub("^%./", "") end
package.path = driver_root .. "/../_shared/lua/?.lua;" .. driver_root .. "/../_shared/lua/?/init.lua;" .. package.path





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

local DEFAULT_RUNS = 5
local DEFAULT_SCENARIO = "the neutral defaults boot"
local MEASURED_ARCH = "arm64"
-- Stages below this median are summed but not listed.
local LISTED_MIN_MS = 5





-- ============================
-- ============================
-- ======= 2/ Runner ==========
-- ============================
-- ============================

local runs, scenario = DEFAULT_RUNS, DEFAULT_SCENARIO
for _, argument in ipairs(arg or {}) do
	local option, value = argument:match("^%-%-([%w_]+)=(.+)$")
	if option == "runs" then runs = assert(tonumber(value), "--runs must be a number")
	elseif option == "scenario" then scenario = value
	else error("unknown argument " .. argument .. " (use --runs=, --scenario=)") end
end
assert((os.getenv("USER") or "") ~= "", "USER must name an account: the logger's privacy identity refuses a boot without one")

--- The median of a list of numbers.
local function median(values)
	local sorted = { table.unpack(values) }
	table.sort(sorted)
	local middle = (#sorted + 1) / 2
	return (sorted[math.floor(middle)] + sorted[math.ceil(middle)]) / 2
end

local stages, order = {}, {}
local real_execute = os.execute
for run = 1, runs do
	local outputs = {}
	-- The scenario deletes its children's output files: read each one as soon as
	-- the command that wrote it returns.
	os.execute = function(command)
		local first, kind, code = real_execute(command)
		if command:find("boot_child.lua", 1, true) then
			for path in command:gmatch("> '([^']+%.out)'") do
				if path:find(MEASURED_ARCH, 1, true) then
					local handle = io.open(path, "r")
					if handle then outputs[#outputs + 1] = handle:read("a"); handle:close() end
				end
			end
		end
		return first, kind, code
	end
	local failures = 0
	dofile(driver_root .. "/tests/e2e/boot/boot_scenarios.lua").run({
		pass = function() end,
		fail = function(label, _, actual)
			failures = failures + 1
			io.stderr:write("FAIL " .. label .. ": " .. tostring(actual) .. "\n")
		end,
		skip = function(label) io.stderr:write("SKIP " .. label .. "\n") end,
	}, { driver = driver_root, interpreter = arg[-1] or "lua5.4", scenario = scenario })
	os.execute = real_execute
	assert(failures == 0, "the boot under measurement failed its scenario")
	assert(#outputs > 0, "no " .. MEASURED_ARCH .. " boot output was captured")
	for line in outputs[1]:gmatch("[^\n]+") do
		local name, cpu = line:match("Boot stage completed: (.-) in .-cpu ([%d.]+) ms")
		if name then
			if not stages[name] then stages[name] = {}; order[#order + 1] = name end
			stages[name][#stages[name] + 1] = tonumber(cpu)
		end
	end
	io.stderr:write(string.format("boot %d/%d done\n", run, runs))
end

local rows, total = {}, 0
for _, name in ipairs(order) do
	local values = stages[name]
	local middle = median(values)
	total = total + middle
	table.sort(values)
	rows[#rows + 1] = { name = name, median = middle, min = values[1], max = values[#values] }
end
table.sort(rows, function(a, b) return a.median > b.median end)
print(string.format("Boot stages, CPU ms over %d boot(s) of '%s' (%s):", runs, scenario, MEASURED_ARCH))
for _, row in ipairs(rows) do
	if row.median >= LISTED_MIN_MS then
		print(string.format("  %7.1f  (min %6.1f, max %6.1f)  %s", row.median, row.min, row.max, row.name))
	end
end
print(string.format("  %7.1f  sum of stage medians", total))
