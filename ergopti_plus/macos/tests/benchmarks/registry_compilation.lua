--- tests/benchmarks/registry_compilation.lua

--- ==============================================================================
--- MODULE: Matched Registry Compilation Benchmark
--- DESCRIPTION:
--- Run from the macOS driver root. Executes real properties with compilation
--- reuse disabled, then enabled, checking every generated input for equality.
--- Clock units are elapsed on Windows Lua and CPU on POSIX Lua, not native
--- Hammerspoon callback latency. No benchmark runs in the ordinary unit suite.
--- ==============================================================================

package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path
local helpers = require("tests.helpers")
local pbt = require("tests.lib.pbt")
local isolation = require("tests.support.module_isolation")
local check = pbt.check
local root = helpers.driver_root():gsub("/+$", "")
local history = {}

local function signature(value)
	local kind = type(value)
	if kind == "string" then return "s" .. #value .. ":" .. value end
	if kind ~= "table" then return kind .. ":" .. tostring(value) end
	local keys, parts = {}, {}
	for key in pairs(value) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return type(a) .. tostring(a) < type(b) .. tostring(b) end)
	for _, key in ipairs(keys) do parts[#parts + 1] = signature(key) .. "=" .. signature(value[key]) end
	return "{" .. table.concat(parts, ";") .. "}"
end

local function payload_bytes()
	local index = 1
	while true do
		local name, value = debug.getupvalue(package.searchers[2], index)
		assert(name, "benchmark must observe the active compilation cache")
		if name == "cache" then
			local bytes = 0
			for _, entry in pairs(value) do bytes = bytes + #entry.source + #entry.bytecode end
			return bytes
		end
		index = index + 1
	end
end

for _, phase in ipairs({ "baseline", "validated_cache" }) do
	isolation.purge(root, root .. "/../_shared/lua")
	helpers.reset_results()
	helpers.set_only_filter(nil)
	local properties, samples = 0, 0
	pbt.check = function(label, generator, predicate, options)
		properties = properties + 1
		local opts = {}
		for key, value in pairs(options or {}) do opts[key] = value end
		opts.seed = 424242
		local index = 0
		if phase == "baseline" then history[label] = { runs = opts.runs, inputs = {} } end
		local prior = assert(history[label], "both phases must execute the same properties")
		assert(prior.runs == opts.runs, "sample counts must remain identical")
		local traced = { generate = function(rng, size)
			local value = generator.generate(rng, size)
			index, samples = index + 1, samples + 1
			local encoded = signature(value)
			if phase == "baseline" then prior.inputs[index] = encoded
			else assert(prior.inputs[index] == encoded, label .. ": differing sample " .. index) end
			return value
		end }
		local result = check(label, traced, predicate, opts)
		assert(index == #prior.inputs, "both phases must consume the same input count")
		return result
	end
	local scope = require("tests.support.compiled_lua_scope")
	local original_scope = scope.with_scope
	local stats = { hits = 0, misses = 0, max_payload_bytes = 0 }
	scope.with_scope = function(callback)
		if phase == "baseline" then return callback() end
		return original_scope(function(counts)
			local result = table.pack(callback())
			stats.hits, stats.misses = stats.hits + counts.hits, stats.misses + counts.misses
			stats.max_payload_bytes = math.max(stats.max_payload_bytes, payload_bytes())
			return table.unpack(result, 1, result.n)
		end)
	end
	local started = os.clock()
	local ok, reason = pcall(dofile, "tests/unit/modules/keymap/test_hotstring_properties.lua")
	local elapsed = os.clock() - started
	scope.with_scope, pbt.check = original_scope, check
	assert(ok, reason)
	local result = helpers.get_results()
	assert(result.failed == 0 and result.passed == 14 and properties == 14 and samples == 5200,
		"the complete registered property workload must remain green")
	print(string.format("BENCH %s clock_seconds=%.6f properties=%d samples=%d hits=%d misses=%d max_payload_bytes=%d",
		phase, elapsed, properties, samples, stats.hits, stats.misses, stats.max_payload_bytes))
end
