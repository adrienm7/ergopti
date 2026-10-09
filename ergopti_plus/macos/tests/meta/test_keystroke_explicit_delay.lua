--- tests/meta/test_keystroke_explicit_delay.lua

--- ==============================================================================
--- MODULE: keyStroke Explicit-Delay Guard Meta Test
--- DESCRIPTION:
--- Static source guard asserting that EVERY hs.eventtap.keyStroke() call site in
--- the driver passes an explicit delay argument.
---
--- ROOT CAUSE ENCODED:
--- hs.eventtap.keyStroke(modifiers, character[, delay, application]) defaults the
--- delay to 200 000 us and implements it as a BLOCKING usleep between the keyDown
--- and keyUp events. The sleep runs on the Hammerspoon main run loop — the same
--- loop that services the typing event tap — so every call site that omits the
--- argument stalls the driver for 200 ms per simulated keystroke. Sites that emit
--- several keystrokes in sequence multiply that (wrap_selection issued four,
--- ~800 ms), and one site sat INSIDE an eventtap callback, where a stall of that
--- length lets macOS disable the tap outright (kCGEventTapDisabledByTimeout) and
--- kills the shortcut permanently.
---
--- The driver already knew this: adapters/text_sender.lua's eraseChars/pressKey
--- both coerce the delay to 0, gestures/actions.lua's postKeyStroke() helper
--- passes 0, and keymap/utils.lua's paste path passes 0. The invariant was simply
--- applied per-site, and 49 sibling sites across gestures/actions.lua,
--- shortcuts/actions/{text,apps,system}.lua and the text_sender paste path never
--- got it — the recurring "one forgotten sibling" failure mode of this repo.
---
--- WHY A SOURCE SCAN AND NOT A BEHAVIOURAL TEST:
--- The delay is invisible at runtime in the harness: tests/stubs/hs.lua models
--- keyStroke as function(mods, key, delay) and records the third argument, but a
--- stub can never reproduce the real usleep. Only the source itself can prove the
--- argument is present. This test therefore enumerates the WHOLE CLASS — every
--- .lua file under the driver root — rather than pinning the sites that were
--- fixed, so a NEW call site added tomorrow without a delay fails CI too.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Source subtrees that ship in the driver. tests/, vendor/ and _generated/ are
-- excluded: stubs legitimately declare keyStroke with a two-argument signature.
local SOURCE_DIRS = { "adapters", "infra", "modules", "platform", "ui" }

-- Minimum argument count for a correct call: (modifiers, character, delay).
local REQUIRED_ARG_COUNT = 3





-- ====================================
-- ====================================
-- ======= 1/ Source Collection =======
-- ====================================
-- ====================================

--- Resolves the driver root from this test file's own location.
--- @return string root Absolute-ish path to the Hammerspoon driver root.
local function driver_root()
	local self = debug.getinfo(1, "S").source:gsub("^@", "")
	return self:match("^(.*)[/\\]tests[/\\]") or "."
end

--- Recursively lists every .lua file under a directory.
--- Prefers LuaFileSystem and falls back to a shell listing, mirroring the
--- discovery strategy already used by tests/run.lua.
--- @param dir string Absolute path to walk.
--- @param out table Accumulator receiving absolute file paths.
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





-- ===========================================
-- ===========================================
-- ======= 2/ Call-Site Argument Count =======
-- ===========================================
-- ===========================================

--- Counts top-level arguments of a call whose argument list starts at `from`.
--- Commas nested inside braces, brackets or parentheses do not separate
--- arguments, so depth is tracked and only depth-0 commas are counted.
--- @param src string Source with comments already stripped.
--- @param from integer Index of the first character after the opening delimiter.
--- @return integer count Number of top-level arguments.
local function count_args(src, from)
	local depth, count, saw_content = 0, 0, false
	for i = from, #src do
		local c = src:sub(i, i)
		if c == "(" or c == "{" or c == "[" then
			depth = depth + 1
			saw_content = true
		elseif c == ")" or c == "}" or c == "]" then
			if depth == 0 then
				return saw_content and (count + 1) or 0
			end
			depth = depth - 1
		elseif c == "," and depth == 0 then
			count = count + 1
		elseif not c:match("%s") then
			saw_content = true
		end
	end
	return saw_content and (count + 1) or 0
end

--- Finds every keyStroke call site in one source string that passes fewer than
--- REQUIRED_ARG_COUNT arguments.
--- Two call shapes exist in this codebase:
---   hs.eventtap.keyStroke(mods, key[, delay])   -- direct
---   pcall(hs.eventtap.keyStroke, mods, key[, delay])  -- pcall-wrapped
--- @param src string Raw file contents.
--- @return table offenders List of { line = integer, text = string }.
local function find_offenders(src)
	-- Strip line comments so a documented example never counts as a call site.
	local stripped = src:gsub("%-%-[^\n]*", "")
	local offenders = {}

	local pos = 1
	while true do
		local s, e = stripped:find("keyStroke", pos, true)
		if not s then break end
		pos = e + 1

		-- Reject identifiers that merely END with "keyStroke" (postKeyStroke).
		local prev = s > 1 and stripped:sub(s - 1, s - 1) or ""
		if not prev:match("[%w_]") then
			-- Skip "keyStrokes" (a different API with no delay parameter).
			local next_char = stripped:sub(e + 1, e + 1)
			if next_char ~= "s" then
				local rest  = stripped:sub(e + 1)
				local open  = rest:match("^%s*%(")
				local comma = rest:match("^%s*,")
				local args  = nil
				if open then
					args = count_args(stripped, e + #open + 1)
				elseif comma then
					-- pcall(fn, ...) form: arguments follow the comma.
					args = count_args(stripped, e + #comma + 1)
				end
				if args and args > 0 and args < REQUIRED_ARG_COUNT then
					local upto = stripped:sub(1, s)
					local _, line = upto:gsub("\n", "")
					offenders[#offenders + 1] = { line = line + 1 }
				end
			end
		end
	end
	return offenders
end





-- ============================
-- ============================
-- ======= 3/ The Guard =======
-- ============================
-- ============================

helpers.describe("keyStroke call sites: explicit delay argument", function()
	helpers.it("no driver source calls hs.eventtap.keyStroke without an explicit delay", function()
		local root  = driver_root()
		local files = {}
		for _, dir in ipairs(SOURCE_DIRS) do
			collect_lua_files(root .. "/" .. dir, files)
		end
		-- init.lua sits at the driver root rather than in a subtree.
		files[#files + 1] = root .. "/init.lua"

		helpers.assert_true(#files > 0,
			"the source walk must find driver .lua files — an empty list would make this guard vacuous")

		local report, total = {}, 0
		for _, path in ipairs(files) do
			local fh = io.open(path, "r")
			if fh then
				local src = fh:read("*a")
				fh:close()
				for _, off in ipairs(find_offenders(src)) do
					total = total + 1
					local rel = path:gsub("^" .. root:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1") .. "[/\\]?", "")
					report[#report + 1] = string.format("%s:%d", rel, off.line)
				end
			end
		end

		helpers.assert_true(total == 0, string.format(
			"%d hs.eventtap.keyStroke call site(s) omit the explicit delay argument and therefore "
			.. "block the main run loop for 200 ms each (macOS may disable the typing event tap): %s",
			total, table.concat(report, ", ")))
	end)
end)
