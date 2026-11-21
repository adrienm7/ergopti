--- tests/unit/settings/migration/test_registry_cache.lua

--- ==============================================================================
--- MODULE: Registry Parse Cache Tests
--- DESCRIPTION:
--- The macOS typed cache of migrations.toml serves the cached model only for the
--- exact source and parser it was built from, validates it on every hit, and
--- refuses a stale, foreign or corrupt file: the source is parsed again and the
--- refusal logged. Config migration rewrites a user's settings, so each of
--- these is a test of what a wrong cache would rewrite.
--- ==============================================================================

local helpers = require("tests.helpers")
local Digest = require("tests.support.content_digest")

local SOURCE = helpers.shared(require("settings.engine.migration.migrate").REGISTRY_PATH)
-- The parser file this test edits, found as the cache finds it.
local CODEC_PATH = assert(package.searchpath("core.text.engine.toml_codec.codec", package.path))

--- Reads a whole file or nil.
local function read_file(path)
	local handle = io.open(path, "rb")
	if not handle then return nil, "missing" end
	local bytes = handle:read("a")
	handle:close()
	return bytes
end

--- Writes a whole file.
local function write_file(path, bytes)
	local handle = assert(io.open(path, "wb"))
	assert(handle:write(bytes))
	assert(handle:close())
	return true
end

