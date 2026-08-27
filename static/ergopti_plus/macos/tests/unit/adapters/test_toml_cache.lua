--- tests/unit/adapters/test_toml_cache.lua

--- ==============================================================================
--- MODULE: TOML hotstring cache adapter (regression)
--- DESCRIPTION:
--- Validates the disk-snapshot cache that accelerates hotstring boot loading.
---
--- ROOT CAUSE ENCODED: two failure modes that a caching layer must never have.
--- 1. CORRUPTION — a snapshot must deserialise to a table structurally identical
---    to what reader.parse() produced, including lang-map description tables,
---    nested sections, quote/newline/UTF-8 strings, and integer vs float numbers.
---    The round-trip assertion below would fail if the serialiser ever drops or
---    mangles a field.
--- 2. STALENESS — a snapshot must be served ONLY when the source's mtime AND size
---    still match the values captured at write time. If invalidation regresses,
---    an edited hotstrings file would keep loading its old contents forever; the
---    mtime/size mismatch tests guard exactly that.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Use the OS temp directory: scratch_test_dir is gitignored and absent in CI,
-- so io.open(SRC, "w") would silently fail there, leaving content_fingerprint()
-- unable to read the file and causing store() to abort without writing a snapshot.
local CACHE_DIR = (os.getenv("TMPDIR") or os.getenv("TMP") or "/tmp"):gsub("[/\\]+$", "")
local SRC = CACHE_DIR .. "/fake_hotstrings_" .. tostring(os.time()) .. ".toml"

-- content_fingerprint() opens the source file in binary mode to hash its bytes;
-- without a real file on disk, io.open returns nil and store() aborts silently.
do
	local fh = io.open(SRC, "w")
	if fh then fh:write("# fake toml content for fingerprinting"); fh:close() end
end

-- Controllable source attributes, read by the adapter via the stubbed hs.fs.
local cur_mtime, cur_size = 1000.5, 4242

local fs_override = {
	dir            = function(_) return function() return nil end end,
	pathToAbsolute = function(p) return p end,
	displayName    = function(p) return p end,
	mkdir          = function(_) return true end,
	attributes     = function(p)
		if p == SRC then
			return { modification = cur_mtime, size = cur_size }
		end
		-- Every other path (the cache dir + ancestors) reports as an existing
		-- directory so ensure_dir() succeeds without real mkdir.
		return { mode = "directory" }
	end,
}

local cache = helpers.load_with_stubs("adapters.toml_cache", { fs = fs_override })
cache.init(CACHE_DIR)

-- Mirror of the adapter's filename derivation so the test can clean up its
-- snapshot afterwards (kept in sync deliberately; documents the naming scheme).
local function snapshot_path(path)
	local h = 5381
	for i = 1, #path do h = (h * 33 + path:byte(i)) % 4294967296 end
	local base = (path:match("([^/\\]+)$") or "toml"):gsub("[^%w%.%-_]", "_")
	return CACHE_DIR .. "/" .. base .. "_" .. string.format("%d", h) .. ".lua"
end

local SAMPLE = {
	meta = {
		description    = { fr = "Réductions \"★\"", en = "Reductions" },
		sections       = { red = { description = "x", delay = 0.5, priority = 10 } },
		sections_order = { "red", "-" },
		section_delays = { red = 2.0 },
		delay          = 1.0,
		color          = "#ff0000",
		show_tooltip   = true,
		priority       = 75,
	},
	sections_order = { "red", "-" },
	sections = {
		red = {
			description = "Reductions",
			entries = {
				{
					trigger = "t\"x",  output = "y\nz", is_word = true, auto_expand = false,
					is_case_sensitive = false, final_result = true, priority = 90,
				},
				{ trigger = "★a", output = "\u{2192}", is_word = false },
			},
			is_placeholder = false,
		},
	},
}

helpers.describe("adapters.toml_cache: snapshot round-trip + invalidation", function()
	helpers.it("stores then loads a structurally identical table", function()
		helpers.assert_eq(cache.store(SRC, SAMPLE, cache.capture_source(SRC)), true)
		local loaded = cache.load(SRC)
		helpers.assert_true(loaded ~= nil, "snapshot should load on an unchanged source")
		helpers.assert_true(helpers.deep_equal(loaded, SAMPLE),
			"loaded snapshot must deep-equal the original parsed table")
		-- Spot-check the trickiest fields survive byte-exact.
		helpers.assert_eq(loaded.sections.red.entries[1].trigger, "t\"x")
		helpers.assert_eq(loaded.sections.red.entries[1].output, "y\nz")
		helpers.assert_eq(loaded.sections.red.entries[2].trigger, "★a")
		helpers.assert_eq(loaded.meta.description.fr, "Réductions \"★\"")
		helpers.assert_eq(loaded.meta.priority, 75)
		helpers.assert_eq(loaded.meta.delay, 1.0)
		helpers.assert_eq(loaded.sections.red.entries[1].is_word, true)
		helpers.assert_eq(loaded.sections.red.entries[1].auto_expand, false)
	end)

	helpers.it("rejects the snapshot when the source mtime changed", function()
		cur_mtime = 1000.5
		helpers.assert_eq(cache.store(SRC, SAMPLE, cache.capture_source(SRC)), true)
		cur_mtime = 2000.7  -- simulate the user editing the file
		helpers.assert_nil(cache.load(SRC), "a stale (mtime) snapshot must be a miss")
		cur_mtime = 1000.5
	end)

	helpers.it("rejects the snapshot when the source size changed", function()
		cur_size = 4242
		helpers.assert_eq(cache.store(SRC, SAMPLE, cache.capture_source(SRC)), true)
		cur_size = 9999  -- different byte count → different content
		helpers.assert_nil(cache.load(SRC), "a stale (size) snapshot must be a miss")
		cur_size = 4242
	end)

	helpers.it("misses cleanly when no snapshot exists yet", function()
		local fresh = SRC .. ".never_written"
		helpers.assert_nil(cache.load(fresh), "absent snapshot must be a miss, not an error")
	end)

	helpers.it("rejects a version-3 snapshot produced before BOM parsing was fixed", function()
		cur_mtime, cur_size = 1000.5, 4242
		local path = snapshot_path(SRC)
		local fh = assert(io.open(path, "w"), "cannot create legacy snapshot fixture")
		fh:write("return {ver=3,mtime=1000.5,size=4242,fp=0,wrote_at=2000,data={legacy=true}}\n")
		fh:close()
		helpers.assert_nil(cache.load(SRC),
			"a cache generated by the BOM-blind parser must be invalidated")
	end)

	helpers.it("is a no-op when the cache was never initialised", function()
		local disabled = helpers.load_with_stubs("adapters.toml_cache", { fs = fs_override })
		-- init() not called → _cache_dir nil.
		helpers.assert_nil(disabled.load(SRC), "disabled cache must always miss")
		helpers.assert_eq(disabled.store(SRC, SAMPLE), false)  -- must not raise
		helpers.assert_true(disabled.stats().enabled == false, "stats must report disabled")
	end)

	-- Cleanup: remove the snapshot and the temporary source file this run created.
	os.remove(snapshot_path(SRC))
	os.remove(SRC)
end)
