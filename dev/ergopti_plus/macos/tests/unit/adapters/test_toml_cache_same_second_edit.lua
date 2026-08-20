--- tests/unit/adapters/test_toml_cache_same_second_edit.lua

--- ==============================================================================
--- MODULE: Regression — a same-second edit past the fingerprint window must
---         invalidate the snapshot
--- DESCRIPTION:
--- The snapshot guard checks CACHE_VERSION, mtime and size. HFS+ stores mtime at
--- one-second resolution, so an edit landing in the same second as the cached
--- mtime, at an unchanged size, passes all three — which is precisely what the
--- content fingerprint exists for. But the fingerprint hashed only
--- `f:read(FINGERPRINT_READ_BYTES)`: the first 512 bytes. In this repo's hotstring
--- corpus the `[_meta]` preamble alone runs past that mark, so the evidence window
--- covered the header and none of the entries. A same-second edit to any actual
--- hotstring, at unchanged total length, was invisible and stale data was served
--- for the rest of the session.
---
--- ROOT CAUSE ENCODED:
--- A verifier whose evidence window does not overlap the data it verifies. The
--- assertion edits past byte 512 and asks whether the cache notices — not how wide
--- the hash is — so any fix that closes the window passes.
---
--- WHY THIS IS A NET SPEED-UP, which the second case pins. The ambiguity exists
--- ONLY when the snapshot was written in the same integer second as the source
--- mtime. If it was written in a strictly later second, any subsequent edit
--- necessarily moves mtime past it and the cheap mtime check already catches it —
--- so the unambiguous hit needs no content read at all, and one io.open plus a
--- read comes off every single cache hit.
---
--- HARNESS NOTE, because two attempts were lost to it: this drives REAL files.
--- `content_fingerprint` opens the source in binary mode, so a stubbed io.open is
--- fighting the module rather than testing it — and the stat stub must return
--- `modification`, not `mtime`, which is the field the adapter actually reads.
--- ==============================================================================

local helpers = require("tests.helpers")

local TMP = (os.getenv("TMPDIR") or os.getenv("TMP") or "/tmp"):gsub("[/\\]+$", "")
local CACHE_DIR = TMP
local SRC = TMP .. "/adapt4b_src_" .. tostring(os.time()) .. ".toml"

-- Long enough that the divergence sits well past the old 512-byte window.
local PREAMBLE = string.rep("# padding comment line\n", 40)

-- Identical LENGTH, differing only after the preamble, so neither mtime nor size
-- can distinguish them and the content check is the only defence left.
local BODY_A = PREAMBLE .. '[alpha]\ntrigger = "aaa"\noutput = "AAA"\n'
local BODY_B = PREAMBLE .. '[alpha]\ntrigger = "aaa"\noutput = "BBB"\n'

-- The stat values the adapter sees. Held in locals so a case can hold them still
-- while the file underneath changes — which is exactly the same-second scenario.
--
-- The mtime must be a REAL epoch second, not an arbitrary small number: the fix
-- compares the snapshot's wall-clock write time against floor(mtime), so a fake
-- mtime of 1000.5 makes every write look strictly later and the ambiguous branch
-- becomes unreachable. That is what an earlier version of this fixture did, and
-- it reported the fix as broken when the fixture was.
-- Deliberately NOT initialised from os.time() here. This value is read at store
-- time, and the ambiguous branch only exists while floor(mtime) equals the
-- second in which the snapshot was written. Fixing it at module-load time made
-- the case depend on how long the rest of the suite took to reach it: on a slow
-- run the clock had already advanced, the write looked strictly newer than the
-- stat, and the test failed claiming the fix was broken when the fixture was.
-- The case re-stamps it immediately before storing.
local cur_mtime, cur_size = 0, #BODY_A


--- Writes bytes to the shared source path.
--- @param bytes string
local function write_source(bytes)
	local fh = io.open(SRC, "wb")
	if fh then fh:write(bytes) fh:close() end
end


--- Loads a fresh toml_cache whose stat calls answer from the locals above.
--- @return table
local function fresh_cache()
	package.loaded["adapters.toml_cache"] = nil
	package.loaded["infra.logger"] = nil
	_ = helpers.load_with_stubs("infra.logger")

	local cache = helpers.load_with_stubs("adapters.toml_cache", {
		fs = {
			dir            = function(_) return function() return nil end end,
			pathToAbsolute = function(p) return p end,
			displayName    = function(p) return p end,
			mkdir          = function(_) return true end,
			attributes     = function(p)
				-- `modification`, not `mtime`: that is the field the adapter reads.
				if p == SRC then return { modification = cur_mtime, size = cur_size } end
				return { mode = "directory" }
			end,
		},
	})
	cache.init(CACHE_DIR)
	return cache
end




-- ==================================================================
-- ==================================================================
-- ======= 1/ The same-second edit is caught ========================
-- ==================================================================
-- ==================================================================

helpers.describe("toml_cache: a same-second edit past 512 bytes invalidates", function()

	helpers.it("notices a change beyond the old fingerprint window", function()
		helpers.assert_eq(#BODY_A, #BODY_B,
			"the two bodies must be the same length, or the size check would catch the edit "
			.. "and this case would prove nothing about the content check")
		helpers.assert_true(#PREAMBLE > 512,
			"the divergence must sit past the old 512-byte window, or the prefix hash would "
			.. "see it and there would be nothing to fix")

		write_source(BODY_A)
		cur_size = #BODY_A
		local cache = fresh_cache()
		-- Stamp the stat mtime into the SAME second the snapshot is written, which
		-- is the only condition under which the ambiguous branch is reachable.
		cur_mtime = os.time() + 0.5
		cache.store(SRC, { alpha = { "AAA" } })

		local hit = cache.load(SRC)
		helpers.assert_type(hit, "table",
			"the snapshot must be readable back before the edit, or the assertion below "
			.. "would pass simply because nothing was ever cached")

		-- The edit: same reported mtime, same size, different bytes past 512.
		write_source(BODY_B)

		helpers.assert_nil(cache.load(SRC),
			"the source changed after the snapshot, in the same second and at the same "
			.. "length, so mtime and size both match. The content check is the only thing "
			.. "that can see it, and hashing only the first 512 bytes cannot — in this "
			.. "repo's hotstring corpus the [_meta] preamble alone runs past that mark, so "
			.. "the window covered the header and none of the entries")
	end)

	helpers.it("still serves an unmodified source", function()
		-- Without this case the assertion above would pass against a cache that
		-- invalidates unconditionally, i.e. one that has been switched off.
		write_source(BODY_A)
		cur_size = #BODY_A
		local cache = fresh_cache()
		cache.store(SRC, { alpha = { "AAA" } })

		helpers.assert_type(cache.load(SRC), "table",
			"an untouched source must still hit; a cache that never hits is not a cache")
	end)

end)


-- Leave no artefacts behind: the source and the snapshot both live in TMPDIR.
os.remove(SRC)