--- Lists a folder as hs.fs.dir would, through the system's ls.
local function list_dir(dir)
	local names = {}
	local pipe = assert(io.popen("ls -1 " .. require("core.text.engine.utils_core").shell_quote(dir)))
	for name in pipe:lines() do names[#names + 1] = name end
	pipe:close()
	return names
end

--- Builds one fixture: a fresh cache module over a scratch cache file, with
--- a content-exact hash and an optional edit of the parser or the source.
local function fixture(name)
	local scratch = helpers.temp_dir() .. "/ergopti_registry_cache_" .. name .. "_" .. tostring(os.time())
	os.remove(scratch)
	local f = { cache_path = scratch, logs = {}, parser_suffix = "", source_suffix = "", parses = 0 }
	local oracle = Digest.create()
	f.hash = oracle.for_bytes
	package.loaded["settings.adapters.registry_cache"] = nil
	local Logger = require("core.logger.engine.logger")
	local Codec = require("core.text.engine.toml_codec")
	local Cache = require("settings.adapters.registry_cache")
	f.cache = Cache
	local saved = { info = Logger.info, warn = Logger.warn, decode = Codec.decode }
	Logger.info = function(_, message, ...) f.logs[#f.logs + 1] = "INFO " .. string.format(message, ...) end
	Logger.warn = function(_, message, ...) f.logs[#f.logs + 1] = "WARN " .. string.format(message, ...) end
	Codec.decode = function(...)
		f.parses = f.parses + 1
		return saved.decode(...)
	end
	function f.restore()
		Logger.info, Logger.warn, Codec.decode = saved.info, saved.warn, saved.decode
		os.remove(scratch)
		Cache._reset()
	end
	Cache.init({ cache_path = scratch, ports = {
		hash = oracle.for_bytes,
		read = function(path)
			local bytes, detail = read_file(path)
			if bytes == nil then return nil, detail end
			if path == CODEC_PATH then return bytes .. f.parser_suffix end
			if path == SOURCE then return bytes .. f.source_suffix end
			return bytes
		end,
		write = write_file,
		list_dir = list_dir,
		ensure_dir = function() return true end,
		clock = function() return os.clock() * 1000 end,
	} })
	function f.load()
		f.parses = 0
		return Cache.load_registry(SOURCE)
	end
	function f.logged(pattern)
		for _, line in ipairs(f.logs) do
			if line:find(pattern) then return true end
		end
		return false
	end
	return f
end

--- Runs one case and always restores the patched modules.
local function with_fixture(name, body)
	local f = fixture(name)
	local ok, err = pcall(body, f)
	f.restore()
	if not ok then error(err, 0) end
end

helpers.describe("Registry parse cache", function()
	helpers.it("parses on the first boot, then serves a validated hit without parsing", function()
		with_fixture("hit", function(f)
			local first = assert(f.load())
			helpers.assert_eq(f.parses, 1, "the first boot parses the source")
			helpers.assert_true(read_file(f.cache_path) ~= nil, "the cache is published")
			local second = assert(f.load())
			helpers.assert_eq(f.parses, 0, "a hit does not parse")
			helpers.assert_true(f.logged("cache hit, validated"), "the hit is logged")
			helpers.assert_eq(second.current, first.current, "current version")
			helpers.assert_eq(#second.steps, #first.steps, "same chain")
			for index, step in ipairs(first.steps) do
				helpers.assert_eq(require("core.text.engine.json").encode(second.steps[index].ops),
					require("core.text.engine.json").encode(step.ops), "step " .. index .. " ops")
			end
		end)
	end)

	helpers.it("treats a changed registry source as a stale key and parses it", function()
		with_fixture("stale_source", function(f)
			assert(f.load())
			f.source_suffix = "\n# edited\n"
			assert(f.load())
			helpers.assert_eq(f.parses, 1, "the edited source is parsed again")
			helpers.assert_true(f.logged("cache is stale"), "the stale key is logged")
		end)
	end)

	helpers.it("treats a changed parser as a stale key and parses the source", function()
		with_fixture("stale_parser", function(f)
			assert(f.load())
			f.parser_suffix = "\n-- parser changed\n"
			assert(f.load())
			helpers.assert_eq(f.parses, 1, "a parser change parses again")
			helpers.assert_true(f.logged("cache is stale"), "the parser change is logged as stale")
			assert(f.load())
			helpers.assert_eq(f.parses, 0, "the rebuilt cache serves the new parser")
		end)
	end)

	helpers.it("refuses a corrupt cache file, parses the source and rewrites the cache", function()
		for label, corrupt in pairs({
			truncated = function(text) return text:sub(1, #text - 9) end,
			flipped = function(text) return text:sub(1, -2) .. string.char((text:byte(-1) + 1) % 256) end,
			garbage = function() return "not a cache\n" end,
			empty = function() return "" end,
		}) do
			with_fixture("corrupt_" .. label, function(f)
				assert(f.load())
				write_file(f.cache_path, corrupt(read_file(f.cache_path)))
				f.logs = {}
				local registry = f.load()
				helpers.assert_true(registry ~= nil, label .. ": the source still loads")
				helpers.assert_eq(f.parses, 1, label .. ": the source is parsed again")
				helpers.assert_true(f.logged("^WARN Registry parse cache refused"), label .. ": the refusal is logged")
				f.load()
				helpers.assert_eq(f.parses, 0, label .. ": the rewritten cache is served")
			end)
		end
	end)

	helpers.it("still validates a hit and refuses a cached model the validator rejects", function()
		with_fixture("hit_validates", function(f)
			assert(f.load())
			local text = read_file(f.cache_path)
			local identity = text:match("^(%x+)\n")
			-- A well-formed cache of the right identity whose model breaks the chain.
			local model = require("core.text.engine.toml_codec").decode(read_file(SOURCE))
			model.registry.current_version = model.registry.current_version + 1
			write_file(f.cache_path, f.cache.envelope(identity, f.cache.encode(model), f.hash))
			f.logs = {}
			local registry = f.load()
			helpers.assert_true(registry ~= nil, "the source still loads")
			helpers.assert_true(f.logged("^WARN Registry parse cache refused"), "the forged hit is refused")
			helpers.assert_eq(f.parses, 1, "the source is parsed again")
		end)
	end)

	helpers.it("round-trips every value type and rejects forged payloads", function()
		with_fixture("codec", function(f)
			local Cache = f.cache
			local value = { "a", 2, 3.5, true, false, { nested = { 1, 2 } }, key = "v", [""] = 0, float = 1.0 }
			local back = Cache.decode(Cache.encode(value))
			helpers.assert_eq(back[1], "a", "string")
			helpers.assert_eq(math.type(back[2]), "integer", "integer kept")
			helpers.assert_eq(math.type(back.float), "float", "float kept")
			helpers.assert_eq(back[5], false, "false kept")
			helpers.assert_eq(back[6].nested[2], 2, "nested")
			helpers.assert_eq(back[""], 0, "empty key")
			local payload = Cache.encode(value)
			helpers.assert_throws(function() Cache.decode(payload .. "x") end, "trailing bytes")
			helpers.assert_throws(function() Cache.decode(payload:sub(1, -2)) end, "truncated")
			helpers.assert_throws(function() Cache.decode("T" .. string.pack(">I4I4", 1000000, 0)) end, "count")
			helpers.assert_throws(function() Cache.decode("Xabc") end, "unknown tag")
			helpers.assert_throws(function()
				Cache.decode("T" .. string.pack(">I4I4", 0, 2) .. string.pack(">s4", "b") .. "1"
					.. string.pack(">s4", "a") .. "1")
			end, "unsorted keys")
			helpers.assert_throws(function() Cache.encode({ [{}] = 1 }) end, "table keys")
			helpers.assert_throws(function() Cache.encode({ f = print }) end, "functions")
			-- No cached byte can be code: a Lua chunk is just an unknown tag.
			helpers.assert_throws(function() Cache.decode("return {}") end, "a Lua chunk")
		end)
	end)

	helpers.it("is the loader config_migrate.run calls instead of its own parse", function()
		local Migrate = require("settings.engine.migration.migrate")
		local asked = nil
		local result = Migrate.run({
			path = helpers.temp_dir() .. "/ergopti_registry_loader_config.toml",
			driver = "hs",
			registry_path = SOURCE,
			registry_loader = function(path) asked = path; return nil, "the loader refused" end,
			read = function() return "", "missing" end,
			publish = function() return false, "unused" end,
			create_backup = function() return false, "unused" end,
			logger = helpers.make_logger_stub(),
		})
		helpers.assert_eq(asked, SOURCE, "the loader receives the registry path")
		helpers.assert_eq(result.detail, "the loader refused", "the loader's refusal is the run's")
		-- The boot is the production source that hands the loader to the run.
		local boot = helpers.read_driver_source("registry_loader = registry_loader")
		helpers.assert_true(boot ~= nil and boot:find('require("settings.adapters.registry_cache")', 1, true) ~= nil, "the boot wires the cache")
	end)

	helpers.it("refuses a second initialization", function()
		with_fixture("init", function(f)
			helpers.assert_throws(function() f.cache.init({ cache_path = f.cache_path }) end, "duplicate init")
		end)
	end)
end)
