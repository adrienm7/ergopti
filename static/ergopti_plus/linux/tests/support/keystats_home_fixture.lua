--- tests/support/keystats_home_fixture.lua

--- ==============================================================================
--- MODULE: Keystats Own-Home Fixture
--- DESCRIPTION:
--- Runs one collector test inside a directory the test owns. The collector
--- derives its metrics database, its daily keystroke logs and the metrics flag
--- from HOME and the XDG roots, so a case that did not name every path itself
--- wrote them into the account's config. The fixture points HOME at its own
--- directory for the case and then proves that nothing else changed.
---
--- FEATURES & RATIONALE:
--- 1. The runner's HOME redirect (test.runner_home) is a safety net, not a
---    fixture: a test that relies on it still pollutes the shared scratch home
---    that the next test reads. Each case here runs in a home of its own.
--- 2. After the body, the tree of the HOME that was current before the case is
---    compared with its snapshot taken before: any created, removed or touched
---    file fails the case, naming it, so a path that escapes the fixture is a
---    red test rather than a silent write.
--- 3. The directory lives in the runner's scratch home and goes with it.
--- ==============================================================================

local M = {}

local XDG_VARIABLES = { XDG_CONFIG_HOME = true, XDG_DATA_HOME = true, XDG_STATE_HOME = true, XDG_CACHE_HOME = true }

-- The directory of the case in progress; nil outside one.
local _dir = nil

-- Where the fixture lives inside the runner's scratch home, which the runner
-- removes when it exits. One directory serves the whole run: the SQLite writer
-- pins the first database path it opens ("Cannot switch SQLite stores before
-- explicitly closing the current store"), so a directory per case would leave
-- every later case without a database. Removing it between cases is not an
-- option either, because a flush in flight keeps completing against it.
local FIXTURE_DIRECTORY = "keystats_fixture"

--- Quotes one argument for a POSIX shell.
--- @param value string
--- @return string
local function quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Lists every file below a directory with its size and modification time.
--- @param root string
--- @return string listing Sorted, one file per line.
local function snapshot(root)
	local pipe = assert(io.popen("find " .. quote(root) .. " -path " .. quote(root .. "/" .. FIXTURE_DIRECTORY)
		.. " -prune -o -type f -printf '%p\\t%s\\t%T@\\n' 2>/dev/null"))
	local lines = {}
	for line in pipe:lines() do lines[#lines + 1] = line end
	pipe:close()
	table.sort(lines)
	return table.concat(lines, "\n") .. "\n"
end

--- The path of a file or directory inside the case's own home.
--- @param relative string|nil
--- @return string
function M.path(relative)
	assert(_dir, "keystats_home_fixture.path: no case is running")
	return relative and (_dir .. "/" .. relative) or _dir
end

--- The options that name every collector path inside the case's own home.
--- @param extra table|nil Further init options.
--- @return table
function M.options(extra)
	local options = { sqlite_path = M.path("metrics.sqlite"), log_dir = M.path("logs") }
	for key, value in pairs(extra or {}) do options[key] = value end
	return options
end

--- A fresh database path: any file an earlier init of the case left is removed.
--- @return string
function M.fresh_db()
	os.remove(M.path("metrics.sqlite"))
	return M.path("metrics.sqlite")
end

--- Runs a body with HOME pointed at a fresh directory, then proves that the
--- previous HOME holds exactly what it held before.
--- @param body function
function M.run(body)
	assert(_dir == nil, "keystats_home_fixture.run: cases do not nest")
	local outer_home = assert(os.getenv("HOME"), "the runner must provide a HOME")
	local before = snapshot(outer_home)
	local own = outer_home .. "/" .. FIXTURE_DIRECTORY
	assert(os.execute("mkdir -p " .. quote(own) .. " 2>/dev/null"), "the fixture directory could not be created")
	_dir = own
	local getenv = os.getenv
	os.getenv = function(name)
		if name == "HOME" then return own end
		if XDG_VARIABLES[name] then return nil end
		return getenv(name)
	end
	local ok, failure = xpcall(body, debug.traceback)
	os.getenv = getenv
	_dir = nil
	local after = snapshot(outer_home)
	if not ok then error(failure, 0) end
	if after ~= before then
		error("the case wrote outside its own directory, in " .. outer_home .. ":\n--- before\n" .. before
			.. "--- after\n" .. after, 0)
	end
end

--- Registers one collector case that cannot read or write user preferences and
--- owns its home.
--- @param name string
--- @param body function
function M.it(name, body)
	require("tests.support.metrics_preferences_fixture").it(name, function() M.run(body) end)
end

return M
