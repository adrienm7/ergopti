--- tests/meta/test_gestures_engine_pos_clone.lua

--- ==============================================================================
--- MODULE: Gestures Engine Position Clone Meta Test
--- DESCRIPTION:
--- Static source guard for the "gesture-engine-table-mutation" audit finding in
--- modules/gestures/engine.lua.
---
--- ROOT CAUSE ENCODED:
--- When a gesture started or was rebased, both `gs.startPos` and `gs.endPos` were
--- assigned to the same `pos` table returned by `avgPos(touches)`:
---
---     gs.startPos = pos
---     gs.endPos   = pos
---
--- The centroid-jump compensator later mutated `gs.startPos.x` and `gs.startPos.y`
--- IN PLACE to absorb a finger-count-change jump. Because both fields aliased the
--- same table, this mutation also corrupted `gs.endPos.x`/`y`, producing wrong
--- displacement calculations until `gs.endPos = pos` reset it on the same frame.
---
--- The aliasing was harmless in the common path (endPos is overwritten before
--- being read again), but it is a subtle trap: any new code reading gs.endPos
--- between the mutation and the overwrite would silently see wrong coordinates.
---
--- The fix clones pos at every site where both startPos and endPos are assigned
--- simultaneously: `gs.startPos = {x = pos.x, y = pos.y}`.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

local function read_source(rel)
	local fh = io.open(DRIVER_ROOT .. rel, "r")
	assert(fh, "cannot open " .. rel)
	local src = fh:read("*a")
	fh:close()
	return src
end

local function strip_comments(src)
	local out = {}
	for line in src:gmatch("[^\n]*") do
		if not line:match("^%s*%-%-") then
			out[#out + 1] = line
		end
	end
	return table.concat(out, "\n")
end


-- =============================================================================
-- =============================================================================
-- ======= 1/ gs.startPos is always cloned, never aliased to pos table =========
-- =============================================================================
-- =============================================================================

helpers.describe("gestures/engine.lua: position table clone (gesture-engine-table-mutation)", function()

	helpers.it("gs.startPos is assigned as a cloned table, not a direct reference", function()
		local src = strip_comments(read_source("modules/gestures/engine.lua"))

		-- Every occurrence of gs.startPos = ... must use the clone form
		-- {x = pos.x, y = pos.y}, not a bare `= pos`
		helpers.assert_true(
			src:match("gs%.startPos%s*=%s*{%s*x%s*=") ~= nil,
			"gestures/engine.lua must clone pos when assigning gs.startPos (gesture-engine-table-mutation)")

		-- The bare aliasing form must no longer appear for startPos
		helpers.assert_true(
			src:match("gs%.startPos%s*=%s*pos\n") == nil
			and src:match("gs%.startPos%s*=%s*pos\r") == nil,
			"gestures/engine.lua must NOT assign gs.startPos = pos (bare alias) — use {x=pos.x,y=pos.y} (gesture-engine-table-mutation)")
	end)

	helpers.it("gs.endPos is assigned as a cloned table at rebase sites", function()
		local src = strip_comments(read_source("modules/gestures/engine.lua"))

		-- The simultaneous startPos+endPos rebase sites must both clone
		helpers.assert_true(
			src:match("gs%.endPos%s*=%s*{%s*x%s*=") ~= nil,
			"gestures/engine.lua must clone pos when assigning gs.endPos at rebase sites (gesture-engine-table-mutation)")
	end)

end)
