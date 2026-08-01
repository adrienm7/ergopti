--- tests/unit/meta/test_event_taps_recover_when_disabled.lua

--- ==============================================================================
--- MODULE: Regression — every event tap must survive being disabled by macOS
--- DESCRIPTION:
--- macOS disables an event tap whose callback overruns the system deadline and
--- delivers a `tapDisabledByTimeout` event to that callback instead. The tap
--- stays allocated, `isEnabled()` alone is never consulted again, and no error is
--- raised — so a tap that is disabled once is disabled forever. On the typing tap
--- that is the whole driver going silent; on a tooltip's dismissal tap it is a
--- panel that can no longer be closed.
---
--- ROOT CAUSE ENCODED:
--- Not "the typing tap dies" but "a tap owner has no code path that reacts to
--- being disabled". Exactly one of the driver's taps handled it — the gesture
--- primer — and it handled it inline, which is why the other twelve owners were
--- never compared against it. The scan below is over the WHOLE class: any file
--- that creates a tap must also react to that tap being switched off, by any
--- spelling. Per PROJECT_MEMORY's `project-ahk-invariant-incomplete-application`,
--- the recurring failure on this codebase is the one sibling site that was
--- missed, so a per-file allowlist is exactly the wrong shape for this guard.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Directories that ship runtime tap owners. `tests/` is excluded by the walker.
local SCANNED_DIRS = { "modules", "infra", "adapters", "ui" }

-- The constructor that makes a file a tap owner.
local TAP_CONSTRUCTOR = "eventtap%.new"

-- Any of these spellings proves the file reacts to the OS switching a tap off:
-- the shared guard, or the inline comparison the gesture primer already used.
local RECOVERY_MARKERS = {
	"event_tap_guard",
	"EventTapGuard",
	"handle_disabled",
	"tapDisabledByTimeout",
}




-- ==================================================================
-- ==================================================================
-- ======= 1/ Every tap owner reacts to being disabled ==============
-- ==================================================================
-- ==================================================================

--- Collects every driver `.lua` under the scanned directories.
---
--- The lfs path and the shell fallback must cover the SAME set: an earlier meta
--- test on this driver was green on machines without lfs and blind on machines
--- with it, because only one of its two branches reached the root sources.
--- @return table Array of paths relative to the driver root.
local function all_tap_sources()
	local root = helpers.driver_root()
	local out  = {}

	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local function walk(dir)
			for entry in lfs.dir(root .. dir) do
				if entry ~= "." and entry ~= ".." then
					local rel  = dir .. entry
					local attr = lfs.attributes(root .. rel)
					if attr and attr.mode == "directory" then
						walk(rel .. "/")
					elseif entry:match("%.lua$") then
						out[#out + 1] = rel
					end
				end
			end
		end
		for _, d in ipairs(SCANNED_DIRS) do walk(d .. "/") end
		return out
	end

	local sep = package.config:sub(1, 1)
	local cmd = (sep == "\\")
		and ('cmd /c dir /b /s /a-d "' .. root:gsub("/", "\\") .. '*.lua"')
		or ("find '" .. root .. "' -type f -name '*.lua'")
	local pipe = io.popen(cmd)
	if not pipe then return out end
	for line in pipe:lines() do
		local rel = line:gsub("\\", "/"):gsub(".*/macos/", "")
		local keep = false
		for _, d in ipairs(SCANNED_DIRS) do
			if rel:sub(1, #d + 1) == d .. "/" then keep = true break end
		end
		if keep and not rel:find("/tests/", 1, true) then out[#out + 1] = rel end
	end
	pipe:close()
	return out
end


helpers.describe("event taps: a tap disabled by macOS must not stay disabled", function()

	helpers.it("every file that creates a tap also reacts to that tap being switched off", function()
		local root  = helpers.driver_root()
		local files = all_tap_sources()
		helpers.assert_true(#files > 100,
			"the walker must actually reach the driver sources; a broken path would make "
			.. "every assertion below vacuous")

		local owners, unguarded = 0, {}
		for _, rel in ipairs(files) do
			local fh = io.open(root .. rel, "r")
			if fh then
				local src = fh:read("*a")
				fh:close()
				-- Comments are stripped so a file cannot satisfy the guard by
				-- merely NAMING it in prose — including this very test's own
				-- explanatory style of comment.
				local code = src:gsub("%-%-[^\n]*", "")
				if code:find(TAP_CONSTRUCTOR) then
					owners = owners + 1
					local guarded = false
					for _, marker in ipairs(RECOVERY_MARKERS) do
						if code:find(marker, 1, true) then guarded = true break end
					end
					if not guarded then
						table.insert(unguarded, rel)
					end
				end
			end
		end

		helpers.assert_true(owners >= 10,
			"the scan must find the driver's tap owners; a pattern that matches nothing "
			.. "would let this test pass over a driver with no recovery at all")
		helpers.assert_eq(#unguarded, 0,
			"a tap disabled by macOS is never re-enabled on its own and raises nothing, so "
			.. "these owners go permanently deaf with no log line: "
			.. table.concat(unguarded, ", "))
	end)

end)
