--- tests/unit/lib/test_watcher_count_does_not_scale.lua

--- ==============================================================================
--- MODULE: Regression — no FSEvents stream may be armed per file or per directory
--- DESCRIPTION:
--- `watch_personal_hotstrings_dir` recursed the personal tree and armed one
--- `hs.pathwatcher` per DIRECTORY plus one per `.toml` FILE, and a second loop did
--- the same per file on the shared hotstrings directory. A user with fifty personal
--- hotstring files paid fifty-odd FSEvents streams, every one created
--- synchronously after the typing eventtap was already armed.
---
--- All of it was redundant: `hs.pathwatcher` is recursive and already reports the
--- individual changed paths, so one watcher on the root sees every event its
--- descendants did. The recursion's depth cap and `visited` cycle guard existed
--- only to survive a symlink loop that no longer has to be walked. The per-file
--- watchers were also strictly worse than the directory watcher they duplicated:
--- they applied neither `is_self_written` nor `is_runtime_artefact`, so a write the
--- driver made itself could trigger a reload through them.
---
--- ROOT CAUSE ENCODED:
--- A "safety net" that duplicated the mechanism it was protecting, arming one
--- stream per corpus entry. The invariant is structural — no watcher construction
--- inside a loop or a self-recursive walk — which is what makes the count
--- independent of the corpus.
---
--- PROVENANCE: source invariant, deliberately. A behavioural count is the obvious
--- shape and I wrote it first; it passed against the unfixed code, because the
--- setup function pcalls its own body and the corpus walk never ran under the
--- stubs, so both corpus sizes armed the same few watchers for the wrong reason.
--- An unproven behavioural test is worth less than a proven structural one.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Located by a symbol rather than a path, so the guard follows the code.
local ANCHOR = "script_watchers"

-- The construction this guard is about.
local CONSTRUCTOR = "hs.pathwatcher.new"




-- ==================================================================
-- ==================================================================
-- ======= 1/ No watcher is armed inside a loop =====================
-- ==================================================================
-- ==================================================================

helpers.describe("file watchers: no FSEvents stream is armed per corpus entry", function()

	helpers.it("constructs no pathwatcher inside a loop", function()
		local src = helpers.read_driver_source(ANCHOR)
		helpers.assert_true(src ~= nil and src ~= "",
			"the watcher setup must be locatable by '" .. ANCHOR .. "'; an empty corpus "
			.. "would make every assertion below vacuous")

		-- Comments stripped so the prose in this area — which discusses the removed
		-- per-file loop — is not read as the loop itself.
		local code = src:gsub("%-%-[^\n]*", "")

		-- Walk line by line tracking loop depth. A construction at depth > 0 is one
		-- stream per iteration, which is precisely what made the count scale.
		local depth, line_no, offenders = 0, 0, {}
		for line in (code .. "\n"):gmatch("([^\n]*)\n") do
			line_no = line_no + 1
			local opens_loop = line:match("^%s*for%s") ~= nil or line:match("^%s*while%s") ~= nil
			local closes = 0
			for _ in line:gmatch("%f[%w]end%f[%W]") do closes = closes + 1 end

			if depth > 0 and line:find(CONSTRUCTOR, 1, true) then
				table.insert(offenders, line_no .. ": " .. line:gsub("^%s+", ""):sub(1, 60))
			end
			if opens_loop then depth = depth + 1 end
			-- Only loop-closing `end`s matter; over-counting would end the window
			-- early and under-report, so the depth floor is zero.
			depth = math.max(0, depth - closes)
			if opens_loop and line:find("%f[%w]end%f[%W]") then depth = depth end
		end

		helpers.assert_true(code:find(CONSTRUCTOR, 1, true) ~= nil,
			"the file must still construct watchers; a rename would otherwise make the "
			.. "assertion below pass over a module that watches nothing")

		helpers.assert_eq(#offenders, 0,
			"a pathwatcher armed inside a loop is one FSEvents stream per corpus entry, "
			.. "created synchronously after the typing eventtap is already armed - and "
			.. "redundant, because hs.pathwatcher is recursive and already reports the "
			.. "individual changed paths: " .. table.concat(offenders, " | "))
	end)

	helpers.it("has no self-recursive watcher walk", function()
		local code = helpers.read_driver_source(ANCHOR):gsub("%-%-[^\n]*", "")

		-- The other half of the same shape: a function that walks the tree and calls
		-- itself per sub-directory, arming a watcher at each level.
		helpers.assert_true(code:find("watch_personal_hotstrings_dir", 1, true) == nil,
			"the recursive per-directory walk arms one stream per level. A single "
			.. "recursive watcher on the root covers the whole tree, which also retires "
			.. "the depth cap and the cycle guard that existed only to walk it safely")
	end)

	helpers.it("the loop detector really fires", function()
		-- Positive control. Without it a mistake in the depth tracking would make the
		-- absence assertion above pass over the very shape it forbids.
		local sample = 'for _, f in ipairs(list) do\n\tlocal w = hs.pathwatcher.new(f, cb)\nend\n'
		local depth, flagged = 0, false
		for line in sample:gmatch("([^\n]*)\n") do
			local opens = line:match("^%s*for%s") ~= nil or line:match("^%s*while%s") ~= nil
			local closes = 0
			for _ in line:gmatch("%f[%w]end%f[%W]") do closes = closes + 1 end
			if depth > 0 and line:find(CONSTRUCTOR, 1, true) then flagged = true end
			if opens then depth = depth + 1 end
			depth = math.max(0, depth - closes)
		end
		helpers.assert_true(flagged, "a construction inside a for loop must be flagged")
	end)

end)
