--- tests/unit/meta/test_interactive_actions_do_not_block_runloop.lua

--- ==============================================================================
--- MODULE: Regression — user-triggered actions must not freeze the runloop
--- DESCRIPTION:
--- `hs.execute` and `hs.osascript.applescript` are SYNCHRONOUS: they block the
--- single Hammerspoon runloop until the subprocess exits. While they run, the
--- keyboard tap receives nothing — and a tap whose callback misses the system
--- deadline is disabled by macOS outright, which is the outage
--- `test_event_taps_recover_when_disabled.lua` covers. `open` waits on Launch
--- Services, `screencapture` on the window server, `python3` on interpreter
--- startup, and the Finder AppleScript walks every open window; each is tens to
--- hundreds of milliseconds of a completely frozen driver, on a keystroke.
---
--- ROOT CAUSE ENCODED:
--- Not "one action is slow" but "the interactive layer reaches for the blocking
--- API at all". `hs.timer.doAfter(0, …)` is NOT the fix and several sites already
--- used it: the deferral gets the call out of the tap callback, so it protects
--- the tap deadline, but the timer body runs on that same single runloop — it
--- moves the freeze rather than removing it. Only an asynchronous subprocess
--- does. The scan is therefore over the whole layer and does not accept a
--- deferral as an excuse.
---
--- Scope is deliberately the INTERACTIVE layer. Boot, menu-build and onboarding
--- code also calls hs.execute, and blocking there is a different trade-off that
--- this guard does not pretend to judge.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Directories whose code runs in direct response to a live user input event.
local INTERACTIVE_DIRS = {
	"modules/shortcuts/actions",
	"modules/gestures",
}

-- The synchronous APIs. Both block the runloop until the child process exits.
local BLOCKING_CALLS = {
	{ pattern = "hs%.execute%s*[%(,]", name = "hs.execute" },
	-- Matches both `hs.osascript.applescript` and a module-local alias such as
	-- `local osascript = require("hs.osascript")`, without double-counting the
	-- first as two separate offences.
	{ pattern = "osascript%.applescript", name = "osascript.applescript" },
}





-- ==================================================================
-- ==================================================================
-- ======= 1/ No blocking subprocess in the interactive layer =======
-- ==================================================================
-- ==================================================================

--- Lists driver `.lua` files under one relative directory, recursively.
--- @param rel_dir string Directory relative to the driver root.
--- @return table Array of paths relative to the driver root.
local function lua_files_under(rel_dir)
	local root = helpers.driver_root()
	local out  = {}

	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local function walk(dir)
			for entry in lfs.dir(root .. dir) do
				if entry ~= "." and entry ~= ".." then
					local rel  = dir .. "/" .. entry
					local attr = lfs.attributes(root .. rel)
					if attr and attr.mode == "directory" then
						walk(rel)
					elseif entry:match("%.lua$") then
						out[#out + 1] = rel
					end
				end
			end
		end
		walk(rel_dir)
		return out
	end

	-- Shell fallback. It must cover the SAME set as the lfs branch: a meta test
	-- on this driver was once green without lfs and blind with it, because only
	-- one branch reached part of the tree.
	local sep = package.config:sub(1, 1)
	local abs = root .. rel_dir
	local cmd = (sep == "\\")
		and ('cmd /c dir /b /s /a-d "' .. abs:gsub("/", "\\") .. '\\*.lua"')
		or ("find '" .. abs .. "' -type f -name '*.lua'")
	local pipe = io.popen(cmd)
	if not pipe then return out end
	for line in pipe:lines() do
		out[#out + 1] = (line:gsub("\\", "/"):gsub(".*/macos/", ""))
	end
	pipe:close()
	return out
end


helpers.describe("interactive actions: no synchronous subprocess on a user-triggered path", function()

	helpers.it("no blocking hs.execute or AppleScript call survives in the interactive layer", function()
		local root      = helpers.driver_root()
		local offenders = {}
		local scanned   = 0

		for _, dir in ipairs(INTERACTIVE_DIRS) do
			local files = lua_files_under(dir)
			helpers.assert_true(#files > 0,
				"the walker must reach " .. dir .. "; an empty list would make this vacuous")
			for _, rel in ipairs(files) do
				local fh = io.open(root .. rel, "r")
				if fh then
					local src = fh:read("*a")
					fh:close()
					scanned = scanned + 1
					-- Comments stripped: a file must not satisfy — or violate — this
					-- guard by discussing the API in prose. This very file names all
					-- three spellings in its own header.
					local code = src:gsub("%-%-[^\n]*", "")
					for _, call in ipairs(BLOCKING_CALLS) do
						local _, n = code:gsub(call.pattern, "")
						if n > 0 then
							table.insert(offenders, string.format("%s (%dx %s)", rel, n, call.name))
						end
					end
				end
			end
		end

		helpers.assert_true(scanned >= 5,
			"the scan must actually read the interactive-action files; a broken path would "
			.. "report a clean layer that was never opened")
		helpers.assert_eq(#offenders, 0,
			"these run on a keystroke or a gesture and freeze the ENTIRE driver until the "
			.. "child process exits — long enough for macOS to disable the typing tap. "
			.. "Route them through the async adapter (ShellRunner.open / .applescript / "
			.. ".spawn); hs.timer.doAfter(0, …) only moves the freeze, it does not remove "
			.. "it, because the timer body runs on the same runloop: "
			.. table.concat(offenders, ", "))
	end)

	helpers.it("the scanner would catch a blocking call if one were reintroduced", function()
		-- Without this case the assertion above would pass against a pattern that
		-- matches nothing at all — the exact false green this suite tracks.
		local sample = 'local x = 1\npcall(hs.execute, "open /tmp")\n'
		local hits = 0
		for _, call in ipairs(BLOCKING_CALLS) do
			local _, n = sample:gsub(call.pattern, "")
			hits = hits + n
		end
		helpers.assert_true(hits > 0, "the pattern set must match a real blocking call")

		local prose_only = '-- hs.execute is blocking, so we avoid it\nlocal y = 2\n'
		local prose_hits = 0
		local stripped = prose_only:gsub("%-%-[^\n]*", "")
		for _, call in ipairs(BLOCKING_CALLS) do
			local _, n = stripped:gsub(call.pattern, "")
			prose_hits = prose_hits + n
		end
		helpers.assert_eq(prose_hits, 0, "and must not fire on a comment that merely names it")
	end)

end)
