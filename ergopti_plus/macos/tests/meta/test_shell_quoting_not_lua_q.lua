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

local SOURCE_DIRS = { "adapters", "infra", "modules", "platform", "ui" }

local SHELL_CALL_PATTERNS = {
	"pcall%s*%(%s*hs%.execute%s*,",
	"pcall%s*%(%s*os%.execute%s*,",
	"pcall%s*%(%s*io%.popen%s*,",
	"hs%.execute%s*%(",
	"os%.execute%s*%(",
	"io%.popen%s*%(",
}

--- Returns the source span of a balanced Lua call starting at `call_at`.
--- Parentheses inside strings are deliberately counted too: they remain balanced
--- in every shell command in the driver, while the outer-call boundary is what
--- lets this guard see a formatter split across several lines.
--- @param source string Lua source.
--- @param call_at integer Start of the call expression.
--- @return string
local function balanced_call(source, call_at)
	local open_at = source:find("(", call_at, true)
	if not open_at then return source:sub(call_at) end
	local depth = 0
	for index = open_at, #source do
		local char = source:sub(index, index)
		if char == "(" then
			depth = depth + 1
		elseif char == ")" then
			depth = depth - 1
			if depth == 0 then return source:sub(call_at, index) end
		end
	end
	return source:sub(call_at)
end

--- Finds shell-call expressions that contain a Lua `%q` formatter.
--- @param source string Lua source.
--- @return table Array of one-based byte offsets.
local function lua_q_shell_calls(source)
	local offsets, seen = {}, {}
	for _, pattern in ipairs(SHELL_CALL_PATTERNS) do
		local from = 1
		while true do
			local call_at = source:find(pattern, from)
			if not call_at then break end
			local call = balanced_call(source, call_at)
			if call:find("%q", 1, true) and not seen[call_at] then
				seen[call_at] = true
				offsets[#offsets + 1] = call_at
			end
			from = call_at + 1
		end
	end
	table.sort(offsets)
	return offsets
end





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
				for _, call_at in ipairs(lua_q_shell_calls(src)) do
					local line_no = select(2, src:sub(1, call_at):gsub("\n", "")) + 1
					offenders[#offenders + 1] =
						path:gsub("^.*/macos/", "") .. ":" .. line_no
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

	helpers.it("recognises same-line and multiline shell formatters", function()
		local samples = {
			{ source = [[hs.execute(string.format("find %q", path))]], expected = 1 },
			{
				source = [[
local ok = pcall(hs.execute, string.format(
	"find %q -maxdepth 1",
	path
))]],
				expected = 1,
			},
			{ source = [[Logger.error(LOG, "path=%q", path)]], expected = 0 },
			{
				source = [[hs.execute(string.format("find %s", text_utils.shell_quote(path)))]],
				expected = 0,
			},
		}
		for index, sample in ipairs(samples) do
			helpers.assert_eq(#lua_q_shell_calls(sample.source), sample.expected,
				"shell-quoting scanner sample " .. tostring(index) .. " must be classified exactly")
		end
	end)
end)
