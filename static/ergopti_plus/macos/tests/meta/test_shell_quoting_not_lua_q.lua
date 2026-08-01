--- tests/meta/test_shell_quoting_not_lua_q.lua

--- ==============================================================================
--- MODULE: Shell-Quoting Guard Meta Test
--- DESCRIPTION:
--- Class-wide guard: a path interpolated into a shell command must be quoted for
--- POSIX sh, never with Lua's %q.
---
--- ROOT CAUSE ENCODED:
--- string.format("%q", path) escapes for a LUA literal. It quotes backslashes,
--- quotes and newlines, but leaves $, backticks and ! completely untouched — all
--- of which /bin/sh expands. Every one of these paths is user-configurable through
--- the config-directory setting, so a directory named with a "$" was interpolated
--- straight into a shell command.
---
--- The driver already knows the right answer: karabiner/generator.lua defines a
--- POSIX single-quoter for exactly this reason ("so neither key_code nor the log
--- path can be used for shell injection, e.g. a config dir containing an
--- apostrophe") and has its own regression test — which covers that ONE file. The
--- sibling call site 150 lines away in karabiner/init.lua used %q.
---
--- This guard enumerates the class instead: no driver source may build a shell
--- command with %q.
--- ==============================================================================

local helpers = require("tests.helpers")

local SOURCE_DIRS = { "adapters", "infra", "modules", "ui" }





-- ===========================================
-- ===========================================
-- ======= 1/ No %q In A Shell Command =======
-- ===========================================
-- ===========================================

--- Lists every driver .lua file under the given subtree.
--- @param dir string Absolute directory.
--- @param out table Accumulator.
local function collect(dir, out)
	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local function walk(path)
			for entry in lfs.dir(path) do
				if entry ~= "." and entry ~= ".." then
					local full = path .. "/" .. entry
					local attr = lfs.attributes(full)
					if attr and attr.mode == "directory" then walk(full)
					elseif entry:match("%.lua$") then out[#out + 1] = full end
				end
			end
		end
		walk(dir)
		return
	end
	local cmd = (package.config:sub(1, 1) == "\\")
		and ('cmd /c dir /b /s /a-d "' .. dir:gsub("/", "\\") .. '\\*.lua"')
		or ("find '" .. dir .. "' -type f -name '*.lua'")
	local pipe = io.popen(cmd)
	if not pipe then return end
	for line in pipe:lines() do
		local t = line:gsub("%s+$", ""):gsub("\\", "/")
		if t:match("%.lua$") then out[#out + 1] = t end
	end
	pipe:close()
end

helpers.describe("shell commands are POSIX-quoted, never %q-quoted", function()
	helpers.it("no driver source builds a shell command with a %q placeholder", function()
		local root, files = helpers.driver_root(), {}
		for _, d in ipairs(SOURCE_DIRS) do collect(root .. d, files) end
		helpers.assert_true(#files > 0,
			"the source walk must find driver .lua files — an empty list would make this guard vacuous")

		local offenders = {}
		for _, path in ipairs(files) do
			local fh = io.open(path, "r")
			if fh then
				local src = fh:read("*a") ; fh:close()
				local line_no = 0
				for line in (src .. "\n"):gmatch("([^\n]*)\n") do
					line_no = line_no + 1
					local code = line:gsub("%-%-.*$", "")
					-- A %q placeholder on a line that also builds a shell command.
					local has_q     = code:find("%q", 1, true) ~= nil
					local is_shell  = code:find("mkdir", 1, true) ~= nil
						or code:find("hs.execute", 1, true) ~= nil
						or code:find("os.execute", 1, true) ~= nil
					if has_q and is_shell then
						offenders[#offenders + 1] = path:gsub("^.*/macos/", "") .. ":" .. line_no
					end
				end
			end
		end

		helpers.assert_true(#offenders == 0, string.format(
			"%d shell command(s) quote a path with Lua's %%q. That escapes for a LUA "
			.. "literal and leaves $, backticks and ! untouched — all expanded by /bin/sh, "
			.. "and every one of these paths is user-configurable. Use the POSIX "
			.. "single-quoter karabiner/generator.lua already defines: %s",
			#offenders, table.concat(offenders, ", ")))
	end)
end)
