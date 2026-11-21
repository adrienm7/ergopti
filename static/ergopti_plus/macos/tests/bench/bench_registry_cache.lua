--- tests/bench/bench_registry_cache.lua

--- ==============================================================================
--- MODULE: Registry Parse Cache Benchmark
--- DESCRIPTION:
--- Run from the macOS driver root with lua5.4. Times, interleaved, the boot
--- path without the cache (decode migrations.toml, then validate) and a cache
--- hit (open the typed envelope, decode the payload, then validate), and
--- prints the median, p90 and maximum of each. The SHA-256 of the source and
--- parser files is native on a Mac (hs.hash.SHA256) and replaced here by a
--- constant, so it is not in either number. CPU clock, not Hammerspoon time.
--- No benchmark runs in the ordinary unit suite.
--- ==============================================================================

package.path = "./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;./tests/?.lua;./tests/stubs/?.lua;"
	.. package.path
local helpers = require("tests.helpers")
-- The cache reads its payload bound from the registry, as the unit suite does.
helpers.provide_timings()
local Migrate = require("settings.engine.migration.migrate")
local TomlCodec = require("core.text.engine.toml_codec")
local Cache = require("settings.adapters.registry_cache")

local ROUNDS = tonumber(arg and arg[1]) or 21
local IDENTITY = string.rep("a", 64)
local function hash() return string.rep("b", 64) end

local handle = assert(io.open(helpers.shared("settings/data/config_schema/migrations.toml"), "rb"))
local source = handle:read("a")
handle:close()
local envelope = Cache.envelope(IDENTITY, Cache.encode(TomlCodec.decode(source)), hash)

local function timed(body)
	local started = os.clock()
	assert(body())
	return (os.clock() - started) * 1000
end

local samples = { parse = {}, hit = {} }
for _ = 1, ROUNDS do
	samples.parse[#samples.parse + 1] = timed(function() return Migrate.validate_registry(TomlCodec.decode(source)) end)
	samples.hit[#samples.hit + 1] = timed(function()
		return Migrate.validate_registry(Cache.open_envelope(envelope, IDENTITY, hash))
	end)
end

local function report(name, values)
	table.sort(values)
	print(string.format("%-6s median %.2f ms  p90 %.2f ms  max %.2f ms  (%d rounds, %d source bytes, %d cache bytes)",
		name, values[math.ceil(#values / 2)], values[math.ceil(#values * 0.9)], values[#values], #values, #source,
		#envelope))
end
report("parse", samples.parse)
report("hit", samples.hit)
