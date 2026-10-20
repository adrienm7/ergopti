--- tests/unit/adapters/storage/toml_cache/test_preserved_source_metadata.lua

--- ==============================================================================
--- MODULE: TOML Cache Content Identity With Preserved Metadata
--- DESCRIPTION:
--- Real files, filesystem timestamps and the real shared reader expose stale
--- hotstrings after an archive-style restore. Only injected binary stream errors
--- are modeled; no Hammerspoon or macOS filesystem execution is claimed.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED = {
	"adapters.toml_cache", "infra.logger", "lfs", "toml_codec.reader", "toml_codec.bom",
	"toml_codec.basic_string", "toml_codec.key_path", "toml_codec.record_scanner", "compat.utf8",
}
local OLD = '[[alpha]]\n"key" = { output = "OLD" }\n'
local NEW = '[[alpha]]\n"key" = { output = "NEW" }\n'
local MTIME = 1700000000

local function output(document) return document.sections.alpha.entries[1].output end

--- Owns actual scratch files and restores the binary-open fault port on every exit.
local function with_cache(run)
	local previous_open, previous_lfs = io.open, rawget(_G, "lfs")
	local fs, root
	local ok, detail = xpcall(function()
		helpers.with_stub_scope(OWNED, function()
			fs = require("lfs")
			root = os.tmpname()
			assert(os.remove(root)); assert(fs.mkdir(root))
			local directory, source = root .. "/cache", root .. "/source.toml"
			assert(fs.mkdir(directory))
			_G.hs = { fs = { attributes = fs.attributes, mkdir = fs.mkdir } }
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local cache, reader = require("adapters.toml_cache"), require("toml_codec.reader")
			cache.init(directory)
			reader.set_cache_provider(cache)
			local env = { source = source, cache = cache, reader = reader, opens = 0, closes = 0 }
			function env.write(body, mtime, target)
				local path = target or source
				local file = assert(previous_open(path, "wb"))
				assert(file:write(body)); assert(file:close())
				assert(fs.touch(path, mtime, mtime))
				local stat = assert(fs.attributes(path))
				helpers.assert_eq(stat.modification, mtime, "the actual filesystem must retain the timestamp")
				helpers.assert_eq(stat.size, #body, "the actual filesystem must retain the byte length")
				return stat
			end
			function env.parse(expected)
				local parsed, committed = reader.parse(source)
				helpers.assert_true(committed, "the real Reader must commit")
				helpers.assert_eq(output(parsed), expected, "the hotstring consumer must see current source content")
				return parsed
			end
			function env.fault(mode)
				io.open = function(path, access)
					local native, open_error = previous_open(path, access)
					if path ~= source or access ~= "rb" or not native then return native, open_error end
					env.opens = env.opens + 1
					local reads, closed = 0, false
					return {
						read = function(_, count)
							reads = reads + 1
							if mode == "read error after bytes" and reads > 1 then return nil, "source read refused", 5 end
							if mode == "read raises" then error("source read raised") end
							return native:read(count)
						end,
						close = function()
							assert(not closed, "a consumed source stream cannot be closed twice")
							closed = true; env.closes = env.closes + 1
							assert(native:close())
							if mode == "close nil" then return nil, "source close refused", 5 end
							if mode == "close raises" then error("source close raised") end
							return true
						end,
					}
				end
			end
			function env.clear_fault() io.open = previous_open end
			env.write(OLD, MTIME)
			env.parse("OLD")
			helpers.assert_eq(cache.stats().writes, 1, "the snapshot must come from a real committed parse")
			run(env, fs)
		end)
	end, debug.traceback)
	io.open = previous_open
	rawset(_G, "lfs", previous_lfs)
	local cleaned, cleanup_error = pcall(function()
		if root then
			for name in fs.dir(root .. "/cache") do
				if name ~= "." and name ~= ".." then assert(os.remove(root .. "/cache/" .. name)) end
			end
			assert(fs.rmdir(root .. "/cache"))
			for name in fs.dir(root) do
				if name ~= "." and name ~= ".." then assert(os.remove(root .. "/" .. name)) end
			end
			assert(fs.rmdir(root))
		end
	end)
	if not ok then error(detail, 0) end
	assert(cleaned, cleanup_error)
end

helpers.describe("TOML cache proves source content even when metadata survives", function()
	helpers.it("serves an unchanged old source from a real disk snapshot", function()
		with_cache(function(env)
			env.parse("OLD")
			helpers.assert_eq(env.cache.stats().hits, 1, "content validation must preserve useful cache hits")
			helpers.assert_eq(env.cache.stats().writes, 1, "a cache hit must not reparse or rewrite")
		end)
	end)

	helpers.it("invalidates a normal timestamp-changing rewrite", function()
		with_cache(function(env)
			env.write(NEW, MTIME + 1)
			env.parse("NEW")
			helpers.assert_eq(env.cache.stats().writes, 2)
		end)
	end)

	for _, method in ipairs({ "in place", "atomic replacement" }) do
		helpers.it("invalidates equal-size preserved-mtime content changed " .. method, function()
			with_cache(function(env, fs)
				helpers.assert_eq(#OLD, #NEW)
				local before = assert(fs.attributes(env.source))
				if method == "in place" then env.write(NEW, MTIME)
				else
					local replacement = env.source .. ".replacement"
					env.write(NEW, MTIME, replacement)
					assert(os.rename(replacement, env.source))
					helpers.assert_true(fs.attributes(env.source).ino ~= before.ino, "the replacement has a new real inode")
				end
				local file = assert(io.open(env.source, "rb"))
				helpers.assert_eq(file:read("*a"), NEW, "actual disk bytes must change before the cache lookup")
				assert(file:close())
				env.parse("NEW")
				helpers.assert_eq(env.cache.stats().writes, 2, "a stale snapshot must be replaced after the real parse")
				env.parse("NEW")
				helpers.assert_eq(env.cache.stats().hits, 1, "the refreshed snapshot remains usable")
			end)
		end)
	end


	helpers.it("distinguishes two valid equal-size TOML inputs with the same FNV32 fingerprint", function()
		with_cache(function(env)
			-- Fixed causal pair found by a bounded deterministic search, not brute-forced by the test.
			local prefix, suffix = '[[alpha]]\n"key" = { output = "', '" }\n'
			local first, second = prefix .. "scijnrxp" .. suffix, prefix .. "vbiqvrbk" .. suffix
			helpers.assert_eq(#first, #second)
			env.write(first, MTIME)
			env.parse("scijnrxp")
			env.parse("scijnrxp")
			local prior_hits = env.cache.stats().hits
			env.write(second, MTIME)
			env.parse("vbiqvrbk")
			helpers.assert_eq(env.cache.stats().hits, prior_hits,
				"the colliding fingerprint cannot authorize the previous parsed output")
			env.parse("vbiqvrbk")
			helpers.assert_eq(env.cache.stats().hits, prior_hits + 1, "the new exact snapshot remains usable")
		end)
	end)



	helpers.it("rejects a valid legacy version-6 snapshot without exact identity while source metadata stays unchanged", function()
		with_cache(function(env, fs)
			local source = '[[alpha]]\n"key" = { output = "scijnrxp" }\n'
			env.write(source, MTIME); env.parse("scijnrxp")
			local before = assert(fs.attributes(env.source))
			local snapshot
			for name in fs.dir(env.cache.stats().dir) do
				if name ~= "." and name ~= ".." then snapshot = env.cache.stats().dir .. "/" .. name end
			end
			local file = assert(io.open(assert(snapshot), "rb"))
			local current = assert(file:read("*a")); assert(file:close())
			local data = assert(current:match("data=(.*)}%s*$"))
			-- This is the real valid parsed payload and the known FNV32 identity
			-- of the unchanged 42-byte source, not a corrupt or mismatched fixture.
			local legacy = string.format("return {ver=6,mtime=%.17g,size=%d,fp=4249101702,wrote_at=%d,data=%s}\n",
				before.modification, before.size, os.time(), data)
			file = assert(io.open(snapshot, "wb")); assert(file:write(legacy)); assert(file:close())
			helpers.assert_nil(env.cache.load(env.source), "legacy hashes cannot attest exact bytes")
			local after = assert(fs.attributes(env.source))
			helpers.assert_eq(after.modification, before.modification)
			helpers.assert_eq(after.size, before.size)
			helpers.assert_eq(after.ino, before.ino)
			env.parse("scijnrxp")
			env.parse("scijnrxp")
			helpers.assert_eq(env.cache.stats().hits, 1, "replacement schema-7 snapshot remains useful")
		end)
	end)

	helpers.it("never stores parsed B under an A token when the real source changes A-B-A", function()
		with_cache(function(env, fs)
			local directory = env.cache.stats().dir
			for name in fs.dir(directory) do
				if name ~= "." and name ~= ".." then assert(os.remove(directory .. "/" .. name)) end
			end
			local native_open, captured, restored = io.open, 0, 0
			local function restore_a() env.write(OLD, MTIME); restored = restored + 1 end
			-- The old producer reads B after capture and restores A on the exact
			-- text-stream close. The snapshot producer parses captured A instead.
			io.open = function(path, access)
				local native, detail = native_open(path, access)
				if path ~= env.source or access ~= "r" or not native then return native, detail end
				return {
					lines = function() return native:lines() end,
					close = function() local closed = native:close(); restore_a(); return closed end,
				}
			end
			env.reader.set_cache_provider({
				load = env.cache.load,
				capture_source = function(path)
					local token = assert(env.cache.capture_source(path))
					captured = captured + 1; env.write(NEW, MTIME)
					return token
				end,
				read_snapshot = function(path, token)
					local bytes = env.cache.read_snapshot(path, token)
					restore_a()
					return bytes
				end,
				store = env.cache.store,
			})
			local _, committed = env.reader.parse(env.source)
			helpers.assert_true(committed)
			helpers.assert_eq(captured, 1)
			helpers.assert_eq(restored, 1, "the actual source must return to A before store")
			env.clear_fault()
			env.reader.set_cache_provider(env.cache)
			local file = assert(io.open(env.source, "rb"))
			helpers.assert_eq(file:read("*a"), OLD); assert(file:close())
			env.parse("OLD")
			helpers.assert_eq(env.cache.stats().hits, 1,
				"only a snapshot parsed from the attested A bytes may serve the restored source")
			local token = assert(env.cache.capture_source(env.source))
			helpers.assert_eq(env.cache.read_snapshot(env.source, token), OLD)
			helpers.assert_nil(env.cache.read_snapshot(env.source .. ".foreign", token), "a receipt cannot attest another path")
			helpers.assert_nil(env.cache.read_snapshot(env.source, {}), "a foreign receipt cannot reveal captured bytes")
		end)
	end)

	for _, mode in ipairs({ "read error after bytes", "read raises", "close nil", "close raises" }) do
		helpers.it("refuses source-byte admission with " .. mode .. " and retires its stream once", function()
			with_cache(function(env)
				env.fault(mode)
				local cached = env.cache.load(env.source)
				helpers.assert_nil(cached, "refused source IO cannot authorize a cached hotstring")
				helpers.assert_eq(env.opens, 1)
				helpers.assert_eq(env.closes, 1, "even read failure must retire the exact stream")
				env.clear_fault()
				env.parse("OLD")
				helpers.assert_eq(env.cache.stats().hits, 1, "transient source IO refusal leaves the snapshot retryable")
			end)
		end)
	end
end)
