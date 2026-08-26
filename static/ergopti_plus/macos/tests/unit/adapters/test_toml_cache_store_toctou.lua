--- tests/unit/adapters/test_toml_cache_store_toctou.lua

--- ==============================================================================
--- MODULE: TOML Cache Parse-to-Store Identity Regression Tests
--- DESCRIPTION:
--- Proves that parsed data is cached only under the exact source identity that
--- produced it. An external rewrite between reader.parse() and cache.store()
--- must leave no snapshot that can bind old data to the new file indefinitely.
--- ==============================================================================

local helpers = require("tests.helpers")

local TMP = (os.getenv("TMPDIR") or os.getenv("TMP") or "/tmp"):gsub("[/\\]+$", "")
local SRC = os.tmpname():gsub("\\", "/")
local OLD_BODY = '[[alpha]]\n"key" = { output = "OLD" }\n'
local NEW_BODY = '[[alpha]]\n"key" = { output = "NEW" }\n'
local source_mtime = 1000
local source_size = #OLD_BODY


--- Writes the exact source bytes used by the real cache fingerprint.
--- @param body string TOML source bytes.
local function write_source(body)
	local file = assert(io.open(SRC, "wb"))
	file:write(body)
	file:close()
	source_size = #body
end


--- Mirrors the cache adapter's deterministic snapshot naming for cleanup.
--- @param path string Source path.
--- @return string snapshot Snapshot path.
local function snapshot_path(path)
	local hash = 5381
	for i = 1, #path do hash = (hash * 33 + path:byte(i)) % 4294967296 end
	local base = (path:match("([^/\\]+)$") or "toml"):gsub("[^%w%.%-_]", "_")
	return TMP .. "/" .. base .. "_" .. string.format("%d", hash) .. ".lua"
end


--- Loads the real cache adapter against controllable source metadata.
--- @return table cache Fresh cache adapter.
local function fresh_cache()
	package.loaded["adapters.toml_cache"] = nil
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	local cache = helpers.load_with_stubs("adapters.toml_cache", {
		fs = {
			dir = function() return function() return nil end end,
			pathToAbsolute = function(path) return path end,
			displayName = function(path) return path end,
			mkdir = function() return true end,
			attributes = function(path)
				if path == SRC then
					return { modification = source_mtime, size = source_size }
				end
				return { mode = "directory" }
			end,
		},
	})
	cache.init(TMP)
	return cache
end


helpers.describe("toml_cache: parse-to-store source identity", function()

	helpers.it("refuses stale parsed data after an external rewrite (HS-041)", function()
		helpers.assert_eq(#OLD_BODY, #NEW_BODY,
			"the rewrite must preserve size so only content identity can catch it")
		write_source(OLD_BODY)
		os.remove(snapshot_path(SRC))
		local cache = fresh_cache()
		package.loaded["infra.toml.reader"] = nil
		local reader = helpers.load_with_stubs("infra.toml.reader")
		local rewritten = false
		local original_open = io.open

		reader.set_cache_provider({
			load = cache.load,
			capture_source = function(path)
				if type(cache.capture_source) ~= "function" then return {} end
				return cache.capture_source(path)
			end,
			store = cache.store,
		})

		-- Rewrite only when the reader closes the exact text handle it parsed.
		-- Fingerprint reads use "rb" and therefore cannot trigger this hook. A
		-- capture moved after the parse would observe NEW and incorrectly authorize
		-- the OLD table, which keeps this regression sensitive to ordering.
		io.open = function(path, mode)
			local file, open_error = original_open(path, mode)
			if path ~= SRC or mode ~= "r" or rewritten or not file then
				return file, open_error
			end
			return {
				lines = function() return file:lines() end,
				close = function()
					local closed = file:close()
					write_source(NEW_BODY)
					rewritten = true
					return closed
				end,
			}, nil
		end

		local parse_ok, parsed, committed = pcall(reader.parse, SRC)
		io.open = original_open
		local cached_after_race = cache.load(SRC)
		local writes_after_race = cache.stats().writes
		reader.set_cache_provider(nil)
		os.remove(snapshot_path(SRC))
		os.remove(SRC)

		helpers.assert_eq(parse_ok, true, "the real reader must finish without throwing")
		helpers.assert_eq(committed, true, "the original parse must commit")
		helpers.assert_eq(parsed.sections.alpha.entries[1].output, "OLD",
			"the fixture must parse the pre-rewrite bytes")
		helpers.assert_eq(rewritten, true, "the external rewrite must happen before store")
		helpers.assert_nil(cached_after_race,
			"old parsed data must not be cached under the rewritten file's fresh identity")
		helpers.assert_eq(writes_after_race, 0,
			"a stale parse-to-store source identity must publish no snapshot")
	end)

end)
