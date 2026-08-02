--- tests/meta/test_no_sync_toml_formatter.lua

--- ==============================================================================
--- MODULE: Synchronous TOML-Formatter Guard Meta Test
--- DESCRIPTION:
--- Class-wide guard asserting that NO driver source shells out to the Python TOML
--- formatter on a save path, and that no source still builds a repo-root path from
--- the "static/drivers/" layout that this tree has not used since the move to
--- static/ergopti_plus/.
---
--- ROOT CAUSE ENCODED:
--- Two defects always travelled together, because the second was copy-pasted from
--- the first:
---   1. os.execute("python3 <...>/format_toml.py <prefs>") runs a full interpreter
---      startup SYNCHRONOUSLY on the Hammerspoon main run loop — the loop that
---      services the typing event tap — on every preferences save.
---   2. The script path was derived with gsub("static[/\\]drivers[/\\].*$", ""),
---      a pattern that matches nothing in the current layout. The gsub returns the
---      unchanged script dir, so the resolved path pointed at a file that does not
---      exist and the reformat silently never happened. The cost was paid, the
---      benefit never delivered, and pcall swallowed the failure.
---
--- WHY THIS TEST IS CLASS-WIDE:
--- Both defects were found and fixed in platform/remap/config.lua, and pinned
--- by tests/unit/platform/remap/test_config_repo_root.lua. That guard asserts
--- against ONE file, so the identical copy in infra/preferences.lua — on the
--- hotter path of the two, since every menu toggle calls save_prefs() — survived
--- untouched. This test therefore enumerates every driver source file instead of
--- naming one, which is the documented lesson of
--- project-ahk-guard-tests-must-loop-the-class.
---
--- The formatter is cosmetic only: both call sites already serialise through
--- TomlCodec.encode, which emits valid TOML on its own.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Driver subtrees to scan. tests/ is excluded so this file's own documentation of
-- the forbidden strings does not trip the guard.
local SOURCE_DIRS = { "adapters", "infra", "modules", "platform", "ui" }

-- The two forbidden markers, with the reason each one is banned.
local FORBIDDEN = {
	{
		needle = "format_toml.py",
		reason = "shells out to the Python TOML formatter synchronously on a save path "
			.. "(full interpreter startup on the main run loop; TomlCodec.encode already emits valid TOML)",
	},
	{
		needle = "static/drivers/",
		reason = "builds a repo-root path from the pre-move static/drivers/ layout, "
			.. "a pattern that matches nothing today and silently resolves to a non-existent file",
	},
}





-- ====================================
-- ====================================
-- ======= 1/ Source Collection =======
-- ====================================
-- ====================================

--- Resolves the driver root from this test file's own location.
--- @return string root Path to the Hammerspoon driver root.
local function driver_root()
	local self = debug.getinfo(1, "S").source:gsub("^@", "")
	return self:match("^(.*)[/\\]tests[/\\]") or "."
end

--- Recursively lists every .lua file under a directory.
--- Mirrors the lfs-then-shell discovery strategy used by tests/run.lua.
--- @param dir string Directory to walk.
--- @param out table Accumulator receiving file paths.
local function collect_lua_files(dir, out)
	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local function walk(path)
			for entry in lfs.dir(path) do
				if entry ~= "." and entry ~= ".." then
					local full = path .. "/" .. entry
					local attr = lfs.attributes(full)
					if attr and attr.mode == "directory" then
						walk(full)
					elseif entry:match("%.lua$") then
						out[#out + 1] = full
					end
				end
			end
		end
		walk(dir)
		return
	end

	local cmd
	if package.config:sub(1, 1) == "\\" then
		cmd = string.format('cmd /c dir /b /s /a-d "%s\\*.lua"', dir:gsub("/", "\\"))
	else
		cmd = string.format("find '%s' -type f -name '*.lua'", dir)
	end
	local pipe = io.popen(cmd)
	if not pipe then return end
	for line in pipe:lines() do
		local trimmed = line:gsub("%s+$", ""):gsub("\\", "/")
		if trimmed:match("%.lua$") then out[#out + 1] = trimmed end
	end
	pipe:close()
end





-- ==============================
-- ==============================
-- ======= 2/ The Guard =========
-- ==============================
-- ==============================

helpers.describe("no driver source runs the Python TOML formatter synchronously", function()
	helpers.it("no source references format_toml.py or the static/drivers/ repo-root pattern", function()
		local root  = driver_root()
		local files = {}
		for _, dir in ipairs(SOURCE_DIRS) do
			collect_lua_files(root .. "/" .. dir, files)
		end
		files[#files + 1] = root .. "/init.lua"

		helpers.assert_true(#files > 0,
			"the source walk must find driver .lua files — an empty list would make this guard vacuous")

		for _, entry in ipairs(FORBIDDEN) do
			local offenders = {}
			for _, path in ipairs(files) do
				local fh = io.open(path, "r")
				if fh then
					local src = fh:read("*a")
					fh:close()
					-- Normalise separators so the Windows form of the pattern is caught too.
					local normalised = src:gsub("\\\\", "/"):gsub("%[/\\%]", "/")
					if normalised:find(entry.needle, 1, true) then
						offenders[#offenders + 1] = path:gsub("^.*[/\\]macos[/\\]", "")
					end
				end
			end
			helpers.assert_true(#offenders == 0, string.format(
				"%d file(s) still contain %q — %s: %s",
				#offenders, entry.needle, entry.reason, table.concat(offenders, ", ")))
		end
	end)
end)
