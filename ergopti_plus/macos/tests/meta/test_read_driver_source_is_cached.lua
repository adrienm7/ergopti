--- tests/meta/test_read_driver_source_is_cached.lua

--- ==============================================================================
--- MODULE: read_driver_source Caching Contract
--- DESCRIPTION:
--- Guards the memoisation of helpers.read_driver_source — the symbol-keyed scan
--- that every move-resilient source invariant in this suite goes through.
---
--- FEATURES & RATIONALE:
--- 1. The scan is the PRESCRIBED alternative to naming a production path, so its
---    cost decides whether writing a source invariant correctly is cheap or
---    expensive. It used to re-shell `dir`/`find` and re-read all 201 production
---    files on every one of the several hundred call sites — ~1.2 GB of file I/O
---    per suite run — which made the honest way to write these tests the slow
---    one. Caching halved the suite's wall clock.
--- 2. The regression this encodes is not "it is fast" but "it scans ONCE": a
---    revert to per-call scanning is invisible in every existing assertion,
---    because the answers are identical either way. Only the call count differs.
--- 3. A failed scan must not be cached. Caching an empty result would make every
---    later call return nil, and a source invariant handed nil passes vacuously —
---    the whole suite would go green by asserting nothing.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ================================================
-- ================================================
-- ======= 1/ The scan happens at most once =======
-- ================================================
-- ================================================

helpers.describe("read_driver_source: the production tree is scanned once per process", function()
	helpers.it("two reads do not shell out twice", function()
		-- Counted rather than asserted equal to 1: by the time this file runs the
		-- cache may already be primed by an earlier test, in which case the honest
		-- answer is 0. Both 0 and 1 are correct; an uncached implementation scores
		-- 2 and fails, which is what makes this falsifiable in either state.
		local real_popen = io.popen
		local calls = 0
		io.popen = function(...)
			calls = calls + 1
			return real_popen(...)
		end

		local ok, err = pcall(function()
			helpers.read_driver_source("local function")
			helpers.read_driver_source("local function")
		end)

		io.popen = real_popen
		helpers.assert_true(ok, "read_driver_source must not raise: " .. tostring(err))
		helpers.assert_true(calls <= 1,
			"the production tree must be scanned at most once per process, not once per call "
				.. "(observed " .. tostring(calls) .. " scan(s) across two reads)")
	end)

	helpers.it("repeated reads of the same symbol return the same source", function()
		local first = helpers.read_driver_source("local function")
		local second = helpers.read_driver_source("local function")
		helpers.assert_true(first ~= nil, "the driver tree must be readable")
		helpers.assert_eq(#first, #second,
			"a cache that returned a different answer on the second call would make every "
				.. "source invariant order-dependent")
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 2/ The selector still selects ====
-- ==========================================
-- ==========================================

helpers.describe("read_driver_source: the cache did not turn the filter into a passthrough", function()
	helpers.it("an unmatched symbol returns nil, not the whole tree", function()
		-- A cache that answered every call with the full concatenation would keep
		-- every existing test green while silently widening what each one inspects.
		local none = helpers.read_driver_source("SYMBOL_THAT_CANNOT_EXIST_IN_ANY_PRODUCTION_FILE")
		helpers.assert_true(none == nil,
			"a symbol present in no production file must return nil, so a test whose selector "
				.. "goes stale fails loudly instead of scanning everything")
	end)

	helpers.it("a selector narrows the result", function()
		local all = helpers.read_driver_source(nil)
		local narrowed = helpers.read_driver_source("hs.shutdownCallback")
		helpers.assert_true(all ~= nil and narrowed ~= nil,
			"both the unfiltered and the filtered read must find source")
		helpers.assert_true(#narrowed < #all,
			"filtering by a symbol must return strictly less than the whole tree")
	end)
end)
